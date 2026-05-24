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
    try {
      final res = await client.sendMessage(
        chatId,
        text,
        attaches: attachesPayload,
        replyToId: replyToId,
      );
      final serverId = (res['message'] is Map)
          ? ((res['message'] as Map)['id'] as num?)?.toInt()
          : null;
      await db.updateMessageByLocalId(
        localId,
        serverId: serverId,
        status: MessageStatus.sent,
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
      _log.i('sendMedia offline after upload, marking failed: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed, attaches: uploaded);
    } on MaxTimeout catch (e) {
      _log.i('sendMedia timeout after upload: $e');
      await db.updateMessageByLocalId(localId, status: MessageStatus.failed);
      _onChat.add(chatId);
      return pending.copyWith(status: MessageStatus.failed, attaches: uploaded);
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
