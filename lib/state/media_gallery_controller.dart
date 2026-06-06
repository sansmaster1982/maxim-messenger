import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/max/models/attach.dart';
import 'providers.dart';

/// Контроллер галереи медиа конкретного чата. Сразу отдаёт локальный
/// срез из БД, в фоне дёргает sync через [MediaRepository].
class MediaGalleryController
    extends FamilyAsyncNotifier<List<MaxAttach>, int> {
  static const _filterTypes = [MaxAttachType.photo, MaxAttachType.video];

  late int _chatId;

  @override
  Future<List<MaxAttach>> build(int chatId) async {
    _chatId = chatId;
    final repo = await ref.watch(mediaRepositoryProvider.future);
    final local = await repo.localChatMedia(chatId, types: _filterTypes);
    // Фоновый sync: после успеха перерисуем state.
    unawaited(_syncInBackground());
    return local;
  }

  Future<void> _syncInBackground() async {
    try {
      final repo = await ref.read(mediaRepositoryProvider.future);
      final synced = await repo.syncChatMedia(_chatId, types: _filterTypes);
      state = AsyncData(synced);
    } catch (_) {
      // Молчим — локальная выборка уже в state.
    }
  }

  /// Свайп вниз: принудительный rerun sync.
  Future<void> refresh() async {
    final repo = await ref.read(mediaRepositoryProvider.future);
    final synced = await repo.syncChatMedia(_chatId, types: _filterTypes);
    state = AsyncData(synced);
  }
}

final mediaGalleryProvider = AsyncNotifierProvider.family<
    MediaGalleryController, List<MaxAttach>, int>(
  MediaGalleryController.new,
);
