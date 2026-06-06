import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/max/models/message.dart';
import '../../state/chats_controller.dart';
import '../widgets/chat_input.dart';
import '../widgets/date_divider.dart';
import '../widgets/message_bubble.dart';
import 'forward_picker_screen.dart';
import 'media_gallery_screen.dart';
import 'profile_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.title});
  final int chatId;
  final String? title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();

  /// Сообщение, на которое сейчас отвечаем. null = обычный режим.
  MaxMessage? _replyTo;

  /// Чтобы понимать, прирос ли список с «низа» (новое сообщение) или с «верха»
  /// (догрузка). При догрузке не дёргаем _scrollToEnd.
  int? _lastBottomTs;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Близко к самому верху (где сидят самые старые) — догружаем.
    if (_scroll.position.pixels <= 80) {
      final ctrl = ref.read(chatHistoryProvider(widget.chatId).notifier);
      if (!ctrl.isLoadingOlder) {
        ctrl.loadOlder();
      }
    }
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

  void _maybeScrollToEnd(List<MaxMessage> msgs) {
    if (msgs.isEmpty) {
      _lastBottomTs = null;
      return;
    }
    final last = msgs.last.timeMs;
    if (_lastBottomTs == null || last > _lastBottomTs!) {
      _lastBottomTs = last;
      _scrollToEnd();
    }
  }

  Future<void> _onMessageLongPress(MaxMessage m) async {
    final canEdit =
        m.direction == MessageDirection.outgoing && m.id != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Ответить'),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Копировать'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Переслать'),
              onTap: () => Navigator.pop(ctx, 'forward'),
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Редактировать'),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'reply') {
      if (m.id == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нельзя ответить: сообщение ещё не подтверждено сервером'),
          ),
        );
        return;
      }
      setState(() => _replyTo = m);
    } else if (action == 'copy') {
      await _copyToClipboard(m.text);
    } else if (action == 'forward') {
      if (m.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Пока пересылаются только текстовые сообщения'),
          ),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ForwardPickerScreen(text: m.text),
        ),
      );
    } else if (action == 'edit') {
      await _showEditDialog(m);
    }
  }

  Future<void> _showEditDialog(MaxMessage m) async {
    final messageId = m.id;
    if (messageId == null) return;
    final controller = TextEditingController(text: m.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Редактировать'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: 'Новый текст',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (newText == null) return;
    final trimmed = newText.trim();
    if (trimmed.isEmpty || trimmed == m.text) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(chatHistoryProvider(widget.chatId).notifier)
          .editMessage(messageId, trimmed);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось отредактировать: $e')),
      );
    }
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(chatHistoryProvider(widget.chatId));
    final ctrl = ref.read(chatHistoryProvider(widget.chatId).notifier);
    final loadingOlder = ctrl.isLoadingOlder;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProfileScreen(
                chatId: widget.chatId,
                title: widget.title,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  child: Text(
                    (widget.title?.isNotEmpty == true)
                        ? widget.title![0].toUpperCase()
                        : '?',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title ?? 'Чат ${widget.chatId}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'был(а) недавно',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Видеозвонок',
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Видеозвонок: в разработке')),
            ),
            icon: const Icon(Icons.videocam_outlined),
          ),
          IconButton(
            tooltip: 'Звонок',
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Звонок: в разработке')),
            ),
            icon: const Icon(Icons.call_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'media') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        MediaGalleryScreen(chatId: widget.chatId),
                  ),
                );
              } else if (v == 'sync') {
                ctrl.syncFromServer();
              } else if (v == 'profile') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(
                      chatId: widget.chatId,
                      title: widget.title,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Профиль')),
              PopupMenuItem(value: 'media', child: Text('Медиа чата')),
              PopupMenuItem(value: 'sync', child: Text('Обновить')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: async.when(
              data: (msgs) {
                _maybeScrollToEnd(msgs);
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text('Сообщений пока нет'),
                  );
                }
                return _buildList(msgs, loadingOlder);
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Ошибка: $e')),
            ),
          ),
          if (_replyTo != null) _replyChip(_replyTo!),
          ChatInput(
            onSend: (text) async {
              final reply = _replyTo;
              setState(() => _replyTo = null);
              await ctrl.send(
                text,
                replyToId: reply?.id,
                replyToPreview: reply?.text,
              );
              _scrollToEnd();
            },
            onTypingChanged: (active) => ctrl.sendTyping(active),
            onAttach: (inputs) async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await ctrl.sendMedia(inputs, text: '');
                _scrollToEnd();
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('Не удалось отправить вложение: $e')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<MaxMessage> msgs, bool loadingOlder) {
    // Собираем плоский список item'ов: спиннер сверху + (date-divider + bubble)*.
    final items = <_ListItem>[];
    if (loadingOlder) {
      items.add(const _ListItem.spinner());
    }
    DateTime? prevDay;
    for (final m in msgs) {
      final t = DateTime.fromMillisecondsSinceEpoch(m.timeMs);
      final day = DateTime(t.year, t.month, t.day);
      if (prevDay == null || day != prevDay) {
        items.add(_ListItem.divider(day));
        prevDay = day;
      }
      items.add(_ListItem.message(m));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final it = items[i];
        switch (it.kind) {
          case _ItemKind.spinner:
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          case _ItemKind.divider:
            return DateDivider(date: it.date!);
          case _ItemKind.message:
            final m = it.message!;
            return GestureDetector(
              onLongPress: () => _onMessageLongPress(m),
              child: MessageBubble(
                message: m,
                chatId: widget.chatId,
                messageServerId: m.id,
                onRetry: m.status == MessageStatus.failed
                    ? () => ref
                        .read(chatHistoryProvider(widget.chatId).notifier)
                        .retryFailed()
                    : null,
              ),
            );
        }
      },
    );
  }

  Widget _replyChip(MaxMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final preview = m.text.length > 80 ? '${m.text.substring(0, 80)}...' : m.text;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.reply, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ответ на:',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Отменить ответ',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }
}

enum _ItemKind { spinner, divider, message }

class _ListItem {
  const _ListItem._(this.kind, {this.date, this.message});
  const _ListItem.spinner() : this._(_ItemKind.spinner);
  _ListItem.divider(DateTime d) : this._(_ItemKind.divider, date: d);
  _ListItem.message(MaxMessage m) : this._(_ItemKind.message, message: m);
  final _ItemKind kind;
  final DateTime? date;
  final MaxMessage? message;
}
