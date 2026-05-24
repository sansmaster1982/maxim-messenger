import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/contact.dart';
import '../../state/providers.dart';
import 'chat_screen.dart';

final _contactsListProvider = FutureProvider<List<MaxContact>>((ref) async {
  final repo = await ref.watch(contactsRepositoryProvider.future);
  return repo.listLocal();
});

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_contactsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Контакты'),
        actions: [
          IconButton(
            tooltip: 'Добавить по номеру',
            onPressed: () => _showAddDialog(context, ref),
            icon: const Icon(Icons.person_add_alt),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Контактов нет. Добавь первый по номеру телефона.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _showAddDialog(context, ref),
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Добавить'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 0),
            itemBuilder: (_, i) {
              final c = items[i];
              final initial =
                  (c.name?.isNotEmpty ?? false) ? c.name![0].toUpperCase() : '?';
              return ListTile(
                leading: CircleAvatar(child: Text(initial)),
                title: Text(c.name ?? c.phone ?? 'Контакт ${c.id}'),
                subtitle: c.phone == null ? null : Text(c.phone!),
                trailing: const Icon(Icons.chat_bubble_outline),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(chatId: c.id, title: c.name),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Найти по номеру'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              hintText: '+79991234567',
              labelText: 'Телефон',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Найти'),
            ),
          ],
        );
      },
    );
    if (result == null || result.isEmpty) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(contactsRepositoryProvider.future);
      final c = await repo.findByPhone(result);
      ref.invalidate(_contactsListProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('Найден: ${c.name ?? c.phone ?? c.id}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }
}
