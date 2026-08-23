import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/slidge_process_manager.dart';
import 'package:gibber_backend/src/services/prosody_component_manager.dart';

class UserGateway {
  final String id;
  final String jid;
  final String gatewayType;
  final Map<String, dynamic> config;
  final bool enabled;
  final String status;
  final String? componentJid;
  final String? containerId;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserGateway({
    required this.id,
    required this.jid,
    required this.gatewayType,
    required this.config,
    required this.enabled,
    required this.status,
    this.componentJid,
    this.containerId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserGateway.fromRow(Map<String, dynamic> row) {
    return UserGateway(
      id: row['id'] as String,
      jid: row['jid'] as String,
      gatewayType: row['gateway_type'] as String,
      config: row['config'] != null ? jsonDecode(row['config'] as String) as Map<String, dynamic> : {},
      enabled: (row['enabled'] as int) == 1,
      status: row['status'] as String? ?? 'disabled',
      componentJid: row['component_jid'] as String?,
      containerId: row['container_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': jid,
    'gatewayType': gatewayType,
    'config': config,
    'enabled': enabled,
    'status': status,
    'componentJid': componentJid,
    'containerId': containerId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

class UserGatewayService {
  final DatabaseService _db;
  final SlidgeProcessManager _processManager;
  final ProsodyComponentManager _prosodyManager;
  final Uuid _uuid = const Uuid();

  static final availableGatewayTypes = {
    'telegram': {
      'name': 'Telegram',
      'description': 'Bridge to Telegram messenger',
      'requiresConfig': ['api_id', 'api_hash'],
      'optionalConfig': ['phone_number', 'bot_token'],
      'componentJid': 'telegram',
      'slidgeImage': 'ghcr.io/regretfulswan/slidgram:latest',
      'perUserInstance': true,
    },
    'discord': {
      'name': 'Discord',
      'description': 'Bridge to Discord servers and channels',
      'requiresConfig': ['bot_token'],
      'optionalConfig': ['server_ids'],
      'componentJid': 'discord',
      'slidgeImage': 'ghcr.io/regretfulswan/slidcord:latest',
      'perUserInstance': true,
    },
    'irc': {
      'name': 'IRC',
      'description': 'Bridge to IRC networks',
      'requiresConfig': ['server_hostname', 'server_port'],
      'optionalConfig': ['nickname', 'channels', 'password'],
      'componentJid': 'irc',
      'slidgeImage': 'ghcr.io/regretfulswan/slidirc:latest',
      'perUserInstance': true,
    },
    'matrix': {
      'name': 'Matrix',
      'description': 'Bridge to Matrix homeservers',
      'requiresConfig': ['homeserver_url'],
      'optionalConfig': ['access_token', 'user_id'],
      'componentJid': 'matrix',
      'slidgeImage': 'ghcr.io/regretfulswan/matridge:latest',
      'perUserInstance': false,
    },
    'whatsapp': {
      'name': 'WhatsApp',
      'description': 'Bridge to WhatsApp (via linked device)',
      'requiresConfig': ['phone_number'],
      'optionalConfig': ['device_name'],
      'componentJid': 'whatsapp',
      'slidgeImage': 'ghcr.io/regretfulswan/slidge-whatsapp:latest',
      'perUserInstance': true,
    },
    'steam': {
      'name': 'Steam',
      'description': 'Bridge to Steam Chat',
      'requiresConfig': [],
      'optionalConfig': ['username', 'password'],
      'componentJid': 'steam',
      'slidgeImage': 'codeberg.org/slidge/sleamdge:latest',
      'perUserInstance': true,
    },
  };

  UserGatewayService(this._db, this._processManager, this._prosodyManager);

  List<UserGateway> getUserGateways(String jid) {
    final result = _db.db.select(
      'SELECT * FROM user_gateways WHERE jid = ? ORDER BY created_at DESC',
      [jid],
    );
    return result.map((row) => UserGateway.fromRow(row)).toList();
  }

  UserGateway? getUserGateway(String jid, String gatewayType) {
    final result = _db.db.select(
      'SELECT * FROM user_gateways WHERE jid = ? AND gateway_type = ?',
      [jid, gatewayType],
    );
    if (result.isEmpty) return null;
    return UserGateway.fromRow(result.first);
  }

  UserGateway? getUserGatewayById(String id) {
    final result = _db.db.select(
      'SELECT * FROM user_gateways WHERE id = ?',
      [id],
    );
    if (result.isEmpty) return null;
    return UserGateway.fromRow(result.first);
  }

  UserGateway createOrUpdateGateway({
    required String jid,
    required String gatewayType,
    required Map<String, dynamic> config,
  }) {
    final existing = getUserGateway(jid, gatewayType);
    final now = DateTime.now().toIso8601String();

    if (existing != null) {
      _db.db.execute(
        '''UPDATE user_gateways SET config = ?, updated_at = ? WHERE id = ?''',
        [jsonEncode(config), now, existing.id],
      );
      return getUserGatewayById(existing.id)!;
    } else {
      final id = _uuid.v4();
      _db.db.execute(
        '''INSERT INTO user_gateways (id, jid, gateway_type, config, enabled, status, created_at, updated_at)
           VALUES (?, ?, ?, ?, 0, 'configured', ?, ?)''',
        [id, jid, gatewayType, jsonEncode(config), now, now],
      );
      return getUserGatewayById(id)!;
    }
  }

  Future<UserGateway?> enableGateway(String jid, String gatewayType) async {
    final existing = getUserGateway(jid, gatewayType);
    if (existing == null) return null;

    final componentJid = existing.componentJid ?? _generateComponentJid(jid, gatewayType);
    final componentSecret = _generateSecret();
    final now = DateTime.now().toIso8601String();

    _db.db.execute(
      '''UPDATE user_gateways SET enabled = 1, status = 'starting', component_jid = ?, updated_at = ? WHERE id = ?''',
      [componentJid, now, existing.id],
    );

    final added = await _prosodyManager.addComponent(componentJid, componentSecret);
    if (!added) {
      print('Failed to add Prosody component for $componentJid');
      updateGatewayStatus(existing.id, 'error');
      return getUserGatewayById(existing.id);
    }

    final instance = await _processManager.startInstance(
      userJid: jid,
      gatewayType: gatewayType,
      config: existing.config,
      componentJid: componentJid,
      componentSecret: componentSecret,
    );

    if (instance != null) {
      updateGatewayStatus(existing.id, 'running', containerId: instance.id);
      print('Started slidge instance ${instance.id} for $jid ($gatewayType)');
    } else {
      updateGatewayStatus(existing.id, 'error');
      print('Failed to start slidge instance for $jid ($gatewayType)');
    }

    return getUserGatewayById(existing.id);
  }

  Future<UserGateway?> disableGateway(String jid, String gatewayType) async {
    final existing = getUserGateway(jid, gatewayType);
    if (existing == null) return null;

    final instance = _processManager.getInstanceForUser(jid, gatewayType);
    if (instance != null) {
      await _processManager.stopInstance(instance.id);
    }

    if (existing.componentJid != null) {
      await _prosodyManager.removeComponent(existing.componentJid!);
    }

    final now = DateTime.now().toIso8601String();
    _db.db.execute(
      '''UPDATE user_gateways SET enabled = 0, status = 'disabled', container_id = NULL, updated_at = ? WHERE id = ?''',
      [now, existing.id],
    );

    return getUserGatewayById(existing.id);
  }

  Future<bool> removeGateway(String jid, String gatewayType) async {
    final existing = getUserGateway(jid, gatewayType);
    if (existing == null) return false;

    if (existing.enabled) {
      await disableGateway(jid, gatewayType);
    }

    _db.db.execute(
      'DELETE FROM user_gateways WHERE jid = ? AND gateway_type = ?',
      [jid, gatewayType],
    );
    return true;
  }

  void updateGatewayStatus(String id, String status, {String? containerId}) {
    final now = DateTime.now().toIso8601String();
    if (containerId != null) {
      _db.db.execute(
        'UPDATE user_gateways SET status = ?, container_id = ?, updated_at = ? WHERE id = ?',
        [status, containerId, now, id],
      );
    } else {
      _db.db.execute(
        'UPDATE user_gateways SET status = ?, updated_at = ? WHERE id = ?',
        [status, now, id],
      );
    }
  }

  Future<void> startAllEnabledGateways() async {
    final result = _db.db.select('SELECT * FROM user_gateways WHERE enabled = 1');
    for (final row in result) {
      final gateway = UserGateway.fromRow(row);
      try {
        await enableGateway(gateway.jid, gateway.gatewayType);
      } catch (e) {
        print('Failed to start gateway ${gateway.jid}/${gateway.gatewayType}: $e');
      }
    }
  }

  Future<void> stopAllGateways() async {
    final result = _db.db.select('SELECT * FROM user_gateways WHERE enabled = 1');
    for (final row in result) {
      final gateway = UserGateway.fromRow(row);
      try {
        await disableGateway(gateway.jid, gateway.gatewayType);
      } catch (e) {
        print('Failed to stop gateway ${gateway.jid}/${gateway.gatewayType}: $e');
      }
    }
  }

  Map<String, dynamic>? testGatewayConfig(String gatewayType, Map<String, dynamic> config) {
    switch (gatewayType) {
      case 'telegram':
        return _testTelegramConfig(config);
      case 'discord':
        return _testDiscordConfig(config);
      case 'matrix':
        return _testMatrixConfig(config);
      case 'irc':
        return _testIrcConfig(config);
      case 'whatsapp':
        return _testWhatsappConfig(config);
      default:
        return {'valid': true, 'message': 'Configuration accepted'};
    }
  }

  Map<String, dynamic>? _testTelegramConfig(Map<String, dynamic> config) {
    final apiId = config['api_id'];
    final apiHash = config['api_hash'];
    if (apiId == null || apiHash == null) {
      return {'valid': false, 'error': 'api_id and api_hash are required'};
    }
    final apiIdInt = int.tryParse(apiId.toString());
    if (apiIdInt == null) {
      return {'valid': false, 'error': 'api_id must be a number'};
    }
    if (apiHash.toString().length < 32) {
      return {'valid': false, 'error': 'api_hash appears to be invalid'};
    }
    return {'valid': true, 'message': 'Telegram configuration appears valid'};
  }

  Map<String, dynamic>? _testDiscordConfig(Map<String, dynamic> config) {
    final botToken = config['bot_token'];
    if (botToken == null || botToken.toString().isEmpty) {
      return {'valid': false, 'error': 'bot_token is required'};
    }
    if (!botToken.toString().contains('.')) {
      return {'valid': false, 'error': 'bot_token appears to be invalid'};
    }
    return {'valid': true, 'message': 'Discord configuration appears valid'};
  }

  Map<String, dynamic>? _testMatrixConfig(Map<String, dynamic> config) {
    final homeserver = config['homeserver_url'];
    if (homeserver == null || homeserver.toString().isEmpty) {
      return {'valid': false, 'error': 'homeserver_url is required'};
    }
    if (!homeserver.toString().startsWith('http')) {
      return {'valid': false, 'error': 'homeserver_url must be a valid URL'};
    }
    return {'valid': true, 'message': 'Matrix configuration appears valid'};
  }

  Map<String, dynamic>? _testIrcConfig(Map<String, dynamic> config) {
    final hostname = config['server_hostname'];
    if (hostname == null || hostname.toString().trim().isEmpty) {
      return {'valid': false, 'error': 'server_hostname is required'};
    }
    final port = config['server_port'];
    if (port != null) {
      final portInt = int.tryParse(port.toString());
      if (portInt == null || portInt < 1 || portInt > 65535) {
        return {'valid': false, 'error': 'server_port must be a number between 1 and 65535'};
      }
    }
    return {'valid': true, 'message': 'IRC configuration appears valid'};
  }

  Map<String, dynamic>? _testWhatsappConfig(Map<String, dynamic> config) {
    final phone = config['phone_number'];
    if (phone == null || phone.toString().trim().isEmpty) {
      return {'valid': false, 'error': 'phone_number is required'};
    }
    final cleaned = phone.toString().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (!RegExp(r'^\+?\d{7,15}$').hasMatch(cleaned)) {
      return {'valid': false, 'error': 'phone_number must be in E.164 format (e.g. +1234567890)'};
    }
    return {'valid': true, 'message': 'WhatsApp configuration appears valid'};
  }

  String _generateComponentJid(String jid, String gatewayType) {
    final parts = jid.split('@');
    final userHash = parts.first.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final domain = parts.length > 1 ? parts[1].split('/').first : 'gibberapp.online';
    return '${gatewayType}_$userHash.$domain';
  }

  String _generateSecret() {
    return _processManager.generateSecret();
  }
}
