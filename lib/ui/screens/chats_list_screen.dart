import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/max/models/chat.dart';
import '../../state/chats_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_banner.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';

class ChatsListScreen extends ConsumerStatefulWidget {
  const ChatsListScreen({super.key});

  @override
  ConsumerState<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends ConsumerState<ChatsListScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Maxim'),
        actions: [
          IconButton(
            tooltip: 'Архив',
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Архив пока пуст')),
            ),
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск',
              ),
            ),
          ),
          Expanded(
            child: chatsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Ошибка: $e')),
              data: (chats) {
                final visible = _query.isEmpty
                    ? chats
                    : chats.where((c) {
                        final t = (c.title ?? '').toLowerCase();
                        final p = (c.lastMessagePreview ?? '').toLowerCase();
                        return t.contains(_query) || p.contains(_query);
                      }).toList();
                if (visible.isEmpty) {
                  return _EmptyState(query: _query);
                }
                return RefreshIndicator(
                  onRefresh: () =>
                      ref.read(chatsListProvider.notifier).refresh(),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 0, indent: 76),
                    itemBuilder: (_, i) => _ChatTile(chat: visible[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ContactsScreen()),
        ),
        tooltip: 'Новый чат',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              query.isEmpty ? Icons.forum_outlined : Icons.search_off,
              size: 56,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              query.isEmpty
                  ? 'Чатов пока нет'
                  : 'Ничего не найдено',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              query.isEmpty
                  ? 'Нажмите на кнопку справа внизу,\nчтобы начать новый чат.'
                  : 'Попробуйте другой запрос.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat});
  final MaxChat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final time = chat.lastMessageTimeMs == null
        ? ''
        : _formatTime(
            DateTime.fromMillisecondsSinceEpoch(chat.lastMessageTimeMs!),
          );
    final initials = (chat.title?.isNotEmpty ?? false)
        ? chat.title!.characters.first.toUpperCase()
        : '?';
    return InkWell(
      onLongPress: () => _showActions(context, ref, chat),
      onTap: () async {
        await ref.read(chatsListProvider.notifier).markRead(chat.id);
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(chatId: chat.id, title: chat.title),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: _avatarColor(chat.id, scheme),
              foregroundColor: Colors.white,
              child: Text(
                initials,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.title ?? 'Чат ${chat.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (time.isNotEmpty)
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 12,
                            color: chat.unreadCount > 0
                                ? scheme.primary
                                : MaxColors.textSecondaryLight,
                            fontWeight: chat.unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.lastMessagePreview ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: MaxColors.textSecondaryLight,
                          ),
                        ),
                      ),
                      if (chat.unreadCount > 0)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${chat.unreadCount}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    MaxChat c,
  ) async {
    final notifier = ref.read(chatsListProvider.notifier);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(c.isPinned
                  ? Icons.push_pin
                  : Icons.push_pin_outlined),
              title: Text(c.isPinned ? 'Открепить' : 'Закрепить'),
              onTap: () {
                notifier.togglePin(c.id, !c.isPinned);
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: Icon(c.isMuted
                  ? Icons.notifications_off
                  : Icons.notifications_off_outlined),
              title: Text(c.isMuted
                  ? 'Включить уведомления'
                  : 'Отключить уведомления'),
              onTap: () {
                notifier.toggleMute(c.id, !c.isMuted);
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: Icon(c.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined),
              title: Text(c.isArchived ? 'Вернуть из архива' : 'Архивировать'),
              onTap: () {
                notifier.toggleArchive(c.id, !c.isArchived);
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.mark_chat_read_outlined),
              title: const Text('Прочитано'),
              onTap: () {
                notifier.markRead(c.id);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final same = dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day;
    if (same) return DateFormat.Hm().format(dt);
    final yest = now.subtract(const Duration(days: 1));
    if (dt.year == yest.year && dt.month == yest.month && dt.day == yest.day) {
      return 'Вчера';
    }
    if (now.difference(dt).inDays < 7) return DateFormat.E('ru_RU').format(dt);
    return DateFormat('d MMM').format(dt);
  }

  static Color _avatarColor(int id, ColorScheme scheme) {
    const palette = [
      Color(0xFF0066FF),
      Color(0xFF34C759),
      Color(0xFFFF9500),
      Color(0xFFFF3B30),
      Color(0xFF5E5CE6),
      Color(0xFFFF2D55),
      Color(0xFF00C2FF),
      Color(0xFFAF52DE),
    ];
    return palette[id.abs() % palette.length];
  }
}
