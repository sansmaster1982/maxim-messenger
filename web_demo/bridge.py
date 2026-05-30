"""
Мост браузер <-> MAX (api.oneme.ru).

Зачем: браузер не умеет открывать raw-TLS к oneme.ru. Этот скрипт держит
TLS-соединение с MAX и пробрасывает протокол в браузер через WebSocket.
На каждое WS-подключение — отдельное TLS-соединение к MAX.

Зависимости: только msgpack (стандартный websocket реализован вручную на
asyncio + stdlib, чтобы не требовать pip install).

Запуск:  python bridge.py   (слушает ws://127.0.0.1:8765)

Протокол браузер -> мост (JSON):
  {"action":"login","token":"<auth-token>"}
  {"action":"chats"}
  {"action":"history","chatId":123,"from":0,"count":50}
  {"action":"send","chatId":123,"text":"привет"}
  {"action":"profile"}

Мост -> браузер (JSON):
  {"type":"login_ok","profile":{...},"chats":[...]}
  {"type":"login_error","message":"..."}
  {"type":"chats","items":[...]}
  {"type":"history","chatId":123,"messages":[...]}
  {"type":"sent","chatId":123,"messageId":...}
  {"type":"message", ... }   # входящий push
  {"type":"error","message":"..."}
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import re
import ssl
import struct
import time
import uuid

import msgpack

HOST = "api.oneme.ru"
PORT = 443
PROTO_VER = 10
APP_VERSION = "26.15.0"

WS_HOST = "127.0.0.1"
WS_PORT = 8765
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ════════════════════════════ MAX protocol ════════════════════════════

class MaxConn:
    """Одно TLS-соединение к MAX + reader loop."""

    def __init__(self, on_push):
        self.device_id = str(uuid.uuid4())
        self._reader = None
        self._writer = None
        self._seq = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._reader_task = None
        self._closed = False
        self._on_push = on_push
        self.token = None
        self.my_id = None

    async def connect(self):
        ctx = ssl.create_default_context()
        self._reader, self._writer = await asyncio.open_connection(
            HOST, PORT, ssl=ctx
        )
        self._closed = False
        self._reader_task = asyncio.create_task(self._reader_loop())
        cmd, _, _, _ = await self._request(6, {
            "userAgent": {
                "deviceType": "ANDROID",
                "locale": "ru",
                "appVersion": APP_VERSION,
            },
            "deviceId": self.device_id,
        })
        if cmd != 1:
            raise RuntimeError(f"INIT failed cmd={cmd}")

    async def close(self):
        self._closed = True
        if self._reader_task:
            self._reader_task.cancel()
        if self._writer:
            try:
                self._writer.close()
                await self._writer.wait_closed()
            except Exception:
                pass

    async def _reader_loop(self):
        try:
            while not self._closed:
                header = await self._reader.readexactly(10)
                cmd = header[1]
                resp_seq = (header[2] << 8) | header[3]
                length_raw = (
                    (header[6] << 24) | (header[7] << 16)
                    | (header[8] << 8) | header[9]
                )
                payload_len = length_raw & 0x00FFFFFF
                body = b""
                if payload_len:
                    body = await self._reader.readexactly(payload_len)
                decoded = self._unpack(body)
                fut = self._pending.pop(resp_seq, None)
                if fut and not fut.done():
                    fut.set_result((cmd, resp_seq, decoded, body))
                    continue
                # push
                msg = self._parse_push(decoded, body)
                if msg and self._on_push:
                    await self._on_push(msg)
        except (asyncio.IncompleteReadError, asyncio.CancelledError):
            pass
        except Exception as e:
            print("reader loop error:", e)

    @staticmethod
    def _unpack(data: bytes):
        if not data:
            return None
        for off in (0, 1, 2, 3, 4):
            try:
                return msgpack.unpackb(data[off:], raw=False,
                                       strict_map_key=False)
            except Exception:
                pass
        return None

    async def _request(self, opcode: int, payload: dict, timeout=30.0):
        if self._writer is None:
            raise RuntimeError("not connected")
        seq = self._seq
        self._seq = (self._seq + 1) & 0xFFFF
        body = msgpack.packb(payload, use_bin_type=True)
        header = bytearray(10)
        header[0] = PROTO_VER
        header[1] = 0
        header[2] = (seq >> 8) & 0xFF
        header[3] = seq & 0xFF
        header[4] = (opcode >> 8) & 0xFF
        header[5] = opcode & 0xFF
        ln = len(body)
        header[6] = (ln >> 24) & 0xFF
        header[7] = (ln >> 16) & 0xFF
        header[8] = (ln >> 8) & 0xFF
        header[9] = ln & 0xFF
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pending[seq] = fut
        self._writer.write(bytes(header) + body)
        await self._writer.drain()
        return await asyncio.wait_for(fut, timeout=timeout)

    # ── auth ──
    async def login(self, token: str) -> dict:
        cmd, _, decoded, raw = await self._request(19, {
            "token": token,
            "interactive": False,
            "chatsCount": 40,
            "chatsSync": 0,
            "contactsSync": 0,
            "presenceSync": 0,
            "draftsSync": 0,
        })
        if cmd != 1:
            msg = self._err_message(decoded)
            raise RuntimeError(msg or f"LOGIN cmd={cmd}")
        self.token = token
        return decoded if isinstance(decoded, dict) else {}

    async def profile(self) -> dict:
        cmd, _, decoded, _ = await self._request(16, {})
        if cmd != 1 or not isinstance(decoded, dict):
            return {}
        return decoded

    async def chat_history(self, chat_id: int, from_id=0, count=50):
        cmd, _, decoded, _ = await self._request(49, {
            "chatId": chat_id, "from": from_id, "forward": count,
        })
        if cmd != 1:
            raise RuntimeError(f"history cmd={cmd}")
        if isinstance(decoded, dict):
            return decoded.get("messages") or []
        return []

    async def send_message(self, chat_id: int, text: str) -> dict:
        cmd, _, decoded, _ = await self._request(64, {
            "chatId": chat_id,
            "message": {"text": text, "cid": int(time.time() * 1000)},
            "notify": True,
        })
        if cmd != 1:
            raise RuntimeError(f"send cmd={cmd}")
        return decoded if isinstance(decoded, dict) else {}

    @staticmethod
    def _err_message(decoded):
        if isinstance(decoded, dict):
            return (decoded.get("localizedMessage")
                    or decoded.get("message")
                    or decoded.get("error"))
        return None

    @staticmethod
    def _parse_push(decoded, raw):
        if not isinstance(decoded, dict):
            return None
        chat_id = decoded.get("chatId")
        m = decoded.get("message")
        if isinstance(chat_id, int) and isinstance(m, dict):
            return {
                "type": "message",
                "chatId": chat_id,
                "messageId": m.get("id"),
                "sender": m.get("sender"),
                "text": m.get("text", ""),
                "time": m.get("time") or int(time.time() * 1000),
            }
        return None


def extract_chats(login_resp: dict) -> list:
    """Вытащить список чатов из ответа LOGIN. Структура может отличаться,
    поэтому ищем по нескольким ключам."""
    arr = None
    for key in ("chats", "chatList", "items"):
        v = login_resp.get(key)
        if isinstance(v, list):
            arr = v
            break
    if arr is None:
        return []
    out = []
    for c in arr:
        if not isinstance(c, dict):
            continue
        cid = c.get("id") or c.get("chatId")
        if cid is None:
            continue
        last = c.get("lastMessage") or c.get("message") or {}
        out.append({
            "id": cid,
            "title": c.get("title") or c.get("name") or f"Чат {cid}",
            "type": c.get("type", ""),
            "lastText": last.get("text", "") if isinstance(last, dict) else "",
            "lastTime": (last.get("time") if isinstance(last, dict) else None)
                        or c.get("lastEventTime"),
            "unread": c.get("newMessages") or c.get("unread") or 0,
        })
    return out


# ════════════════════════════ WebSocket (stdlib) ════════════════════════════

async def ws_handshake(reader, writer) -> bool:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(1024)
        if not chunk:
            return False
        data += chunk
        if len(data) > 65536:
            return False
    text = data.decode("latin-1", "ignore")
    m = re.search(r"Sec-WebSocket-Key:\s*(.+)\r\n", text, re.I)
    if not m:
        return False
    key = m.group(1).strip()
    accept = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode()).digest()
    ).decode()
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    writer.write(resp.encode())
    await writer.drain()
    return True


async def ws_read(reader):
    """Читает один text-фрейм, возвращает str или None (close)."""
    buf = b""
    final = False
    while True:
        hdr = await reader.readexactly(2)
        b1, b2 = hdr[0], hdr[1]
        opcode = b1 & 0x0F
        fin = (b1 & 0x80) != 0
        masked = (b2 & 0x80) != 0
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", await reader.readexactly(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", await reader.readexactly(8))[0]
        mask = await reader.readexactly(4) if masked else b"\x00\x00\x00\x00"
        payload = await reader.readexactly(ln)
        if masked:
            payload = bytes(p ^ mask[i % 4] for i, p in enumerate(payload))
        if opcode == 0x8:  # close
            return None
        if opcode in (0x1, 0x2, 0x0):
            buf += payload
            if fin:
                return buf.decode("utf-8", "ignore")
        elif opcode == 0x9:  # ping -> pong (ignore here)
            continue


def ws_frame(text: str) -> bytes:
    data = text.encode("utf-8")
    ln = len(data)
    out = bytearray()
    out.append(0x81)  # FIN + text
    if ln < 126:
        out.append(ln)
    elif ln < 65536:
        out.append(126)
        out += struct.pack(">H", ln)
    else:
        out.append(127)
        out += struct.pack(">Q", ln)
    out += data
    return bytes(out)


# ════════════════════════════ session ════════════════════════════

async def handle_client(reader, writer):
    peer = writer.get_extra_info("peername")
    print(f"[ws] client {peer}")
    if not await ws_handshake(reader, writer):
        writer.close()
        return

    send_lock = asyncio.Lock()

    async def send_json(obj):
        async with send_lock:
            writer.write(ws_frame(json.dumps(obj, ensure_ascii=False)))
            await writer.drain()

    async def on_push(msg):
        await send_json(msg)

    conn = MaxConn(on_push=on_push)

    try:
        while True:
            raw = await ws_read(reader)
            if raw is None:
                break
            try:
                req = json.loads(raw)
            except Exception:
                continue
            action = req.get("action")

            try:
                if action == "login":
                    await conn.connect()
                    resp = await conn.login(req["token"])
                    prof = await conn.profile()
                    if isinstance(prof.get("id"), int):
                        conn.my_id = prof["id"]
                    await send_json({
                        "type": "login_ok",
                        "myId": conn.my_id,
                        "profile": prof,
                        "chats": extract_chats(resp),
                    })

                elif action == "history":
                    msgs = await conn.chat_history(
                        req["chatId"],
                        req.get("from", 0),
                        req.get("count", 50),
                    )
                    await send_json({
                        "type": "history",
                        "chatId": req["chatId"],
                        "myId": conn.my_id,
                        "messages": msgs,
                    })

                elif action == "send":
                    res = await conn.send_message(req["chatId"], req["text"])
                    mid = None
                    if isinstance(res.get("message"), dict):
                        mid = res["message"].get("id")
                    await send_json({
                        "type": "sent",
                        "chatId": req["chatId"],
                        "messageId": mid,
                    })

                elif action == "profile":
                    await send_json({"type": "profile",
                                     "profile": await conn.profile()})

            except Exception as e:
                await send_json({"type": "error",
                                 "action": action, "message": str(e)})
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass
    finally:
        await conn.close()
        try:
            writer.close()
        except Exception:
            pass
        print(f"[ws] disconnect {peer}")


async def main():
    server = await asyncio.start_server(handle_client, WS_HOST, WS_PORT)
    print(f"MAX bridge listening on ws://{WS_HOST}:{WS_PORT}")
    print("Открой web_demo/max_interface.html в браузере и введи auth-token.")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nbridge stopped")
