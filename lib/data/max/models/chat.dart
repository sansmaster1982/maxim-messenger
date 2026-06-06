import 'package:equatable/equatable.dart';

class MaxChat extends Equatable {
  final int id;
  final String? title;
  final String? avatarUrl;
  final bool isGroup;
  final int? lastMessageTimeMs;
  final String? lastMessagePreview;
  final int unreadCount;
  final bool isPinned;
  final bool isArchived;
  final bool isMuted;

  /// != null ⇒ диалог 1:1 с этим userId; null ⇒ группа/канал/неизвестно.
  final int? peerUserId;

  /// != null ⇒ подтверждённый серверный chatId (маршрут отправки op 64).
  final int? serverChatId;

  const MaxChat({
    required this.id,
    this.title,
    this.avatarUrl,
    this.isGroup = false,
    this.lastMessageTimeMs,
    this.lastMessagePreview,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isArchived = false,
    this.isMuted = false,
    this.peerUserId,
    this.serverChatId,
  });

  bool get isDialog => peerUserId != null;

  MaxChat copyWith({
    int? id,
    String? title,
    String? avatarUrl,
    bool? isGroup,
    int? lastMessageTimeMs,
    String? lastMessagePreview,
    int? unreadCount,
    bool? isPinned,
    bool? isArchived,
    bool? isMuted,
    int? peerUserId,
    int? serverChatId,
  }) {
    return MaxChat(
      id: id ?? this.id,
      title: title ?? this.title,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isGroup: isGroup ?? this.isGroup,
      lastMessageTimeMs: lastMessageTimeMs ?? this.lastMessageTimeMs,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
      isArchived: isArchived ?? this.isArchived,
      isMuted: isMuted ?? this.isMuted,
      peerUserId: peerUserId ?? this.peerUserId,
      serverChatId: serverChatId ?? this.serverChatId,
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
    'is_pinned': isPinned ? 1 : 0,
    'is_archived': isArchived ? 1 : 0,
    'is_muted': isMuted ? 1 : 0,
    'peer_user_id': peerUserId,
    'server_chat_id': serverChatId,
  };

  factory MaxChat.fromDbRow(Map<String, Object?> r) => MaxChat(
    id: r['id'] as int,
    title: r['title'] as String?,
    avatarUrl: r['avatar_url'] as String?,
    isGroup: (r['is_group'] as int? ?? 0) == 1,
    lastMessageTimeMs: r['last_message_time_ms'] as int?,
    lastMessagePreview: r['last_message_preview'] as String?,
    unreadCount: r['unread_count'] as int? ?? 0,
    isPinned: (r['is_pinned'] as int? ?? 0) == 1,
    isArchived: (r['is_archived'] as int? ?? 0) == 1,
    isMuted: (r['is_muted'] as int? ?? 0) == 1,
    peerUserId: (r['peer_user_id'] as num?)?.toInt(),
    serverChatId: (r['server_chat_id'] as num?)?.toInt(),
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
    isPinned,
    isArchived,
    isMuted,
    peerUserId,
    serverChatId,
  ];
}
