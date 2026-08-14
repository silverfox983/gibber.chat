class Subscription {
  final String id;
  final String jid;
  final String tier;
  final String provider;
  final String providerId;
  final String status;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final DateTime? cancelAt;
  final DateTime createdAt;

  Subscription({
    required this.id,
    required this.jid,
    required this.tier,
    required this.provider,
    required this.providerId,
    this.status = 'active',
    this.currentPeriodStart,
    this.currentPeriodEnd,
    this.cancelAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isActive =>
      status == 'active' &&
      (currentPeriodEnd == null || currentPeriodEnd!.isAfter(DateTime.now()));

  Map<String, dynamic> toJson() => {
        'id': id,
        'jid': jid,
        'tier': tier,
        'provider': provider,
        'providerId': providerId,
        'status': status,
        'currentPeriodStart': currentPeriodStart?.toIso8601String(),
        'currentPeriodEnd': currentPeriodEnd?.toIso8601String(),
        'cancelAt': cancelAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Subscription.fromRow(Map<String, dynamic> row) => Subscription(
        id: row['id'] as String,
        jid: row['jid'] as String,
        tier: row['tier'] as String,
        provider: row['provider'] as String,
        providerId: row['provider_id'] as String,
        status: row['status'] as String,
        currentPeriodStart: row['current_period_start'] != null
            ? DateTime.parse(row['current_period_start'] as String)
            : null,
        currentPeriodEnd: row['current_period_end'] != null
            ? DateTime.parse(row['current_period_end'] as String)
            : null,
        cancelAt: row['cancel_at'] != null
            ? DateTime.parse(row['cancel_at'] as String)
            : null,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}