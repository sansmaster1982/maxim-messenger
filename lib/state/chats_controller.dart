import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/max/models/chat.dart';
import '../data/max/models/message.dart';
import 'providers.dart';

/// Поток списка чатов, перерисовывается при любом изменении.
class ChatsListController extends AsyncNotifier<List<MaxChat>> {
  StreamSubscription? _sub;

  @override
  Future<List<MaxChat>> build() async {
    final repo = await ref.watch(chatsRepositoryProvider.future);
    final msgRepo = await ref.watch(messagesRepositoryProvider.future);
    _sub?.cancel();
    _sub = msgRepo.changedChats.listen((_) => _reload());
    ref.onDispose(() => _sub?.cancel());
    return repo.listLocal();
  }

  Future<void> _reload() async {
    final repo = await ref.read(chatsRepositoryProvider.future);
    state = AsyncData(await repo.listLocal());
  }

  Future<void> refresh() => _reload();

  Future<void> markRead(int chatId) async {
    final repo = await ref.read(chatsRepositoryProvider.future);
    await repo.markRead(chatId);
    await _reload();
  }
}

final chatsListProvider =
    AsyncNotifierProvider<ChatsListController, List<MaxChat>>(
  ChatsListController.new,
);

/// Сообщения конкретного чата. Если есть локальные - отдаём сразу,
/// параллельно подтягиваем свежие с сервера.
class ChatHistoryController extends FamilyAsyncNotifier<List<MaxMessage>, int> {
  StreamSubscription? _sub;
  late int _chatId;
  bool _loadingOlder = false;

  /// Истинно пока идёт догрузка более старых сообщений — UI рисует спиннер.
  bool get isLoadingOlder => _loadingOlder;

  @override
  Future<List<MaxMessage>> build(int chatId) async {
    _chatId = chatId;
    final repo = await ref.watch(messagesRepositoryProvider.future);
    final chatsRepo = await ref.watch(chatsRepositoryProvider.future);
    _sub?.cancel();
    _sub = repo.changedChats.where((c) => c == chatId).listen((_) => _reload());
    ref.onDispose(() => _sub?.cancel());
    await chatsRepo.ensureExists(chatId);
    final local = await repo.localHistory(chatId);
    if (local.isEmpty) {
      unawaited(repo.syncHistory(chatId, count: 50));
    } else {
      unawaited(repo.syncHistory(chatId, count: 30));
    }
    return local;
  }

  Future<void> _reload() async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    state = AsyncData(await repo.localHistory(_chatId));
  }

  Future<void> send(
    String text, {
    int? replyToId,
    String? replyToPreview,
  }) async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.sendText(
      _chatId,
      text,
      replyToId: replyToId,
      replyToPreview: replyToPreview,
    );
  }

  Future<void> syncFromServer({int count = 50}) async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.syncHistory(_chatId, count: count);
  }

  /// Подтянуть более старые сообщения. UI вызывает при скролле вверх.
  Future<void> loadOlder({int count = 50}) async {
    if (_loadingOlder) return;
    _loadingOlder = true;
    // Перерисуем, чтобы показать спиннер сверху.
    if (state is AsyncData<List<MaxMessage>>) {
      state = AsyncData(state.value ?? const []);
    }
    try {
      final repo = await ref.read(messagesRepositoryProvider.future);
      await repo.loadOlder(_chatId, count: count);
    } finally {
      _loadingOlder = false;
      if (state is AsyncData<List<MaxMessage>>) {
        state = AsyncData(state.value ?? const []);
      }
    }
  }

  Future<void> sendTyping(bool active) async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.sendTyping(_chatId, active: active);
  }

  /// Повторить отправку всех failed-сообщений этого чата. Дёргает дренаж
  /// outbox в фоне.
  Future<void> retryFailed() async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.retryFailed(_chatId);
  }
}

final chatHistoryProvider = AsyncNotifierProvider.family<
    ChatHistoryController, List<MaxMessage>, int>(
  ChatHistoryController.new,
);
