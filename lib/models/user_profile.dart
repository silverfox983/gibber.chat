
class UserProfile {
  final String id;
  String displayName;
  String? nickName;
  String? bio;
  String? email;
  String? phone;
  String? url;
  String? organization;
  String? title;
  String? role;
  String? birthday;
  String? pronouns;
  String? avatarHash;
  String? bannerUrl;

  final List<String> accountIds;

  UserProfile({
    required this.id,
    required this.displayName,
    this.nickName,
    this.bio,
    this.email,
    this.phone,
    this.url,
    this.organization,
    this.title,
    this.role,
    this.birthday,
    this.pronouns,
    this.avatarHash,
    this.bannerUrl,
    required this.accountIds,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'nickName': nickName,
    'bio': bio,
    'email': email,
    'phone': phone,
    'url': url,
    'organization': organization,
    'title': title,
    'role': role,
    'birthday': birthday,
    'pronouns': pronouns,
    'avatarHash': avatarHash,
    'bannerUrl': bannerUrl,
    'accountIds': accountIds,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'],
    displayName: json['displayName'],
    nickName: json['nickName'] as String?,
    bio: json['bio'] as String?,
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    url: json['url'] as String?,
    organization: json['organization'] as String?,
    title: json['title'] as String?,
    role: json['role'] as String?,
    birthday: json['birthday'] as String?,
    pronouns: json['pronouns'] as String?,
    avatarHash: json['avatarHash'] as String?,
    bannerUrl: json['bannerUrl'] as String?,
    accountIds: List<String>.from(json['accountIds']),
  );
}
