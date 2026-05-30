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

# ── логирование диалога с сервером (консоль + bridge.log) ──
import os as _os
_LOG_PATH = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "bridge.log")
try:
    _LOG_FILE = open(_LOG_PATH, "w", encoding="utf-8")
except Exception:
    _LOG_FILE = None

_SECRET_KEYS = {"token", "password", "trackId", "authToken"}

def _redact(v):
    """Прячет токены/пароли, обрезает длинные значения для лога."""
    if isinstance(v, dict):
        return {k: ("<скрыто>" if str(k) in _SECRET_KEYS else _redact(val))
                for k, val in v.items()}
    if isinstance(v, list):
        return [_redact(x) for x in v[:10]]
    s = str(v)
    return s if len(s) <= 300 else s[:300] + f"...(+{len(s)-300})"

_orig_print = print

def print(*args, **kwargs):  # noqa: A001 — намеренно переопределяем
    kwargs.setdefault("flush", True)
    _orig_print(*args, **kwargs)
    if _LOG_FILE:
        try:
            _LOG_FILE.write(" ".join(str(a) for a in args) + "\n")
            _LOG_FILE.flush()
        except Exception:
            pass


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

    async def connect(self, device_type: str = "ANDROID"):
        """device_type: ANDROID для SMS-флоу, WEB для входа по веб-токену.
        Веб-токены из web.max.ru сервер принимает только при deviceType=WEB
        (проверено: с ANDROID возвращается login.cred = FAIL_WRONG_PASSWORD)."""
        ctx = ssl.create_default_context()
        self._reader, self._writer = await asyncio.open_connection(
            HOST, PORT, ssl=ctx
        )
        self._closed = False
        self._reader_task = asyncio.create_task(self._reader_loop())
        cmd, _, _, _ = await self._request(6, {
            "userAgent": {
                "deviceType": device_type,
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
                cof = (length_raw >> 24) & 0xFF
                payload_len = length_raw & 0x00FFFFFF
                body = b""
                if payload_len:
                    body = await self._reader.readexactly(payload_len)
                body = self._decompress(cof, payload_len, body)
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
    def _decode_bytes(o):
        """Рекурсивно превращает bytes->str (utf-8), оставляя бинарь как есть.
        Нужно потому что распаковка идёт с raw=True (иначе msgpack падает на
        бинарных полях вроде аватаров с байтом 0xff)."""
        if isinstance(o, bytes):
            try:
                return o.decode("utf-8")
            except Exception:
                return o.decode("utf-8", "replace")
        if isinstance(o, dict):
            return {MaxConn._decode_bytes(k): MaxConn._decode_bytes(v)
                    for k, v in o.items()}
        if isinstance(o, list):
            return [MaxConn._decode_bytes(x) for x in o]
        return o

    @staticmethod
    def _decompress(cof: int, ln: int, body: bytes) -> bytes:
        """Тело кадра MAX сжато. Старший байт поля длины (cof) — флаг:
        0 = без сжатия, 0xFF = zstd, >0 = LZ4 block (размер распаковки = ln*cof).
        Источник: реверс defpackage/e1d.java + lp.java в декомпиле APK."""
        if cof == 0 or not body:
            return body
        try:
            if cof == 0xFF:
                import zstandard
                return zstandard.ZstdDecompressor().decompress(body)
            import lz4.block
            return lz4.block.decompress(body, uncompressed_size=ln * cof)
        except Exception as e:
            print(f"[decompress] cof={cof} ln={ln} failed: {e}")
            return body

    @staticmethod
    def _unpack(data: bytes):
        """Парсинг уже РАСПАКОВАННОГО msgpack-тела. raw=False (строки в utf-8),
        потоковый Unpacker (большой ответ бывает со «склеенными» объектами).
        Перебор offset — на случай редкого ведущего префикса."""
        if not data:
            return None
        best = None
        for off in range(0, 4):
            try:
                u = msgpack.Unpacker(raw=False, strict_map_key=False,
                                     max_buffer_size=0)
                u.feed(data[off:])
                obj = u.unpack()
            except Exception:
                continue
            if isinstance(obj, dict):
                if best is None or len(obj) > len(best):
                    best = obj
                if any(k in obj for k in ("chats", "profile", "message",
                                          "messages", "contact", "contacts")):
                    return obj
        return best

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
        print(f"[REQ] op={opcode} seq={seq} {_redact(payload)}", flush=True)
        self._writer.write(bytes(header) + body)
        await self._writer.drain()
        cmd, op, decoded, raw = await asyncio.wait_for(fut, timeout=timeout)
        shown = _redact(decoded) if isinstance(decoded, (dict, list)) else \
            (f"<{len(raw)} bytes>" if raw else decoded)
        print(f"[RESP] op={opcode} seq={seq} cmd={cmd} {shown}", flush=True)
        return cmd, op, decoded, raw

    # ── auth: вход по SMS ──
    async def start_auth_sms(self, phone: str) -> str:
        cmd, _, decoded, raw = await self._request(17, {
            "phone": phone,
            "type": "START_AUTH",
        })
        if cmd != 1:
            raise RuntimeError(self._err_message(decoded) or f"AUTH_REQUEST cmd={cmd}")
        token = self._find_long_token(raw)
        if not token:
            raise RuntimeError("verify-token не извлечён из ответа")
        return token

    async def confirm_sms(self, verify_token: str, code: str):
        """Возвращает ('token', auth_token) либо ('2fa', track_id)."""
        cmd, _, decoded, raw = await self._request(18, {
            "token": verify_token,
            "verifyCode": code,
            "authTokenType": "CHECK_CODE",
        })
        if cmd != 1:
            msg = self._err_message(decoded)
            raise RuntimeError(msg or "Неверный код или истёк. Запросите новый.")
        auth = self._find_long_token(raw)
        if auth:
            return ("token", auth)
        if b"passwordChallenge" in raw:
            track = self._find_uuid(raw)
            if not track:
                raise RuntimeError("2FA нужен, но trackId не найден")
            return ("2fa", track)
        raise RuntimeError("Нет токена и нет 2FA-челленджа")

    async def confirm_2fa(self, track_id: str, password: str) -> str:
        cmd, _, decoded, raw = await self._request(115, {
            "trackId": track_id,
            "password": password,
        })
        if cmd != 1:
            raise RuntimeError(self._err_message(decoded) or f"2FA cmd={cmd}")
        token = self._find_long_token(raw)
        if not token:
            raise RuntimeError("auth-token не извлечён после 2FA")
        return token

    @staticmethod
    def _find_long_token(data: bytes):
        valid = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            "0123456789_-+.~="
        )
        best = None
        cur = []
        for b in data:
            c = chr(b)
            if c in valid:
                cur.append(c)
            else:
                if len(cur) > 100:
                    t = "".join(cur)
                    if best is None or len(t) > len(best):
                        best = t
                cur = []
        if len(cur) > 100:
            t = "".join(cur)
            if best is None or len(t) > len(best):
                best = t
        return best

    @staticmethod
    def _find_uuid(data: bytes):
        m = re.search(
            rb"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            data,
        )
        return m.group(0).decode() if m else None

    # ── auth: вход по токену ──
    async def login(self, token: str) -> dict:
        # interactive=True заставляет сервер вернуть полный снэпшот:
        # профиль + контакты + чаты (~200+ KB). При False чаты не приходят.
        cmd, _, decoded, raw = await self._request(19, {
            "token": token,
            "interactive": True,
            "chatsCount": 40,
            "chatsSync": 0,
            "contactsSync": 0,
            "presenceSync": 0,
            "draftsSync": 0,
        }, timeout=45.0)
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
    """Вытащить список чатов из ответа LOGIN. Формат отличается между
    ANDROID и WEB: chats бывает list или map {chatId: chatObj}."""
    if not isinstance(login_resp, dict):
        return []
    arr = None
    for key in ("chats", "chatList", "items", "dialogs"):
        v = login_resp.get(key)
        if isinstance(v, list):
            arr = v
            break
        if isinstance(v, dict):
            arr = list(v.values())
            break
    if arr is None:
        return []
    out = []
    for c in arr:
        if not isinstance(c, dict):
            continue
        cid = c.get("id") or c.get("chatId") or c.get("cid")
        if cid is None:
            continue
        last = c.get("lastMessage") or c.get("message") or c.get("lastMsg") or {}
        title = (c.get("title") or c.get("name")
                 or _peer_name(c) or f"Чат {cid}")
        out.append({
            "id": cid,
            "title": title,
            "type": c.get("type", ""),
            "lastText": last.get("text", "") if isinstance(last, dict) else "",
            "lastTime": (last.get("time") if isinstance(last, dict) else None)
                        or c.get("lastEventTime") or c.get("modified"),
            "unread": c.get("newMessages") or c.get("unread")
                      or c.get("unreadCount") or 0,
        })
    # свежие сверху
    out.sort(key=lambda x: x.get("lastTime") or 0, reverse=True)
    return out


def _peer_name(chat: dict):
    """Имя собеседника для диалога 1:1, если нет title."""
    for key in ("participants", "members", "users"):
        v = chat.get(key)
        if isinstance(v, list):
            for p in v:
                if isinstance(p, dict):
                    nm = p.get("name") or p.get("firstName")
                    if nm:
                        return nm
        if isinstance(v, dict):
            for p in v.values():
                if isinstance(p, dict):
                    nm = p.get("name") or p.get("firstName")
                    if nm:
                        return nm
    return None


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
    verify_token = None   # для SMS-флоу
    track_id = None       # для 2FA

    async def finish_login(auth_token):
        """Общий финиш: LOGIN по токену, профиль, чаты. Отдаёт сам токен,
        чтобы пользователь мог сохранить его для будущих входов."""
        resp = await conn.login(auth_token)
        prof = await conn.profile()
        if isinstance(prof.get("id"), int):
            conn.my_id = prof["id"]
        await send_json({
            "type": "login_ok",
            "myId": conn.my_id,
            "authToken": auth_token,
            "profile": prof,
            "chats": extract_chats(resp),
        })

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
                    # Веб-токены принимаются только при deviceType=WEB.
                    await conn.connect(device_type="WEB")
                    await finish_login(req["token"])

                elif action == "request_sms":
                    await conn.connect(device_type="ANDROID")
                    verify_token = await conn.start_auth_sms(req["phone"])
                    await send_json({"type": "sms_sent"})

                elif action == "confirm_sms":
                    if not verify_token:
                        raise RuntimeError("SMS не запрошен")
                    kind, value = await conn.confirm_sms(verify_token, req["code"])
                    if kind == "token":
                        await finish_login(value)
                    else:
                        track_id = value
                        await send_json({"type": "need_2fa"})

                elif action == "confirm_2fa":
                    if not track_id:
                        raise RuntimeError("2FA-челлендж отсутствует")
                    auth = await conn.confirm_2fa(track_id, req["password"])
                    await finish_login(auth)

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
