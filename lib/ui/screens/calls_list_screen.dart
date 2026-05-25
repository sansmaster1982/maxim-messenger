import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/local/database.dart';
import '../../state/providers.dart';

/// История звонков. WebRTC-вызовы не реализованы (опкоды реал-тайм медиа
/// не реверснуты на момент 0.1.x), поэтому экран показывает локальный
/// журнал и кнопку «новый звонок» с заглушкой.
class CallsListScreen extends ConsumerWidget {
  const CallsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(_callsLogProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Звонки'),
        actions: [
          IconButton(
            tooltip: 'Создать звонок',
            onPressed: () => _showStub(context),
            icon: const Icon(Icons.add_call),
          ),
        ],
      ),
      body: calls.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.call_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'История звонков пуста',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Голосовые и видеозвонки появятся в одном из следующих обновлений.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 0, indent: 72),
            itemBuilder: (_, i) {
              final row = rows[i];
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                    ((row['peer_name'] as String?)?.isNotEmpty == true)
                        ? (row['peer_name'] as String)[0].toUpperCase()
                        : '?',
                  ),
                ),
                title: Text(
                  (row['peer_name'] as String?) ??
                      'Контакт ${row['peer_id'] ?? '?'}',
                ),
                subtitle: Text(_formatCallRow(row)),
                trailing: IconButton(
                  onPressed: () => _showStub(context),
                  icon: const Icon(Icons.call),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showStub(context),
        child: const Icon(Icons.add_call),
      ),
    );
  }

  void _showStub(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Голосовые и видеозвонки в разработке. '
          'Опкоды реал-тайм медиа MAX пока не реверснуты.',
        ),
      ),
    );
  }

  String _formatCallRow(Map<String, Object?> row) {
    final direction = (row['direction'] as String?) ?? 'incoming';
    final missed = (row['missed'] as int? ?? 0) == 1;
    final ts = (row['started_at_ms'] as num?)?.toInt() ?? 0;
    final dur = (row['duration_ms'] as num?)?.toInt() ?? 0;
    final label = missed
        ? 'Пропущенный'
        : direction == 'incoming'
            ? 'Входящий'
            : 'Исходящий';
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final dateStr = DateFormat('d MMM HH:mm', 'ru_RU').format(date);
    final mins = dur ~/ 60000;
    final secs = (dur % 60000) ~/ 1000;
    final durStr = mins > 0
        ? '$mins:${secs.toString().padLeft(2, "0")} мин'
        : (dur > 0 ? '$secs сек' : '');
    return durStr.isEmpty ? '$label · $dateStr' : '$label · $dateStr · $durStr';
  }
}

/// Локальная таблица звонков создаётся on-demand при первом обращении —
/// чтобы не тащить миграцию ради заглушки.
final _callsLogProvider =
    FutureProvider<List<Map<String, Object?>>>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  await _ensureCallsTable(db);
  return db.raw.query('calls', orderBy: 'started_at_ms DESC', limit: 200);
});

Future<void> _ensureCallsTable(AppDatabase db) async {
  await db.raw.execute('''
    CREATE TABLE IF NOT EXISTS calls (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      peer_id INTEGER NOT NULL,
      peer_name TEXT,
      direction TEXT NOT NULL,
      missed INTEGER NOT NULL DEFAULT 0,
      started_at_ms INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'audio'
    )
  ''');
}
