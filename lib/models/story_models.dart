class Story {
  final String id;
  final String authorJid;
  final String mediaUrl;
  final String? caption;
  final DateTime postedAt;
  final DateTime expiresAt;
  final bool viewed;
  final String? mediaType;

  Story({
    required this.id,
    required this.authorJid,
    required this.mediaUrl,
    this.caption,
    required this.postedAt,
    required this.expiresAt,
    this.viewed = false,
    this.mediaType,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  static const Duration expireDuration = Duration(hours: 24);

  Story copyWith({
    String? id,
    String? authorJid,
    String? mediaUrl,
    String? caption,
    DateTime? postedAt,
    DateTime? expiresAt,
    bool? viewed,
    String? mediaType,
  }) {
    return Story(
      id: id ?? this.id,
      authorJid: authorJid ?? this.authorJid,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      caption: caption ?? this.caption,
      postedAt: postedAt ?? this.postedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      viewed: viewed ?? this.viewed,
      mediaType: mediaType ?? this.mediaType,
    );
  }
}

class StoryGroup {
  final String authorJid;
  final String? authorName;
  final String? authorAvatarUrl;
  final List<Story> stories;
  final bool hasUnviewed;

  StoryGroup({
    required this.authorJid,
    this.authorName,
    this.authorAvatarUrl,
    required this.stories,
  }) : hasUnviewed = stories.any((s) => !s.viewed);

  Story? get oldestUnviewed {
    final unviewed = stories.where((s) => !s.viewed).toList();
    if (unviewed.isEmpty) return null;
    return unviewed.last;
  }
}
