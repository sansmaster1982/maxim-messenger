import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import '../../core/errors.dart';
import '../local/database.dart';
import '../max/max_client.dart';
import '../max/models/attach.dart';
import '../max/models/upload_input.dart';

/// Ошибка на стадии аплоада: либо протокол MAX не дал URL, либо HTTP-сервер
/// вернул не-2xx, либо в теле ответа не нашлось токена. Наследуется от
/// [MaxError], чтобы вызывающий код мог ловить общим catch.
class UploadError extends MaxError {
  const UploadError(super.message);
  @override
  String toString() => 'UploadError: $message';
}

/// Заливает локальный файл на upload-сервер MAX, парсит токен и сохраняет
/// его в таблице `attachments`. Не знает про сообщения — этим занимается
/// [MessagesRepository].
class UploadRepository {
  UploadRepository({
    required this.client,
    required this.db,
    http.Client? httpClient,
    Logger? logger,
  })  : _http = httpClient ?? http.Client(),
        _log = logger ?? Logger();

  final MaxClient client;
  final AppDatabase db;
  final http.Client _http;
  final Logger _log;

  /// Заливает файл и возвращает обновлённый [MaxAttach] со статусом
  /// `uploaded` и проставленным token/fileId. [attachRowId] — id уже
  /// существующей строки в attachments (status=uploading). Прогресс
  /// эмитится в диапазоне 0..1.
  Future<MaxAttach> upload(
    UploadInput input,
    int attachRowId, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0);

    // 1. Получаем upload URL через нужный опкод.
    final Map<String, dynamic> opResponse;
    switch (input.type) {
      case MaxAttachType.photo:
        opResponse = await client.requestPhotoUpload(count: 1, profile: false);
        break;
      case MaxAttachType.video:
      case MaxAttachType.videoMsg:
        opResponse = await client.requestVideoUpload(
          type: 'VIDEO',
          count: 1,
          uploaderType: 'VIDEO',
        );
        break;
      case MaxAttachType.audio:
        opResponse = await client.requestVideoUpload(
          type: 'AUDIO',
          count: 1,
          uploaderType: 'AUDIO',
        );
        break;
      case MaxAttachType.file:
      case MaxAttachType.sticker:
        opResponse = await client.requestFileUpload(count: 1);
        break;
    }

    final url = _extractUploadUrl(opResponse);
    if (url == null) {
      _log.w('upload URL missing in op response: $opResponse');
      await db.updateAttach(attachRowId, status: MaxAttachStatus.failed);
      throw const UploadError('upload URL missing');
    }

    // 2. HTTP POST файла. Прогресс — грубый, без stream-байтов:
    // 0 → старт, 0.5 → отправили тело, 1.0 → получили токен.
    onProgress?.call(0.1);
    final file = File(input.path);
    if (!await file.exists()) {
      await db.updateAttach(attachRowId, status: MaxAttachStatus.failed);
      throw UploadError('local file not found: ${input.path}');
    }

    // Реальный MAX льёт файл одним PUT СЫРЫХ байтов (не multipart):
    // Content-Type: application/octet-stream + content-disposition/-range.
    // Ответ — msgpack {token, attachId}. (w6j.java/z6j.java в декомпиле.)
    final bytes = await file.readAsBytes();
    final host = Uri.tryParse(url)?.host ?? '?';
    _log.i('upload POST ${bytes.length}B → host=$host');
    final request = http.Request('POST', Uri.parse(url))
      ..bodyBytes = bytes
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers['Content-Disposition'] =
          'attachment; filename=${Uri.encodeComponent(input.fileName ?? 'file')}';

