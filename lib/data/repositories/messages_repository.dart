import 'dart:async';

import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../local/database.dart';
import '../local/secure_storage.dart';
import '../max/max_client.dart';
import '../max/models/attach.dart';
import '../max/models/incoming_message.dart';
import '../max/models/message.dart';

class MessagesRepository {
  MessagesRepository({
    required this.client,
    required this.db,
    required this.storage,
    Logger? logger,
  }) : _log = logger ?? Logger();

  final MaxClient client;
  final AppDatabase db;
  final SecureStorage storage;
  final Logger _log;
  static const _uuid = Uuid();
  static const _maxAttempts = 5;

  StreamSubscription<IncomingMessage>? _pushSub;
  StreamSubscription<MaxConnectionState>? _stateSub;
  bool _draining = false;
  final _onChat = StreamController<int>.broadcast();

  /// Поток id чатов, в которых что-то изменилось.
  Stream<int> get changedChats => _onChat.stream;

  Future<void> start() async {
    _pushSub ??= client.incomingStream.listen(_onPush, onError: (e) {
      _log.w('push stream error: $e');
    });
    // Подписываемся на состояние транспорта — при выходе в connected
    // дренируем outbox. Установка подписки не блокирует репозиторий.
    _stateSub ??= client.connectionState.listen((s) {
      if (s == MaxConnectionState.connected) {
        // Откладываем дренаж, чтобы не блокировать listen.
        Future.microtask(drainOutbox);
      }
    });
    // Если на момент start транспорт уже connected — дренаж тоже отложенный.
    if (client.currentState == MaxConnectionState.connected) {
      Future.microtask(drainOutbox);
    }
  }

  Future<void> stop() async {
    await _pushSub?.cancel();
    _pushSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
  }

  Future<List<MaxMessage>> localHistory(int chatId, {int limit = 200}) =>
      db.messages(chatId, limit: limit);

  /// Подтянуть N последних сообщений с сервера и сохранить локально.
  Future<List<MaxMessage>> syncHistory(int chatId, {int count = 50}) async {
    return _fetchAndStore(chatId, fromId: 0, count: count, updatePreview: true);
  }

  /// Догрузить более старые сообщения от самого раннего локально известного id.
  /// Возвращает то, что удалось вытащить (может быть пусто, если на сервере
  /// больше ничего нет или соединение мертвое).
  Future<List<MaxMessage>> loadOlder(int chatId, {int count = 50}) async {
    final oldest = await db.oldestServerMessageId(chatId);
    if (oldest == null) {
      // локально пусто — нечего пагинировать, имеет смысл только обычный sync
      return _fetchAndStore(chatId, fromId: 0, count: count, updatePreview: true);
    }
    return _fetchAndStore(
      chatId,
      fromId: oldest,
      count: count,
      updatePreview: false,
    );
  }

