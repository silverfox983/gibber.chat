import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/models/subscription.dart';
import 'package:gibber_backend/src/models/payment.dart';

class PaymentService {
  final DatabaseService db;
  final _uuid = const Uuid();

  final String stripeSecretKey;
  final String stripeWebhookSecret;
  final String btcpayUrl;
  final String btcpayApiKey;
  final String btcpayStoreId;

  static const Map<String, double> tierPrices = {
    'pro': 9.99,
    'ultimate': 19.99,
  };

  static const Map<String, String> tierCurrencies = {
    'pro': 'USD',
    'ultimate': 'USD',
  };

  PaymentService({
    required this.db,
    this.stripeSecretKey = '',
    this.stripeWebhookSecret = '',
    this.btcpayUrl = '',
    this.btcpayApiKey = '',
    this.btcpayStoreId = '',
  });

  bool get stripeEnabled => stripeSecretKey.isNotEmpty;
  bool get btcpayEnabled => btcpayApiKey.isNotEmpty && btcpayStoreId.isNotEmpty;

  Future<Map<String, dynamic>> getPricing() async {
    return {
      'tiers': [
        {
          'id': 'pro',
          'name': 'Pro',
          'price': tierPrices['pro'],
          'currency': 'USD',
          'interval': 'month',
          'features': [
            'Gibber + Slack + Discord + IRC protocols',
            '300 min transcription/month',
            '100 AI queries/month',
            '10-person group calls',
          ],
        },
        {
          'id': 'ultimate',
          'name': 'Ultimate',
          'price': tierPrices['ultimate'],
          'currency': 'USD',
          'interval': 'month',
          'features': [
            'All protocols',
            'Unlimited transcription',
            'Unlimited AI queries',
            'Unlimited group calls',
          ],
        },
      ],
      'paymentMethods': {
        'stripe': stripeEnabled,
        'btcpay': btcpayEnabled,
      },
    };
  }

