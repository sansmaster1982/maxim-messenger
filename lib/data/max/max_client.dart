import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import 'max_codec.dart';
import 'models/incoming_message.dart';
import 'raw_parsers.dart';

/// Колбэк для отладки push-фреймов (как `on_push_debug` в Python-версии).
typedef PushDebug = void Function(MaxFrame frame);

/// Один MaxClient = одно TLS-соединение к api.oneme.ru:443 + один читающий
/// сабскрипшен. Запросы идут через [_request], ответы матчатся по seq.
/// Сервер-пуш сваливается в [incomingStream].
class MaxClient {
  MaxClient({this.onPushDebug, Logger? logger})
    : _log = logger ?? Logger(printer: PrettyPrinter(methodCount: 0));

  final PushDebug? onPushDebug;
  final Logger _log;

  String? _token;
  String get deviceId => _deviceId;
  final String _deviceId = const Uuid().v4();

  SecureSocket? _socket;
  StreamSubscription<Uint8List>? _sub;
  int _seq = 0;
  bool _closed = false;
  final _pending = <int, Completer<MaxFrame>>{};
  final _pushCtrl = StreamController<IncomingMessage>.broadcast();
  final _bufferBuilder = BytesBuilder(copy: false);

  Stream<IncomingMessage> get incomingStream => _pushCtrl.stream;
  String? get token => _token;
  bool get isConnected => _socket != null && !_closed;

  Future<void> connect() async {
    final s = await SecureSocket.connect(
      MaxProto.host,
      MaxProto.port,
      timeout: const Duration(seconds: 15),
    );
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _closed = false;
    _sub = s.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
    await _initSession();
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _failAllPending(const MaxNotConnected('closed by client'));
  }

  Future<void> _initSession() async {
    final f = await _request(MaxOp.init, {
      'userAgent': {
        'deviceType': MaxProto.deviceType,
        'locale': MaxProto.locale,
        'appVersion': MaxProto.appVersion,
      },
      'deviceId': _deviceId,
    });
    if (f.cmd != 1) {
      throw MaxError('INIT failed cmd=${f.cmd}');
    }
  }

  // ─────────────────────────── auth ───────────────────────────

  Future<String> startAuthSms(String phone) async {
    final f = await _request(MaxOp.authRequest, {
      'phone': phone,
      'type': 'START_AUTH',
    });
    if (f.cmd != 1) throw MaxLoginFailed('AUTH_REQUEST cmd=${f.cmd}');
    final t = RawParsers.findLongToken(f.body);
    if (t == null) throw const MaxLoginFailed('verify token not extracted');
    return t;
  }

  /// Возвращает (authToken, trackIdFor2fa). Один из двух непустой.
  Future<({String? authToken, String? trackId})> confirmSms(
    String verifyToken,
    String code,
  ) async {
    final f = await _request(MaxOp.authConfirm, {
      'token': verifyToken,
      'verifyCode': code,
      'authTokenType': 'CHECK_CODE',
    });
    if (f.cmd != 1) throw MaxLoginFailed('AUTH_CONFIRM cmd=${f.cmd}');

    final authToken = RawParsers.findLongToken(f.body);
    if (authToken != null) return (authToken: authToken, trackId: null);

    if (_contains(f.body, 'passwordChallenge')) {
      final tid = RawParsers.findUuid(f.body);
      if (tid == null) {
        throw const MaxLoginFailed('2FA required but trackId not found');
      }
      return (authToken: null, trackId: tid);
    }
    throw const MaxLoginFailed('no auth token and no 2FA challenge');
  }

  Future<String> confirm2fa(String trackId, String password) async {
    final f = await _request(MaxOp.twoFa, {
      'trackId': trackId,
      'password': password,
    });
    if (f.cmd != 1) throw MaxLoginFailed('2FA cmd=${f.cmd}');
    final t = RawParsers.findLongToken(f.body);
    if (t == null) throw const MaxLoginFailed('auth token missing after 2FA');
    return t;
  }

  /// Логин по сохранённому токену. Возвращает raw payload, оттуда вызывающий
  /// код может вытащить контакты/чаты при синхронизации.
  Future<Uint8List> login(String token) async {
    final f = await _request(MaxOp.login, {
      'token': token,
      'interactive': false,
      'chatsCount': 40,
      'chatsSync': 0,
      'contactsSync': 0,
      'presenceSync': 0,
      'draftsSync': 0,
    });
    if (f.cmd != 1) throw MaxLoginFailed('LOGIN cmd=${f.cmd}');
    _token = token;
    return f.body;
  }

  // ───────────────────────── messaging ────────────────────────

