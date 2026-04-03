
class UserProfile {
  final String id;
  String displayName;
  String? nickName;
  String? bio;
  String? avatarPath;
  final List<String> accountIds;

  UserProfile({
    required this.id,
    required this.displayName,
    this.nickName,
    this.bio,
    this.avatarPath,
    required this.accountIds,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'nickName': nickName,
    'bio': bio,
    'avatarPath': avatarPath,
    'accountIds': accountIds,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'],
    displayName: json['displayName'],
    nickName: json['nickName'] as String?,
    bio: json['bio'] as String?,
    avatarPath: json['avatarPath'],
    accountIds: List<String>.from(json['accountIds']),
  );
}

class AccountConfig {
  final String id;
  final String name;
  final String protocol; // 'XMPP' or 'IRC'
  final Map<String, dynamic> settings;
  bool isEnabled;

  AccountConfig({
    required this.id,
    required this.name,
    required this.protocol,
    required this.settings,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol,
    'settings': settings,
    'isEnabled': isEnabled,
  };

  factory AccountConfig.fromJson(Map<String, dynamic> json) => AccountConfig(
    id: json['id'],
    name: json['name'],
    protocol: json['protocol'],
    settings: Map<String, dynamic>.from(json['settings']),
    isEnabled: json['isEnabled'] ?? true,
  );
}
