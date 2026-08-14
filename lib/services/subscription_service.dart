import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class PricingTier {
  final String id;
  final String name;
  final double price;
  final String currency;
  final String interval;
  final List<String> features;

  PricingTier({
    required this.id,
    required this.name,
    required this.price,
    this.currency = 'USD',
    this.interval = 'month',
    this.features = const [],
  });

  factory PricingTier.fromJson(Map<String, dynamic> json) => PricingTier(
        id: json['id'] as String,
        name: json['name'] as String,
        price: (json['price'] as num).toDouble(),
        currency: json['currency'] as String? ?? 'USD',
        interval: json['interval'] as String? ?? 'month',
        features: List<String>.from(json['features'] ?? []),
      );
}

class SubscriptionInfo {
  final String? id;
  final String? tier;
  final String? provider;
  final String? providerId;
  final String? status;
  final DateTime? currentPeriodEnd;
  final DateTime? cancelAt;

  SubscriptionInfo({
    this.id,
    this.tier,
    this.provider,
    this.providerId,
    this.status,
    this.currentPeriodEnd,
    this.cancelAt,
  });

  bool get isActive =>
      status == 'active' &&
      (currentPeriodEnd == null || currentPeriodEnd!.isAfter(DateTime.now()));

  factory SubscriptionInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) return SubscriptionInfo();
    return SubscriptionInfo(
      id: json['id'] as String?,
      tier: json['tier'] as String?,
      provider: json['provider'] as String?,
      providerId: json['providerId'] as String?,
      status: json['status'] as String?,
      currentPeriodEnd: json['currentPeriodEnd'] != null
          ? DateTime.parse(json['currentPeriodEnd'] as String)
          : null,
      cancelAt: json['cancelAt'] != null
          ? DateTime.parse(json['cancelAt'] as String)
          : null,
    );
  }
}

class SubscriptionService extends ChangeNotifier {
  String _backendUrl = 'https://gibberapp.online';
  PricingTier? _proTier;
  PricingTier? _ultimateTier;
  bool _stripeEnabled = false;
  bool _btcpayEnabled = false;
  bool _isLoading = false;
  String _error = '';

  String get backendUrl => _backendUrl;
  PricingTier? get proTier => _proTier;
  PricingTier? get ultimateTier => _ultimateTier;
  bool get stripeEnabled => _stripeEnabled;
  bool get btcpayEnabled => _btcpayEnabled;
  bool get isLoading => _isLoading;
  String get error => _error;

  void setBackendUrl(String url) {
    _backendUrl = url;
  }

  Future<void> fetchPricing() async {
    _isLoading = true;
    _error = '';
    notifyListeners();

    try {
      final response = await http.get(
        Uri.parse('$_backendUrl/pricing'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tiers = data['tiers'] as List<dynamic>;
        final methods = data['paymentMethods'] as Map<String, dynamic>;

        for (final tier in tiers) {
          final t = PricingTier.fromJson(tier as Map<String, dynamic>);
          if (t.id == 'pro') _proTier = t;
          if (t.id == 'ultimate') _ultimateTier = t;
        }

        _stripeEnabled = methods['stripe'] == true;
        _btcpayEnabled = methods['btcpay'] == true;
      } else {
        _error = 'Failed to fetch pricing';
      }
    } catch (e) {
      _error = 'Network error: $e';
      debugPrint('SubscriptionService: $_error');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> createStripeCheckout(String jid, String tier) async {
    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/payments/stripe/checkout'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'jid': jid, 'tier': tier}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['url'] as String?;
      } else {
        _error = 'Failed to create checkout session';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    }
  }

  Future<String?> createBtcpayInvoice(String jid, String tier) async {
    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/payments/btcpay/invoice'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'jid': jid, 'tier': tier}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['url'] as String?;
      } else {
        _error = 'Failed to create invoice';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    }
  }

  Future<SubscriptionInfo> fetchSubscription(String jid) async {
    try {
      final response = await http.get(
        Uri.parse('$_backendUrl/subscription/${Uri.encodeComponent(jid)}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return SubscriptionInfo.fromJson(data['subscription'] as Map<String, dynamic>?);
      }
    } catch (e) {
      debugPrint('SubscriptionService: fetchSubscription error: $e');
    }
    return SubscriptionInfo();
  }

  Future<bool> cancelSubscription(String jid) async {
    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/subscription/${Uri.encodeComponent(jid)}/cancel'),
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200;
    } catch (e) {
      _error = 'Network error: $e';
      return false;
    }
  }
}