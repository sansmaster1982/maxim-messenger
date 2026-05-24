import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/max/models/attach.dart';

/// Полноэкранный просмотр одной фотографии/кадра видео. Pinch-to-zoom
/// через [InteractiveViewer]. Источник — локальный файл, если он есть,
/// иначе thumbnail/download URL.
class PhotoViewScreen extends StatelessWidget {
  const PhotoViewScreen({super.key, required this.attach});

  final MaxAttach attach;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          attach.fileName ?? 'Фото',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: _buildImage(),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final local = attach.localPath;
    if (local != null) {
      final f = File(local);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _placeholder(),
        );
      }
    }
    final url = attach.downloadUrl ?? attach.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        placeholder: (_, __) => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return const Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 64,
        color: Colors.white54,
      ),
    );
  }
}
