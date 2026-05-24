import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/max/models/upload_input.dart';
import 'attach_picker.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.onSend,
    this.onAttach,
    this.onTypingChanged,
  });
  final Future<void> Function(String text) onSend;

  /// Колбэк после выбора пользователем файлов через [AttachPicker].
  /// Если null — кнопка вложений неактивна.
  final void Function(List<UploadInput> inputs)? onAttach;

  /// Колбэк, через который виджет сигналит наверх о статусе «печатает».
  /// Дергается с дебаунсом: true при первом вводе, потом каждые 4 секунды,
  /// false когда поле опустошается.
  final void Function(bool active)? onTypingChanged;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  static const _repeatInterval = Duration(seconds: 4);

  final _ctrl = TextEditingController();
  bool _busy = false;
  bool _typing = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _typingTimer?.cancel();
    if (_typing) {
      widget.onTypingChanged?.call(false);
    }
    _ctrl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    if (hasText) {
      if (!_typing) {
        _typing = true;
        widget.onTypingChanged?.call(true);
        _typingTimer?.cancel();
        _typingTimer = Timer.periodic(_repeatInterval, (_) {
          if (_typing) widget.onTypingChanged?.call(true);
        });
      }
    } else if (_typing) {
      _stopTyping();
    }
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_typing) {
      _typing = false;
      widget.onTypingChanged?.call(false);
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      _ctrl.clear();
      _stopTyping();
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
              onPressed: widget.onAttach == null
                  ? null
                  : () async {
                      final inputs = await AttachPicker.show(context);
                      if (inputs.isNotEmpty) {
                        widget.onAttach?.call(inputs);
                      }
                    },
              icon: const Icon(Icons.attach_file),
              tooltip: 'Прикрепить',
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
