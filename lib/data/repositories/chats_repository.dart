import '../local/database.dart';
import '../max/max_client.dart';
import '../max/models/chat.dart';

class ChatsRepository {
  ChatsRepository({required this.client, required this.db});

  final MaxClient client;
  final AppDatabase db;

  Future<List<MaxChat>> listLocal() => db.chats();

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
        ));
      }
    }
  }

  Future<void> ensureExists(int chatId, {String? title}) async {
    final existing = await db.chat(chatId);
    if (existing == null) {
      await db.upsertChat(MaxChat(id: chatId, title: title ?? 'Чат $chatId'));
    } else if (title != null && (existing.title?.isEmpty ?? true)) {
      await db.upsertChat(existing.copyWith(title: title));
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
          );
        })
        .whereType<MaxChat>()
        .toList();
  }
}
