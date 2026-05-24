import 'dart:async';

import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../local/database.dart';
import '../local/secure_storage.dart';
import '../max/max_client.dart';
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

  StreamSubscription<IncomingMessage>? _pushSub;
  final _onChat = StreamController<int>.broadcast();

  /// Поток id чатов, в которых что-то изменилось.
  Stream<int> get changedChats => _onChat.stream;

  Future<void> start() async {
    _pushSub ??= client.incomingStream.listen(_onPush, onError: (e) {
      _log.w('push stream error: $e');
    });
  }

  Future<void> stop() async {
    await _pushSub?.cancel();
    _pushSub = null;
  }

  Future<List<MaxMessage>> localHistory(int chatId, {int limit = 200}) =>
      db.messages(chatId, limit: limit);

  /// Подтянуть N последних сообщений с сервера и сохранить локально.
  Future<List<MaxMessage>> syncHistory(int chatId, {int count = 50}) async {
    final myId = await storage.readMyUserId();
    final raw = await client.chatHistory(chatId, count: count);
    final out = <MaxMessage>[];
    for (final m in raw) {
      final id = (m['id'] as num?)?.toInt();
      final sender = (m['sender'] as num?)?.toInt();
      final text = m['text']?.toString() ?? '';
      final time = (m['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      if (text.isEmpty) continue;
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
      out.add(msg);
    }
    if (out.isNotEmpty) {
      final last = out.reduce((a, b) => a.timeMs > b.timeMs ? a : b);
      await db.updateChatPreview(
        chatId: chatId,
        timeMs: last.timeMs,
        preview: last.text,
      );
      _onChat.add(chatId);
    }
    return out;
  }

  Future<MaxMessage> sendText(int chatId, String text) async {
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
    );
    await db.insertMessage(pending);
    await db.updateChatPreview(
      chatId: chatId,
      timeMs: pending.timeMs,
      preview: text,
    );
    _onChat.add(chatId);

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
      _onChat.add(chatId);
      return pending.copyWith(id: serverId, status: MessageStatus.sent);
    } catch (e) {
      _log.w('sendText failed: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed);
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
    await db.updateChatPreview(
      chatId: m.chatId,
      timeMs: msg.timeMs,
      preview: msg.text,
      incUnread: dir == MessageDirection.incoming ? 1 : 0,
    );
    _onChat.add(m.chatId);
  }
}
