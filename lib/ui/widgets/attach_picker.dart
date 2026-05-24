import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/max/models/upload_input.dart';

/// Bottom-sheet с четырьмя источниками вложений: фото из галереи,
/// видео из галереи, съёмка фотокамерой и произвольный файл.
/// Возвращает список [UploadInput] — пустой, если пользователь
/// закрыл sheet без выбора или дал отказ.
class AttachPicker {
  AttachPicker._();

  static Future<List<UploadInput>> show(BuildContext context) async {
    final result = await showModalBottomSheet<List<UploadInput>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото из галереи'),
              onTap: () async {
                final picked = await _pickPhotos();
                if (ctx.mounted) Navigator.of(ctx).pop(picked);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Видео из галереи'),
              onTap: () async {
                final picked = await _pickGalleryVideo();
                if (ctx.mounted) Navigator.of(ctx).pop(picked);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Снять фото'),
              onTap: () async {
                final picked = await _pickCamera(video: false);
                if (ctx.mounted) Navigator.of(ctx).pop(picked);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Снять видео'),
              onTap: () async {
                final picked = await _pickCamera(video: true);
                if (ctx.mounted) Navigator.of(ctx).pop(picked);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Файл'),
              onTap: () async {
                final picked = await _pickFiles();
                if (ctx.mounted) Navigator.of(ctx).pop(picked);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    return result ?? const <UploadInput>[];
  }

  static Future<List<UploadInput>> _pickPhotos() async {
    try {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage();
      if (files.isEmpty) return const [];
      return files.map((x) => UploadInput.fromPath(x.path)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<UploadInput>> _pickGalleryVideo() async {
    try {
      final picker = ImagePicker();
      final v = await picker.pickVideo(source: ImageSource.gallery);
      if (v == null) return const [];
      return [UploadInput.fromPath(v.path)];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<UploadInput>> _pickCamera({required bool video}) async {
    try {
      final picker = ImagePicker();
      final x = video
          ? await picker.pickVideo(source: ImageSource.camera)
          : await picker.pickImage(source: ImageSource.camera);
      if (x == null) return const [];
      return [UploadInput.fromPath(x.path)];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<UploadInput>> _pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (res == null) return const [];
      final out = <UploadInput>[];
      for (final f in res.files) {
        final path = f.path;
        if (path == null) continue;
        out.add(UploadInput.fromPath(path));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
