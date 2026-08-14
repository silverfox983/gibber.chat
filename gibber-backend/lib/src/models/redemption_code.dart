class RedemptionCode {
  final String code;
  final String tier;
  final List<String> protocols;
  final int durationDays;
  final bool used;
  final String? usedBy;
  final DateTime? usedAt;
  final DateTime createdAt;

  RedemptionCode({
    required this.code,
    required this.tier,
    this.protocols = const [],
    this.durationDays = 30,
    this.used = false,
    this.usedBy,
    this.usedAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'code': code,
        'tier': tier,
        'protocols': protocols,
        'durationDays': durationDays,
        'used': used,
        'usedBy': usedBy,
        'usedAt': usedAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory RedemptionCode.fromRow(Map<String, dynamic> row) => RedemptionCode(
        code: row['code'] as String,
        tier: row['tier'] as String,
        protocols:
            (row['protocols'] as String?)?.split(',').where((p) => p.isNotEmpty).toList() ?? [],
        durationDays: (row['duration_days'] as int?) ?? 30,
        used: (row['used'] as int?) == 1,
        usedBy: row['used_by'] as String?,
        usedAt: row['used_at'] != null
            ? DateTime.parse(row['used_at'] as String)
            : null,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}