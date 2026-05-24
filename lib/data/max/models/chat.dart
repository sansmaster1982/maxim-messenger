import 'package:equatable/equatable.dart';

class MaxChat extends Equatable {
  final int id;
  final String? title;
  final String? avatarUrl;
  final bool isGroup;
  final int? lastMessageTimeMs;
  final String? lastMessagePreview;
  final int unreadCount;

  const MaxChat({
    required this.id,
    this.title,
    this.avatarUrl,
    this.isGroup = false,
    this.lastMessageTimeMs,
    this.lastMessagePreview,
    this.unreadCount = 0,
  });

  MaxChat copyWith({
    String? title,
    String? avatarUrl,
    bool? isGroup,
    int? lastMessageTimeMs,
    String? lastMessagePreview,
    int? unreadCount,
  }) {
    return MaxChat(
      id: id,
      title: title ?? this.title,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isGroup: isGroup ?? this.isGroup,
      lastMessageTimeMs: lastMessageTimeMs ?? this.lastMessageTimeMs,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'avatar_url': avatarUrl,
    'is_group': isGroup ? 1 : 0,
    'last_message_time_ms': lastMessageTimeMs,
    'last_message_preview': lastMessagePreview,
    'unread_count': unreadCount,
  };

  factory MaxChat.fromDbRow(Map<String, Object?> r) => MaxChat(
    id: r['id'] as int,
    title: r['title'] as String?,
    avatarUrl: r['avatar_url'] as String?,
    isGroup: (r['is_group'] as int? ?? 0) == 1,
    lastMessageTimeMs: r['last_message_time_ms'] as int?,
    lastMessagePreview: r['last_message_preview'] as String?,
    unreadCount: r['unread_count'] as int? ?? 0,
  );

  @override
  List<Object?> get props => [
    id,
    title,
    avatarUrl,
    isGroup,
    lastMessageTimeMs,
    lastMessagePreview,
    unreadCount,
  ];
}
