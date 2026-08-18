import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class BackendConfig extends ChangeNotifier {
  String _apiUrl = 'https://gibberapp.online';
  String _poolUrl = 'wss://gibberapp.online/ws/miner';
  bool _captchaEnabled = true;
  String? _domain;
  String? _uploadUrl;
  String? _websocketUrl;
  int _maxUploadSize = 52428800;
  String? _sfuUrl;
  String? _sfuApiKey;
  List<Map<String, dynamic>> _iceServers = [];

  static const String _apiUrlKey = 'gibber_backend_api_url';
  static const String _poolUrlKey = 'gibber_backend_pool_url';

  final Completer<void> _ready = Completer<void>();
  Future<void> get ready => _ready.future;

  String get apiUrl => _apiUrl;
  String get poolUrl => _poolUrl;
  bool get captchaEnabled => _captchaEnabled;
  String? get domain => _domain;
  String? get uploadUrl => _uploadUrl;
  int get maxUploadSize => _maxUploadSize;
  String? get websocketUrl => _websocketUrl;
  String? get sfuUrl => _sfuUrl;
  String? get sfuApiKey => _sfuApiKey;
  List<Map<String, dynamic>> get iceServers => _iceServers;

  String get derivedWebsocketUrl {
    if (_websocketUrl != null) return _websocketUrl!;
    final uri = Uri.parse(_apiUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final port = uri.port > 0 ? ':${uri.port}' : '';
    return '$wsScheme://${uri.host}$port/xmpp-websocket';
  }

  String? get derivedSfuUrl {
    if (_sfuUrl != null && _sfuUrl!.isNotEmpty) return _sfuUrl!;
    return null;
  }

  BackendConfig() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final api = prefs.getString(_apiUrlKey);
    final pool = prefs.getString(_poolUrlKey);
    if (api != null) _apiUrl = api;
    if (pool != null) _poolUrl = pool;
    _ready.complete();
    notifyListeners();
    fetchServerConfig();
  }

  Future<void> fetchServerConfig() async {
    try {
      final response = await http
          .get(Uri.parse('$apiUrl/config'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _captchaEnabled = data['captchaEnabled'] == true;
        _domain = data['domain'] as String?;
        _uploadUrl = data['uploadUrl'] as String?;
        _websocketUrl = data['websocketUrl'] as String?;
        _maxUploadSize = (data['maxUploadSize'] as int?) ?? 52428800;
        _sfuUrl = data['sfuUrl'] as String?;
        _sfuApiKey = data['sfuApiKey'] as String?;
        final ice = data['iceServers'] as List<dynamic>?;
        if (ice != null) {
          _iceServers = ice.cast<Map<String, dynamic>>();
        }
        notifyListeners();
      } else {
        debugPrint('BackendConfig: Failed to fetch config, status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('BackendConfig: Failed to fetch config: $e');
    }
  }

  Future<void> setApiUrl(String url) async {
    _apiUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiUrlKey, url);
    notifyListeners();
  }

  Future<void> setPoolUrl(String url) async {
    _poolUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_poolUrlKey, url);
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    _apiUrl = 'https://gibberapp.online';
    _poolUrl = 'wss://gibberapp.online/ws/miner';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_apiUrlKey);
    await prefs.remove(_poolUrlKey);
    notifyListeners();
  }
}