  Future<Map<String, dynamic>> createStripeCheckoutSession(String jid, String tier) async {
    if (!stripeEnabled) {
      throw Exception('Stripe is not configured');
    }
    if (!tierPrices.containsKey(tier)) {
      throw Exception('Invalid tier: $tier');
    }

    final price = tierPrices[tier]!;
    final id = _uuid.v4();

    final client = HttpClient();
    try {
      final url = Uri.parse('https://api.stripe.com/v1/checkout/sessions');
      final request = await client.postUrl(url);
      request.headers.set('Authorization', 'Bearer $stripeSecretKey');
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      final body = StringBuffer();
      body.write('mode=subscription');
      body.write('&payment_method_types[]=card');
      body.write('&client_reference_id=$jid');
      body.write('&metadata[jid]=$jid');
      body.write('&metadata[tier]=$tier');
      body.write('&line_items[0][price_data][currency]=usd');
      body.write('&line_items[0][price_data][product_data][name]=Gibber $tier');
      body.write('&line_items[0][price_data][unit_amount]=${(price * 100).toInt()}');
      body.write('&line_items[0][price_data][recurring][interval]=month');
      body.write('&line_items[0][quantity]=1');
      body.write('&success_url=https://gibberapp.online/app?payment=success');
      body.write('&cancel_url=https://gibberapp.online/app?payment=cancelled');
      request.write(body.toString());

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody) as Map<String, dynamic>;
        final sessionId = data['id'] as String;
        final sessionUrl = data['url'] as String?;

        _ensureUser(jid);
        db.db.execute(
          'INSERT INTO payments (id, jid, provider, provider_payment_id, tier, amount, currency, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [id, jid, 'stripe', sessionId, tier, price, 'USD', 'pending'],
        );

        return {
          'sessionId': sessionId,
          'url': sessionUrl,
        };
      } else {
        throw Exception('Stripe error: $responseBody');
      }
    } finally {
      client.close();
    }
  }

  Future<void> handleStripeWebhook(Map<String, dynamic> event) async {
    final eventType = event['type'] as String?;

    if (eventType == 'checkout.session.completed') {
      final session = event['data']['object'] as Map<String, dynamic>;
      final jid = session['metadata']?['jid'] as String?;
      final tier = session['metadata']?['tier'] as String?;
      final subscriptionId = session['subscription'] as String?;

      if (jid != null && tier != null && subscriptionId != null) {
        await _activateSubscription(
          jid: jid,
          tier: tier,
          provider: 'stripe',
          providerId: subscriptionId,
        );
      }
    } else if (eventType == 'customer.subscription.updated') {
      final subscription = event['data']['object'] as Map<String, dynamic>;
      final providerId = subscription['id'] as String?;
      if (providerId != null) {
        await _updateSubscriptionFromStripe(providerId, subscription);
      }
    } else if (eventType == 'customer.subscription.deleted') {
      final subscription = event['data']['object'] as Map<String, dynamic>;
      final providerId = subscription['id'] as String?;
      if (providerId != null) {
        await cancelSubscription(providerId);
      }
    }
  }

  Future<Map<String, dynamic>> createBtcpayInvoice(String jid, String tier) async {
    if (!btcpayEnabled) {
      throw Exception('BTCPay Server is not configured');
    }
    if (!tierPrices.containsKey(tier)) {
      throw Exception('Invalid tier: $tier');
    }

    final price = tierPrices[tier]!;
    final id = _uuid.v4();

    final client = HttpClient();
    try {
      final url = Uri.parse('$btcpayUrl/api/v1/stores/$btcpayStoreId/invoices');
      final request = await client.postUrl(url);
      request.headers.set('Authorization', 'token $btcpayApiKey');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'amount': price.toStringAsFixed(2),
        'currency': 'USD',
        'metadata': {
          'jid': jid,
          'tier': tier,
          'orderId': id,
        },
        'checkout': {
          'redirectURL': 'https://gibberapp.online/app?payment=success',
          'speedPolicy': 'LowSpeed',
        },
      }));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody) as Map<String, dynamic>;
        final invoiceId = data['id'] as String;
        final checkoutLink = data['checkoutLink'] as String?;

        _ensureUser(jid);
        db.db.execute(
          'INSERT INTO payments (id, jid, provider, provider_payment_id, tier, amount, currency, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [id, jid, 'btcpay', invoiceId, tier, price, 'USD', 'pending'],
        );

        return {
          'invoiceId': invoiceId,
          'url': checkoutLink ?? data['checkoutLink'] as String?,
        };
      } else {
        throw Exception('BTCPay error: $responseBody');
      }
    } finally {
      client.close();
    }
  }

  Future<void> handleBtcpayWebhook(Map<String, dynamic> event) async {
    final eventType = event['type'] as String?;
    final invoiceId = event['invoiceId'] as String?;

    if (invoiceId == null) return;

    if (eventType == 'InvoiceSettled' || eventType == 'InvoicePaid') {
      final rows = db.db.select(
        'SELECT * FROM payments WHERE provider_payment_id = ? AND provider = ?',
        [invoiceId, 'btcpay'],
      );
      if (rows.isEmpty) return;

      final payment = rows.first;
      final jid = payment['jid'] as String;
      final tier = payment['tier'] as String;

      db.db.execute(
        'UPDATE payments SET status = ? WHERE provider_payment_id = ? AND provider = ?',
        ['completed', invoiceId, 'btcpay'],
      );

      await _activateSubscription(
        jid: jid,
        tier: tier,
        provider: 'btcpay',
        providerId: invoiceId,
      );
    } else if (eventType == 'InvoiceExpired' || eventType == 'InvoiceInvalid') {
      db.db.execute(
        'UPDATE payments SET status = ? WHERE provider_payment_id = ? AND provider = ?',
        ['failed', invoiceId, 'btcpay'],
      );
    }
  }

  Future<Subscription?> getActiveSubscription(String jid) async {
    final rows = db.db.select(
      "SELECT * FROM subscriptions WHERE jid = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1",
      [jid],
    );
    if (rows.isEmpty) return null;
    final sub = Subscription.fromRow(rows.first);
    if (!sub.isActive) return null;
    return sub;
  }

  Future<List<Payment>> getPaymentHistory(String jid) async {
    final rows = db.db.select(
      'SELECT * FROM payments WHERE jid = ? ORDER BY created_at DESC',
      [jid],
    );
    return rows.map((r) => Payment.fromRow(r)).toList();
  }

  Future<void> _activateSubscription({
    required String jid,
    required String tier,
    required String provider,
    required String providerId,
  }) async {
    _ensureUser(jid);

    final existing = db.db.select(
      "SELECT id FROM subscriptions WHERE jid = ? AND status = 'active'",
      [jid],
    );
    if (existing.isNotEmpty) {
      db.db.execute(
        "UPDATE subscriptions SET status = 'replaced' WHERE jid = ? AND status = 'active'",
        [jid],
      );
    }

    final id = _uuid.v4();
    final now = DateTime.now();
    final periodEnd = now.add(const Duration(days: 30));

    db.db.execute(
      'INSERT INTO subscriptions (id, jid, tier, provider, provider_id, status, current_period_start, current_period_end) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, jid, tier, provider, providerId, 'active', now.toIso8601String(), periodEnd.toIso8601String()],
    );

    db.db.execute(
      'INSERT OR REPLACE INTO entitlements (id, jid, tier, additional_protocols, expires_at) VALUES (?, ?, ?, ?, ?)',
      [_uuid.v4(), jid, tier, '', periodEnd.toIso8601String()],
    );

    db.db.execute(
      'UPDATE users SET tier = ?, updated_at = datetime(\'now\') WHERE jid = ?',
      [tier, jid],
    );
  }

  Future<void> _updateSubscriptionFromStripe(String providerId, Map<String, dynamic> subscription) async {
    final rows = db.db.select(
      'SELECT * FROM subscriptions WHERE provider_id = ? AND provider = ?',
      [providerId, 'stripe'],
    );
    if (rows.isEmpty) return;

    final currentPeriodStart = subscription['current_period_start'] as int?;
    final currentPeriodEnd = subscription['current_period_end'] as int?;
    final cancelAt = subscription['cancel_at'] as int?;

    db.db.execute(
      'UPDATE subscriptions SET current_period_start = ?, current_period_end = ?, cancel_at = ? WHERE provider_id = ? AND provider = ?',
      [
        currentPeriodStart != null ? DateTime.fromMillisecondsSinceEpoch(currentPeriodStart * 1000).toIso8601String() : null,
        currentPeriodEnd != null ? DateTime.fromMillisecondsSinceEpoch(currentPeriodEnd * 1000).toIso8601String() : null,
        cancelAt != null && cancelAt > 0 ? DateTime.fromMillisecondsSinceEpoch(cancelAt * 1000).toIso8601String() : null,
        providerId,
        'stripe',
      ],
    );
  }

  Future<void> cancelSubscription(String providerId) async {
    db.db.execute(
      "UPDATE subscriptions SET status = 'cancelled' WHERE provider_id = ?",
      [providerId],
    );
  }

  void _ensureUser(String jid) {
    final existing = db.db.select('SELECT id FROM users WHERE jid = ?', [jid]);
    if (existing.isEmpty) {
      db.db.execute('INSERT INTO users (id, jid) VALUES (?, ?)', [_uuid.v4(), jid]);
    }
  }
}