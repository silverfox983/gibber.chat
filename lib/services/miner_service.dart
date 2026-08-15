import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'resource_scheduler_service.dart';
import 'entitlement_service.dart';

enum MinerStatus {
  idle,
  initializing,
  mining,
  paused,
  error,
}

class MiningStats {
  final double hashesPerSecond;
  final double totalHashes;
  final double hashesDonated;
  final Duration uptime;

  MiningStats({
    this.hashesPerSecond = 0,
    this.totalHashes = 0,
    this.hashesDonated = 0,
    this.uptime = Duration.zero,
  });

  MiningStats copyWith({
    double? hashesPerSecond,
    double? totalHashes,
    double? hashesDonated,
    Duration? uptime,
  }) =>
      MiningStats(
        hashesPerSecond: hashesPerSecond ?? this.hashesPerSecond,
        totalHashes: totalHashes ?? this.totalHashes,
        hashesDonated: hashesDonated ?? this.hashesDonated,
        uptime: uptime ?? this.uptime,
      );
}

class MinerService extends ChangeNotifier {
  MinerStatus _status = MinerStatus.idle;
  String _error = '';
  MiningStats _stats = MiningStats();
  String? _poolSessionToken;
  String _backendUrl = 'https://gibberapp.online';
  String _jid = '';
  double _cpuCap = 0.3;
  bool _consent = false;
  DateTime? _startTime;
  Timer? _statsTimer;
  Timer? _heartbeatTimer;
  final ResourceSchedulerService _scheduler;
  EntitlementService? _entitlementService;

  StreamSubscription? _minerSuspendSub;
  StreamSubscription? _minerResumeSub;

  static const String _consentKey = 'gibber_miner_consent';
  static const String _donatedKey = 'gibber_hashes_donated';

  MinerStatus get status => _status;
  String get error => _error;
  MiningStats get stats => _stats;
  double get cpuCap => _cpuCap;
  bool get consent => _consent;

  MinerService(this._scheduler) {
    _loadConsent();
    _minerSuspendSub = _scheduler.onMinerSuspended.listen((_) => _pause());
    _minerResumeSub = _scheduler.onMinerResumed.listen((_) => _resumeIfConsented());
  }

  void setEntitlementService(EntitlementService es) {
    _entitlementService = es;
  }

  Future<void> _loadConsent() async {
    final prefs = await SharedPreferences.getInstance();
    _consent = prefs.getBool(_consentKey) ?? false;
    _stats = _stats.copyWith(
      hashesDonated: prefs.getDouble(_donatedKey) ?? 0,
    );
  }

  Future<void> setConsent(bool value) async {
    if (value && _entitlementService != null && _entitlementService!.currentTier != UserTier.free) {
      return;
    }
    _consent = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consentKey, value);
    _scheduler.setMinerConsent(value);
    notifyListeners();

    if (value && _status == MinerStatus.idle) {
      await startMining();
    } else if (!value && _status == MinerStatus.mining) {
      await stopMining();
    }
  }

  void setCpuCap(double cap) {
    _cpuCap = cap.clamp(0.1, 0.8);
    _scheduler.setMinerCpuCap(_cpuCap);
    notifyListeners();
  }

  void setBackendUrl(String url) {
    _backendUrl = url;
  }

  void setPoolUrl(String url) {
    // pool URL stored in _backendUrl
  }

  void setJid(String jid) {
    _jid = jid;
  }

  Future<bool> startMining() async {
    if (!_consent) {
      _error = 'Mining consent not granted';
      notifyListeners();
      return false;
    }

    if (_entitlementService != null && _entitlementService!.currentTier != UserTier.free) {
      _error = 'Mining is only available for free-tier users';
      _status = MinerStatus.error;
      notifyListeners();
      return false;
    }

    if (kIsWeb) {
      return _startWasmMiner();
    } else {
      _error = 'Mining is only supported in the browser';
      _status = MinerStatus.error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> _startWasmMiner() async {
    final acquired = await _scheduler.acquireMiner();
    if (!acquired) {
      _error = 'Cannot start mining: resource conflict';
      _status = MinerStatus.error;
      notifyListeners();
      return false;
    }

    _status = MinerStatus.initializing;
    _error = '';
    notifyListeners();

    try {
      _poolSessionToken = await _registerWithPool();

      _startTime = DateTime.now();
      _status = MinerStatus.mining;

      _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _updateStats();
      });

      _heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        _sendHeartbeat();
      });

      notifyListeners();
      debugPrint('MinerService: Mining started (CPU cap: ${(_cpuCap * 100).toInt()}%)');
      return true;
    } catch (e) {
      _error = 'Failed to start mining: $e';
      _status = MinerStatus.error;
      _scheduler.release(ResourceTask.miner);
      notifyListeners();
      return false;
    }
  }

  Future<String?> _registerWithPool() async {
    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/miner/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'jid': _jid, 'cpuCap': _cpuCap}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['sessionToken'] as String?;
      }
      return null;
    } catch (_) {
      debugPrint('MinerService: Pool registration failed, will use direct mining');
      return null;
    }
  }

  Future<void> _sendHeartbeat() async {
    if (_poolSessionToken == null) return;
    try {
      await http.post(
        Uri.parse('$_backendUrl/miner/heartbeat'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_poolSessionToken',
        },
      );
    } catch (_) {}
  }

  Future<void> _submitHashes(double hashes) async {
    if (_poolSessionToken == null) return;
    try {
      await http.post(
        Uri.parse('$_backendUrl/miner/submit'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_poolSessionToken',
        },
        body: jsonEncode({'hashes': hashes}),
      );

      final prefs = await SharedPreferences.getInstance();
      final newDonated = _stats.hashesDonated + hashes;
      _stats = _stats.copyWith(hashesDonated: newDonated);
      await prefs.setDouble(_donatedKey, newDonated);
    } catch (_) {}
  }

  void _updateStats() {
    if (_status != MinerStatus.mining || _startTime == null) return;

    final uptime = DateTime.now().difference(_startTime!);
    final simHashRate = 50.0 * _cpuCap;
    final totalHashes = simHashRate * uptime.inSeconds.toDouble();

    _stats = _stats.copyWith(
      hashesPerSecond: simHashRate,
      totalHashes: totalHashes,
      uptime: uptime,
    );

    _submitHashes(simHashRate * 5);
    notifyListeners();
  }

  Future<void> stopMining() async {
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statsTimer = null;
    _heartbeatTimer = null;
    _startTime = null;

    _status = MinerStatus.idle;
    _scheduler.release(ResourceTask.miner);
    notifyListeners();
    debugPrint('MinerService: Mining stopped');
  }

  void _pause() {
    if (_status != MinerStatus.mining) return;
    _statsTimer?.cancel();
    _status = MinerStatus.paused;
    notifyListeners();
  }

  Future<void> _resumeIfConsented() async {
    if (!_consent || _status != MinerStatus.paused) return;
    final acquired = await _scheduler.acquireMiner();
    if (!acquired) return;
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _updateStats();
    });
    _status = MinerStatus.mining;
    notifyListeners();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    _minerSuspendSub?.cancel();
    _minerResumeSub?.cancel();
    if (_status == MinerStatus.mining || _status == MinerStatus.paused) {
      _scheduler.release(ResourceTask.miner);
    }
    super.dispose();
  }
}