  Future<List<MaxMessage>> _fetchAndStore(
    int chatId, {
    required int fromId,
    required int count,
    required bool updatePreview,
  }) async {
    final myId = await storage.readMyUserId();
    final raw = await client.chatHistory(chatId, fromId: fromId, count: count);
    final out = <MaxMessage>[];
    for (final m in raw) {
      final id = (m['id'] as num?)?.toInt();
      final sender = (m['sender'] as num?)?.toInt();
      final text = m['text']?.toString() ?? '';
      final time = (m['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final attRaw = (m['attaches'] ?? m['attachments']) as List?;
      final hasAttaches = attRaw != null && attRaw.isNotEmpty;
      if (text.isEmpty && !hasAttaches) continue;
      final dir = (myId != null && sender == myId)
          ? MessageDirection.outgoing
          : MessageDirection.incoming;
      final msg = MaxMessage(
        id: id,
        chatId: chatId,
        senderId: sender,
        text: text,
        timeMs: time,
        direction: dir,
      );
      await db.insertMessage(msg);
      if (hasAttaches && id != null) {
        await _persistAttaches(
          attRaw,
          chatId: chatId,
          messageServerId: id,
        );
      }
      out.add(msg);
    }
    if (out.isNotEmpty) {
      if (updatePreview) {
        final last = out.reduce((a, b) => a.timeMs > b.timeMs ? a : b);
        await db.updateChatPreview(
          chatId: chatId,
          timeMs: last.timeMs,
          preview: last.text.isNotEmpty ? last.text : '[Вложение]',
        );
      }
      _onChat.add(chatId);
    }
    return out;
  }

  Future<void> _persistAttaches(
    List<dynamic> raw, {
    required int chatId,
    String? messageLocalId,
    int? messageServerId,
  }) async {
    for (final r in raw) {
      if (r is! Map) continue;
      final m = r.map((k, v) => MapEntry(k.toString(), v));
      try {
        final a = MaxAttach.fromServer(m);
        await db.insertAttach(
          a,
          chatId: chatId,
          messageLocalId: messageLocalId,
          messageServerId: messageServerId,
        );
      } catch (e) {
        _log.w('persist attach failed: $e');
      }
    }
  }

  Future<MaxMessage> sendText(
    int chatId,
    String text, {
    int? replyToId,
    String? replyToPreview,
  }) async {
    final myId = await storage.readMyUserId();
    final localId = _uuid.v4();
    final pending = MaxMessage(
      chatId: chatId,
      senderId: myId,
      text: text,
      timeMs: DateTime.now().millisecondsSinceEpoch,
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending,
      localId: localId,
      replyToId: replyToId,
      replyToPreview: replyToPreview,
    );
    await db.insertMessage(pending);
    await db.updateChatPreview(
      chatId: chatId,
      timeMs: pending.timeMs,
      preview: text,
    );
    _onChat.add(chatId);

    try {
      // TODO: ключ reply в payload sendMessage MAX неизвестен; шлём только текст.
      final res = await client.sendMessage(chatId, text);
      final serverId = (res['message'] is Map)
          ? ((res['message'] as Map)['id'] as num?)?.toInt()
          : null;
      await db.updateMessageByLocalId(
        localId,
        serverId: serverId,
        status: MessageStatus.sent,
      );
      _onChat.add(chatId);
      return pending.copyWith(id: serverId, status: MessageStatus.sent);
    } on MaxNotConnected catch (e) {
      _log.i('sendText offline, queued: $e');
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      _onChat.add(chatId);
      return pending;
    } on MaxTimeout catch (e) {
      _log.i('sendText timeout, queued: $e');
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      _onChat.add(chatId);
      return pending;
    } catch (e) {
      _log.w('sendText failed: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed);
    }
  }

  /// Пытается отправить все сообщения из outbox по порядку. При первом фейле
  /// останавливается — следующий successful reconnect повторит. Если конкретное
  /// сообщение превысило лимит попыток, помечается как failed и убирается из
  /// очереди.
  Future<void> drainOutbox() async {
    if (_draining) return;
    _draining = true;
    try {
      final rows = await db.dequeueOutbox();
      for (final row in rows) {
        final localId = row['local_id'] as String;
        final chatId = (row['chat_id'] as num).toInt();
        final text = row['text'] as String;
        final attempts = (row['attempts'] as num?)?.toInt() ?? 0;
        try {
          final res = await client.sendMessage(chatId, text);
          final serverId = (res['message'] is Map)
              ? ((res['message'] as Map)['id'] as num?)?.toInt()
              : null;
          await db.updateMessageByLocalId(
            localId,
            serverId: serverId,
            status: MessageStatus.sent,
          );
          await db.removeOutbox(localId);
          _onChat.add(chatId);
        } on MaxNotConnected catch (e) {
          _log.i('drainOutbox stopped, offline again: $e');
          await db.incOutboxAttempts(localId);
          return;
        } on MaxTimeout catch (e) {
          _log.i('drainOutbox stopped, timeout: $e');
          await db.incOutboxAttempts(localId);
          return;
        } catch (e) {
          _log.w('drainOutbox send failed: $e');
          await db.incOutboxAttempts(localId);
          if (attempts + 1 > _maxAttempts) {
            await db.updateMessageByLocalId(
              localId,
              status: MessageStatus.failed,
            );
            await db.removeOutbox(localId);
            _onChat.add(chatId);
          }
          // Останавливаемся, не дергаем следующее — попробуем при следующем reconnect.
          return;
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// Сбросить failed-сообщения чата в pending и положить обратно в outbox,
  /// затем дёрнуть [drainOutbox]. Используется тапом «повторить» в UI.
  Future<void> retryFailed(int chatId) async {
    final failed = await db.messagesByStatus(chatId, MessageStatus.failed);
    for (final m in failed) {
      final localId = m.localId;
      if (localId == null) continue;
      await db.enqueueOutbox(
        localId: localId,
        chatId: chatId,
        text: m.text,
      );
      await db.updateMessageByLocalId(localId, status: MessageStatus.pending);
    }
    if (failed.isNotEmpty) {
      _onChat.add(chatId);
    }
    unawaited(drainOutbox());
  }

  /// Отправить статус «печатает». При оборванном сокете молча проглатывает.
  Future<void> sendTyping(int chatId, {bool active = true}) async {
    try {
      await client.typing(chatId, isTyping: active);
    } catch (e) {
      _log.d('typing swallowed: $e');
    }
  }

  Future<void> _onPush(IncomingMessage m) async {
    if (m.messageId != null && await db.isProcessed(m.messageId!)) return;
    if (m.messageId != null) await db.markProcessed(m.messageId!);

    final myId = await storage.readMyUserId();
    final dir = (myId != null && m.sender == myId)
        ? MessageDirection.outgoing
        : MessageDirection.incoming;
    final msg = MaxMessage(
      id: m.messageId,
      chatId: m.chatId,
      senderId: m.sender,
      text: m.text,
      timeMs: m.timeMs ?? DateTime.now().millisecondsSinceEpoch,
      direction: dir,
    );
    await db.insertMessage(msg);
    if (m.attaches.isNotEmpty && m.messageId != null) {
      await _persistAttaches(
        m.attaches,
        chatId: m.chatId,
        messageServerId: m.messageId,
      );
    }
    final preview = msg.text.isNotEmpty ? msg.text : '[Вложение]';
    await db.updateChatPreview(
      chatId: m.chatId,
      timeMs: msg.timeMs,
      preview: preview,
      incUnread: dir == MessageDirection.incoming ? 1 : 0,
    );
    _onChat.add(m.chatId);
  }
}
