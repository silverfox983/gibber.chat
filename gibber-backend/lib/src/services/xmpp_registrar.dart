import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

class XmppRegistrar {
  final String configPath;
  String _domain = 'gibber.chat';
  final String _prosodyCtlPath;
  final String _dockerContainer;
  final bool _useDocker;

  XmppRegistrar({
    required this.configPath,
    String prosodyCtlPath = 'prosodyctl',
    String dockerContainer = 'gibber_xmpp',
    bool useDocker = false,
  }) : _prosodyCtlPath = prosodyCtlPath,
       _dockerContainer = dockerContainer,
       _useDocker = useDocker {
    _loadConfig();
  }

  String get domain => _domain;

  void _loadConfig() {
    final configFile = File(configPath);
    if (configFile.existsSync()) {
      final content = configFile.readAsStringSync();
      final domainMatch = RegExp(r'VirtualHost\s+"([^"]+)"').firstMatch(content);
      if (domainMatch != null) {
        _domain = domainMatch.group(1)!;
      }
    }
  }

  Future<XmppRegistrationResult> register(String username, String password, {String? host}) async {
    final jidDomain = host ?? _domain;
    final jid = '$username@$jidDomain';

    try {
      final result = await _runProsodyCtl(['register', username, jidDomain, password]);

      if (result.exitCode == 0) {
        return XmppRegistrationResult(
          success: true,
          jid: jid,
          message: 'Registration successful',
        );
      }

      final stderr = result.stderr.toString().trim();
      if (stderr.contains('already exists') || stderr.contains('duplicate')) {
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Username already exists',
        );
      }

      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Registration failed: $stderr',
      );
    } catch (e) {
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Failed to register: $e',
      );
    }
  }

  Future<bool> userExists(String username, {String? host}) async {
    final jidDomain = host ?? _domain;
    try {
      final result = await _runProsodyCtl(['user', 'exists', username, jidDomain]);
      return result.exitCode == 0 &&
          result.stdout.toString().trim().toLowerCase().contains('true');
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteUser(String username, {String? host}) async {
    final jidDomain = host ?? _domain;
    try {
      final result = await _runProsodyCtl(['user', 'delete', username, jidDomain]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> changePassword(String username, String newPassword, {String? host}) async {
    final jidDomain = host ?? _domain;
    try {
      final result = await _runProsodyCtl(['register', username, jidDomain, newPassword]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<ProcessResult> _runProsodyCtl(List<String> args) async {
    if (_useDocker) {
      return Process.run(
        'docker',
        ['exec', _dockerContainer, _prosodyCtlPath, ...args],
      );
    }
    return Process.run(_prosodyCtlPath, args);
  }

  String hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}

class XmppRegistrationResult {
  final bool success;
  final String jid;
  final String message;

  XmppRegistrationResult({
    required this.success,
    required this.jid,
    required this.message,
  });
}