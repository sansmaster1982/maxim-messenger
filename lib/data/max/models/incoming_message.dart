import 'dart:typed_data';

import 'package:equatable/equatable.dart';

class IncomingMessage extends Equatable {
  final int chatId;
  final int? messageId;
  final int? sender;
  final String text;
  final int? timeMs;
  final Uint8List raw;

  const IncomingMessage({
    required this.chatId,
    required this.text,
    required this.raw,
    this.messageId,
    this.sender,
    this.timeMs,
  });

  @override
  List<Object?> get props => [chatId, messageId, sender, text, timeMs];
}
