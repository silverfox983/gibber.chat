import 'dart:convert';
import 'dart:io';

enum RegistrationMode { prosodyctl, http, internal }

class XmppRegistrar {
  final String configPath;
  String _domain = 'gibberapp.online';
  final String _prosodyCtlPath;
  final String _dockerContainer;
  final bool _useDocker;
  final RegistrationMode _mode;
  final String _prosodyHttpUrl;

  XmppRegistrar({
    required this.configPath,
    String prosodyCtlPath = 'prosodyctl',
    String dockerContainer = 'gibber_xmpp',
    bool useDocker = false,
    RegistrationMode mode = RegistrationMode.prosodyctl,
    String prosodyHttpUrl = 'http://localhost:5280',
  }) : _prosodyCtlPath = prosodyCtlPath,
       _dockerContainer = dockerContainer,
       _useDocker = useDocker,
       _mode = mode,
       _prosodyHttpUrl = prosodyHttpUrl {
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

    switch (_mode) {
      case RegistrationMode.http:
        return _registerViaHttp(username, password, jidDomain, jid);
      case RegistrationMode.internal:
        return _registerViaInternal(username, password, jidDomain, jid);
      case RegistrationMode.prosodyctl:
        return _registerViaProsodyCtl(username, password, jidDomain, jid);
    }
  }

  Future<XmppRegistrationResult> _registerViaHttp(String username, String password, String domain, String jid) async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('$_prosodyHttpUrl/register/$domain'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'username': username, 'password': password}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode == 200 || response.statusCode == 201) {
        return XmppRegistrationResult(
          success: true,
          jid: jid,
          message: 'Registration successful',
        );
      }

      if (body.contains('already') || body.contains('exists') || body.contains('conflict')) {
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Username already exists',
        );
      }

      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Registration failed: $body',
      );
    } catch (e) {
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'HTTP registration failed: $e',
      );
    }
  }

  Future<XmppRegistrationResult> _registerViaInternal(String username, String password, String domain, String jid) async {
    try {
      final dataDir = Directory('/var/lib/prosody/$domain');
      if (!dataDir.existsSync()) {
        dataDir.createSync(recursive: true);
      }
      final userFile = File('${dataDir.path}/accounts/$username.dat');
      if (userFile.existsSync()) {
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Username already exists',
        );
      }
      final accountsDir = Directory('${dataDir.path}/accounts');
      if (!accountsDir.existsSync()) {
        accountsDir.createSync(recursive: true);
      }
      final escaped = password.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      userFile.writeAsStringSync('return {\n\t["password"] = "$escaped";\n};\n');
      return XmppRegistrationResult(
        success: true,
        jid: jid,
        message: 'Registration successful',
      );
    } catch (e) {
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Internal registration failed: $e',
      );
    }
  }

  Future<XmppRegistrationResult> _registerViaProsodyCtl(String username, String password, String domain, String jid) async {
    try {
      final result = await _runProsodyCtl(['register', username, domain, password]);

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
    switch (_mode) {
      case RegistrationMode.http:
        return _userExistsViaHttp(username, jidDomain);
      case RegistrationMode.internal:
        return _userExistsInternal(username, jidDomain);
      case RegistrationMode.prosodyctl:
        return _userExistsProsodyCtl(username, jidDomain);
    }
  }

  Future<bool> _userExistsViaHttp(String username, String domain) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('$_prosodyHttpUrl/register/$domain?username=$username'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      return body.contains('exists');
    } catch (_) {
      return false;
    }
  }

  Future<bool> _userExistsInternal(String username, String domain) async {
    final userFile = File('/var/lib/prosody/$domain/accounts/$username.dat');
    return userFile.existsSync();
  }

  Future<bool> _userExistsProsodyCtl(String username, String domain) async {
    try {
      final result = await _runProsodyCtl(['user', 'exists', username, domain]);
      return result.exitCode == 0 &&
          result.stdout.toString().trim().toLowerCase().contains('true');
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteUser(String username, {String? host}) async {
    final jidDomain = host ?? _domain;
    switch (_mode) {
      case RegistrationMode.http:
        try {
          final client = HttpClient();
          final request = await client.deleteUrl(Uri.parse('$_prosodyHttpUrl/register/$jidDomain?username=$username'));
          final response = await request.close();
          client.close();
          return response.statusCode == 200 || response.statusCode == 204;
        } catch (_) {
          return false;
        }
      case RegistrationMode.internal:
        final userFile = File('/var/lib/prosody/$jidDomain/accounts/$username.dat');
        if (userFile.existsSync()) {
          userFile.deleteSync();
          return true;
        }
        return false;
      case RegistrationMode.prosodyctl:
        try {
          final result = await _runProsodyCtl(['user', 'delete', username, jidDomain]);
          return result.exitCode == 0;
        } catch (_) {
          return false;
        }
    }
  }

  Future<bool> changePassword(String username, String newPassword, {String? host}) async {
    final jidDomain = host ?? _domain;
    switch (_mode) {
      case RegistrationMode.http:
        try {
          final client = HttpClient();
          final request = await client.putUrl(Uri.parse('$_prosodyHttpUrl/register/$jidDomain'));
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'username': username, 'password': newPassword}));
          final response = await request.close();
          client.close();
          return response.statusCode == 200;
        } catch (_) {
          return false;
        }
      case RegistrationMode.internal:
        final userFile = File('/var/lib/prosody/$jidDomain/accounts/$username.dat');
        if (userFile.existsSync()) {
          final escaped = newPassword.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
          userFile.writeAsStringSync('return {\n\t["password"] = "$escaped";\n};\n');
          return true;
        }
        return false;
      case RegistrationMode.prosodyctl:
        try {
          final result = await _runProsodyCtl(['register', username, jidDomain, newPassword]);
          return result.exitCode == 0;
        } catch (_) {
          return false;
        }
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