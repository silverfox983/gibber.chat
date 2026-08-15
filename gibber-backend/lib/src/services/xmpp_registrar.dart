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
      final baseDir = '/var/lib/prosody';
      final domainDir = Directory('$baseDir/$domain');
      print('XmppRegistrar [internal]: Creating user $jid, domain dir: ${domainDir.path}');

      if (!domainDir.existsSync()) {
        print('XmppRegistrar [internal]: Creating domain directory ${domainDir.path}');
        domainDir.createSync(recursive: true);
      }

      final accountsDir = Directory('${domainDir.path}/accounts');
      if (!accountsDir.existsSync()) {
        print('XmppRegistrar [internal]: Creating accounts directory ${accountsDir.path}');
        accountsDir.createSync(recursive: true);
      }

      final userFile = File('${accountsDir.path}/$username.dat');
      if (userFile.existsSync()) {
        print('XmppRegistrar [internal]: User $jid already exists at ${userFile.path}');
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Username already exists',
        );
      }

      final escaped = password.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final content = 'return {\n\t["password"] = "$escaped";\n};\n';
      print('XmppRegistrar [internal]: Writing user file ${userFile.path}');
      userFile.writeAsStringSync(content);

      _chownRecursive(domainDir.path);

      final verified = userFile.existsSync();
      final size = verified ? userFile.lengthSync() : 0;
      print('XmppRegistrar [internal]: User file created: exists=$verified, size=$size bytes');

      if (!verified || size == 0) {
        print('XmppRegistrar [internal]: WARNING - user file creation failed');
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Failed to create user file on disk',
        );
      }

      print('XmppRegistrar [internal]: User $jid registered successfully');
      return XmppRegistrationResult(
        success: true,
        jid: jid,
        message: 'Registration successful',
      );
    } catch (e) {
      print('XmppRegistrar [internal]: Exception during registration: $e');
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Internal registration failed: $e',
      );
    }
  }

  void _chownRecursive(String path) {
    try {
      final result = Process.runSync('chown', ['-R', '101:101', path]);
      if (result.exitCode != 0) {
        print('XmppRegistrar [internal]: chown -R 101:101 $path failed: ${result.stderr}');
      } else {
        print('XmppRegistrar [internal]: chown -R 101:101 $path succeeded');
      }
    } catch (e) {
      print('XmppRegistrar [internal]: chown exception: $e');
    }
  }

  Future<XmppRegistrationResult> _registerViaProsodyCtl(String username, String password, String domain, String jid) async {
    try {
      print('XmppRegistrar: Running prosodyctl register $username $domain');
      final result = await _runProsodyCtl(['register', username, domain, password]);

      print('XmppRegistrar: prosodyctl register exitCode=${result.exitCode}, stdout=${result.stdout.toString().trim()}, stderr=${result.stderr.toString().trim()}');

      if (result.exitCode == 0) {
        final exists = await _userExistsProsodyCtl(username, domain);
        print('XmppRegistrar: Post-registration user exists check: $exists');
        if (exists) {
          return XmppRegistrationResult(
            success: true,
            jid: jid,
            message: 'Registration successful',
          );
        }
        print('XmppRegistrar: WARNING - prosodyctl register succeeded (exit 0) but user not found');
        return XmppRegistrationResult(
          success: false,
          jid: jid,
          message: 'Registration command succeeded but user was not found. The XMPP server may not be running.',
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
      print('XmppRegistrar: Exception during prosodyctl register: $e');
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
    final exists = userFile.existsSync();
    print('XmppRegistrar [internal]: userExists $username@$domain → ${userFile.path} exists=$exists');
    return exists;
  }

  Future<bool> _userExistsProsodyCtl(String username, String domain) async {
    try {
      final result = await _runProsodyCtl(['user', 'exists', username, domain]);
      final stdout = result.stdout.toString().trim().toLowerCase();
      final exists = result.exitCode == 0 && stdout.contains('true');
      print('XmppRegistrar: prosodyctl user exists $username $domain → exitCode=${result.exitCode}, stdout=$stdout, result=$exists');
      return exists;
    } catch (e) {
      print('XmppRegistrar: prosodyctl user exists exception: $e');
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
          print('XmppRegistrar [internal]: Deleted user $username@$jidDomain');
          return true;
        }
        print('XmppRegistrar [internal]: deleteUser failed - file not found: ${userFile.path}');
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
          _chownRecursive(userFile.path);
          print('XmppRegistrar [internal]: Password changed for $username@$jidDomain');
          return true;
        }
        print('XmppRegistrar [internal]: changePassword failed - user file not found: ${userFile.path}');
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
      final fullArgs = ['exec', _dockerContainer, _prosodyCtlPath, ...args];
      // Redact password from log if present (register command: [register, user, domain, password])
      final logArgs = fullArgs.toList();
      if (logArgs.length > 4 && logArgs[2] == 'register') {
        logArgs[5] = '***';
      }
      print('XmppRegistrar: Running: docker ${logArgs.join(' ')}');
      final result = await Process.run('docker', fullArgs);
      print('XmppRegistrar: docker exec result: exitCode=${result.exitCode}');
      if (result.stderr.toString().trim().isNotEmpty) {
        print('XmppRegistrar: stderr: ${result.stderr.toString().trim()}');
      }
      return result;
    }
    final logArgs = args.toList();
    if (logArgs.length > 3 && logArgs[0] == 'register') {
      logArgs[3] = '***';
    }
    print('XmppRegistrar: Running: $_prosodyCtlPath ${logArgs.join(' ')}');
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