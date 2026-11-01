/// A room displayed on the landing page, sourced from netsplit.de snapshots.
class PopularRoom {
  final String channel;
  final String network;
  final int users;
  final String? category;
  final String? topic;

  const PopularRoom({
    required this.channel,
    required this.network,
    required this.users,
    this.category,
    this.topic,
  });

  factory PopularRoom.fromJson(Map<String, dynamic> json) => PopularRoom(
        channel: json['channel'] as String? ?? '',
        network: json['network'] as String? ?? '',
        users: (json['users'] as num?)?.toInt() ?? 0,
        category: json['category'] as String?,
        topic: json['topic'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'channel': channel,
        'network': network,
        'users': users,
        if (category != null) 'category': category,
        if (topic != null) 'topic': topic,
      };

  String get displayName =>
      channel.startsWith('#') ? channel.substring(1) : channel;
}