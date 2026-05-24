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

  Future<void> send(String text) async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.sendText(_chatId, text);
  }

  Future<void> syncFromServer({int count = 50}) async {
    final repo = await ref.read(messagesRepositoryProvider.future);
    await repo.syncHistory(_chatId, count: count);
  }
}

final chatHistoryProvider = AsyncNotifierProvider.family<
    ChatHistoryController, List<MaxMessage>, int>(
  ChatHistoryController.new,
);
