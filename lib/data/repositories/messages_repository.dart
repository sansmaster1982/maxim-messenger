import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../local/database.dart';
import '../local/secure_storage.dart';
import '../max/max_client.dart';
import '../max/models/attach.dart';
import '../max/models/incoming_message.dart';
import '../max/models/message.dart';
import '../max/models/upload_input.dart';
import 'upload_repository.dart';

class MessagesRepository {
  MessagesRepository({
    required this.client,
    required this.db,
    required this.storage,
    UploadRepository? uploader,
    Logger? logger,
  })  : _log = logger ?? Logger(),
        uploader = uploader ??
            UploadRepository(
              client: client,
              db: db,
              logger: logger,
            );

  final MaxClient client;
  final AppDatabase db;
  final SecureStorage storage;
  final UploadRepository uploader;
  final Logger _log;
  static const _uuid = Uuid();
  static const _maxAttempts = 5;

  StreamSubscription<IncomingMessage>? _pushSub;
  StreamSubscription<MaxConnectionState>? _stateSub;
  StreamSubscription<List<dynamic>>? _syncSub;
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
    // Восстановление входящих медиа из синка чатов (op 19): если живой push
    // (op 128) был пропущен на обрыве, lastMessage с вложением долетит здесь.
    _syncSub ??= client.syncedChatsStream.listen(
      (chats) => unawaited(_ingestSyncedChats(chats)),
      onError: (e) => _log.w('synced chats stream error: $e'),
    );
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
    await _syncSub?.cancel();
    _syncSub = null;
  }

  Future<List<MaxMessage>> localHistory(int chatId, {int limit = 200}) =>
      db.messages(chatId, limit: limit);

  /// Подтянуть N последних сообщений с сервера и сохранить локально.
  /// Вызывается часто как unawaited — поэтому НЕ бросаем при отсутствии сети,
  /// иначе ловим Unhandled Exception. На offline отдаём локальную историю.
  Future<List<MaxMessage>> syncHistory(int chatId, {int count = 50}) async {
    try {
      return await _fetchAndStore(
        chatId,
        fromId: 0,
        count: count,
        updatePreview: true,
      );
    } on MaxNotConnected catch (e) {
      _log.i('syncHistory skipped (offline): $e');
      return localHistory(chatId);
    } on MaxTimeout catch (e) {
      _log.i('syncHistory skipped (timeout): $e');
      return localHistory(chatId);
    }
  }

  /// Догрузить более старые сообщения от самого раннего локально известного id.
  /// Возвращает то, что удалось вытащить (может быть пусто, если на сервере
  /// больше ничего нет или соединение мертвое).
  Future<List<MaxMessage>> loadOlder(int chatId, {int count = 50}) async {
    try {
      final oldest = await db.oldestServerMessageId(chatId);
      if (oldest == null) {
        // локально пусто — нечего пагинировать, имеет смысл только обычный sync
        return await _fetchAndStore(
          chatId,
          fromId: 0,
          count: count,
          updatePreview: true,
        );
      }
      return await _fetchAndStore(
        chatId,
        fromId: oldest,
        count: count,
        updatePreview: false,
      );
    } on MaxNotConnected catch (e) {
      _log.i('loadOlder skipped (offline): $e');
      return localHistory(chatId);
    } on MaxTimeout catch (e) {
      _log.i('loadOlder skipped (timeout): $e');
      return localHistory(chatId);
    }
  }

  Future<List<MaxMessage>> _fetchAndStore(
    int chatId, {
    required int fromId,
    required int count,
    required bool updatePreview,
  }) async {
    final myId = await storage.readMyUserId();
    // op 49 требует СЕРВЕРНЫЙ chatId. Локальная строка диалога имеет id =
    // userId собеседника (создан из контакта), и сервер по нему отдаёт пусто —
    // история и входящие медиа не подгружались. Резолвим в serverChatId.
    final route = await _resolveRoute(chatId);
    final reqChatId = route.chatId ?? chatId;
    final raw =
        await client.chatHistory(reqChatId, fromId: fromId, count: count);
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

  /// Куда слать (op 64): server_chat_id != null → chatId; иначе peer_user_id
  /// != null → новый диалог по userId; иначе legacy/группа → chatId = id.
  Future<({int? chatId, int? peerUserId})> _resolveRoute(int chatId) async {
    final c = await db.chat(chatId);
    if (c == null) return (chatId: null, peerUserId: chatId);
    if (c.serverChatId != null) {
      return (chatId: c.serverChatId, peerUserId: null);
    }
    if (c.peerUserId != null) {
      return (chatId: null, peerUserId: c.peerUserId);
    }
    // Маршрут не выставлен (старая строка или чат открыт не из навигации).
    // Если этот id есть в контактах — это диалог 1:1, слать по userId.
    // Группы сюда не попадают: у них server_chat_id проставлен при синхронизации
    // списка чатов, и мы вышли бы выше по ветке serverChatId.
    final contact = await db.contact(chatId);
    if (contact != null) {
      return (chatId: null, peerUserId: chatId);
    }
    return (chatId: c.id, peerUserId: null);
  }

  int? _serverMsgId(Map<String, dynamic> res) {
    final m = res['message'];
    if (m is Map) return (m['id'] as num?)?.toInt();
    return null;
  }

  /// Достать серверный chatId из ответа op 64 (ключ не подтверждён — перебор
  /// источников) и записать маршрут на ту же локальную строку, БЕЗ переноса
  /// данных: id строки не меняется, UI/провайдеры остаются на месте.
  Future<void> _reconcileServerChatId(
    Map<String, dynamic> res,
    ({int? chatId, int? peerUserId}) route,
    int localChatId,
  ) async {
    if (route.peerUserId == null) return; // обычный чат — маршрут уже известен
    int? serverChatId = (res['chatId'] as num?)?.toInt();
    final chatObj = res['chat'];
    if (serverChatId == null && chatObj is Map) {
      serverChatId = (chatObj['id'] as num?)?.toInt();
    }
    final m = res['message'];
    if (serverChatId == null && m is Map) {
      serverChatId = (m['chatId'] as num?)?.toInt();
    }
    if (serverChatId == null) return; // ключ не пришёл — деградация, не регресс
    await db.setServerChatId(localChatId, serverChatId);
  }

  Future<MaxMessage> sendText(
    int chatId,
    String text, {
    int? replyToId,
    String? replyToPreview,
  }) async {
    if (text.trim().isEmpty) {
      // Пустой текст сервер отвергает (proto.payload) и рвёт соединение.
      throw ArgumentError('Пустое сообщение');
    }
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

    final cid = DateTime.now().microsecondsSinceEpoch;
    try {
      final route = await _resolveRoute(chatId);
      final res = await client.sendMessage(
        chatId: route.chatId,
        peerUserId: route.peerUserId,
        text: text,
        cid: cid,
      );
      final serverId = _serverMsgId(res);
      await _reconcileServerChatId(res, route, chatId);
      await db.updateMessageByLocalId(
        localId,
        serverId: serverId,
        status: MessageStatus.sent,
        cid: cid,
      );
      _onChat.add(chatId);
      return pending.copyWith(id: serverId, status: MessageStatus.sent);
    } on MaxNotConnected catch (e) {
      _log.i('sendText offline, queued: $e');
      await db.updateMessageByLocalId(localId, cid: cid);
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      _onChat.add(chatId);
      return pending;
    } on MaxTimeout catch (e) {
      _log.i('sendText timeout, queued: $e');
      await db.updateMessageByLocalId(localId, cid: cid);
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      _onChat.add(chatId);
      return pending;
    } on MaxRejected catch (e) {
      // permanent (user.not.found и т.п.) → rejected, не повторяем;
      // транзиентный (throttle/flood) → failed, можно повторить руками.
      _log.w('sendText rejected: $e');
      final st = e.isPermanent ? MessageStatus.rejected : MessageStatus.failed;
      await db.updateMessageByLocalId(localId, status: st);
      _onChat.add(chatId);
      return pending.copyWith(status: st);
    } catch (e) {
      _log.w('sendText failed: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed);
    }
  }

  /// Отправить сообщение с одним или несколькими вложениями. Каждый
  /// [UploadInput] сначала аплоадится через [UploadRepository], затем все
  /// собранные attach-payload передаются в `sendMessage`. Прогресс
  /// конкретного файла эмитится через [onProgress] с его индексом.
  ///
  /// Если хоть один upload падает — сообщение помечается failed и
  /// исключение пробрасывается дальше. Уже загруженные attach'и при этом
  /// остаются со статусом uploaded, чтобы их можно было переотправить.
  Future<MaxMessage> sendMedia(
    int chatId,
    List<UploadInput> inputs, {
    String text = '',
    int? replyToId,
    void Function(int attachIndex, double progress)? onProgress,
  }) async {
    if (inputs.isEmpty) {
      throw ArgumentError('sendMedia requires at least one input');
    }

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
    );
    await db.insertMessage(pending);

    // Создаём attach-строки в статусе uploading.
    final attachRowIds = <int>[];
    for (final input in inputs) {
      final fileSize = await _safeSize(input.path);
      final draft = MaxAttach(
        type: input.type,
        status: MaxAttachStatus.uploading,
        mimeType: input.mimeType,
        size: fileSize,
        width: input.width,
        height: input.height,
        durationMs: input.durationMs,
        localPath: input.path,
        fileName: input.fileName,
      );
      final rowId = await db.insertAttach(
        draft,
        chatId: chatId,
        messageLocalId: localId,
      );
      attachRowIds.add(rowId);
    }

    await db.updateChatPreview(
      chatId: chatId,
      timeMs: pending.timeMs,
      preview: text.isNotEmpty ? text : '[Загрузка вложения]',
    );
    _onChat.add(chatId);

    // Последовательный upload.
    final uploaded = <MaxAttach>[];
    for (var i = 0; i < inputs.length; i++) {
      try {
        final a = await uploader.upload(
          inputs[i],
          attachRowIds[i],
          onProgress: (p) => onProgress?.call(i, p),
        );
        uploaded.add(a);
        _onChat.add(chatId);
      } catch (e) {
        _log.w('sendMedia upload failed at index $i: $e');
        // Помечаем все ещё не аплоаженные как failed.
        for (var j = i; j < attachRowIds.length; j++) {
          await db.updateAttach(
            attachRowIds[j],
            status: MaxAttachStatus.failed,
          );
        }
        await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
        _onChat.add(chatId);
        return pending.copyWith(status: MessageStatus.failed);
      }
    }

    // Все файлы загружены — собираем payload и шлём sendMessage.
    final attachesPayload =
        uploaded.map((a) => a.toServerPayload()).toList(growable: false);
    final cid = DateTime.now().microsecondsSinceEpoch;
    try {
      final route = await _resolveRoute(chatId);
      final res = await client.sendMessage(
        chatId: route.chatId,
        peerUserId: route.peerUserId,
        text: text,
        attaches: attachesPayload,
        replyToId: replyToId,
        cid: cid,
      );
      final serverId = _serverMsgId(res);
      await _reconcileServerChatId(res, route, chatId);
      await db.updateMessageByLocalId(
        localId,
        serverId: serverId,
        status: MessageStatus.sent,
        cid: cid,
      );
      if (serverId != null) {
        await db.linkAttachesToServerId(localId, serverId);
      }
      await db.updateChatPreview(
        chatId: chatId,
        timeMs: pending.timeMs,
        preview: text.isNotEmpty ? text : '[Вложение]',
      );
      _onChat.add(chatId);
      return pending.copyWith(
        id: serverId,
        status: MessageStatus.sent,
        attaches: uploaded,
      );
    } on MaxNotConnected catch (e) {
      // Файл УЖЕ залит (token в attachments). Не теряем его — кладём в очередь,
      // op 64 до-отправится на reconnect с тем же токеном, без повторной заливки.
      _log.i('sendMedia offline after upload, queued for retry: $e');
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      await db.updateMessageByLocalId(localId, status: MessageStatus.pending);
      _onChat.add(chatId);
      return pending.copyWith(
        status: MessageStatus.pending,
        attaches: uploaded,
      );
    } on MaxTimeout catch (e) {
      _log.i('sendMedia timeout after upload, queued for retry: $e');
      await db.enqueueOutbox(localId: localId, chatId: chatId, text: text);
      await db.updateMessageByLocalId(localId, status: MessageStatus.pending);
      _onChat.add(chatId);
      return pending.copyWith(
        status: MessageStatus.pending,
        attaches: uploaded,
      );
    } on MaxRejected catch (e) {
      _log.w('sendMedia rejected: $e');
      final st = e.isPermanent ? MessageStatus.rejected : MessageStatus.failed;
      await db.updateMessageByLocalId(localId, status: st);
      _onChat.add(chatId);
      return pending.copyWith(status: st, attaches: uploaded);
    } catch (e) {
      _log.w('sendMedia sendMessage failed: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed, attaches: uploaded);
    }
  }

  Future<int?> _safeSize(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// Скачать вложение в локальный кеш. Возвращает абсолютный путь к файлу
  /// или null, если файл нельзя достать (нет fileId, сетевая ошибка).
  ///
  /// Кеш-хит: если `a.localPath` существует на диске — отдаём его без
  /// похода на сервер. URL запрашивается через opcode 83 (video) или 88
  /// (всё остальное). Прогресс эмитится в БД каждые 64KB; после успеха
  /// статус становится `downloaded`, путь и downloadUrl сохраняются.
  Future<String?> downloadAttach(
    MaxAttach a, {
    required int chatId,
    required int messageId,
  }) async {
    final existingPath = a.localPath;
    if (existingPath != null) {
      try {
        if (await File(existingPath).exists()) return existingPath;
      } catch (_) {
        // упало stat — продолжаем как cache miss
      }
    }
    final fileId = a.fileId;
    if (fileId == null) return null;
    final rowId = a.rowId;

    Future<void> setStatus(MaxAttachStatus s, {double? progress}) async {
      if (rowId == null) return;
      await db.updateAttach(rowId, status: s, progress: progress);
    }

    try {
      await setStatus(MaxAttachStatus.downloading, progress: 0);

      // Получаем актуальный URL у сервера.
      final Map<String, dynamic> res;
      if (a.type == MaxAttachType.video) {
        res = await client.requestVideoPlay(
          videoId: fileId,
          chatId: chatId,
          messageId: messageId,
          token: a.token,
        );
      } else {
        res = await client.requestFileDownload(
          fileId: fileId,
          chatId: chatId,
          messageId: messageId,
        );
      }
      final url = res['url']?.toString();
      if (url == null || url.isEmpty) {
        _log.w('downloadAttach: empty url for fileId=$fileId');
        await setStatus(MaxAttachStatus.failed);
        return null;
      }

      // Готовим путь в getApplicationDocumentsDirectory()/maxim_media.
      final docs = await getApplicationDocumentsDirectory();
      final mediaDir = Directory(p.join(docs.path, 'maxim_media'));
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }
      final safeName = (a.fileName != null && a.fileName!.trim().isNotEmpty)
          ? a.fileName!.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          : 'file';
      final outPath = p.join(mediaDir.path, '${fileId}_$safeName');

      // Стримим GET в файл; прогресс каждые 64KB.
      final httpClient = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await httpClient.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.w('downloadAttach: HTTP ${response.statusCode} on $url');
          await setStatus(MaxAttachStatus.failed);
          return null;
        }
        final total = response.contentLength;
        final out = File(outPath);
        final sink = out.openWrite();
        var received = 0;
        var sinceEmit = 0;
        const emitEvery = 64 * 1024;
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            received += chunk.length;
            sinceEmit += chunk.length;
            if (sinceEmit >= emitEvery && total != null && total > 0) {
              sinceEmit = 0;
              final p01 = (received / total).clamp(0.0, 1.0);
              if (rowId != null) {
                await db.updateAttach(rowId, progress: p01);
              }
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        if (rowId != null) {
          await db.updateAttach(
            rowId,
            status: MaxAttachStatus.downloaded,
            localPath: outPath,
            downloadUrl: url,
            progress: 1.0,
          );
        }
        _onChat.add(chatId);
        return outPath;
      } finally {
        httpClient.close();
      }
    } on SocketException catch (e) {
      _log.w('downloadAttach socket error: $e');
      await setStatus(MaxAttachStatus.failed);
      return null;
    } on HttpException catch (e) {
      _log.w('downloadAttach http error: $e');
      await setStatus(MaxAttachStatus.failed);
      return null;
    } on MaxNotConnected catch (e) {
      _log.i('downloadAttach offline: $e');
      await setStatus(MaxAttachStatus.failed);
      return null;
    } on MaxTimeout catch (e) {
      _log.i('downloadAttach timeout: $e');
      await setStatus(MaxAttachStatus.failed);
      return null;
    } catch (e) {
      _log.w('downloadAttach failed: $e');
      await setStatus(MaxAttachStatus.failed);
      return null;
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
        // Уже залитые вложения сообщения (token в attachments, привязка по
        // message_local_id) — подкладываем в op 64 БЕЗ повторной заливки.
        // Это и делает фото-отправку устойчивой к обрыву после upload.
        final localAttaches = await db.attachesForLocal(localId);
        final attachesPayload = localAttaches
            .where((a) =>
                a.status == MaxAttachStatus.uploaded && a.token != null)
            .map((a) => a.toServerPayload())
            .toList(growable: false);
        // Дропаем, только если НЕТ ни текста, ни вложений (пустой payload сервер
        // отвергает и РВЁТ коннект). Фото с пустой подписью — валидно.
        if (text.trim().isEmpty && attachesPayload.isEmpty) {
          _log.w('drainOutbox: дроп пустого сообщения $localId');
          await db.updateMessageByLocalId(
            localId,
            status: MessageStatus.rejected,
          );
          await db.removeOutbox(localId);
          _onChat.add(chatId);
          continue;
        }
        final cid = DateTime.now().microsecondsSinceEpoch;
        try {
          final route = await _resolveRoute(chatId);
          final res = await client.sendMessage(
            chatId: route.chatId,
            peerUserId: route.peerUserId,
            text: text,
            attaches: attachesPayload.isEmpty ? null : attachesPayload,
            cid: cid,
          );
          final serverId = _serverMsgId(res);
          await _reconcileServerChatId(res, route, chatId);
          await db.updateMessageByLocalId(
            localId,
            serverId: serverId,
            status: MessageStatus.sent,
            cid: cid,
          );
          if (serverId != null) {
            await db.linkAttachesToServerId(localId, serverId);
          }
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
        } on MaxRejected catch (e) {
          if (e.isPermanent) {
            // НЕвосстановимо (user.not.found и т.п.): дроп из очереди, статус
            // rejected, дренаж продолжает. Это и убирает «вечный долбёж».
            _log.w('drainOutbox permanent reject, dropping: $e');
            await db.updateMessageByLocalId(
              localId,
              status: MessageStatus.rejected,
            );
            await db.removeOutbox(localId);
            _onChat.add(chatId);
            continue;
          }
          // Транзиентный (throttle/flood): НЕ дропаем валидное сообщение —
          // ведём как timeout, попробуем при следующем reconnect.
          _log.i('drainOutbox transient reject, will retry: $e');
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
          // Останавливаемся — попробуем при следующем reconnect.
          return;
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// Редактирование сообщения (opcode 67). Возвращает свежий [MaxMessage]
  /// из локальной БД после успешной правки или null, если сообщения нет
  /// в локальной таблице.
  Future<MaxMessage?> editMessage(
    int chatId,
    int messageId,
    String newText,
  ) async {
    final existing = await db.messageById(messageId);
    if (existing == null) {
      _log.w('editMessage: message $messageId not found locally');
      return null;
    }
    try {
      await client.editMessage(chatId, messageId, newText);
    } catch (e) {
      _log.w('editMessage failed: $e');
      rethrow;
    }
    final editedAt = DateTime.now().millisecondsSinceEpoch;
    await db.updateMessageEdit(messageId, newText, editedAt);
    _onChat.add(chatId);
    return db.messageById(messageId);
  }

  /// Запросить расшифровку у сервера (opcode 202) и закешировать. Если
  /// transcription уже есть — возвращается без обращения к сети.
  Future<String?> transcribeAttach(
    MaxAttach a, {
    required int chatId,
    required int messageId,
  }) async {
    final cached = a.transcription;
    if (cached != null && cached.isNotEmpty) return cached;
    final fileId = a.fileId;
    if (fileId == null) return null;
    final Map<String, dynamic> res;
    try {
      res = await client.transcribeMedia(
        mediaId: fileId,
        chatId: chatId,
        messageId: messageId,
      );
    } catch (e) {
      _log.w('transcribeMedia failed: $e');
      return null;
    }
    String? text = res['text']?.toString();
    text ??= res['transcription']?.toString();
    if (text == null) {
      final result = res['result'];
      if (result is Map) {
        text = result['text']?.toString();
      }
    }
    if (text == null || text.isEmpty) return null;
    final rowId = a.rowId;
    if (rowId != null) {
      await db.setAttachTranscription(rowId, text);
      _onChat.add(chatId);
    }
    return text;
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

  /// Из синка чатов (op 19) сохраняем ВХОДЯЩИЕ сообщения с вложениями, если их
  /// ещё нет локально. Это страховка приёма медиа: op 49 (история) вложения не
  /// отдаёт, а живой op 128 теряется на обрыве — а тут lastMessage с фото
  /// долетает на каждом reconnect. Дедуп — по серверному id сообщения.
  Future<void> _ingestSyncedChats(List<dynamic> chats) async {
    final myId = await storage.readMyUserId();
    for (final raw in chats) {
      if (raw is! Map) continue;
      final cm = raw.map((k, v) => MapEntry(k.toString(), v));
      final serverChatId = (cm['id'] as num?)?.toInt();
      final lm = cm['lastMessage'];
      if (serverChatId == null || lm is! Map) continue;
      final m = lm.map((k, v) => MapEntry(k.toString(), v));
      final msgId = (m['id'] as num?)?.toInt();
      if (msgId == null) continue;
      final attRaw = (m['attaches'] ?? m['attachments']) as List?;
      // Только НАСТОЯЩЕЕ медиа (фото/видео/аудио/файл). Системные вложения
      // (_type: CONTROL — приветствие «Избранного», сервисные события) НЕ тянем,
      // иначе в списке всплывают служебные чаты вроде «welcome.saved.dialog».
      final media = (attRaw ?? const []).where((a) {
        if (a is! Map) return false;
        final t = (a['_type'] ?? a['type'])?.toString().toUpperCase();
        return t == 'PHOTO' ||
            t == 'VIDEO' ||
            t == 'AUDIO' ||
            t == 'VIDEO_MSG' ||
            t == 'FILE' ||
            t == 'STICKER';
      }).toList();
      if (media.isEmpty) continue;
      if (await db.isProcessed(msgId)) continue; // уже есть (push/прошлый синк)
      await db.markProcessed(msgId);
      final sender = (m['sender'] as num?)?.toInt();
      // Своё отправленное эхо пропускаем — оно линкуется по cid отдельно.
      if (myId != null && sender == myId) continue;
      final localChatId = await db.localChatIdForServer(serverChatId);
      final text = m['text']?.toString() ?? '';
      final time = (m['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      await db.insertMessage(MaxMessage(
        id: msgId,
        chatId: localChatId,
        senderId: sender,
        text: text,
        timeMs: time,
        direction: MessageDirection.incoming,
      ));
      await _persistAttaches(
        media,
        chatId: localChatId,
        messageServerId: msgId,
      );
      await db.updateChatPreview(
        chatId: localChatId,
        timeMs: time,
        preview: text.isNotEmpty ? text : '[Вложение]',
        incUnread: 1,
      );
      _onChat.add(localChatId);
      _log.i('синк: восстановлено входящее медиа msg=$msgId chat=$localChatId');
    }
  }

  Future<void> _onPush(IncomingMessage m) async {
    if (m.messageId != null && await db.isProcessed(m.messageId!)) return;
    if (m.messageId != null) await db.markProcessed(m.messageId!);

    final myId = await storage.readMyUserId();
    final dir = (myId != null && m.sender == myId)
        ? MessageDirection.outgoing
        : MessageDirection.incoming;

    // Входящий несёт СЕРВЕРНЫЙ chatId; пишем под локальной строкой диалога,
    // если она известна (диалог открывали из контакта по userId).
    final localChatId = await db.localChatIdForServer(m.chatId);

    // Эхо собственного отправленного: слинковать с локальной строкой по cid,
    // не вставляя дубль.
    if (dir == MessageDirection.outgoing &&
        m.cid != null &&
        m.messageId != null) {
      final linked = await db.linkEchoByCid(m.cid!, m.messageId!);
      if (linked) {
        _onChat.add(localChatId);
        return;
      }
    }

    final msg = MaxMessage(
      id: m.messageId,
      chatId: localChatId,
      senderId: m.sender,
      text: m.text,
      timeMs: m.timeMs ?? DateTime.now().millisecondsSinceEpoch,
      direction: dir,
    );
    await db.insertMessage(msg);
    if (m.attaches.isNotEmpty && m.messageId != null) {
      await _persistAttaches(
        m.attaches,
        chatId: localChatId,
        messageServerId: m.messageId,
      );
    }
    final preview = msg.text.isNotEmpty ? msg.text : '[Вложение]';
    await db.updateChatPreview(
      chatId: localChatId,
      timeMs: msg.timeMs,
      preview: preview,
      incUnread: dir == MessageDirection.incoming ? 1 : 0,
    );
    _onChat.add(localChatId);
  }
}
