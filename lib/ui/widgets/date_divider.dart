import 'package:flutter/material.dart';

/// Компактный chip-разделитель между блоками сообщений разных дней.
/// «Сегодня», «Вчера» либо «12 марта» / «12 марта 2024» для прошлых лет.
class DateDivider extends StatelessWidget {
  const DateDivider({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            formatLabel(date),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  static const List<String> _months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  /// Возвращает строку для chip: «Сегодня», «Вчера», «12 марта»,
  /// «12 марта 2024» (если год не текущий).
  static String formatLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    final month = _months[that.month - 1];
    final base = '${that.day} $month';
    return that.year == now.year ? base : '$base ${that.year}';
  }
}
