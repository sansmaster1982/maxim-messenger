import 'package:equatable/equatable.dart';

enum MessageDirection { incoming, outgoing }

enum MessageStatus { pending, sent, delivered, read, failed }

class MaxMessage extends Equatable {
  final int? id;
  final int chatId;
  final int? senderId;
  final String text;
  final int timeMs;
  final MessageDirection direction;
  final MessageStatus status;

  /// Локальный id, который пригодится пока сервер не вернул свой.
  final String? localId;

  const MaxMessage({
    required this.chatId,
    required this.text,
    required this.timeMs,
    required this.direction,
    this.id,
    this.senderId,
    this.status = MessageStatus.sent,
    this.localId,
  });

  MaxMessage copyWith({
    int? id,
    MessageStatus? status,
    String? text,
    int? timeMs,
  }) {
    return MaxMessage(
      id: id ?? this.id,
      chatId: chatId,
      senderId: senderId,
      text: text ?? this.text,
      timeMs: timeMs ?? this.timeMs,
      direction: direction,
      status: status ?? this.status,
      localId: localId,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'local_id': localId,
    'chat_id': chatId,
    'sender_id': senderId,
    'text': text,
    'time_ms': timeMs,
    'direction': direction.name,
    'status': status.name,
  };

  factory MaxMessage.fromDbRow(Map<String, Object?> r) => MaxMessage(
    id: r['id'] as int?,
    localId: r['local_id'] as String?,
    chatId: r['chat_id'] as int,
    senderId: r['sender_id'] as int?,
    text: (r['text'] as String?) ?? '',
    timeMs: (r['time_ms'] as int?) ?? 0,
    direction: MessageDirection.values.firstWhere(
      (d) => d.name == (r['direction'] as String?),
      orElse: () => MessageDirection.incoming,
    ),
    status: MessageStatus.values.firstWhere(
      (s) => s.name == (r['status'] as String?),
      orElse: () => MessageStatus.sent,
    ),
  );

  @override
  List<Object?> get props => [
    id,
    localId,
    chatId,
    senderId,
    text,
    timeMs,
    direction,
    status,
  ];
}
