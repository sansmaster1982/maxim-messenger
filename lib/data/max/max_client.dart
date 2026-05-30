import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import 'lz4_block.dart';
import 'max_codec.dart';
import 'models/incoming_message.dart';
import 'raw_parsers.dart';

/// Колбэк для отладки push-фреймов (как `on_push_debug` в Python-версии).
typedef PushDebug = void Function(MaxFrame frame);

/// Состояние транспортного соединения. На него подписывается UI и репозитории.
enum MaxConnectionState { disconnected, connecting, connected, reconnecting }

/// Один MaxClient = одно TLS-соединение к api.oneme.ru:443 + один читающий
/// сабскрипшен. Запросы идут через [_request], ответы матчатся по seq.
/// Сервер-пуш сваливается в [incomingStream].
class MaxClient {
  MaxClient({this.onPushDebug, Logger? logger})
    : _log = logger ?? Logger(printer: PrettyPrinter(methodCount: 0)) {
    _reconnect = _ReconnectManager(this, _log);
  }

  final PushDebug? onPushDebug;
  final Logger _log;
  late final _ReconnectManager _reconnect;

  /// Вызывается когда сервер отверг сохранённый токен (FAIL_LOGIN_TOKEN) —
  /// UI должен разлогинить и показать экран входа, а не висеть в reconnect.
  void Function()? _authInvalid;
  set onAuthInvalid(void Function()? cb) => _authInvalid = cb;

  String? _token;
  String get deviceId => _deviceId;
  final String _deviceId = const Uuid().v4();

  SecureSocket? _socket;
  StreamSubscription<Uint8List>? _sub;
  int _seq = 0;
  bool _closed = false;
  final _pending = <int, Completer<MaxFrame>>{};
  final _pushCtrl = StreamController<IncomingMessage>.broadcast();
  final _stateCtrl = StreamController<MaxConnectionState>.broadcast();
  MaxConnectionState _state = MaxConnectionState.disconnected;
  final _bufferBuilder = BytesBuilder(copy: false);

  Stream<IncomingMessage> get incomingStream => _pushCtrl.stream;
  Stream<MaxConnectionState> get connectionState => _stateCtrl.stream;
  MaxConnectionState get currentState => _state;
  String? get token => _token;
  bool get isConnected => _socket != null && !_closed;

  void _emitState(MaxConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  /// Тип устройства для INIT: 'ANDROID' (SMS-флоу) или 'WEB' (вход по
  /// веб-токену из web.max.ru). Веб-токены сервер принимает только при WEB.
  String _deviceType = MaxProto.deviceType;

  /// [deviceType] null => сохранить текущий (важно для reconnect: иначе
  /// переподключение сбрасывало бы WEB-сессию на ANDROID и сервер отвергал
  /// бы веб-токен с login.cred).
  Future<void> connect({String? deviceType}) async {
    if (deviceType != null) _deviceType = deviceType;
    _emitState(MaxConnectionState.connecting);
    try {
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
      _emitState(MaxConnectionState.connected);
    } catch (e) {
      // INIT упал или сокет порвался — приведём состояние к чистому
      // disconnected, чтобы следующий connect() имел шанс начать заново.
      await _sub?.cancel();
      _sub = null;
      try {
        await _socket?.close();
      } catch (_) {}
      _socket = null;
      _emitState(MaxConnectionState.disconnected);
      rethrow;
    }
  }

  /// Переподключение по сохранённому токену. Не выставляет [_closed].
  /// Если [_token] не задан — это голый [connect].
  Future<void> reconnect() async {
    await _disconnect();
    await connect();
    final t = _token;
    if (t != null && t.isNotEmpty) {
      await login(t);
    }
  }

  /// Закрытие сокета без флага «навсегда» — для авто-переподключения.
  Future<void> _disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _failAllPending(const MaxNotConnected('disconnected'));
  }

