import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackendConfig extends ChangeNotifier {
  String _apiUrl = 'https://gibberapp.online';
  String _poolUrl = 'wss://gibberapp.online/ws/miner';

  static const String _apiUrlKey = 'gibber_backend_api_url';
  static const String _poolUrlKey = 'gibber_backend_pool_url';

  final Completer<void> _ready = Completer<void>();
  Future<void> get ready => _ready.future;

  String get apiUrl => _apiUrl;
  String get poolUrl => _poolUrl;

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