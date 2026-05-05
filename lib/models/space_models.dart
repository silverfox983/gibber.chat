class SpaceNode {
  final String domain;
  final String node;
  final String name;
  final String? description;
  final String? creator;
  final String? avatarUrl;
  final String? affiliation; // 'owner', 'publisher', 'member', 'none'
  final int? memberCount;
  final List<String> features;
  final String? type; // 'service', 'leaf', 'collection', 'muc'
  final String? accessModel;
  final String? publishModel;
  final int? numSubscribers;
  final String? ownerJid;

  // Enriched fields
  final bool isSubscribed;
  final bool notificationsEnabled;
  final DateTime? lastActivity;
  final int? postCount;
  final DateTime? syncedAt;

  SpaceNode({
    required this.domain,
    required this.node,
    required this.name,
    this.description,
    this.creator,
    this.avatarUrl,
    this.affiliation,
    this.memberCount,
    this.features = const [],
    this.type,
    this.accessModel,
    this.publishModel,
    this.numSubscribers,
    this.ownerJid,
    this.isSubscribed = false,
    this.notificationsEnabled = true,
    this.lastActivity,
    this.postCount,
    this.syncedAt,
  });

  SpaceNode copyWith({
    String? domain,
    String? node,
    String? name,
    String? description,
    String? creator,
    String? avatarUrl,
    String? affiliation,
    int? memberCount,
    List<String>? features,
    String? type,
    String? accessModel,
    String? publishModel,
    int? numSubscribers,
    String? ownerJid,
    bool? isSubscribed,
    bool? notificationsEnabled,
    DateTime? lastActivity,
    int? postCount,
    DateTime? syncedAt,
  }) {
    return SpaceNode(
      domain: domain ?? this.domain,
      node: node ?? this.node,
      name: name ?? this.name,
      description: description ?? this.description,
      creator: creator ?? this.creator,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      affiliation: affiliation ?? this.affiliation,
      memberCount: memberCount ?? this.memberCount,
      features: features ?? this.features,
      type: type ?? this.type,
      accessModel: accessModel ?? this.accessModel,
      publishModel: publishModel ?? this.publishModel,
      numSubscribers: numSubscribers ?? this.numSubscribers,
      ownerJid: ownerJid ?? this.ownerJid,
      isSubscribed: isSubscribed ?? this.isSubscribed,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      lastActivity: lastActivity ?? this.lastActivity,
      postCount: postCount ?? this.postCount,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'domain': domain,
      'node': node,
      'name': name,
      'description': description,
      'creator': creator,
      'avatar_url': avatarUrl,
      'affiliation': affiliation,
      'member_count': memberCount,
      'features': features.join(','),
      'type': type,
      'access_model': accessModel,
      'publish_model': publishModel,
      'num_subscribers': numSubscribers,
      'owner_jid': ownerJid,
      'is_subscribed': isSubscribed ? 1 : 0,
      'notifications_enabled': notificationsEnabled ? 1 : 0,
      'last_activity': lastActivity?.toIso8601String(),
      'post_count': postCount,
      'synced_at': syncedAt?.toIso8601String(),
    };
  }

  factory SpaceNode.fromMap(Map<String, dynamic> map) {
    return SpaceNode(
      domain: map['domain'] ?? '',
      node: map['node'] ?? '',
      name: map['name'] ?? '',
      description: map['description'],
      creator: map['creator'],
      avatarUrl: map['avatar_url'],
      affiliation: map['affiliation'],
      memberCount: map['member_count'],
      features: (map['features'] as String?)?.split(',').where((s) => s.isNotEmpty).toList() ?? [],
      type: map['type'],
      accessModel: map['access_model'],
      publishModel: map['publish_model'],
      numSubscribers: map['num_subscribers'],
      ownerJid: map['owner_jid'],
      isSubscribed: map['is_subscribed'] == 1,
      notificationsEnabled: map['notifications_enabled'] == 1,
      lastActivity: map['last_activity'] != null ? DateTime.tryParse(map['last_activity']) : null,
      postCount: map['post_count'],
      syncedAt: map['synced_at'] != null ? DateTime.tryParse(map['synced_at']) : null,
    );
  }
}

