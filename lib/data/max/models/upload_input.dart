import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'attach.dart';

/// Описание локального файла, который пользователь хочет загрузить
/// и приложить к исходящему сообщению. Сам по себе не сериализуется —
/// `UploadRepository` берёт отсюда [path] и [type], затем создаёт
/// [MaxAttach] с уже выданным сервером token/fileId.
class UploadInput {
  final String path;
  final MaxAttachType type;
  final String? mimeType;
  final String? fileName;
  final int? width;
  final int? height;
  final int? durationMs;

  const UploadInput({
    required this.path,
    required this.type,
    this.mimeType,
    this.fileName,
    this.width,
    this.height,
    this.durationMs,
  });

  /// Сопоставляет расширение и MIME с [MaxAttachType]. Аудио-форматы
  /// перехватываются по расширению до того как MIME image/video отдаст
  /// неверный тип (например, `.ogg` иногда детектится как video).
  factory UploadInput.fromPath(String path) {
    final mime = lookupMimeType(path);
    final ext = p.extension(path).toLowerCase();
    const audioExts = {'.ogg', '.opus', '.m4a', '.aac', '.mp3', '.wav'};

    MaxAttachType type;
    if (audioExts.contains(ext)) {
      type = MaxAttachType.audio;
    } else if (mime != null && mime.startsWith('image/')) {
      type = MaxAttachType.photo;
    } else if (mime != null && mime.startsWith('video/')) {
      type = MaxAttachType.video;
    } else if (mime != null && mime.startsWith('audio/')) {
      type = MaxAttachType.audio;
    } else {
      type = MaxAttachType.file;
    }

    return UploadInput(
      path: path,
      type: type,
      mimeType: mime,
      fileName: p.basename(path),
    );
  }
}
