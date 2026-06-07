import 'package:equatable/equatable.dart';

/// Типы вложений MAX. Имена соответствуют значениям `_type` в attach-payload,
/// см. defpackage/c60.java в декомпиле APK.
enum MaxAttachType {
  photo('PHOTO'),
  video('VIDEO'),
  audio('AUDIO'),
  videoMsg('VIDEO_MSG'),
  file('FILE'),
  sticker('STICKER');

  const MaxAttachType(this.protocolName);
  final String protocolName;

  static MaxAttachType fromProtocol(String s) {
    final up = s.toUpperCase();
    return MaxAttachType.values.firstWhere(
      (t) => t.protocolName == up,
      orElse: () => MaxAttachType.file,
    );
  }
}

/// Жизненный цикл вложения с точки зрения локального клиента.
enum MaxAttachStatus { idle, uploading, uploaded, failed, downloading, downloaded }

class MaxAttach extends Equatable {
  /// Локальный rowid в таблице attachments. Не отсылается на сервер.
  final int? rowId;

  /// Тип вложения.
  final MaxAttachType type;

  /// Текущее состояние upload/download.
  final MaxAttachStatus status;

  /// Токен, возвращённый сервером после успешного upload — используется
  /// при отправке сообщения для подкладывания в attaches.
  final String? token;

  /// Идентификатор файла на сервере — для последующего download.
  final int? fileId;

  /// MIME-тип (для file и attachments из ответа сервера).
  final String? mimeType;

  /// Размер в байтах.
  final int? size;

  /// Размеры превью/исходного медиа.
  final int? width;
  final int? height;

  /// Длительность для аудио/видео в миллисекундах.
  final int? durationMs;

  /// Локальный путь к файлу, выбранному пользователем (до загрузки)
  /// или к кешу после скачивания.
  final String? localPath;

  /// URL для скачивания, выданный сервером (опкод 88/83).
  final String? downloadUrl;

  /// URL миниатюры (если сервер прислал).
  final String? thumbnailUrl;

  /// Имя файла (для FILE / отображения в UI).
  final String? fileName;

  /// 0..1 — прогресс upload/download.
  final double progress;

  /// Расшифровка голосового/видео-сообщения, полученная по opcode 202.
  /// null = ещё не запрашивалась или сервер не вернул текст.
  final String? transcription;

  const MaxAttach({
    required this.type,
    this.status = MaxAttachStatus.idle,
    this.rowId,
    this.token,
    this.fileId,
    this.mimeType,
    this.size,
    this.width,
    this.height,
    this.durationMs,
    this.localPath,
    this.downloadUrl,
    this.thumbnailUrl,
    this.fileName,
    this.progress = 0,
    this.transcription,
  });

  MaxAttach copyWith({
    int? rowId,
    MaxAttachStatus? status,
    String? token,
    int? fileId,
    String? mimeType,
    int? size,
    int? width,
    int? height,
    int? durationMs,
    String? localPath,
    String? downloadUrl,
    String? thumbnailUrl,
    String? fileName,
    double? progress,
    String? transcription,
  }) {
    return MaxAttach(
      type: type,
      status: status ?? this.status,
      rowId: rowId ?? this.rowId,
      token: token ?? this.token,
      fileId: fileId ?? this.fileId,
      mimeType: mimeType ?? this.mimeType,
      size: size ?? this.size,
      width: width ?? this.width,
      height: height ?? this.height,
      durationMs: durationMs ?? this.durationMs,
      localPath: localPath ?? this.localPath,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      fileName: fileName ?? this.fileName,
      progress: progress ?? this.progress,
      transcription: transcription ?? this.transcription,
    );
  }

  /// Сериализация для msgpack-payload поля `message.attaches` в SEND_MESSAGE
  /// (op 64). По декомпилу реального MAX (c60.java + dbd.java) на провод для
  /// ФОТО уходит РОВНО `{_type:"PHOTO", photoToken:<token>}` — никаких
  /// width/baseUrl/size, сервер достаёт их сам по токену. Для остальных типов
  /// формат подтверждён слабее, кладём минимум с наиболее вероятным ключом.
  Map<String, Object?> toServerPayload() {
    final m = <String, Object?>{'_type': type.protocolName};
    switch (type) {
      case MaxAttachType.photo:
      case MaxAttachType.sticker:
        if (token != null) m['photoToken'] = token;
        break;
      case MaxAttachType.video:
      case MaxAttachType.videoMsg:
        if (token != null) m['token'] = token;
        if (fileId != null) m['videoId'] = fileId;
        break;
      case MaxAttachType.audio:
        if (token != null) m['token'] = token;
        if (fileId != null) m['audioId'] = fileId;
        break;
      case MaxAttachType.file:
        if (token != null) m['token'] = token;
        if (fileId != null) m['fileId'] = fileId;
        if (fileName != null) m['name'] = fileName;
        break;
    }
    return m;
  }

