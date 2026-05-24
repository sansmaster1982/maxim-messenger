import 'package:logger/logger.dart';

import '../local/database.dart';
import '../max/max_client.dart';
import '../max/models/attach.dart';

/// Репозиторий галереи: подтягивает медиа чата по opcode 51 и кеширует
/// в локальную таблицу `attachments`. Локальная выборка идёт через
/// [AppDatabase.attachesForChat]; новых таблиц не создаём.
class MediaRepository {
  MediaRepository({
    required this.client,
    required this.db,
    Logger? logger,
  }) : _log = logger ?? Logger();

  final MaxClient client;
  final AppDatabase db;
  final Logger _log;

  /// Подтянуть с сервера медиа чата и слить в локальную таблицу. Возвращает
  /// текущий локальный срез attach'ей после sync.
  ///
  /// [types] определяет фильтр по типам; по умолчанию — `PHOTO` и `VIDEO`.
  /// Дубли защищаются по паре (messageId, fileId): если для серверного id
  /// сообщения уже хранится attach с тем же fileId — пропускаем insert.
  Future<List<MaxAttach>> syncChatMedia(
    int chatId, {
    List<MaxAttachType>? types,
  }) async {
    final filterTypes = types ?? const [MaxAttachType.photo, MaxAttachType.video];
    final attachTypes = filterTypes.map((t) => t.protocolName).toList();

    Map<String, dynamic> res;
    try {
      res = await client.chatMedia(
        chatId: chatId,
        attachTypes: attachTypes,
        forward: 200,
      );
    } catch (e) {
      _log.w('chatMedia($chatId) failed: $e');
      return localChatMedia(chatId, types: filterTypes);
    }

    final rawList = _extractList(res);
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      final messageId = _extractMessageId(m);
      try {
        final attach = MaxAttach.fromServer(m);
        if (messageId != null) {
          final existing = await db.attachesForServer(messageId);
          final dup = existing.any((a) =>
              a.fileId != null && attach.fileId != null && a.fileId == attach.fileId);
          if (dup) continue;
        }
        await db.insertAttach(
          attach,
          chatId: chatId,
          messageServerId: messageId,
        );
      } catch (e) {
        _log.w('syncChatMedia: skip bad attach: $e');
      }
    }
    return localChatMedia(chatId, types: filterTypes);
  }

  /// Локальная выборка attach'ей чата без обращения к сети. Удобно для
  /// мгновенной отрисовки галереи до фонового sync.
  Future<List<MaxAttach>> localChatMedia(
    int chatId, {
    List<MaxAttachType>? types,
  }) {
    return db.attachesForChat(chatId, types: types);
  }

  /// Из ответа server'а на opcode 51 нужно вытащить плоский список attach'ей.
  /// MAX отдаёт это под одним из ключей: `attaches`, `media`, `items`.
  static List<dynamic> _extractList(Map<String, dynamic> res) {
    for (final key in const ['attaches', 'media', 'items', 'attachments']) {
      final v = res[key];
      if (v is List) return v;
    }
    return const [];
  }

  /// Сервер может класть messageId под разными ключами в зависимости от
  /// версии протокола.
  static int? _extractMessageId(Map<String, dynamic> m) {
    for (final key in const ['messageId', 'messageOriginId', 'origin', 'msgId']) {
      final v = m[key];
      if (v is num) return v.toInt();
    }
    return null;
  }
}
