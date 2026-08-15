import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'registration_service.dart';

class JwtTokenService {
  static const _accessTokenKey = 'jwt_access_token';
  static const _refreshTokenKey = 'jwt_refresh_token';
  static const _tokenJidKey = 'jwt_token_jid';
  static const _tokenExpiryKey = 'jwt_token_expiry';

  String? _accessToken;
  String? _refreshToken;
  String? _tokenJid;
  DateTime? _tokenExpiry;
  String? _apiUrl;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  String? get tokenJid => _tokenJid;
  bool get isAuthenticated => _accessToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!);
  bool get canRefresh => _refreshToken != null;

  final _authChangeController = StreamController<bool>.broadcast();
  Stream<bool> get onAuthChange => _authChangeController.stream;

  Future<void> init({String? apiUrl}) async {
    _apiUrl = apiUrl;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_accessTokenKey);
    _refreshToken = prefs.getString(_refreshTokenKey);
    _tokenJid = prefs.getString(_tokenJidKey);
    final expiryMs = prefs.getInt(_tokenExpiryKey);
    if (expiryMs != null) {
      _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
    }
    if (isAuthenticated) {
      _authChangeController.add(true);
    }
  }

  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
    String? jid,
    String? apiUrl,
  }) async {
    _accessToken = accessToken;
    _apiUrl = apiUrl ?? _apiUrl;
    if (refreshToken != null) {
      _refreshToken = refreshToken;
    }
    if (jid != null) {
      _tokenJid = jid;
    }
    _tokenExpiry = DateTime.now().add(const Duration(hours: 23));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    if (refreshToken != null) {
      await prefs.setString(_refreshTokenKey, refreshToken);
    }
    if (jid != null) {
      await prefs.setString(_tokenJidKey, jid);
    }
    await prefs.setInt(_tokenExpiryKey, _tokenExpiry!.millisecondsSinceEpoch);

    _authChangeController.add(true);
  }

  Future<String?> getValidToken() async {
    if (_accessToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken;
    }
    if (_refreshToken != null && _apiUrl != null) {
      final newToken = await RegistrationService.refreshJwtToken(
        apiUrl: _apiUrl!,
        refreshToken: _refreshToken!,
      );
      if (newToken != null) {
        await saveTokens(accessToken: newToken, refreshToken: _refreshToken);
        return newToken;
      }
    }
    await clearTokens();
    return null;
  }

  Map<String, String> authHeaders() {
    if (_accessToken == null) return {};
    return {'Authorization': 'Bearer $_accessToken'};
  }

  Future<Map<String, String>> authHeadersAsync() async {
    final token = await getValidToken();
    if (token == null) return {};
    return {'Authorization': 'Bearer $token'};
  }

  Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenJid = null;
    _tokenExpiry = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_tokenJidKey);
    await prefs.remove(_tokenExpiryKey);

    _authChangeController.add(false);
  }

  void dispose() {
    _authChangeController.close();
  }
}