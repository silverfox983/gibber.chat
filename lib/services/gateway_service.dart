import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, IconData, Icons;
import 'package:http/http.dart' as http;
import 'backend_config.dart';

class GatewayService extends ChangeNotifier {
  final BackendConfig _config;
  String _backendUrl = 'https://gibberapp.online';

  GatewayService(this._config);

  void setBackendUrl(String url) {
    _backendUrl = url;
  }

  Future<GatewayListResponse> listGateways() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendUrl/gateways'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return GatewayListResponse.fromJson(data);
      } else {
        return GatewayListResponse(
          gateways: {},
          error: 'Failed to load gateways: ${response.statusCode}',
        );
      }
    } catch (e) {
      return GatewayListResponse(
        gateways: {},
        error: 'Network error: $e',
      );
    }
  }

  Future<GatewayConfigResponse> configureGateway({
    required String gateway,
    required Map<String, dynamic> config,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/gateways/configure'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'gateway': gateway,
              'config': config,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return GatewayConfigResponse.fromJson(data);
      } else {
        return GatewayConfigResponse(
          gateway: gateway,
          error: 'Failed to configure gateway: ${response.statusCode}',
        );
      }
    } catch (e) {
      return GatewayConfigResponse(
        gateway: gateway,
        error: 'Network error: $e',
      );
    }
  }

  Future<GatewayActionResponse> enableGateway(String gateway) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/gateways/enable'),
            headers: {
              'Content-Type': 'application/json',
              'x-admin-key': _config.apiUrl,
            },
            body: jsonEncode({'gateway': gateway}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return GatewayActionResponse.fromJson(data);
      } else {
        return GatewayActionResponse(
          gateway: gateway,
          error: 'Failed to enable gateway: ${response.statusCode}',
        );
      }
    } catch (e) {
      return GatewayActionResponse(
        gateway: gateway,
        error: 'Network error: $e',
      );
    }
  }

  Future<GatewayActionResponse> disableGateway(String gateway) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/gateways/disable'),
            headers: {
              'Content-Type': 'application/json',
              'x-admin-key': _config.apiUrl,
            },
            body: jsonEncode({'gateway': gateway}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return GatewayActionResponse.fromJson(data);
      } else {
        return GatewayActionResponse(
          gateway: gateway,
          error: 'Failed to disable gateway: ${response.statusCode}',
        );
      }
    } catch (e) {
      return GatewayActionResponse(
        gateway: gateway,
        error: 'Network error: $e',
      );
    }
  }
}

class GatewayInfo {
  final String name;
  final String description;
  final String icon;
  final List<String> requiresConfig;
  final String componentJid;
  final String slidgeImage;
  final bool enabled;
  final bool configured;
  final String status;

  GatewayInfo({
    required this.name,
    required this.description,
    required this.icon,
    required this.requiresConfig,
    required this.componentJid,
    required this.slidgeImage,
    required this.enabled,
    required this.configured,
    required this.status,
  });

  String get statusLabel {
    switch (status) {
      case 'ready':
        return 'Active';
      case 'not_configured':
        return 'Needs Setup';
      case 'disabled':
        return 'Disabled';
      default:
        return status;
    }
  }

  Color get statusColor {
    switch (status) {
      case 'ready':
        return const Color(0xFF4CAF50);
      case 'not_configured':
        return const Color(0xFFFF9800);
      case 'disabled':
        return const Color(0xFF9E9E9E);
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  IconData get iconData {
    switch (icon) {
      case 'telegram':
        return Icons.send;
      case 'discord':
        return Icons.discord;
      case 'irc':
        return Icons.chat;
      case 'matrix':
        return Icons.grid_view;
      case 'whatsapp':
        return Icons.chat_bubble;
      default:
        return Icons.link;
    }
  }
}

class GatewayListResponse {
  final Map<String, GatewayInfo> gateways;
  final String? error;

  GatewayListResponse({required this.gateways, this.error});

  factory GatewayListResponse.fromJson(Map<String, dynamic> json) {
    final gatewaysJson = json['gateways'] as Map<String, dynamic>;
    return GatewayListResponse(
      gateways: gatewaysJson.map((key, value) {
        final data = value as Map<String, dynamic>;
        return MapEntry(key, GatewayInfo(
          name: data['name'] ?? key,
          description: data['description'] ?? '',
          icon: data['icon'] ?? key,
          requiresConfig: (data['requiresConfig'] as List?)?.cast<String>() ?? [],
          componentJid: data['componentJid'] ?? '$key.gibberapp.online',
          slidgeImage: data['slidgeImage'] ?? '',
          enabled: data['enabled'] ?? false,
          configured: data['configured'] ?? false,
          status: data['status'] ?? 'disabled',
        ));
      }),
      error: json['error'] as String?,
    );
  }
}

class GatewayConfigResponse {
  final String gateway;
  final Map<String, dynamic>? config;
  final String? dockerComposeSnippet;
  final Map<String, String>? environmentVars;
  final String? error;

  GatewayConfigResponse({
    required this.gateway,
    this.config,
    this.dockerComposeSnippet,
    this.environmentVars,
    this.error,
  });

  factory GatewayConfigResponse.fromJson(Map<String, dynamic> json) {
    return GatewayConfigResponse(
      gateway: json['gateway'] as String? ?? '',
      config: json['config'] as Map<String, dynamic>?,
      dockerComposeSnippet: json['dockerComposeSnippet'] as String?,
      environmentVars: (json['environmentVars'] as Map<String, dynamic>?)?.cast<String, String>(),
      error: json['error'] as String?,
    );
  }
}

class GatewayActionResponse {
  final String gateway;
  final String? message;
  final String? action;
  final String? restartCommand;
  final String? error;

  GatewayActionResponse({
    required this.gateway,
    this.message,
    this.action,
    this.restartCommand,
    this.error,
  });

  factory GatewayActionResponse.fromJson(Map<String, dynamic> json) {
    return GatewayActionResponse(
      gateway: json['gateway'] as String? ?? '',
      message: json['message'] as String?,
      action: json['action'] as String?,
      restartCommand: json['restartCommand'] as String?,
      error: json['error'] as String?,
    );
  }
}
