import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/user_gateway.dart';
import 'jwt_token_service.dart';

class BridgeConfigService extends ChangeNotifier {
  final JwtTokenService _jwtService;
  String _backendUrl = 'https://gibberapp.online';

  List<UserGateway> _userGateways = [];
  bool _isLoading = false;
  String? _error;

  BridgeConfigService(this._jwtService);

  List<UserGateway> get userGateways => List.unmodifiable(_userGateways);
  bool get isLoading => _isLoading;
  String? get error => _error;

  void setBackendUrl(String url) {
    _backendUrl = url;
  }

  Future<Map<String, String>> _authHeaders() async {
    final headers = await _jwtService.authHeadersAsync();
    return {...headers, 'Content-Type': 'application/json'};
  }

  Future<UserGateway?> getGateway(String userId, String type) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .get(
            Uri.parse('$_backendUrl/user/$userId/gateways/$type'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return UserGateway.fromJson(data);
      } else if (response.statusCode == 404) {
        return null;
      } else {
        _error = 'Failed to load gateway: ${response.statusCode}';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<List<UserGateway>> listUserGateways(String userId) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .get(
            Uri.parse('$_backendUrl/user/$userId/gateways'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final gateways = (data['gateways'] as List<dynamic>?)
                ?.map((e) => UserGateway.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        _userGateways = gateways;
        return gateways;
      } else {
        _error = 'Failed to load gateways: ${response.statusCode}';
        return [];
      }
    } catch (e) {
      _error = 'Network error: $e';
      return [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<UserGateway?> configureGateway({
    required String userId,
    required String type,
    required Map<String, dynamic> config,
  }) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .put(
            Uri.parse('$_backendUrl/user/$userId/gateways/$type'),
            headers: await _authHeaders(),
            body: jsonEncode({'config': config}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final gateway = UserGateway.fromJson(data);
        _updateGatewayInList(gateway);
        return gateway;
      } else {
        final errData = jsonDecode(response.body) as Map<String, dynamic>?;
        _error = errData?['error'] ?? 'Failed to configure gateway: ${response.statusCode}';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> removeGateway(String userId, String type) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .delete(
            Uri.parse('$_backendUrl/user/$userId/gateways/$type'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 204) {
        _userGateways.removeWhere((g) => g.gatewayType == type);
        notifyListeners();
        return true;
      } else {
        _error = 'Failed to remove gateway: ${response.statusCode}';
        return false;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<UserGateway?> enableGateway(String userId, String type) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .post(
            Uri.parse('$_backendUrl/user/$userId/gateways/$type/enable'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final gateway = UserGateway.fromJson(data);
        _updateGatewayInList(gateway);
        return gateway;
      } else {
        final errData = jsonDecode(response.body) as Map<String, dynamic>?;
        _error = errData?['error'] ?? 'Failed to enable gateway: ${response.statusCode}';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> disableGateway(String userId, String type) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .post(
            Uri.parse('$_backendUrl/user/$userId/gateways/$type/disable'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final gateway = UserGateway.fromJson(data);
        _updateGatewayInList(gateway);
        return true;
      } else {
        final errData = jsonDecode(response.body) as Map<String, dynamic>?;
        _error = errData?['error'] ?? 'Failed to disable gateway: ${response.statusCode}';
        return false;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> testGateway({
    required String type,
    required Map<String, dynamic> config,
  }) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final response = await http
          .post(
            Uri.parse('$_backendUrl/gateways/$type/test'),
            headers: await _authHeaders(),
            body: jsonEncode({'config': config}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        final errData = jsonDecode(response.body) as Map<String, dynamic>?;
        _error = errData?['error'] ?? 'Test failed: ${response.statusCode}';
        return null;
      }
    } catch (e) {
      _error = 'Network error: $e';
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _updateGatewayInList(UserGateway gateway) {
    final index = _userGateways.indexWhere((g) => g.gatewayType == gateway.gatewayType);
    if (index >= 0) {
      _userGateways[index] = gateway;
    } else {
      _userGateways.add(gateway);
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