  /// Явное закрытие пользователем. Блокирует все будущие reconnect-попытки.
  Future<void> close() async {
    _closed = true;
    _reconnect.cancel();
    await _disconnect();
    _emitState(MaxConnectionState.disconnected);
  }

  Future<void> _initSession() async {
    final f = await _request(MaxOp.init, {
      'userAgent': {
        'deviceType': _deviceType,
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
    if (f.cmd != 1) {
      // Сервер возвращает structured error в decoded payload:
      //  { error, message, localizedMessage, title }
      // Покажем пользователю localizedMessage если он есть.
      final d = f.decoded;
      if (d is Map) {
        final m = d.map((k, v) => MapEntry(k.toString(), v));
        final loc = m['localizedMessage']?.toString();
        final err = m['error']?.toString();
        if (loc != null && loc.isNotEmpty) {
          throw MaxLoginFailed(loc);
        }
        if (err != null && err.isNotEmpty) {
          throw MaxLoginFailed('Сервер MAX: $err');
        }
      }
      if (f.cmd == 3) {
        throw const MaxLoginFailed(
          'SMS-код неверный или истёк. Запросите новый код.',
        );
      }
      throw MaxLoginFailed('AUTH_CONFIRM cmd=${f.cmd}');
    }

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

  Future<Map<String, dynamic>> sendMessage(
    int chatId,
    String text, {
    List<Map<String, Object?>>? attaches,
    int? replyToId,
  }) async {
    final message = <String, Object?>{'text': text};
    if (attaches != null && attaches.isNotEmpty) {
      message['attaches'] = attaches;
    }
    if (replyToId != null) {
      // ключ reply в payload sendMessage MAX не подтверждён в декомпиле,
      // отправляем как `replyTo` — сервер либо примет, либо проигнорирует.
      message['replyTo'] = replyToId;
    }
    final f = await _request(MaxOp.sendMessage, {
      'chatId': chatId,
      'message': message,
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

  /// Редактирование уже отправленного сообщения (opcode 67).
  Future<Map<String, dynamic>> editMessage(
    int chatId,
    int messageId,
    String text, {
    List<Map<String, Object?>>? attaches,
  }) async {
    final payload = <String, Object?>{
      'chatId': chatId,
      'messageId': messageId,
      'text': text,
    };
    if (attaches != null) payload['attachments'] = attaches;
    final f = await _request(MaxOp.editMessage, payload);
    if (f.cmd != 1) throw MaxError('editMessage cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  // ───────────────────────── media ────────────────────────────

  /// Запрос upload-URL для фото. Возвращает декодированный ответ — клиент
  /// должен взять оттуда `url` (HTTP POST endpoint) и `photoToken`.
  /// Поле profile=true используется для аватарок.
  Future<Map<String, dynamic>> requestPhotoUpload({
    int count = 1,
    bool profile = false,
  }) async {
    final f = await _request(MaxOp.photoUpload, {
      'count': count,
      'profile': profile,
    });
    if (f.cmd != 1) throw MaxError('photoUpload cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Запрос параметров видео-аплоада.
  /// `uploaderType` ∈ {VIDEO, VIDEO_MSG, AUDIO} согласно декомпилу.
  Future<Map<String, dynamic>> requestVideoUpload({
    String type = 'VIDEO',
    int count = 1,
    String uploaderType = 'VIDEO',
  }) async {
    final f = await _request(MaxOp.videoUpload, {
      'type': type,
      'count': count,
      'uploaderType': uploaderType,
    });
    if (f.cmd != 1) throw MaxError('videoUpload cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Универсальный аплоад файла (87). Поля payload не подтверждены в
  /// декомпиле полностью — отправляем минимум.
  Future<Map<String, dynamic>> requestFileUpload({int count = 1}) async {
    final f = await _request(MaxOp.fileUpload, {'count': count});
    if (f.cmd != 1) throw MaxError('fileUpload cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Получить URL воспроизведения видео (opcode 83).
  Future<Map<String, dynamic>> requestVideoPlay({
    required int videoId,
    int? chatId,
    int? messageId,
    String? token,
  }) async {
    final payload = <String, Object?>{'videoId': videoId};
    if (chatId != null) payload['chatId'] = chatId;
    if (messageId != null) payload['messageId'] = messageId;
    if (token != null) payload['token'] = token;
    final f = await _request(MaxOp.videoPlay, payload);
    if (f.cmd != 1) throw MaxError('videoPlay cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Получить download URL для файла (opcode 88).
  Future<Map<String, dynamic>> requestFileDownload({
    required int fileId,
    required int chatId,
    required int messageId,
  }) async {
    final f = await _request(MaxOp.fileDownload, {
      'fileId': fileId,
      'chatId': chatId,
      'messageId': messageId,
    });
    if (f.cmd != 1) throw MaxError('fileDownload cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Список медиа конкретного чата (opcode 51). Используется для галереи.
  Future<Map<String, dynamic>> chatMedia({
    required int chatId,
    int? messageId,
    List<String> attachTypes = const ['PHOTO', 'VIDEO'],
    int forward = 50,
    int backward = 0,
  }) async {
    final payload = <String, Object?>{
      'chatId': chatId,
      'attachTypes': attachTypes,
      'forward': forward,
      'backward': backward,
    };
    if (messageId != null) payload['messageId'] = messageId;
    final f = await _request(MaxOp.chatMedia, payload);
    if (f.cmd != 1) throw MaxError('chatMedia cmd=${f.cmd}');
    return _asMap(f.decoded);
  }

  /// Запрос транскрипции голосового/видео-сообщения (opcode 202).
  Future<Map<String, dynamic>> transcribeMedia({
    required int mediaId,
    required int chatId,
    required int messageId,
  }) async {
    final f = await _request(MaxOp.transcribeMedia, {
      'mediaId': mediaId,
      'chatId': chatId,
      'messageId': messageId,
    });
    if (f.cmd != 1) throw MaxError('transcribeMedia cmd=${f.cmd}');
    return _asMap(f.decoded);
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
    // Маскируем чувствительные поля в логе.
    _log.i(
      'REQ op=$opcode seq=$seq payload=${_redact(payload)}',
    );
    s.add(frame);
    await s.flush();
    final f = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(seq);
        throw const MaxTimeout('request timeout');
      },
    );
    _log.i(
      'RESP op=$opcode seq=$seq cmd=${f.cmd} len=${f.body.length} '
      'decoded=${_redact(f.decoded)}',
    );
    return f;
  }

  static String _redact(Object? v) {
    if (v is Map) {
      return v.map((k, v2) {
        final ks = k.toString();
        if (ks == 'token' || ks == 'password' || ks == 'trackId') {
          return MapEntry(ks, '<redacted>');
        }
        return MapEntry(ks, _redact(v2));
      }).toString();
    }
    if (v is List) return '[${v.map(_redact).join(', ')}]';
    final s = v?.toString() ?? 'null';
    return s.length > 200 ? '${s.substring(0, 200)}...(${s.length})' : s;
  }

  /// Распаковка тела кадра по флагу cof. LZ4 — чистый Dart. zstd (cof=0xFF)
  /// без нативной библиотеки не распакуем — логируем и отдаём сырое
  /// (такие кадры редки; основной трафик — LZ4 cof>0).
  Uint8List _decompressBody(int cof, int payloadLen, Uint8List body) {
    if (cof == 0 || body.isEmpty) return body;
    if (cof == 0xFF) {
      _log.w('zstd-кадр (cof=0xFF) не распакован — нет нативного zstd');
      return body;
    }
    try {
      return Lz4Block.decompress(body, payloadLen * cof);
    } catch (e) {
      _log.w('LZ4 decompress failed (cof=$cof len=$payloadLen): $e');
      return body;
    }
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
      // Старший байт длины = флаг сжатия (cof): 0 нет, 0xFF zstd, >0 LZ4
      // (размер распаковки = payloadLen * cof). Источник: e1d.java/lp.java.
      final cof = (lenRaw >> 24) & 0xFF;
      final payloadLen = lenRaw & 0x00FFFFFF;
      final total = 10 + payloadLen;
      if (buf.length < total) {
        _bufferBuilder
          ..clear()
          ..add(buf);
        return;
      }

      final rawBody = Uint8List.sublistView(buf, 10, total);
      final body = _decompressBody(cof, payloadLen, rawBody);
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
    _handleDrop();
  }

  void _onDone() {
    _log.w('MaxClient socket closed by server');
    _failAllPending(const MaxNotConnected('socket closed'));
    _handleDrop();
  }

  void _handleDrop() {
    // Уже синхронно убираем подписку и сокет — без флага «навсегда».
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    if (_closed) {
      _emitState(MaxConnectionState.disconnected);
      return;
    }
    _emitState(MaxConnectionState.reconnecting);
    _reconnect.start();
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
    var attaches = const <Map<String, dynamic>>[];

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
        final at = mm['attaches'] ?? mm['attachments'];
        if (at is List) {
          attaches = at
              .whereType<Map>()
              .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
              .toList(growable: false);
        }
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

    // Сообщение без текста, но с attach'ем — валидно.
    if (chatId == null) return null;
    final hasContent = (text != null && text.isNotEmpty) || attaches.isNotEmpty;
    if (!hasContent) return null;
    return IncomingMessage(
      chatId: chatId,
      messageId: msgId,
      sender: sender,
      text: text ?? '',
      timeMs: timeMs,
      raw: f.body,
      attaches: attaches,
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

/// Экспоненциальный backoff: 2s → 4s → 8s → 16s → 32s → 60s (cap).
/// При успехе сбрасывается в 2s. Защищён от двойного запуска флагом
/// [_running].
class _ReconnectManager {
  _ReconnectManager(this._client, this._log);

  final MaxClient _client;
  final Logger _log;

  static const _baseDelay = Duration(seconds: 2);
  static const _maxDelay = Duration(seconds: 60);

  Duration _delay = _baseDelay;
  bool _running = false;
  bool _cancelled = false;
  Timer? _timer;

  /// Запускает цикл переподключения, если он ещё не запущен.
  void start() {
    if (_running || _cancelled) return;
    if (_client._closed) return;
    _running = true;
    _delay = _baseDelay;
    _schedule();
  }

  /// Останавливает цикл. Вызывается из [MaxClient.close].
  void cancel() {
    _cancelled = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _timer?.cancel();
    _log.i('reconnect scheduled in ${_delay.inSeconds}s');
    _timer = Timer(_delay, _attempt);
  }

  Future<void> _attempt() async {
    if (_cancelled || _client._closed) {
      _running = false;
      return;
    }
    try {
      await _client.reconnect();
      _log.i('reconnect succeeded');
      _delay = _baseDelay;
      _running = false;
    } catch (e) {
      _log.w('reconnect attempt failed: $e');
      // Токен мёртв (FAIL_LOGIN_TOKEN / login.cred / login.token) — нет смысла
      // долбить сервер протухшим токеном. Останавливаем цикл, чистим токен и
      // сигналим, чтобы UI вышел на экран входа.
      if (e is MaxLoginFailed) {
        _client._token = null;
        _running = false;
        _cancelled = true;
        _client._emitState(MaxConnectionState.disconnected);
        _client._authInvalid?.call();
        return;
      }
      // Удваиваем, но не больше cap.
      final next = _delay * 2;
      _delay = next > _maxDelay ? _maxDelay : next;
      if (!_cancelled && !_client._closed) {
        _schedule();
      } else {
        _running = false;
      }
    }
  }
}
