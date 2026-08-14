class Payment {
  final String id;
  final String jid;
  final String provider;
  final String providerPaymentId;
  final String tier;
  final double amount;
  final String currency;
  final String status;
  final DateTime createdAt;

  Payment({
    required this.id,
    required this.jid,
    required this.provider,
    required this.providerPaymentId,
    required this.tier,
    required this.amount,
    required this.currency,
    this.status = 'pending',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'jid': jid,
        'provider': provider,
        'providerPaymentId': providerPaymentId,
        'tier': tier,
        'amount': amount,
        'currency': currency,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Payment.fromRow(Map<String, dynamic> row) => Payment(
        id: row['id'] as String,
        jid: row['jid'] as String,
        provider: row['provider'] as String,
        providerPaymentId: row['provider_payment_id'] as String,
        tier: row['tier'] as String,
        amount: (row['amount'] as num).toDouble(),
        currency: row['currency'] as String,
        status: row['status'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}