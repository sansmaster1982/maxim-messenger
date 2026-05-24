import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/attach.dart';
import '../../state/media_gallery_controller.dart';
import 'photo_view_screen.dart';

/// Экран «Медиа чата»: 3-колоночная сетка из PHOTO/VIDEO. Свайп вниз —
/// принудительный sync. Тап на ячейку — fullscreen viewer.
class MediaGalleryScreen extends ConsumerWidget {
  const MediaGalleryScreen({super.key, required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mediaGalleryProvider(chatId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Медиа чата'),
      ),
      body: async.when(
        data: (list) => _buildGrid(context, ref, list),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, WidgetRef ref, List<MaxAttach> items) {
    final notifier = ref.read(mediaGalleryProvider(chatId).notifier);
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: notifier.refresh,
        child: ListView(
          children: const [
            SizedBox(height: 200),
            Center(child: Text('Медиа пока нет')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final a = items[i];
          return _GalleryTile(
            attach: a,
            onTap: () {
              if (a.type == MaxAttachType.video ||
                  a.type == MaxAttachType.videoMsg) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Видео плеер: TODO')),
                );
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PhotoViewScreen(attach: a),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({required this.attach, required this.onTap});

  final MaxAttach attach;
  final VoidCallback onTap;

  bool get _isVideo =>
      attach.type == MaxAttachType.video ||
      attach.type == MaxAttachType.videoMsg;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumb(),
            if (_isVideo)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 36,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumb() {
    final local = attach.localPath;
    if (local != null) {
      final f = File(local);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _ph(),
        );
      }
    }
    final url = attach.thumbnailUrl ?? attach.downloadUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => _ph(),
        errorWidget: (_, __, ___) => _ph(icon: Icons.broken_image_outlined),
      );
    }
    return _ph();
  }

  Widget _ph({IconData icon = Icons.image_outlined}) {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: Icon(icon, size: 32, color: Colors.black54),
    );
  }
}
