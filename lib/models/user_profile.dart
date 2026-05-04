
class UserProfile {
  final String id;
  String displayName;
  String? nickName;
  String? bio;
  String? avatarPath;
  String? email;
  String? phone;
  String? url;
  String? organization;
  String? title;
  String? role;
  String? birthday;
  final List<String> accountIds;

  UserProfile({
    required this.id,
    required this.displayName,
    this.nickName,
    this.bio,
    this.avatarPath,
    this.email,
    this.phone,
    this.url,
    this.organization,
    this.title,
    this.role,
    this.birthday,
    required this.accountIds,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'nickName': nickName,
    'bio': bio,
    'avatarPath': avatarPath,
    'email': email,
    'phone': phone,
    'url': url,
    'organization': organization,
    'title': title,
    'role': role,
    'birthday': birthday,
    'accountIds': accountIds,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'],
    displayName: json['displayName'],
    nickName: json['nickName'] as String?,
    bio: json['bio'] as String?,
    avatarPath: json['avatarPath'],
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    url: json['url'] as String?,
    organization: json['organization'] as String?,
    title: json['title'] as String?,
    role: json['role'] as String?,
    birthday: json['birthday'] as String?,
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
