import 'dart:typed_data';

import 'package:equatable/equatable.dart';

class IncomingMessage extends Equatable {
  final int chatId;
  final int? messageId;
  final int? sender;
  final String text;
  final int? timeMs;
  final Uint8List raw;

  /// Сырой список attach'ей из push-payload. Каждый элемент — map с полем
  /// `_type` и набором полей зависящих от типа. Парсится в `MaxAttach.fromServer`.
  final List<Map<String, dynamic>> attaches;

  const IncomingMessage({
    required this.chatId,
    required this.text,
    required this.raw,
    this.messageId,
    this.sender,
    this.timeMs,
    this.attaches = const [],
  });

  @override
  List<Object?> get props => [chatId, messageId, sender, text, timeMs, attaches];
}
