import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/max/models/message.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final MaxMessage message;

  @override
  Widget build(BuildContext context) {
    final isOut = message.direction == MessageDirection.outgoing;
    final scheme = Theme.of(context).colorScheme;
    final bg = isOut ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = isOut ? scheme.onPrimaryContainer : scheme.onSurface;
    final time = DateTime.fromMillisecondsSinceEpoch(message.timeMs);
    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isOut ? 14 : 4),
            bottomRight: Radius.circular(isOut ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.text, style: TextStyle(color: fg)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.Hm().format(time),
                  style: TextStyle(
                    fontSize: 11,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ),
                if (isOut) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _statusIcon(message.status),
                    size: 14,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ]
              ],
            )
          ],
        ),
      ),
    );
  }

  static IconData _statusIcon(MessageStatus s) {
    switch (s) {
      case MessageStatus.pending:
        return Icons.schedule;
      case MessageStatus.sent:
        return Icons.check;
      case MessageStatus.delivered:
        return Icons.done_all;
      case MessageStatus.read:
        return Icons.done_all;
      case MessageStatus.failed:
        return Icons.error_outline;
    }
  }
}
