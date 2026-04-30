class SpaceNode {
  final String domain;
  final String node;
  final String name;
  final String? description;
  final String? creator;
  final String? avatarUrl;
  final String? affiliation; // 'owner', 'publisher', 'member', 'none'
  final int? memberCount;

  SpaceNode({
    required this.domain,
    required this.node,
    required this.name,
    this.description,
    this.creator,
    this.avatarUrl,
    this.affiliation,
    this.memberCount,
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
    );
  }
}

class SpaceItem {
  final String id;
  final String type; // 'room', 'url', 'subscription', 'text'
  final String? name;
  final String? url;
  final String? node; // For sub-spaces
  final String? description;

  SpaceItem({
    required this.id,
    required this.type,
    this.name,
    this.url,
    this.node,
    this.description,
  });
}
