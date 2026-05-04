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
  
  // Social extensions
  Map<String, int> reactions;
  bool isLikedByMe;
  bool isBookmarked;
  bool isExpanded; // for read-more

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
  }) : reactions = reactions ?? {};
}

class SpaceMember {
  final String jid;
  final String affiliation; // 'owner', 'publisher', 'member', 'outcast'

  SpaceMember({required this.jid, required this.affiliation});
}
