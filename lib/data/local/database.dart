import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/constants.dart';
import '../max/models/attach.dart';
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
      version: 7,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN reply_to_id INTEGER',
      );
      await db.execute(
        'ALTER TABLE messages ADD COLUMN reply_to_preview TEXT',
      );
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE outbox (
          local_id TEXT PRIMARY KEY,
          chat_id INTEGER NOT NULL,
          text TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 4) {
      await _createAttachmentsTable(db);
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN edited_at INTEGER',
      );
      await db.execute(
        'ALTER TABLE attachments ADD COLUMN transcription TEXT',
      );
    }
    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE chats ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE chats ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE chats ADD COLUMN is_muted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 7) {
      // Маршрутизация диалогов 1:1: peer_user_id = тип (диалог с userId),
      // server_chat_id = подтверждённый серверный chatId. cid = дедуп эхо.
      await db.execute('ALTER TABLE chats ADD COLUMN peer_user_id INTEGER');
      await db.execute('ALTER TABLE chats ADD COLUMN server_chat_id INTEGER');
      await db.execute('ALTER TABLE messages ADD COLUMN cid INTEGER');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_chats_server ON chats(server_chat_id)',
      );
    }
  }

  static Future<void> _createAttachmentsTable(Database db) async {
    await db.execute('''
      CREATE TABLE attachments (
        rowid_pk INTEGER PRIMARY KEY AUTOINCREMENT,
        message_local_id TEXT,
        message_server_id INTEGER,
        chat_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'idle',
        token TEXT,
        file_id INTEGER,
        mime_type TEXT,
        size_bytes INTEGER,
        width INTEGER,
        height INTEGER,
        duration_ms INTEGER,
        local_path TEXT,
        download_url TEXT,
        thumbnail_url TEXT,
        file_name TEXT,
        progress REAL NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        transcription TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_att_local ON attachments(message_local_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_att_server ON attachments(message_server_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_att_chat ON attachments(chat_id)
    ''');
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
        unread_count INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        is_muted INTEGER NOT NULL DEFAULT 0,
        peer_user_id INTEGER,
        server_chat_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_chats_time ON chats(last_message_time_ms DESC)
    ''');
    await db.execute('''
      CREATE INDEX idx_chats_server ON chats(server_chat_id)
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
        status TEXT NOT NULL DEFAULT 'sent',
        reply_to_id INTEGER,
        reply_to_preview TEXT,
        edited_at INTEGER,
        cid INTEGER
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

    await db.execute('''
      CREATE TABLE outbox (
        local_id TEXT PRIMARY KEY,
        chat_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await _createAttachmentsTable(db);
  }

  Database get raw => _db;

  // ───────────────────────── chats ─────────────────────────

  Future<List<MaxChat>> chats({bool includeArchived = false}) async {
    final rows = await _db.query(
      'chats',
      where: includeArchived ? null : 'is_archived = 0',
      orderBy: 'is_pinned DESC, last_message_time_ms DESC NULLS LAST',
    );
    return rows.map(MaxChat.fromDbRow).toList();
  }

  Future<List<MaxChat>> archivedChats() async {
    final rows = await _db.query(
      'chats',
      where: 'is_archived = 1',
      orderBy: 'last_message_time_ms DESC NULLS LAST',
    );
    return rows.map(MaxChat.fromDbRow).toList();
  }

  Future<void> setChatFlag(int id, {bool? pinned, bool? archived, bool? muted}) async {
    final values = <String, Object?>{};
    if (pinned != null) values['is_pinned'] = pinned ? 1 : 0;
    if (archived != null) values['is_archived'] = archived ? 1 : 0;
    if (muted != null) values['is_muted'] = muted ? 1 : 0;
    if (values.isEmpty) return;
    await _db.update('chats', values, where: 'id = ?', whereArgs: [id]);
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

  /// Проставить подтверждённый серверный chatId диалогу (после op 64).
  /// id строки НЕ меняется — UI/провайдеры остаются на месте.
  Future<void> setServerChatId(int localChatId, int serverChatId) async {
    await _db.update(
      'chats',
      {'server_chat_id': serverChatId},
      where: 'id = ?',
      whereArgs: [localChatId],
    );
  }

  /// Локальная строка чата по подтверждённому серверному chatId.
  Future<MaxChat?> chatByServerId(int serverChatId) async {
    final rows = await _db.query(
      'chats',
      where: 'server_chat_id = ?',
      whereArgs: [serverChatId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MaxChat.fromDbRow(rows.first);
  }

  /// Локальный chatId, под которым лежит чат с данным серверным id.
  /// Если отдельной строки-диалога нет — возвращает сам serverChatId
  /// (обычные чаты/группы писались под своим серверным id).
  Future<int> localChatIdForServer(int serverChatId) async {
    final c = await chatByServerId(serverChatId);
    return c?.id ?? serverChatId;
  }

  Future<void> updateChatPreview({
    required int chatId,
    required int timeMs,
    required String preview,
    int incUnread = 0,
    int? peerUserId,
  }) async {
    final existing = await chat(chatId);
    if (existing == null) {
      await upsertChat(MaxChat(
        id: chatId,
        title: 'Чат $chatId',
        lastMessageTimeMs: timeMs,
        lastMessagePreview: preview,
        unreadCount: incUnread,
        peerUserId: peerUserId,
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
    if (rows.isEmpty) return const [];
    final base = rows.map(MaxMessage.fromDbRow).toList();
    final byLocal = <String, List<MaxAttach>>{};
    final byServer = <int, List<MaxAttach>>{};
    final attRows = await _db.query(
      'attachments',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'rowid_pk ASC',
    );
    for (final r in attRows) {
      final a = MaxAttach.fromDbRow(r);
      final lid = r['message_local_id'] as String?;
      final sid = (r['message_server_id'] as num?)?.toInt();
      if (lid != null) {
        byLocal.putIfAbsent(lid, () => []).add(a);
      }
      if (sid != null) {
        byServer.putIfAbsent(sid, () => []).add(a);
      }
    }
    return [
      for (final m in base)
        m.copyWith(
          attaches: [
            ...?(m.localId != null ? byLocal[m.localId!] : null),
            ...?(m.id != null ? byServer[m.id!] : null),
          ],
        ),
    ];
  }

  Future<int> insertMessage(MaxMessage m) async {
    return _db.insert(
      'messages',
      m.toMap()..remove('rowid_pk'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// id самого старого сообщения в чате с серверным id (для пагинации).
  /// Возвращает null если в чате нет сообщений с проставленным id.
  Future<int?> oldestServerMessageId(int chatId) async {
    final rows = await _db.query(
      'messages',
      columns: ['id'],
      where: 'chat_id = ? AND id IS NOT NULL',
      whereArgs: [chatId],
      orderBy: 'time_ms ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int?;
  }

  /// Сообщение по серверному id (для построения reply-превью).
  Future<MaxMessage?> messageById(int id) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MaxMessage.fromDbRow(rows.first);
  }

  /// Если входящий push несёт cid нашего исходящего — это эхо уже
  /// существующей локальной строки. Проставляем серверный id вместо вставки
  /// дубля. Возвращает true, если эхо слинковано.
  Future<bool> linkEchoByCid(int cid, int serverId) async {
    final n = await _db.update(
      'messages',
      {'id': serverId, 'status': MessageStatus.sent.name},
      where: 'cid = ? AND id IS NULL',
      whereArgs: [cid],
    );
    return n > 0;
  }

  Future<void> updateMessageByLocalId(
    String localId, {
    int? serverId,
    MessageStatus? status,
    int? cid,
  }) async {
    final values = <String, Object?>{};
    if (serverId != null) values['id'] = serverId;
    if (status != null) values['status'] = status.name;
    if (cid != null) values['cid'] = cid;
    if (values.isEmpty) return;
    await _db.update(
      'messages',
      values,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Применить редактирование (opcode 67) локально: меняем текст и время правки.
  Future<void> updateMessageEdit(
    int serverId,
    String newText,
    int editedAtMs,
  ) async {
    await _db.update(
      'messages',
      {
        'text': newText,
        'edited_at': editedAtMs,
      },
      where: 'id = ?',
      whereArgs: [serverId],
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

  Future<void> deleteContact(int id) async {
    await _db.delete(
      'contacts',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<MaxContact>> searchContacts(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      return contacts();
    }
    final like = '%${q.toLowerCase()}%';
    final rows = await _db.query(
      'contacts',
      where: 'LOWER(name) LIKE ? OR LOWER(phone) LIKE ?',
      whereArgs: [like, like],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(MaxContact.fromDbRow).toList();
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

  // ──────────────────────── outbox ─────────────────────────

  /// Положить исходящее сообщение в очередь для отправки при появлении сети.
  Future<void> enqueueOutbox({
    required String localId,
    required int chatId,
    required String text,
  }) async {
    await _db.insert(
      'outbox',
      {
        'local_id': localId,
        'chat_id': chatId,
        'text': text,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Все pending-записи в очереди отправки, в порядке появления.
  Future<List<Map<String, Object?>>> dequeueOutbox() async {
    return _db.query('outbox', orderBy: 'created_at ASC');
  }

  Future<void> removeOutbox(String localId) async {
    await _db.delete('outbox', where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> incOutboxAttempts(String localId) async {
    await _db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1 WHERE local_id = ?',
      [localId],
    );
  }

  /// Сообщения определённого чата со статусом [status]. Используется
  /// для ручного retry «не отправленных» из UI.
  Future<List<MaxMessage>> messagesByStatus(int chatId, MessageStatus status) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ? AND status = ?',
      whereArgs: [chatId, status.name],
      orderBy: 'time_ms ASC',
    );
    return rows.map(MaxMessage.fromDbRow).toList();
  }

  Future<void> wipe() async {
    await _db.delete('messages');
    await _db.delete('chats');
    await _db.delete('contacts');
    await _db.delete('processed_message_ids');
    await _db.delete('outbox');
    await _db.delete('attachments');
  }

  // ─────────────────────── attachments ─────────────────────

  Future<int> insertAttach(
    MaxAttach a, {
    String? messageLocalId,
    int? messageServerId,
    required int chatId,
  }) async {
    return _db.insert(
      'attachments',
      a.toDbMap()
        ..['message_local_id'] = messageLocalId
        ..['message_server_id'] = messageServerId
        ..['chat_id'] = chatId
        ..['created_at'] = DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Сохранить расшифровку (opcode 202) для attach'а по его rowId.
  Future<void> setAttachTranscription(int rowId, String text) async {
    await _db.update(
      'attachments',
      {'transcription': text},
      where: 'rowid_pk = ?',
      whereArgs: [rowId],
    );
  }

  Future<void> updateAttach(
    int rowId, {
    MaxAttachStatus? status,
    String? token,
    int? fileId,
    String? downloadUrl,
    String? localPath,
    double? progress,
  }) async {
    final values = <String, Object?>{};
    if (status != null) values['status'] = status.name;
    if (token != null) values['token'] = token;
    if (fileId != null) values['file_id'] = fileId;
    if (downloadUrl != null) values['download_url'] = downloadUrl;
    if (localPath != null) values['local_path'] = localPath;
    if (progress != null) values['progress'] = progress;
    if (values.isEmpty) return;
    await _db.update(
      'attachments',
      values,
      where: 'rowid_pk = ?',
      whereArgs: [rowId],
    );
  }

  /// После того как сервер вернул серверный id сообщения, перенесём связь
  /// attach'ей с локального id на серверный, чтобы они нашлись в истории.
  Future<void> linkAttachesToServerId(String localId, int serverId) async {
    await _db.update(
      'attachments',
      {'message_server_id': serverId},
      where: 'message_local_id = ? AND message_server_id IS NULL',
      whereArgs: [localId],
    );
  }

  Future<List<MaxAttach>> attachesForLocal(String localId) async {
    final r = await _db.query(
      'attachments',
      where: 'message_local_id = ?',
      whereArgs: [localId],
      orderBy: 'rowid_pk ASC',
    );
    return r.map(MaxAttach.fromDbRow).toList();
  }

  Future<List<MaxAttach>> attachesForServer(int serverId) async {
    final r = await _db.query(
      'attachments',
      where: 'message_server_id = ?',
      whereArgs: [serverId],
      orderBy: 'rowid_pk ASC',
    );
    return r.map(MaxAttach.fromDbRow).toList();
  }

  /// Все attach'и чата по типам — для будущего экрана «галерея чата».
  Future<List<MaxAttach>> attachesForChat(
    int chatId, {
    List<MaxAttachType>? types,
  }) async {
    final args = <Object?>[chatId];
    var where = 'chat_id = ?';
    if (types != null && types.isNotEmpty) {
      where += ' AND type IN (${List.filled(types.length, '?').join(',')})';
      args.addAll(types.map((t) => t.protocolName));
    }
    final r = await _db.query(
      'attachments',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return r.map(MaxAttach.fromDbRow).toList();
  }
}
