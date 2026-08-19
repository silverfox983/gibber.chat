import 'dart:async';
import 'dart:io';

class SlidgeProcessConfig {
  final String userJid;
  final String gatewayType;
  final String componentJid;
  final String componentSecret;
  final Map<String, dynamic> config;
  final int processId;

  SlidgeProcessConfig({
    required this.userJid,
    required this.gatewayType,
    required this.componentJid,
    required this.componentSecret,
    required this.config,
    required this.processId,
  });
}

class SupervisorService {
  static const String _supervisordConfDir = '/etc/supervisor/conf.d';
  static const String _slidgeConfDir = '/etc/slidge';

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    final slidgeDir = Directory(_slidgeConfDir);
    if (!await slidgeDir.exists()) {
      await slidgeDir.create(recursive: true);
    }

    _initialized = true;
    print('SupervisorService initialized');
  }

  Future<Map<String, dynamic>> callSupervisorctl(List<String> args) async {
    final result = await Process.run(
      'supervisorctl',
      ['-c', '/etc/supervisor/supervisord.conf', ...args],
    );

    return {
      'exitCode': result.exitCode,
      'stdout': result.stdout.toString(),
      'stderr': result.stderr.toString(),
    };
  }

  String _slidgeImageForType(String gatewayType) {
    switch (gatewayType) {
      case 'telegram':
        return 'ghcr.io/regretfulswan/slidgram:latest';
      case 'discord':
        return 'ghcr.io/regretfulswan/slidcord:latest';
      case 'irc':
        return 'ghcr.io/regretfulswan/slidirc:latest';
      case 'matrix':
        return 'ghcr.io/regretfulswan/matridge:latest';
      case 'whatsapp':
        return 'ghcr.io/regretfulswan/slidge-whatsapp:latest';
      default:
        return 'ghcr.io/regretfulswan/slidgram:latest';
    }
  }

  String _supervisordProgramForConfig(SlidgeProcessConfig cfg) {
    final image = _slidgeImageForType(cfg.gatewayType);
    final safeName = '${cfg.gatewayType}_${cfg.processId}'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

    final envVars = <String, String>{
      'SLIDGE_COMPONENT_JID': cfg.componentJid,
      'SLIDGE_COMPONENT_SECRET': cfg.componentSecret,
      'SLIDGE_XMPP_SERVER': 'localhost',
      'SLIDGE_XMPP_PORT': '5270',
      'SLIDGE_REGISTRATION_OPEN': 'false',
    };

    switch (cfg.gatewayType) {
      case 'telegram':
        envVars['TG_API_ID'] = cfg.config['api_id']?.toString() ?? '';
        envVars['TG_API_HASH'] = cfg.config['api_hash']?.toString() ?? '';
        break;
      case 'discord':
        envVars['DISCORD_BOT_TOKEN'] = cfg.config['bot_token']?.toString() ?? '';
        break;
      case 'irc':
        envVars['IRC_SERVER_HOSTNAME'] = cfg.config['server_hostname']?.toString() ?? '';
        envVars['IRC_SERVER_PORT'] = cfg.config['server_port']?.toString() ?? '6667';
        envVars['IRC_NICKNAME'] = cfg.config['nickname']?.toString() ?? cfg.userJid.split('@').first;
        break;
      case 'matrix':
        envVars['MATRIX_HOMESERVER'] = cfg.config['homeserver_url']?.toString() ?? 'https://matrix.org';
        break;
      case 'whatsapp':
        envVars['WA_PHONE_NUMBER'] = cfg.config['phone_number']?.toString() ?? '';
        break;
    }

    final envLine = envVars.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '"${e.key}=${e.value}"')
        .join(',');

    return '''
[program:slidge_$safeName]
command=docker run --rm --network host
  -e SLIDGE_COMPONENT_JID=${cfg.componentJid}
  -e SLIDGE_COMPONENT_SECRET=${cfg.componentSecret}
  -e SLIDGE_XMPP_SERVER=localhost
  -e SLIDGE_XMPP_PORT=5270
  -e SLIDGE_REGISTRATION_OPEN=false
  $image
environment=$envLine
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
''';
  }

  Future<bool> startGateway(SlidgeProcessConfig cfg) async {
    await initialize();

    final safeName = '${cfg.gatewayType}_${cfg.processId}'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final programFile = '$_supervisordConfDir/slidge_$safeName.conf';

    final content = _supervisordProgramForConfig(cfg);
    final file = File(programFile);
    await file.writeAsString(content);

    final result = await callSupervisorctl(['reread']);
    if (result['exitCode'] != 0) {
      print('supervisorctl reread failed: ${result['stderr']}');
      return false;
    }

    final startResult = await callSupervisorctl(['update', 'slidge_$safeName']);
    if (startResult['exitCode'] != 0) {
      print('supervisorctl start failed: ${startResult['stderr']}');
      return false;
    }

    print('Started slidge_$safeName for ${cfg.userJid}');
    return true;
  }

  Future<bool> stopGateway(String gatewayType, int processId) async {
    final safeName = '${gatewayType}_$processId'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final programFile = '$_supervisordConfDir/slidge_$safeName.conf';

    final result = await callSupervisorctl(['stop', 'slidge_$safeName']);
    if (result['exitCode'] != 0 && !result['stderr'].toString().contains('not running')) {
      print('supervisorctl stop failed: ${result['stderr']}');
    }

    final file = File(programFile);
    if (await file.exists()) {
      await file.delete();
    }

    await callSupervisorctl(['reread']);
    await callSupervisorctl(['update']);

    print('Stopped slidge_$safeName');
    return true;
  }

  Future<Map<String, String>> getGatewayStatuses(List<String> gatewayTypes) async {
    final result = await callSupervisorctl(['status', '-v']);
    final statuses = <String, String>{};

    final lines = result['stdout'].toString().split('\n');
    for (final line in lines) {
      for (final type in gatewayTypes) {
        if (line.contains('slidge_$type')) {
          if (line.contains('RUNNING')) {
            statuses[type] = 'running';
          } else if (line.contains('STARTING')) {
            statuses[type] = 'starting';
          } else if (line.contains('FATAL')) {
            statuses[type] = 'error';
          } else {
            statuses[type] = 'stopped';
          }
        }
      }
    }

    return statuses;
  }

  Future<bool> restartGateway(String gatewayType, int processId) async {
    final safeName = '${gatewayType}_$processId'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final result = await callSupervisorctl(['restart', 'slidge_$safeName']);
    return result['exitCode'] == 0;
  }

  Future<String?> getGatewayLogs(String gatewayType, int processId, {int lines = 50}) async {
    final safeName = '${gatewayType}_$processId'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final result = await callSupervisorctl(['tail', '-$lines', 'slidge_$safeName']);
    if (result['exitCode'] == 0) {
      return result['stdout'].toString();
    }
    return null;
  }
}
