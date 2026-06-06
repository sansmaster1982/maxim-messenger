import '../local/database.dart';
import '../max/max_client.dart';
import '../max/models/chat.dart';

class ChatsRepository {
  ChatsRepository({required this.client, required this.db});

  final MaxClient client;
  final AppDatabase db;

  Future<List<MaxChat>> listLocal() async {
    final chats = await db.chats();
    // Для диалогов с плейсхолдерным именем («Чат N») или пустым подставляем
    // имя контакта — иначе в списке чат называется числом.
    final out = <MaxChat>[];
    for (final c in chats) {
      final isPlaceholder =
          c.title == null || c.title!.isEmpty || c.title == 'Чат ${c.id}';
      if (isPlaceholder) {
        final contact = await db.contact(c.id);
        final name = contact?.name;
        if (name != null && name.isNotEmpty) {
          out.add(c.copyWith(title: name));
          continue;
        }
      }
      out.add(c);
    }
    return out;
  }

  Future<MaxChat?> get(int id) => db.chat(id);

  /// Запросить chat_info у сервера для списка id и обновить локально.
  Future<void> refresh(List<int> ids) async {
    if (ids.isEmpty) return;
    final info = await client.chatInfo(ids);
    final chats = _extractChats(info);
    for (final c in chats) {
      final existing = await db.chat(c.id);
      if (existing == null) {
        await db.upsertChat(c);
      } else {
        await db.upsertChat(existing.copyWith(
          title: c.title ?? existing.title,
          avatarUrl: c.avatarUrl ?? existing.avatarUrl,
          isGroup: c.isGroup,
          serverChatId: c.serverChatId ?? existing.serverChatId,
        ));
      }
    }
  }

  /// [peerUserId] != null ⇒ это диалог 1:1 (открыт из контакта). Тип приходит
  /// явно из навигации, без эвристики «id ∈ contacts» (она ломала бы группы).
  Future<void> ensureExists(int chatId, {String? title, int? peerUserId}) async {
    final existing = await db.chat(chatId);
    if (existing == null) {
      await db.upsertChat(MaxChat(
        id: chatId,
        title: title ?? 'Чат $chatId',
        peerUserId: peerUserId,
      ));
      return;
    }
    var updated = existing;
    if (title != null && (existing.title?.isEmpty ?? true)) {
      updated = updated.copyWith(title: title);
    }
    // Backfill типа для диалогов, заведённых до миграции v7 (peer_user_id
    // IS NULL, но открыты из контакта) — лечим лениво при открытии.
    if (peerUserId != null && existing.peerUserId == null) {
      updated = updated.copyWith(peerUserId: peerUserId);
    }
    if (!identical(updated, existing)) {
      await db.upsertChat(updated);
    }
  }

  Future<void> markRead(int chatId) => db.resetUnread(chatId);

  static List<MaxChat> _extractChats(Map<String, dynamic> info) {
    Object? arr = info['chats'] ?? info['items'] ?? info['result'];
    if (arr is! List) return const [];
    return arr
        .whereType<Map>()
        .map((m) {
          final mm = m.map((k, v) => MapEntry(k.toString(), v));
          final id = mm['id'];
          if (id is! num) return null;
          final isGroup = mm['type']?.toString().toLowerCase().contains(
                    'group',
                  ) ==
                  true ||
              (mm['membersCount'] is num &&
                  (mm['membersCount'] as num).toInt() > 2);
          return MaxChat(
            id: id.toInt(),
            title: mm['title']?.toString() ?? mm['name']?.toString(),
            avatarUrl: mm['avatar']?.toString() ?? mm['photo']?.toString(),
            isGroup: isGroup,
            // Запись из серверного списка чатов — её id уже серверный,
            // маршрут отправки = chatId (а не userId).
            serverChatId: id.toInt(),
          );
        })
        .whereType<MaxChat>()
        .toList();
  }
}