  Future<Map<String, dynamic>> sendMessage(int chatId, String text) async {
    final f = await _request(MaxOp.sendMessage, {
      'chatId': chatId,
      'message': {'text': text},
      'randomId': DateTime.now().millisecondsSinceEpoch,
    });
    if (f.cmd != 1) throw MaxError('send_message cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  Future<void> typing(int chatId, {bool isTyping = true}) async {
    await _request(MaxOp.typing, {
      'chatId': chatId,
      'typing': isTyping,
    });
  }

  Future<Map<String, dynamic>> findContactByPhone(String phone) async {
    final f = await _request(MaxOp.contactByPhone, {'phone': phone});
    if (f.cmd != 1) throw MaxError('contactByPhone cmd=${f.cmd}');
    return _parseContact(f);
  }

  Future<Map<String, dynamic>> contactInfo(List<int> ids) async {
    final f = await _request(MaxOp.contactInfo, {'contactIds': ids});
    if (f.cmd != 1) throw MaxError('contactInfo cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  Future<Map<String, dynamic>> chatInfo(List<int> ids) async {
    final f = await _request(MaxOp.chatInfo, {'chatIds': ids});
    if (f.cmd != 1) throw MaxError('chatInfo cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  Future<List<Map<String, dynamic>>> chatHistory(
    int chatId, {
    int fromId = 0,
    int count = 50,
  }) async {
    final f = await _request(MaxOp.chatHistory, {
      'chatId': chatId,
      'from': fromId,
      'forward': count,
    });
    if (f.cmd != 1) throw MaxError('chatHistory cmd=${f.cmd}');
    final m = _asMap(f.decoded);
    final msgs = m['messages'];
    if (msgs is List) {
      return msgs.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return _parseMessagesRaw(f.body);
  }

  Future<Map<String, dynamic>> currentProfile() async {
    final f = await _request(MaxOp.profile, {});
    if (f.cmd != 1) throw MaxError('profile cmd=${f.cmd}');
    final m = _asMap(f.decoded);
    if (m.isNotEmpty) return m;
    return {
      'id': RawParsers.readIntAfterKey(
        f.body,
        Uint8List.fromList([0xA2, ...'id'.codeUnits]),
      ),
      'name': RawParsers.readStrAfterKey(
        f.body,
        Uint8List.fromList([0xA4, ...'name'.codeUnits]),
      ),
    };
  }

  // ───────────────────────── internals ────────────────────────

  Future<MaxFrame> _request(
    int opcode,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final s = _socket;
    if (s == null || _closed) throw const MaxNotConnected('socket is null');

    final seq = _seq;
    _seq = (_seq + 1) & 0xFFFF;
    final completer = Completer<MaxFrame>();
    _pending[seq] = completer;

    final frame = MaxCodec.frame(seq: seq, opcode: opcode, payload: payload);
    s.add(frame);
    await s.flush();

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(seq);
        throw const MaxTimeout('request timeout');
      },
    );
  }

  void _onData(Uint8List chunk) {
    _bufferBuilder.add(chunk);
    while (true) {
      final buf = _bufferBuilder.toBytes();
      if (buf.length < 10) {
        _bufferBuilder
          ..clear()
          ..add(buf);
        return;
      }
      final cmd = buf[1];
      final seq = (buf[2] << 8) | buf[3];
      final opcode = (buf[4] << 8) | buf[5];
      final lenRaw =
          (buf[6] << 24) | (buf[7] << 16) | (buf[8] << 8) | buf[9];
      final payloadLen = lenRaw & 0x00FFFFFF;
      final total = 10 + payloadLen;
      if (buf.length < total) {
        _bufferBuilder
          ..clear()
          ..add(buf);
        return;
      }

      final body = Uint8List.sublistView(buf, 10, total);
      final decoded = MaxCodec.tryUnpack(body);
      final frame = MaxFrame(
        cmd: cmd,
        seq: seq,
        opcode: opcode,
        body: body,
        decoded: decoded,
      );

      // переложить остаток обратно в builder
      _bufferBuilder.clear();
      if (buf.length > total) {
        _bufferBuilder.add(Uint8List.sublistView(buf, total));
      }

      final waiter = _pending.remove(seq);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(frame);
        continue;
      }

      onPushDebug?.call(frame);
      final msg = _parsePush(frame);
      if (msg != null && !_pushCtrl.isClosed) {
        _pushCtrl.add(msg);
      }
    }
  }

  void _onError(Object e, StackTrace st) {
    _log.w('MaxClient socket error: $e');
    _failAllPending(MaxNotConnected('socket error: $e'));
  }

  void _onDone() {
    _log.w('MaxClient socket closed by server');
    _failAllPending(const MaxNotConnected('socket closed'));
    _closed = true;
  }

  void _failAllPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  Map<String, dynamic> _asMap(Object? d) {
    if (d is Map) {
      return d.map(
        (k, v) => MapEntry(k.toString(), v),
      );
    }
    return const {};
  }

  IncomingMessage? _parsePush(MaxFrame f) {
    int? chatId;
    String? text;
    int? sender;
    int? msgId;
    int? timeMs;

    final d = f.decoded;
    if (d is Map) {
      final dm = d.map((k, v) => MapEntry(k.toString(), v));
      chatId = _toInt(dm['chatId']);
      final m = dm['message'];
      if (m is Map) {
        final mm = m.map((k, v) => MapEntry(k.toString(), v));
        text = mm['text']?.toString();
        sender = _toInt(mm['sender']);
        msgId = _toInt(mm['id']);
        timeMs = _toInt(mm['time']);
      } else {
        text = dm['text']?.toString();
        sender = _toInt(dm['sender']);
        msgId = _toInt(dm['id']);
        timeMs = _toInt(dm['time']);
      }
    }

    chatId ??= RawParsers.readIntAfterKey(
      f.body,
      Uint8List.fromList([0xA6, ...'chatId'.codeUnits]),
    );
    text ??= RawParsers.readStrAfterKey(
      f.body,
      Uint8List.fromList([0xA4, ...'text'.codeUnits]),
    );
    sender ??= RawParsers.readIntAfterKey(
      f.body,
      Uint8List.fromList([0xA6, ...'sender'.codeUnits]),
    );
    msgId ??= RawParsers.readIntAfterKey(
      f.body,
      Uint8List.fromList([0xA2, ...'id'.codeUnits]),
    );
    timeMs ??= RawParsers.readIntAfterKey(
      f.body,
      Uint8List.fromList([0xA4, ...'time'.codeUnits]),
    );

    if (chatId == null || text == null || text.isEmpty) return null;
    return IncomingMessage(
      chatId: chatId,
      messageId: msgId,
      sender: sender,
      text: text,
      timeMs: timeMs,
      raw: f.body,
    );
  }

  Map<String, dynamic> _parseContact(MaxFrame f) {
    final d = f.decoded;
    if (d is Map) {
      final dm = d.map((k, v) => MapEntry(k.toString(), v));
      for (final key in ('contact contacts user'.split(' '))) {
        var v = dm[key];
        if (v is List && v.isNotEmpty) v = v.first;
        if (v is Map) {
          final mm = v.map((k, v) => MapEntry(k.toString(), v));
          return {
            'id': _toInt(mm['id']),
            'name': mm['name']?.toString() ?? mm['names']?.toString(),
            'phone': mm['phone']?.toString(),
          };
        }
      }
    }
    return {
      'id': RawParsers.readIntAfterKey(
        f.body,
        Uint8List.fromList([0xA2, ...'id'.codeUnits]),
      ),
      'name': RawParsers.readStrAfterKey(
        f.body,
        Uint8List.fromList([0xA4, ...'name'.codeUnits]),
      ),
      'phone': RawParsers.readIntAfterKey(
        f.body,
        Uint8List.fromList([0xA5, ...'phone'.codeUnits]),
      )?.toString(),
    };
  }

  List<Map<String, dynamic>> _parseMessagesRaw(Uint8List raw) {
    final marker = Uint8List.fromList([0xA8, ...'messages'.codeUnits]);
    final start = RawParsers.indexOf(raw, marker);
    if (start == -1) return [];
    final region = Uint8List.sublistView(raw, start);
    final positions = <int>[];
    // Найти повторяющиеся "id" + (D2|D3) внутри блока messages.
    for (var i = 0; i < region.length - 3; i++) {
      if (region[i] == 0xA2 &&
          region[i + 1] == 'i'.codeUnitAt(0) &&
          region[i + 2] == 'd'.codeUnitAt(0) &&
          (region[i + 3] == 0xD2 || region[i + 3] == 0xD3)) {
        positions.add(i);
      }
    }
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      final end = i + 1 < positions.length ? positions[i + 1] : region.length;
      final chunk = Uint8List.sublistView(region, p, end);
      result.add({
        'id': RawParsers.readIntAfterKey(
          chunk,
          Uint8List.fromList([0xA2, ...'id'.codeUnits]),
        ),
        'sender': RawParsers.readIntAfterKey(
          chunk,
          Uint8List.fromList([0xA6, ...'sender'.codeUnits]),
        ),
        'text': RawParsers.readStrAfterKey(
          chunk,
          Uint8List.fromList([0xA4, ...'text'.codeUnits]),
        ),
        'time': RawParsers.readIntAfterKey(
          chunk,
          Uint8List.fromList([0xA4, ...'time'.codeUnits]),
        ),
      });
    }
    return result;
  }

  bool _contains(Uint8List data, String s) {
    final needle = Uint8List.fromList(s.codeUnits);
    return RawParsers.indexOf(data, needle) != -1;
  }

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
