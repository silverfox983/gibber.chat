class Entitlement {
  final String id;
  final String jid;
  final String tier;
  final List<String> additionalProtocols;
  final DateTime? expiresAt;
  final DateTime createdAt;

  Entitlement({
    required this.id,
    required this.jid,
    required this.tier,
    this.additionalProtocols = const [],
    this.expiresAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isActive =>
      expiresAt == null || expiresAt!.isAfter(DateTime.now());

  Map<String, dynamic> toJson() => {
        'id': id,
        'jid': jid,
        'tier': tier,
        'additionalProtocols': additionalProtocols,
        'expiresAt': expiresAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Entitlement.fromRow(Map<String, dynamic> row) => Entitlement(
        id: row['id'] as String,
        jid: row['jid'] as String,
        tier: row['tier'] as String,
        additionalProtocols:
            (row['additional_protocols'] as String?)?.split(',').where((p) => p.isNotEmpty).toList() ?? [],
        expiresAt: row['expires_at'] != null
            ? DateTime.parse(row['expires_at'] as String)
            : null,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}