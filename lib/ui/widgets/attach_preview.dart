import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/attach.dart';
import '../../state/chats_controller.dart';

/// Превью одного MaxAttach внутри пузыря сообщения. Поддерживает PHOTO,
/// STICKER, VIDEO/VIDEO_MSG, AUDIO, FILE. Сетевые миниатюры кешируются
/// через cached_network_image; локальный файл рисуется из Image.file.
class AttachPreview extends ConsumerWidget {
  const AttachPreview({
    super.key,
    required this.attach,
    required this.chatId,
    required this.messageServerId,
  });

  final MaxAttach attach;
  final int chatId;
  final int? messageServerId;

  static const _previewWidth = 220.0;
  static const _radius = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isUploading = attach.status == MaxAttachStatus.uploading;
    final isDownloading = attach.status == MaxAttachStatus.downloading;
    final isFailed = attach.status == MaxAttachStatus.failed;
    final progressBar = (isUploading || isDownloading)
        ? LinearProgressIndicator(
            value: attach.progress > 0 && attach.progress < 1
                ? attach.progress
                : null,
            minHeight: 3,
          )
        : null;

    final body = switch (attach.type) {
      MaxAttachType.photo || MaxAttachType.sticker => _buildImage(),
      MaxAttachType.video || MaxAttachType.videoMsg =>
        _buildVideo(context, scheme),
      MaxAttachType.audio => _buildAudio(context, scheme),
      MaxAttachType.file => _buildFile(context, ref, scheme),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: Container(
        color: scheme.surfaceContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            if (progressBar != null) progressBar,
            if (isFailed) _failedBadge(scheme),
          ],
        ),
      ),
    );
  }

  Widget _placeholder({IconData icon = Icons.image_outlined}) {
    return Container(
      width: _previewWidth,
      height: 160,
      color: Colors.black12,
      alignment: Alignment.center,
      child: Icon(icon, size: 40, color: Colors.black54),
    );
  }

  Widget _buildImage() {
    final local = attach.localPath;
    if (local != null) {
      final f = File(local);
      if (f.existsSync()) {
        return Image.file(
          f,
          width: _previewWidth,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        );
      }
    }
    final url = attach.thumbnailUrl ?? attach.downloadUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        width: _previewWidth,
        fit: BoxFit.cover,
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) => _placeholder(icon: Icons.broken_image),
      );
    }
    return _placeholder();
  }

  Widget _buildVideo(BuildContext context, ColorScheme scheme) {
    return InkWell(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Видео: TODO плеер')),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildImage(),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_circle_fill,
              color: Colors.white,
              size: 48,
            ),
          ),
          if (attach.durationMs != null)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatDuration(attach.durationMs!),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAudio(BuildContext context, ColorScheme scheme) {
    final dur = attach.durationMs != null
        ? _formatDuration(attach.durationMs!)
        : '--:--';
    return InkWell(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Аудио TODO')),
        );
      },
      child: Container(
        width: _previewWidth,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(Icons.mic, size: 28, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Аудио',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    dur,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFile(
    BuildContext context,
    WidgetRef ref,
    ColorScheme scheme,
  ) {
    final name = (attach.fileName?.trim().isNotEmpty == true)
        ? attach.fileName!
        : 'Файл';
    final sizeLabel = attach.size != null ? _formatSize(attach.size!) : null;
    final isDownloading = attach.status == MaxAttachStatus.downloading;

    return InkWell(
      onTap: () async {
        final local = attach.localPath;
        if (local != null && File(local).existsSync()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Файл: $local')),
          );
          return;
        }
        if (isDownloading) return;
        final serverId = messageServerId;
        if (serverId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Файл недоступен: сообщение ещё не подтверждено сервером',
              ),
            ),
          );
          return;
        }
        await ref
            .read(chatHistoryProvider(chatId).notifier)
            .downloadAttach(attach, serverId);
      },
      child: Container(
        width: _previewWidth,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 28,
              color: scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (sizeLabel != null)
                    Text(
                      sizeLabel,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedBadge(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        'Ошибка',
        style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
      ),
    );
  }

  static String _formatDuration(int ms) {
    final s = (ms ~/ 1000);
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
