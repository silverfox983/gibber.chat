class User {
  final String id;
  final String jid;
  final String? passwordHash;
  final String tier;
  final DateTime createdAt;
  final DateTime updatedAt;

  User({
    required this.id,
    required this.jid,
    this.passwordHash,
    this.tier = 'free',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'jid': jid,
        'tier': tier,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory User.fromRow(Map<String, dynamic> row) => User(
        id: row['id'] as String,
        jid: row['jid'] as String,
        passwordHash: row['password_hash'] as String?,
        tier: row['tier'] as String? ?? 'free',
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
}