class MediaAttachment {
  final String url;
  final String? type;
  final String? title;

  MediaAttachment({required this.url, this.type, this.title});
}

class SpaceItem {
  final String id;
  final String type; // 'room', 'url', 'subscription', 'text', 'entry'
  final String? name;
  final String? url;
  final String? node; // For sub-spaces
  final String? description;
  final String? jid; // Target JID for subscriptions/rooms
  final String? imageUrl; // Inline image for entries (legacy fallback)
  final List<MediaAttachment> mediaAttachments;
  final List<String> categories;
  final String? replyToId;
  final bool isPinned;
  final String? author; // Microblogging author
  final DateTime? publishedDate; // Microblogging date
  final DateTime? updatedDate;
  final String? rawContent; // Microblogging raw content HTML/markdown
  final String? contentType;
  final String? commentNode; // XEP-0277 Replies node
  final String? commentService; // XEP-0277 Replies service
  final SpaceNode? sourceSpace;
  
  // Social extensions — immutable snapshot; UI state tracked in widget Map
  final Map<String, int> reactions;
  final bool isLikedByMe;
  final bool isBookmarked;
  final bool isExpanded; // for read-more

  SpaceItem({
    required this.id,
    required this.type,
    this.name,
    this.url,
    this.node,
    this.description,
    this.jid,
    this.imageUrl,
    this.mediaAttachments = const [],
    this.categories = const [],
    this.replyToId,
    this.isPinned = false,
    this.author,
    this.publishedDate,
    this.updatedDate,
    this.rawContent,
    this.contentType,
    this.commentNode,
    this.commentService,
    this.sourceSpace,
    Map<String, int>? reactions,
    this.isLikedByMe = false,
    this.isBookmarked = false,
    this.isExpanded = false,
  }) : reactions = reactions ?? const {};

  SpaceItem copyWith({
    String? id,
    String? type,
    String? name,
    String? url,
    String? node,
    String? description,
    String? jid,
    String? imageUrl,
    List<MediaAttachment>? mediaAttachments,
    List<String>? categories,
    String? replyToId,
    bool? isPinned,
    String? author,
    DateTime? publishedDate,
    DateTime? updatedDate,
    String? rawContent,
    String? contentType,
    String? commentNode,
    String? commentService,
    SpaceNode? sourceSpace,
    Map<String, int>? reactions,
    bool? isLikedByMe,
    bool? isBookmarked,
    bool? isExpanded,
  }) {
    return SpaceItem(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      url: url ?? this.url,
      node: node ?? this.node,
      description: description ?? this.description,
      jid: jid ?? this.jid,
      imageUrl: imageUrl ?? this.imageUrl,
      mediaAttachments: mediaAttachments ?? this.mediaAttachments,
      categories: categories ?? this.categories,
      replyToId: replyToId ?? this.replyToId,
      isPinned: isPinned ?? this.isPinned,
      author: author ?? this.author,
      publishedDate: publishedDate ?? this.publishedDate,
      updatedDate: updatedDate ?? this.updatedDate,
      rawContent: rawContent ?? this.rawContent,
      contentType: contentType ?? this.contentType,
      commentNode: commentNode ?? this.commentNode,
      commentService: commentService ?? this.commentService,
      sourceSpace: sourceSpace ?? this.sourceSpace,
      reactions: reactions ?? this.reactions,
      isLikedByMe: isLikedByMe ?? this.isLikedByMe,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      isExpanded: isExpanded ?? this.isExpanded,
    );
  }
}

class SpaceMember {
  final String jid;
  final String affiliation; // 'owner', 'publisher', 'member', 'outcast'

  SpaceMember({required this.jid, required this.affiliation});
}
