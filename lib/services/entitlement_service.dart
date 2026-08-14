import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum UserTier {
  free,
  pro,
  ultimate,
}

extension UserTierExtension on UserTier {
  String get label {
    switch (this) {
      case UserTier.free:
        return 'Free';
      case UserTier.pro:
        return 'Pro';
      case UserTier.ultimate:
        return 'Ultimate';
    }
  }

  List<String> get allowedProtocols {
    switch (this) {
      case UserTier.free:
        return ['XMPP'];
      case UserTier.pro:
        return ['XMPP', 'Slack', 'Discord', 'IRC'];
      case UserTier.ultimate:
        return ['XMPP', 'Slack', 'Discord', 'IRC', 'Teams', 'Matrix', 'Telegram', 'SMS'];
    }
  }

  int get transcriptionMinutesPerMonth {
    switch (this) {
      case UserTier.free:
        return 30;
      case UserTier.pro:
        return 300;
      case UserTier.ultimate:
        return -1;
    }
  }

  int get aiQueriesPerMonth {
    switch (this) {
      case UserTier.free:
        return 10;
      case UserTier.pro:
        return 100;
      case UserTier.ultimate:
        return -1;
    }
  }

  int get maxGroupCallSize {
    switch (this) {
      case UserTier.free:
        return 4;
      case UserTier.pro:
        return 10;
      case UserTier.ultimate:
        return -1;
    }
  }

  int get historyRetentionDays {
    switch (this) {
      case UserTier.free:
        return 30;
      case UserTier.pro:
        return 365;
      case UserTier.ultimate:
        return -1;
    }
  }
}

class Entitlement {
  final UserTier tier;
  final DateTime? expiresAt;
  final List<String> additionalProtocols;
  final String? redemptionCode;

  Entitlement({
    required this.tier,
    this.expiresAt,
    this.additionalProtocols = const [],
    this.redemptionCode,
  });

  bool get isActive => expiresAt == null || expiresAt!.isAfter(DateTime.now());

  Map<String, dynamic> toJson() => {
        'tier': tier.name,
        'expiresAt': expiresAt?.toIso8601String(),
        'additionalProtocols': additionalProtocols,
        'redemptionCode': redemptionCode,
      };

  factory Entitlement.fromJson(Map<String, dynamic> json) => Entitlement(
        tier: UserTier.values.firstWhere((t) => t.name == json['tier']),
        expiresAt: json['expiresAt'] != null
            ? DateTime.parse(json['expiresAt'])
            : null,
        additionalProtocols:
            List<String>.from(json['additionalProtocols'] ?? []),
        redemptionCode: json['redemptionCode'],
      );
}

class EntitlementService extends ChangeNotifier {
  Entitlement _entitlement = Entitlement(tier: UserTier.free);
  String _backendUrl = 'https://gibberapp.online';
  bool _isLoading = false;
  String _error = '';

  int _transcriptionSecondsUsed = 0;
  int _aiQueriesUsed = 0;
  String? _usageMonth;
  String? _bareJid;

  Entitlement get entitlement => _entitlement;
  UserTier get currentTier => _entitlement.tier;
  bool get isLoading => _isLoading;
  String get error => _error;

  int get transcriptionSecondsUsed => _transcriptionSecondsUsed;
  int get aiQueriesUsed => _aiQueriesUsed;
  int get transcriptionSecondsLimit => currentTier.transcriptionMinutesPerMonth == -1
      ? -1
      : currentTier.transcriptionMinutesPerMonth * 60;
  int get aiQueriesLimit => currentTier.aiQueriesPerMonth;

  static const String _entitlementKey = 'gibber_entitlement';
  static const String _usageKey = 'gibber_usage';

  EntitlementService() {
    _loadCachedEntitlement();
    _loadCachedUsage();
  }

  void setBackendUrl(String url) {
    _backendUrl = url;
  }