    onProgress?.call(0.3);
    http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request);
    } catch (e) {
      _log.w('upload HTTP send failed: $e');
      await db.updateAttach(attachRowId, status: MaxAttachStatus.failed);
      throw UploadError('HTTP send failed: $e');
    }
    onProgress?.call(0.7);

    final bodyBytes = await streamed.stream.toBytes();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      _log.w('upload non-2xx: ${streamed.statusCode} body=${_safeAscii(bodyBytes)}');
      await db.updateAttach(attachRowId, status: MaxAttachStatus.failed);
      throw UploadError('HTTP ${streamed.statusCode}');
    }

    final parsed = _extractTokenFromBytes(bodyBytes);
    if (parsed.token == null && parsed.fileId == null) {
      _log.w('upload token missing in body (len=${bodyBytes.length})');
      await db.updateAttach(attachRowId, status: MaxAttachStatus.failed);
      throw const UploadError('token missing in upload response');
    }

    // 3. Помечаем attach как uploaded.
    await db.updateAttach(
      attachRowId,
      status: MaxAttachStatus.uploaded,
      token: parsed.token,
      fileId: parsed.fileId,
      progress: 1.0,
    );
    onProgress?.call(1.0);

    // 4. Собираем актуальный MaxAttach.
    final fileSize = await _safeFileSize(file);
    return MaxAttach(
      rowId: attachRowId,
      type: input.type,
      status: MaxAttachStatus.uploaded,
      token: parsed.token,
      fileId: parsed.fileId,
      mimeType: input.mimeType,
      size: fileSize,
      width: input.width,
      height: input.height,
      durationMs: input.durationMs,
      localPath: input.path,
      fileName: input.fileName,
      progress: 1.0,
    );
  }

  Future<int?> _safeFileSize(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return null;
    }
  }

  /// Достаёт upload endpoint из ответа опкодов 80/82/87. Поля точно не
  /// зафиксированы в декомпиле, поэтому ищем варианты, которые встречаются
  /// в реальных payload'ах MAX и других мессенджеров на той же основе.
  String? _extractUploadUrl(Map<String, dynamic> resp) {
    for (final key in const ['url', 'uploadUrl', 'endpoint']) {
      final v = resp[key];
      if (v is String && v.isNotEmpty) return v;
    }
    for (final listKey in const ['info', 'urls', 'upload', 'uploads']) {
      final lst = resp[listKey];
      if (lst is List && lst.isNotEmpty) {
        final first = lst.first;
        if (first is String && first.isNotEmpty) return first;
        if (first is Map) {
          for (final k in const ['url', 'uploadUrl', 'endpoint']) {
            final v = first[k];
            if (v is String && v.isNotEmpty) return v;
          }
        }
      }
    }
    // Иногда payload приходит вложенным в result/data.
    for (final wrapKey in const ['result', 'data', 'response']) {
      final w = resp[wrapKey];
      if (w is Map) {
        final inner = w.map((k, v) => MapEntry(k.toString(), v));
        final nested = _extractUploadUrl(inner);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  /// Ответ upload-сервера MAX — msgpack `{token, attachId, thumbhashBase64}`
  /// (op.java/d7j.java в декомпиле). `token` — это и есть photoToken для
  /// вложения. Если тело не msgpack — откатываемся на JSON/plain парсер.
  _UploadResult _extractTokenFromBytes(List<int> bodyBytes) {
    try {
      final decoded = msgpack.deserialize(
        bodyBytes is Uint8List ? bodyBytes : Uint8List.fromList(bodyBytes),
      );
      if (decoded is Map) {
        final m = decoded.map((k, v) => MapEntry(k.toString(), v));
        final token = m['token']?.toString();
        final attachId = (m['attachId'] as num?)?.toInt() ??
            (m['fileId'] as num?)?.toInt() ??
            (m['id'] as num?)?.toInt();
        if ((token != null && token.isNotEmpty) || attachId != null) {
          return _UploadResult(token: token, fileId: attachId);
        }
      }
    } catch (_) {
      // не msgpack — пробуем как текст/JSON ниже
    }
    return _extractToken(utf8.decode(bodyBytes, allowMalformed: true));
  }

  static String _safeAscii(List<int> b) {
    final s = utf8.decode(b, allowMalformed: true);
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  /// Парсит тело HTTP-ответа с upload-сервера. Возвращает любой из:
  /// `photoToken`, `token`, `videoId`, `fileId`, `id`. Поиск идёт сначала
  /// по верхнему уровню, потом по `result.tokens[0]`, `result.id`,
  /// `result.uploadedFiles[0].token`.
  _UploadResult _extractToken(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // Иногда сервер отдаёт plain-text token — пробуем как есть.
      final trimmed = body.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('<')) {
        return _UploadResult(token: trimmed);
      }
      return const _UploadResult();
    }
    if (decoded is! Map) return const _UploadResult();
    final m = decoded.map((k, v) => MapEntry(k.toString(), v));

    // Реальный ответ /uploadImage: {"photos": {"<id>": {"token": "..."}}}.
    // Токен фото — значение photos.<первый ключ>.token; сам ключ = photoId.
    final photos = m['photos'];
    if (photos is Map && photos.isNotEmpty) {
      final firstId = photos.keys.first;
      final first = photos.values.first;
      if (first is Map) {
        final t = first['token']?.toString();
        if (t != null && t.isNotEmpty) {
          return _UploadResult(token: t, fileId: int.tryParse('$firstId'));
        }
      }
    }

    String? token;
    int? fileId;

    // top-level
    for (final k in const ['photoToken', 'token', 'videoId', 'fileId', 'id']) {
      final v = m[k];
      if (v == null) continue;
      if (token == null && (k == 'photoToken' || k == 'token')) {
        token = v.toString();
      }
      if (fileId == null && (k == 'videoId' || k == 'fileId' || k == 'id')) {
        if (v is num) {
          fileId = v.toInt();
        } else {
          fileId = int.tryParse(v.toString());
        }
      }
    }
    if (token != null || fileId != null) {
      return _UploadResult(token: token, fileId: fileId);
    }

    // result.{tokens[0], id, uploadedFiles[0].token}
    final result = m['result'];
    if (result is Map) {
      final r = result.map((k, v) => MapEntry(k.toString(), v));
      final tokens = r['tokens'];
      if (tokens is List && tokens.isNotEmpty) {
        return _UploadResult(token: tokens.first.toString());
      }
      final id = r['id'];
      if (id is num) {
        return _UploadResult(fileId: id.toInt());
      }
      final uf = r['uploadedFiles'];
      if (uf is List && uf.isNotEmpty && uf.first is Map) {
        final first = (uf.first as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final t = first['token']?.toString();
        final fid = first['fileId'] ?? first['id'];
        final fidInt = fid is num ? fid.toInt() : int.tryParse(fid?.toString() ?? '');
        if (t != null || fidInt != null) {
          return _UploadResult(token: t, fileId: fidInt);
        }
      }
    }
    return const _UploadResult();
  }

  void close() {
    _http.close();
  }
}

class _UploadResult {
  final String? token;
  final int? fileId;
  const _UploadResult({this.token, this.fileId});
}
