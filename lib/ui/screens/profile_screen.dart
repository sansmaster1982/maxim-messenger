import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/contact.dart';
import '../../state/providers.dart';
import '../theme/app_theme.dart';
import 'media_gallery_screen.dart';

/// Профиль собеседника. Открывается по тапу на заголовок ChatScreen.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({
    super.key,
    required this.chatId,
    this.title,
  });

  final int chatId;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactAsync = ref.watch(_contactProvider(chatId));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
      ),
      body: contactAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (c) {
          final displayName = c?.name ?? title ?? 'Чат $chatId';
          final phone = c?.phone;
          return ListView(
            children: [
              const SizedBox(height: 24),
              Center(
                child: CircleAvatar(
                  radius: 48,
                  backgroundColor: scheme.primary,
                  foregroundColor: Colors.white,
                  child: Text(
                    displayName.isNotEmpty
                        ? displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (phone != null) ...[
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    phone,
                    style: TextStyle(
                      fontSize: 14,
                      color: MaxColors.textSecondaryLight,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionTile(
                    icon: Icons.chat_bubble_outline,
                    label: 'Чат',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  _ActionTile(
                    icon: Icons.call_outlined,
                    label: 'Звонок',
                    onTap: () => _stub(context, 'Звонок'),
                  ),
                  _ActionTile(
                    icon: Icons.videocam_outlined,
                    label: 'Видео',
                    onTap: () => _stub(context, 'Видеозвонок'),
                  ),
                  _ActionTile(
                    icon: Icons.search,
                    label: 'Поиск',
                    onTap: () => _stub(context, 'Поиск в чате'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Divider(height: 0),
              ListTile(
                leading: const Icon(Icons.collections_outlined),
                title: const Text('Медиа, файлы и ссылки'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MediaGalleryScreen(chatId: chatId),
                  ),
                ),
              ),
              const Divider(height: 0),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Уведомления'),
                subtitle: const Text('Включены'),
                trailing: Switch(
                  value: true,
                  onChanged: (_) => _stub(context, 'Mute'),
                ),
              ),
              const Divider(height: 0),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Закрепить чат'),
                onTap: () => _stub(context, 'Закрепление чата'),
              ),
              const Divider(height: 0),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Архивировать'),
                onTap: () => _stub(context, 'Архивация'),
              ),
              const Divider(height: 0),
              ListTile(
                iconColor: scheme.error,
                textColor: scheme.error,
                leading: const Icon(Icons.delete_outline),
                title: const Text('Очистить историю'),
                onTap: () => _confirmClear(context, ref),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить историю?'),
        content: const Text(
          'Сообщения и вложения будут удалены только локально. '
          'На сервере останется как есть.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final db = await ref.read(appDatabaseProvider.future);
    await db.raw.delete(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    await db.raw.delete(
      'attachments',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('История очищена локально')),
      );
    }
  }

  void _stub(BuildContext context, String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name: в разработке')),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _contactProvider = FutureProvider.family<MaxContact?, int>((ref, id) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return db.contact(id);
});