  Future<void> _loadCachedEntitlement() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_entitlementKey);
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        _entitlement = Entitlement.fromJson(json);
        if (!_entitlement.isActive) {
          _entitlement = Entitlement(tier: UserTier.free);
          await prefs.remove(_entitlementKey);
        }
        notifyListeners();
      } catch (_) {
        await prefs.remove(_entitlementKey);
      }
    }
  }

  Future<void> _cacheEntitlement() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _entitlementKey, jsonEncode(_entitlement.toJson()));
  }

  Future<void> fetchEntitlement(String bareJid) async {
    _bareJid = bareJid;
    _isLoading = true;
    _error = '';
    notifyListeners();

    try {
      final response = await http.get(
        Uri.parse('$_backendUrl/entitlements/${Uri.encodeComponent(bareJid)}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _entitlement = Entitlement.fromJson(data);
        await _cacheEntitlement();
      } else {
        _error = 'Failed to fetch entitlements: ${response.statusCode}';
      }
    } catch (e) {
      _error = 'Network error: $e';
      debugPrint('EntitlementService: $_error');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> redeemCode(String code) async {
    _isLoading = true;
    _error = '';
    notifyListeners();

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/redeem'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': code, 'jid': _bareJid ?? ''}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _entitlement = Entitlement.fromJson(data);
        await _cacheEntitlement();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Invalid redemption code';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'Network error: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  bool isProtocolAllowed(String protocol) {
    if (_entitlement.additionalProtocols.contains(protocol)) return true;
    return currentTier.allowedProtocols.contains(protocol);
  }

  bool get canTranscribe {
    final limit = currentTier.transcriptionMinutesPerMonth;
    if (limit == -1) return true;
    return _transcriptionSecondsUsed < limit * 60;
  }

  bool get canUseAI {
    final limit = currentTier.aiQueriesPerMonth;
    if (limit == -1) return true;
    return _aiQueriesUsed < limit;
  }

  String? transcriptionLimitMessage() {
    if (currentTier == UserTier.ultimate) return null;
    if (!canTranscribe) {
      if (currentTier == UserTier.free) {
        return 'Free tier transcription limit (30 min/month) reached. Upgrade to Pro for 300 min.';
      }
      return 'Pro tier transcription limit (300 min/month) reached. Upgrade to Ultimate for unlimited.';
    }
    return null;
  }

  String? aiLimitMessage() {
    if (currentTier == UserTier.ultimate) return null;
    if (!canUseAI) {
      if (currentTier == UserTier.free) {
        return 'Free tier AI query limit (10/month) reached. Upgrade to Pro for 100 queries.';
      }
      return 'Pro tier AI query limit (100/month) reached. Upgrade to Ultimate for unlimited.';
    }
    return null;
  }

  void recordTranscriptionSeconds(int seconds) {
    _transcriptionSecondsUsed += seconds;
    _cacheUsage();
    notifyListeners();
  }

  void recordAIQuery() {
    _aiQueriesUsed += 1;
    _cacheUsage();
    notifyListeners();
  }

  Future<void> _loadCachedUsage() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final currentMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final cached = prefs.getString(_usageKey);
    if (cached != null) {
      try {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        if (data['month'] == currentMonth) {
          _transcriptionSecondsUsed = (data['transcriptionSeconds'] as num?)?.toInt() ?? 0;
          _aiQueriesUsed = (data['aiQueries'] as num?)?.toInt() ?? 0;
        } else {
          _transcriptionSecondsUsed = 0;
          _aiQueriesUsed = 0;
        }
      } catch (_) {
        _transcriptionSecondsUsed = 0;
        _aiQueriesUsed = 0;
      }
    }
    _usageMonth = currentMonth;
  }

  Future<void> _cacheUsage() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    _usageMonth ??= '${now.year}-${now.month.toString().padLeft(2, '0')}';
    await prefs.setString(_usageKey, jsonEncode({
      'month': _usageMonth,
      'transcriptionSeconds': _transcriptionSecondsUsed,
      'aiQueries': _aiQueriesUsed,
    }));
  }

}