  /// Достраивает URL картинки из `baseUrl` по правилу реального MAX
  /// (xu0.b: `baseUrl + "&fn=" + descriptor`). baseUrl уже несёт свой токен
  /// в query, поэтому добавляем размер через `&` (или `?`, если query пуст).
  static String withSizeDescriptor(String baseUrl, String descriptor) {
    final sep = baseUrl.contains('?') ? '&' : '?';
    return '$baseUrl${sep}fn=$descriptor';
  }

  Map<String, Object?> toDbMap() => {
    'type': type.protocolName,
    'status': status.name,
    'token': token,
    'file_id': fileId,
    'mime_type': mimeType,
    'size_bytes': size,
    'width': width,
    'height': height,
    'duration_ms': durationMs,
    'local_path': localPath,
    'download_url': downloadUrl,
    'thumbnail_url': thumbnailUrl,
    'file_name': fileName,
    'progress': progress,
    'transcription': transcription,
  };

  factory MaxAttach.fromDbRow(Map<String, Object?> r) {
    return MaxAttach(
      rowId: r['rowid_pk'] as int?,
      type: MaxAttachType.fromProtocol(
        (r['type'] as String?) ?? 'FILE',
      ),
      status: MaxAttachStatus.values.firstWhere(
        (s) => s.name == (r['status'] as String?),
        orElse: () => MaxAttachStatus.idle,
      ),
      token: r['token'] as String?,
      fileId: (r['file_id'] as num?)?.toInt(),
      mimeType: r['mime_type'] as String?,
      size: (r['size_bytes'] as num?)?.toInt(),
      width: (r['width'] as num?)?.toInt(),
      height: (r['height'] as num?)?.toInt(),
      durationMs: (r['duration_ms'] as num?)?.toInt(),
      localPath: r['local_path'] as String?,
      downloadUrl: r['download_url'] as String?,
      thumbnailUrl: r['thumbnail_url'] as String?,
      fileName: r['file_name'] as String?,
      progress: (r['progress'] as num?)?.toDouble() ?? 0,
      transcription: r['transcription'] as String?,
    );
  }

  /// Распаковка attach из ответа сервера (push или history).
  /// Для фото реальный MAX кладёт `baseUrl` (хост i.oneme.ru, с токеном в
  /// query) и иногда готовый `photoUrl`. URL для показа: `photoUrl` если есть,
  /// иначе `baseUrl + &fn=w_720` (p80.b/xu0.b в декомпиле).
  factory MaxAttach.fromServer(Map<String, Object?> m) {
    final typeStr = m['_type']?.toString() ?? m['type']?.toString() ?? 'FILE';
    final type = MaxAttachType.fromProtocol(typeStr);

    final baseUrl = m['baseUrl']?.toString();
    final photoUrl = m['photoUrl']?.toString();
    final previewUrl = m['previewUrl']?.toString();
    final isImage =
        type == MaxAttachType.photo || type == MaxAttachType.sticker;

    String? displayUrl;
    if (photoUrl != null && photoUrl.isNotEmpty) {
      displayUrl = photoUrl;
    } else if (baseUrl != null && baseUrl.isNotEmpty) {
      displayUrl = withSizeDescriptor(
        baseUrl,
        type == MaxAttachType.sticker ? 'sqr_256' : 'w_720',
      );
    }
    // Миниатюра: явный previewUrl, иначе квадрат из baseUrl для картинок.
    String? thumbUrl = (previewUrl != null && previewUrl.isNotEmpty)
        ? previewUrl
        : m['thumbnail']?.toString();
    if ((thumbUrl == null || thumbUrl.isEmpty) &&
        isImage &&
        baseUrl != null &&
        baseUrl.isNotEmpty) {
      thumbUrl = withSizeDescriptor(baseUrl, 'sqr_320');
    }

    return MaxAttach(
      type: type,
      status: MaxAttachStatus.uploaded,
      token: m['photoToken']?.toString() ?? m['token']?.toString(),
      fileId: (m['fileId'] as num?)?.toInt() ??
          (m['photoId'] as num?)?.toInt() ??
          (m['videoId'] as num?)?.toInt() ??
          (m['id'] as num?)?.toInt(),
      mimeType: m['mimeType']?.toString(),
      size: (m['size'] as num?)?.toInt(),
      width: (m['width'] as num?)?.toInt(),
      height: (m['height'] as num?)?.toInt(),
      durationMs: (m['duration'] as num?)?.toInt(),
      downloadUrl: displayUrl,
      thumbnailUrl: thumbUrl,
      fileName: m['name']?.toString(),
    );
  }

  @override
  List<Object?> get props => [
    rowId,
    type,
    status,
    token,
    fileId,
    mimeType,
    size,
    width,
    height,
    durationMs,
    localPath,
    downloadUrl,
    thumbnailUrl,
    fileName,
    progress,
    transcription,
  ];
}
