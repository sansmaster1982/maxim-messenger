import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chats_controller.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.title});
  final int chatId;
  final String? title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(chatHistoryProvider(widget.chatId));
    final ctrl = ref.read(chatHistoryProvider(widget.chatId).notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Чат ${widget.chatId}'),
        actions: [
          IconButton(
            tooltip: 'Подтянуть с сервера',
            onPressed: () => ctrl.syncFromServer(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: async.when(
              data: (msgs) {
                _scrollToEnd();
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text('Сообщений пока нет'),
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => MessageBubble(message: msgs[i]),
                );
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Ошибка: $e')),
            ),
          ),
          ChatInput(
            onSend: (text) async {
              await ctrl.send(text);
              _scrollToEnd();
            },
            onAttach: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Отправка медиа пока не реализована: опкоды протокола '
                    'для загрузки файлов не реверснуты.',
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
