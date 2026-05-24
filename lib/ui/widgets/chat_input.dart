import 'package:flutter/material.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({super.key, required this.onSend, this.onAttach});
  final Future<void> Function(String text) onSend;
  final VoidCallback? onAttach;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      _ctrl.clear();
      await widget.onSend(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: widget.onAttach,
              icon: const Icon(Icons.attach_file),
              tooltip: 'Прикрепить (TODO: опкоды загрузки не реверснуты)',
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Сообщение',
                ),
              ),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _busy ? null : _send,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
