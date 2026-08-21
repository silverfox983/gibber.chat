import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class SlidgeInstance {
  final String id;
  final String userJid;
  final String gatewayType;
  final String componentJid;
  final String componentSecret;
  final Map<String, String> envVars;
  Process? process;
  int? pid;
  bool isRunning = false;
  String? lastError;

  SlidgeInstance({
    required this.id,
    required this.userJid,
    required this.gatewayType,
    required this.componentJid,
    required this.componentSecret,
    required this.envVars,
    this.process,
    this.pid,
    this.isRunning = false,
    this.lastError,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'userJid': userJid,
    'gatewayType': gatewayType,
    'componentJid': componentJid,
    'isRunning': isRunning,
    'pid': pid,
    'lastError': lastError,
  };
}

class SlidgeProcessManager {
  static const String _instancesDir = '/tmp/slidge_instances';
  static const String _venvDir = '/tmp/slidge_venvs';

  final Map<String, SlidgeInstance> _instances = {};

  SlidgeProcessManager() {
    _ensureDirectories();
  }

  void _ensureDirectories() {
    Directory(_instancesDir).createSync(recursive: true);
    Directory(_venvDir).createSync(recursive: true);
  }

  String _getVenvForType(String gatewayType) {
    return '$_venvDir/$gatewayType';
  }

  Future<bool> _ensureVenv(String gatewayType) async {
    final venvPath = _getVenvForType(gatewayType);
    final venvDir = Directory(venvPath);

    if (venvDir.existsSync()) {
      return true;
    }

    final result = await Process.run('python3', ['-m', 'venv', venvPath]);
    if (result.exitCode != 0) {
      print('Failed to create venv for $gatewayType: ${result.stderr}');
      return false;
    }

    final pipResult = await Process.run(
      '$venvPath/bin/pip',
      ['install', '-q', _pipPackageForType(gatewayType)],
    );
    if (pipResult.exitCode != 0) {
      print('Failed to install slidge for $gatewayType: ${pipResult.stderr}');
      return false;
    }

    return true;
  }

  String _pipPackageForType(String gatewayType) {
    switch (gatewayType) {
      case 'telegram':
        return 'slidgram';
      case 'discord':
        return 'slidcord';
      case 'irc':
        return 'slidirc';
      case 'matrix':
        return 'matridge';
      case 'whatsapp':
        return 'slidge-whatsapp';
      default:
        return 'slidgram';
    }
  }

  String generateSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<SlidgeInstance?> startInstance({
    required String userJid,
    required String gatewayType,
    required Map<String, dynamic> config,
    required String componentJid,
    required String componentSecret,
  }) async {
    final instanceId = '${gatewayType}_${userJid.split('@').first}_${DateTime.now().millisecondsSinceEpoch}';

    final envVars = <String, String>{
      'SLIDGE_COMPONENT_JID': componentJid,
      'SLIDGE_COMPONENT_SECRET': componentSecret,
      'SLIDGE_XMPP_SERVER': 'localhost',
      'SLIDGE_XMPP_PORT': '5270',
      'SLIDGE_REGISTRATION_OPEN': 'false',
      'PATH': Platform.resolvedExecutable.contains('dart')
          ? '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
          : Platform.resolvedExecutable.substring(0, Platform.resolvedExecutable.lastIndexOf('/')),
    };

    switch (gatewayType) {
      case 'telegram':
        envVars['TG_API_ID'] = config['api_id']?.toString() ?? '';
        envVars['TG_API_HASH'] = config['api_hash']?.toString() ?? '';
        if (config['bot_token'] != null) {
          envVars['TG_BOT_TOKEN'] = config['bot_token'].toString();
        }
        if (config['phone_number'] != null) {
          envVars['TG_PHONE_NUMBER'] = config['phone_number'].toString();
        }
        break;
      case 'discord':
        envVars['DISCORD_BOT_TOKEN'] = config['bot_token']?.toString() ?? '';
        break;
      case 'irc':
        envVars['IRC_SERVER_HOSTNAME'] = config['server_hostname']?.toString() ?? '';
        envVars['IRC_SERVER_PORT'] = config['server_port']?.toString() ?? '6667';
        envVars['IRC_NICKNAME'] = config['nickname']?.toString() ?? userJid.split('@').first;
        if (config['password'] != null) {
          envVars['IRC_SERVER_PASSWORD'] = config['password'].toString();
        }
        if (config['channels'] != null) {
          envVars['IRC_CHANNELS'] = config['channels'].toString();
        }
        break;
      case 'matrix':
        envVars['MATRIX_HOMESERVER'] = config['homeserver_url']?.toString() ?? 'https://matrix.org';
        if (config['access_token'] != null) {
          envVars['MATRIX_ACCESS_TOKEN'] = config['access_token'].toString();
        }
        if (config['user_id'] != null) {
          envVars['MATRIX_USER_ID'] = config['user_id'].toString();
        }
        break;
      case 'whatsapp':
        envVars['WA_PHONE_NUMBER'] = config['phone_number']?.toString() ?? '';
        if (config['device_name'] != null) {
          envVars['WA_DEVICE_NAME'] = config['device_name'].toString();
        }
        break;
    }

    final instance = SlidgeInstance(
      id: instanceId,
      userJid: userJid,
      gatewayType: gatewayType,
      componentJid: componentJid,
      componentSecret: componentSecret,
      envVars: envVars,
    );

    _instances[instanceId] = instance;

    bool started = false;
    String? error;

    if (gatewayType == 'irc') {
      started = await _startIrcInstance(instance);
    } else {
      started = await _startPythonInstance(instance);
    }

    if (started) {
      instance.isRunning = true;
      print('Started slidge instance $instanceId for $userJid');
      return instance;
    } else {
      instance.isRunning = false;
      instance.lastError = error ?? 'Failed to start';
      _instances.remove(instanceId);
      return null;
    }
  }

  Future<bool> _startPythonInstance(SlidgeInstance instance) async {
    final venvPath = _getVenvForType(instance.gatewayType);
    final venvDir = Directory(venvPath);

    if (!venvDir.existsSync()) {
      final created = await _ensureVenv(instance.gatewayType);
      if (!created) return false;
    }

    final slidgeCmd = '$venvPath/bin/slidge';

    try {
      final process = await Process.start(
        slidgeCmd,
        [],
        environment: instance.envVars,
        workingDirectory: _instancesDir,
      );

      instance.process = process;
      instance.pid = process.pid;

      process.stderr.transform(utf8.decoder).listen((data) {
        if (data.contains('Error') || data.contains('Exception')) {
          instance.lastError = data;
        }
        print('[slidge ${instance.gatewayType}] $data');
      });

      process.stdout.transform(utf8.decoder).listen((data) {
        print('[slidge ${instance.gatewayType}] $data');
      });

      process.exitCode.then((code) {
        print('Slidge instance ${instance.id} exited with code $code');
        instance.isRunning = false;
      });

      await Future.delayed(const Duration(seconds: 2));

      if (!instance.isRunning && instance.process != null) {
        return instance.process!.pid > 0;
      }

      return instance.isRunning;
    } catch (e) {
      instance.lastError = e.toString();
      print('Failed to start slidge instance: $e');
      return false;
    }
  }

  Future<bool> _startIrcInstance(SlidgeInstance instance) async {
    return _startPythonInstance(instance);
  }

  Future<bool> stopInstance(String instanceId) async {
    final instance = _instances[instanceId];
    if (instance == null) return false;

    if (instance.process != null) {
      instance.process!.kill(ProcessSignal.sigterm);
      await Future.delayed(const Duration(seconds: 2));
      if (instance.process != null && instance.process!.pid > 0) {
        instance.process!.kill(ProcessSignal.sigkill);
      }
    }

    instance.isRunning = false;
    _instances.remove(instanceId);
    print('Stopped slidge instance $instanceId');
    return true;
  }

  Future<bool> stopAllForUser(String userJid) async {
    final toStop = _instances.values.where((i) => i.userJid == userJid).toList();
    for (final instance in toStop) {
      await stopInstance(instance.id);
    }
    return true;
  }

  SlidgeInstance? getInstance(String instanceId) => _instances[instanceId];

  SlidgeInstance? getInstanceForUser(String userJid, String gatewayType) {
    try {
      return _instances.values.firstWhere(
        (i) => i.userJid == userJid && i.gatewayType == gatewayType,
      );
    } catch (_) {
      return null;
    }
  }

  List<SlidgeInstance> getAllInstances() => _instances.values.toList();

  List<SlidgeInstance> getInstancesForUser(String userJid) {
    return _instances.values.where((i) => i.userJid == userJid).toList();
  }

  bool isInstanceRunning(String instanceId) {
    final instance = _instances[instanceId];
    if (instance == null) return false;
    if (instance.process == null) return false;
    return instance.isRunning && instance.process!.pid > 0;
  }

  Future<void> cleanupDeadInstances() async {
    final dead = <String>[];
    for (final entry in _instances.entries) {
      final instance = entry.value;
      if (instance.process != null) {
        try {
          final killResult = await Process.run('kill', ['-0', instance.process!.pid.toString()]);
          if (killResult.exitCode != 0) {
            dead.add(entry.key);
          }
        } catch (_) {
          dead.add(entry.key);
        }
      }
    }
    for (final id in dead) {
      _instances.remove(id);
    }
  }
}
