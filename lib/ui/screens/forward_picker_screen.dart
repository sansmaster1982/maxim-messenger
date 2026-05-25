import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/chat.dart';
import '../../state/chats_controller.dart';

/// Экран выбора чата для пересылки.
class ForwardPickerScreen extends ConsumerStatefulWidget {
  const ForwardPickerScreen({super.key, required this.text});
  final String text;

  @override
  ConsumerState<ForwardPickerScreen> createState() =>
      _ForwardPickerScreenState();
}

class _ForwardPickerScreenState extends ConsumerState<ForwardPickerScreen> {
  String _query = '';
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Переслать в'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск чата',
              ),
            ),
          ),
        ),
      ),
      body: chatsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (chats) {
          final visible = _query.isEmpty
              ? chats
              : chats
                  .where((c) => (c.title ?? '').toLowerCase().contains(_query))
                  .toList();
          if (visible.isEmpty) {
            return const Center(child: Text('Ничего не найдено'));
          }
          return ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, __) => const Divider(height: 0, indent: 72),
            itemBuilder: (_, i) {
              final c = visible[i];
              return _ForwardTile(
                chat: c,
                disabled: _sending,
                onPicked: () => _forwardTo(c),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _forwardTo(MaxChat c) async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ctrl = ref.read(chatHistoryProvider(c.id).notifier);
      await ctrl.send(widget.text);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Переслано в ${c.title ?? "чат ${c.id}"}')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }
}

class _ForwardTile extends StatelessWidget {
  const _ForwardTile({
    required this.chat,
    required this.onPicked,
    required this.disabled,
  });
  final MaxChat chat;
  final VoidCallback onPicked;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: disabled ? null : onPicked,
      leading: CircleAvatar(
        child: Text(
          (chat.title?.isNotEmpty ?? false)
              ? chat.title!.characters.first.toUpperCase()
              : '?',
        ),
      ),
      title: Text(chat.title ?? 'Чат ${chat.id}'),
      subtitle: chat.lastMessagePreview == null
          ? null
          : Text(
              chat.lastMessagePreview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: disabled
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
