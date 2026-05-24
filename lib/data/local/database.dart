import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/constants.dart';
import '../max/models/chat.dart';
import '../max/models/contact.dart';
import '../max/models/message.dart';

/// Локальная БД: чаты, сообщения, контакты, dedup id'шек.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;
  static AppDatabase? _instance;

  static Future<AppDatabase> instance() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, AppMeta.dbName);
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE chats (
        id INTEGER PRIMARY KEY,
        title TEXT,
        avatar_url TEXT,
        is_group INTEGER NOT NULL DEFAULT 0,
        last_message_time_ms INTEGER,
        last_message_preview TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_chats_time ON chats(last_message_time_ms DESC)
    ''');

    await db.execute('''
      CREATE TABLE messages (
        rowid_pk INTEGER PRIMARY KEY AUTOINCREMENT,
        id INTEGER,
        local_id TEXT,
        chat_id INTEGER NOT NULL,
        sender_id INTEGER,
        text TEXT NOT NULL,
        time_ms INTEGER NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'sent'
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_messages_chat_time
        ON messages(chat_id, time_ms DESC)
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_messages_id
        ON messages(id) WHERE id IS NOT NULL
    ''');

    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY,
        name TEXT,
        phone TEXT,
        avatar_url TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE processed_message_ids (
        id INTEGER PRIMARY KEY,
        seen_at INTEGER NOT NULL
      )
    ''');
  }

  Database get raw => _db;

  // ───────────────────────── chats ─────────────────────────

  Future<List<MaxChat>> chats() async {
    final rows = await _db.query(
      'chats',
      orderBy: 'last_message_time_ms DESC NULLS LAST',
    );
    return rows.map(MaxChat.fromDbRow).toList();
  }

  Future<MaxChat?> chat(int id) async {
    final rows = await _db.query(
      'chats',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MaxChat.fromDbRow(rows.first);
  }

  Future<void> upsertChat(MaxChat c) async {
    await _db.insert(
      'chats',
      c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateChatPreview({
    required int chatId,
    required int timeMs,
    required String preview,
    int incUnread = 0,
  }) async {
    final existing = await chat(chatId);
    if (existing == null) {
      await upsertChat(MaxChat(
        id: chatId,
        title: 'Чат $chatId',
        lastMessageTimeMs: timeMs,
        lastMessagePreview: preview,
        unreadCount: incUnread,
      ));
    } else {
      await upsertChat(existing.copyWith(
        lastMessageTimeMs: timeMs,
        lastMessagePreview: preview,
        unreadCount: existing.unreadCount + incUnread,
      ));
    }
  }

  Future<void> resetUnread(int chatId) async {
    await _db.update(
      'chats',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  // ──────────────────────── messages ───────────────────────

  Future<List<MaxMessage>> messages(int chatId, {int limit = 200}) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'time_ms ASC',
      limit: limit,
    );
    return rows.map(MaxMessage.fromDbRow).toList();
  }

  Future<int> insertMessage(MaxMessage m) async {
    return _db.insert(
      'messages',
      m.toMap()..remove('rowid_pk'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> updateMessageByLocalId(
    String localId, {
    int? serverId,
    MessageStatus? status,
  }) async {
    final values = <String, Object?>{};
    if (serverId != null) values['id'] = serverId;
    if (status != null) values['status'] = status.name;
    if (values.isEmpty) return;
    await _db.update(
      'messages',
      values,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // ──────────────────────── contacts ───────────────────────

  Future<List<MaxContact>> contacts() async {
    final rows = await _db.query('contacts', orderBy: 'name COLLATE NOCASE');
    return rows.map(MaxContact.fromDbRow).toList();
  }

  Future<MaxContact?> contact(int id) async {
    final rows = await _db.query(
      'contacts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MaxContact.fromDbRow(rows.first);
  }

  Future<void> upsertContact(MaxContact c) async {
    await _db.insert(
      'contacts',
      c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ─────────────────────── processed ids ───────────────────

  Future<bool> isProcessed(int messageId) async {
    final r = await _db.query(
      'processed_message_ids',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  Future<void> markProcessed(int messageId) async {
    await _db.insert(
      'processed_message_ids',
      {
        'id': messageId,
        'seen_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> wipe() async {
    await _db.delete('messages');
    await _db.delete('chats');
    await _db.delete('contacts');
    await _db.delete('processed_message_ids');
  }
}
