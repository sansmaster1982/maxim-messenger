import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/max/models/message.dart';
import 'attach_preview.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.chatId,
    this.messageServerId,
  });
  final MaxMessage message;

  /// Колбэк по тапу на статус-иконку failed-сообщения. Если null — иконка не
  /// кликабельная.
  final VoidCallback? onRetry;

  /// id чата — нужен для AttachPreview (запрос download URL).
  final int? chatId;

  /// Серверный id сообщения для download endpoint. Если null, attach
  /// без локального пути не сможет начать скачиваться.
  final int? messageServerId;

  @override
  Widget build(BuildContext context) {
    final isOut = message.direction == MessageDirection.outgoing;
    final scheme = Theme.of(context).colorScheme;
    final bg = isOut ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = isOut ? scheme.onPrimaryContainer : scheme.onSurface;
    final time = DateTime.fromMillisecondsSinceEpoch(message.timeMs);
    final hasReply = message.replyToId != null;
    final isFailed = message.status == MessageStatus.failed;
    final statusColor = isFailed ? scheme.error : fg.withValues(alpha: 0.7);
    final statusIcon = Icon(
      _statusIcon(message.status),
      size: 14,
      color: statusColor,
    );
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
            if (hasReply) _replyBlock(fg),
            if (message.attaches.isNotEmpty) _attachList(),
            if (message.text.isNotEmpty) ...[
              if (message.attaches.isNotEmpty) const SizedBox(height: 4),
              Text(message.text, style: TextStyle(color: fg)),
            ],
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
                if (message.editedAtMs != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    'изм.',
                    style: TextStyle(
                      fontSize: 10,
                      color: fg.withValues(alpha: 0.7),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                if (isOut) ...[
                  const SizedBox(width: 4),
                  if (isFailed && onRetry != null)
                    InkWell(
                      onTap: onRetry,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            statusIcon,
                            const SizedBox(width: 2),
                            Text(
                              'повторить',
                              style: TextStyle(
                                fontSize: 11,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    statusIcon,
                ]
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _attachList() {
    final cId = chatId ?? message.chatId;
    final items = <Widget>[];
    for (var i = 0; i < message.attaches.length; i++) {
      if (i > 0) items.add(const SizedBox(height: 4));
      items.add(AttachPreview(
        attach: message.attaches[i],
        chatId: cId,
        messageServerId: messageServerId ?? message.id,
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: items,
    );
  }

  Widget _replyBlock(Color fg) {
    final preview = message.replyToPreview?.trim();
    final label = (preview == null || preview.isEmpty)
        ? 'Сообщение'
        : preview.length > 80
            ? '${preview.substring(0, 80)}...'
            : preview;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: fg.withValues(alpha: 0.6), width: 3),
        ),
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: fg.withValues(alpha: 0.8),
          fontStyle: FontStyle.italic,
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
