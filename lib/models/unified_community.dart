import 'space_models.dart';

export 'space_models.dart';

enum CommunityType { space, room, microblog }

class UnifiedCommunity {
  final String id;
  final String name;
  final String? description;
  final String? avatarUrl;
  final String? coverUrl;
  final int memberCount;
  final bool isJoined;
  final CommunityType type;
  final String domain;
  final String? node;
  final String? jid;
  final bool isPublic;
  final List<String> features;
  final String? affiliation;
  final String? topic;
  final bool passwordProtected;
  final int? occupantCount;
  final String? rawJid;
  final DateTime? lastActivity;

  const UnifiedCommunity({
    required this.id,
    required this.name,
    this.description,
    this.avatarUrl,
    this.coverUrl,
    required this.memberCount,
    required this.isJoined,
    required this.type,
    required this.domain,
    this.node,
    this.jid,
    required this.isPublic,
    this.features = const [],
    this.affiliation,
    this.topic,
    this.passwordProtected = false,
    this.occupantCount,
    this.rawJid,
    this.lastActivity,
  });

  String get displayId => jid ?? (node != null ? '$node@$domain' : '$domain');

  bool get isSpace => type == CommunityType.space;
  bool get isRoom => type == CommunityType.room;
  bool get isMicroblog => type == CommunityType.microblog;

  UnifiedCommunity copyWith({
    String? id,
    String? name,
    String? description,
    String? avatarUrl,
    String? coverUrl,
    int? memberCount,
    bool? isJoined,
    CommunityType? type,
    String? domain,
    String? node,
    String? jid,
    bool? isPublic,
    List<String>? features,
    String? affiliation,
    String? topic,
    bool? passwordProtected,
    int? occupantCount,
    String? rawJid,
    DateTime? lastActivity,
  }) {
    return UnifiedCommunity(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      coverUrl: coverUrl ?? this.coverUrl,
      memberCount: memberCount ?? this.memberCount,
      isJoined: isJoined ?? this.isJoined,
      type: type ?? this.type,
      domain: domain ?? this.domain,
      node: node ?? this.node,
      jid: jid ?? this.jid,
      isPublic: isPublic ?? this.isPublic,
      features: features ?? this.features,
      affiliation: affiliation ?? this.affiliation,
      topic: topic ?? this.topic,
      passwordProtected: passwordProtected ?? this.passwordProtected,
      occupantCount: occupantCount ?? this.occupantCount,
      rawJid: rawJid ?? this.rawJid,
      lastActivity: lastActivity ?? this.lastActivity,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'avatarUrl': avatarUrl,
      'coverUrl': coverUrl,
      'memberCount': memberCount,
      'isJoined': isJoined,
      'type': type.name,
      'domain': domain,
      'node': node,
      'jid': jid,
      'isPublic': isPublic,
      'features': features,
      'affiliation': affiliation,
      'topic': topic,
      'passwordProtected': passwordProtected,
      'occupantCount': occupantCount,
      'rawJid': rawJid,
      'lastActivity': lastActivity?.toIso8601String(),
    };
  }

  factory UnifiedCommunity.fromMap(Map<String, dynamic> map) {
    return UnifiedCommunity(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      avatarUrl: map['avatarUrl'] as String?,
      coverUrl: map['coverUrl'] as String?,
      memberCount: map['memberCount'] as int? ?? 0,
      isJoined: map['isJoined'] as bool? ?? false,
      type: CommunityType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => CommunityType.space,
      ),
      domain: map['domain'] as String,
      node: map['node'] as String?,
      jid: map['jid'] as String?,
      isPublic: map['isPublic'] as bool? ?? true,
      features: (map['features'] as List<dynamic>?)?.cast<String>() ?? [],
      affiliation: map['affiliation'] as String?,
      topic: map['topic'] as String?,
      passwordProtected: map['passwordProtected'] as bool? ?? false,
      occupantCount: map['occupantCount'] as int?,
      rawJid: map['rawJid'] as String?,
      lastActivity: map['lastActivity'] != null
          ? DateTime.tryParse(map['lastActivity'] as String)
          : null,
    );
  }

  factory UnifiedCommunity.fromSpaceNode(
    SpaceNode space, {
    bool isJoined = false,
    CommunityType? overrideType,
  }) {
    CommunityType ct = overrideType ?? CommunityType.space;
    if (space.type == 'microblog') ct = CommunityType.microblog;
    return UnifiedCommunity(
      id: '${space.domain}|${space.node}',
      name: space.name,
      description: space.description,
      avatarUrl: space.avatarUrl,
      coverUrl: space.coverUrl,
      memberCount: space.numSubscribers ?? space.memberCount ?? 0,
      isJoined: isJoined || space.isSubscribed,
      type: ct,
      domain: space.domain,
      node: space.node,
      jid: null,
      isPublic: space.isPublic,
      features: space.features,
      affiliation: space.affiliation,
      topic: null,
      passwordProtected: false,
      occupantCount: null,
      rawJid: null,
      lastActivity: space.lastActivity,
    );
  }

  factory UnifiedCommunity.fromMucRoom(
    Map<String, dynamic> room, {
    required String domain,
    required bool isJoined,
    String? topic,
    int? occupantCount,
    bool passwordProtected = false,
  }) {
    final jid = room['jid'] as String;
    final name = room['name'] as String? ?? jid.split('@').first;
    return UnifiedCommunity(
      id: jid,
      name: name,
      description: room['description'] as String?,
      avatarUrl: null,
      coverUrl: null,
      memberCount: occupantCount ?? 0,
      isJoined: isJoined,
      type: CommunityType.room,
      domain: domain,
      node: null,
      jid: jid,
      isPublic: !passwordProtected,
      features: const [],
      affiliation: null,
      topic: topic,
      passwordProtected: passwordProtected,
      occupantCount: occupantCount,
      rawJid: jid,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnifiedCommunity && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
