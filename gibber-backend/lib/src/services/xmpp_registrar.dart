import 'dart:convert';
import 'dart:io';
import 'dart:async';

enum RegistrationMode { prosodyctl, http, internal, xmpp }

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
  String get prosodyHttpUrl => _prosodyHttpUrl;

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
      case RegistrationMode.xmpp:
        return _registerViaXmpp(username, password, jidDomain, jid);
      case RegistrationMode.prosodyctl:
        return _registerViaProsodyCtl(username, password, jidDomain, jid);
    }
  }

  Future<XmppRegistrationResult> _registerViaXmpp(String username, String password, String domain, String jid) async {
    final prosodyUri = Uri.parse(_prosodyHttpUrl);
    final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
    final wsPort = prosodyUri.port > 0 ? prosodyUri.port : (prosodyUri.scheme == 'https' ? 5281 : 5280);
    final wsUrl = '$wsScheme://${prosodyUri.host}:$wsPort/xmpp-websocket';

    print('XmppRegistrar [xmpp]: Connecting to $wsUrl for in-band registration of $jid (Host: $domain)');

    WebSocket? socket;
    try {
      socket = await WebSocket.connect(wsUrl, headers: {'Host': domain}, protocols: ['xmpp']);
      print('XmppRegistrar [xmpp]: WebSocket connected');
    } catch (e) {
      print('XmppRegistrar [xmpp]: Failed to connect WebSocket: $e');
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Failed to connect to XMPP server: $e',
      );
    }

    try {
      final completer = Completer<XmppRegistrationResult>();
      bool registrationSent = false;
      bool completed = false;

      socket.listen(
        (data) {
          if (data is! String) return;
          final msg = data.trim();
          if (msg.isEmpty) return;

          final preview = msg.length > 300 ? '${msg.substring(0, 300)}...' : msg;
          print('XmppRegistrar [xmpp]: Received: ${preview.replaceAll('\n', ' ')}');

          if (msg.contains('<stream:features') || msg.contains('<features')) {
            if (msg.contains('jabber:iq:register') || msg.contains("<register xmlns='http://jabber.org/features/iq-register'/>") || msg.contains('<register')) {
              if (!registrationSent) {
                registrationSent = true;
                print('XmppRegistrar [xmpp]: Stream features received with register support, sending registration IQ');

                final escapedUsername = _xmlEscape(username);
                final escapedPassword = _xmlEscape(password);
                final regIq = "<iq type='set' id='reg1'><query xmlns='jabber:iq:register'><username>$escapedUsername</username><password>$escapedPassword</password></query></iq>";
                socket!.add(regIq);
              }
            } else if (!registrationSent) {
              print('XmppRegistrar [xmpp]: Stream features received but no register support');
              if (!completed) {
                completed = true;
                completer.complete(XmppRegistrationResult(
                  success: false,
                  jid: jid,
                  message: 'XMPP server does not support in-band registration',
                ));
              }
            }
          }

          if (registrationSent && msg.contains('<iq')) {
            if (msg.contains("type='result'") || msg.contains('type="result"')) {
              print('XmppRegistrar [xmpp]: Registration successful for $jid');
              if (!completed) {
                completed = true;
                completer.complete(XmppRegistrationResult(
                  success: true,
                  jid: jid,
                  message: 'Registration successful',
                ));
              }
            } else if (msg.contains("type='error'") || msg.contains('type="error"')) {
              String errorMsg = 'Registration failed';
              if (msg.contains('<conflict') || msg.contains('already registered') || msg.contains('already exists')) {
                errorMsg = 'Username already exists';
              } else if (msg.contains('<not-acceptable') || msg.contains('not-acceptable')) {
                errorMsg = 'Registration not acceptable';
              } else if (msg.contains('<forbidden')) {
                errorMsg = 'Registration forbidden';
              } else if (msg.contains('<service-unavailable')) {
                errorMsg = 'Registration service unavailable';
              } else if (msg.contains('<not-allowed')) {
                errorMsg = 'Registration not allowed';
              }
              final errorDetail = RegExp(r'<text[^>]*>(.*?)</text>', dotAll: true).firstMatch(msg);
              if (errorDetail != null) {
                errorMsg = '$errorMsg: ${errorDetail.group(1)}';
              }
              print('XmppRegistrar [xmpp]: Registration failed: $errorMsg');
              if (!completed) {
                completed = true;
                completer.complete(XmppRegistrationResult(
                  success: false,
                  jid: jid,
                  message: errorMsg,
                ));
              }
            }
          }
        },
        onError: (e) {
          print('XmppRegistrar [xmpp]: WebSocket error: $e');
          if (!completed) {
            completed = true;
            completer.complete(XmppRegistrationResult(
              success: false,
              jid: jid,
              message: 'WebSocket error: $e',
            ));
          }
        },
        onDone: () {
          print('XmppRegistrar [xmpp]: WebSocket closed');
          if (!completed) {
            completed = true;
            completer.complete(XmppRegistrationResult(
              success: false,
              jid: jid,
              message: 'WebSocket closed before registration completed',
            ));
          }
        },
        cancelOnError: true,
      );

      socket.add("<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$domain' version='1.0'/>");

      final result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('XmppRegistrar [xmpp]: Registration timed out after 10 seconds');
          return XmppRegistrationResult(
            success: false,
            jid: jid,
            message: 'Registration timed out',
          );
        },
      );

      try {
        socket.add("<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>");
      } catch (_) {}
      await socket.close();

      return result;
    } catch (e) {
      print('XmppRegistrar [xmpp]: Exception during registration: $e');
      try {
        await socket.close();
      } catch (_) {}
      return XmppRegistrationResult(
        success: false,
        jid: jid,
        message: 'Registration failed: $e',
      );
    }
  }

  String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", '&apos;')
        .replaceAll('"', '&quot;');
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

      await _reloadProsody();

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

  Future<void> _reloadProsody() async {
    try {
      if (_useDocker && _dockerContainer != null) {
        final result = await Process.run('docker', ['exec', _dockerContainer!, 'prosodyctl', 'reload']);
        print('XmppRegistrar: docker exec prosodyctl reload exitCode=${result.exitCode}');
      } else {
        final result = await Process.run(_prosodyCtlPath, ['reload']);
        print('XmppRegistrar: prosodyctl reload exitCode=${result.exitCode}');
      }
    } catch (e) {
      print('XmppRegistrar: prosodyctl reload failed (non-fatal): $e');
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
      case RegistrationMode.xmpp:
        return _userExistsViaHttp(username, jidDomain);
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
      final request = await client.getUrl(Uri.parse('$_prosodyHttpUrl/check/?username=$username&host=$domain'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(body) as Map<String, dynamic>;
          return data['available'] == false || data['exists'] == true;
        } catch (_) {}
      }
      return body.contains('exists') || body.contains('conflict') || body.contains('not-available');
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
      case RegistrationMode.xmpp:
        // Use the Prosody HTTP registration API to delete the user.
        // Even in xmpp mode, we can use the HTTP API for user management
        // since the backend and Prosody share a Docker network.
        try {
          final client = HttpClient();
          final request = await client.deleteUrl(Uri.parse('$_prosodyHttpUrl/register/$jidDomain?username=$username'));
          final response = await request.close();
          client.close();
          if (response.statusCode == 200 || response.statusCode == 204) {
            print('XmppRegistrar [xmpp]: Deleted user $username@$jidDomain via HTTP API');
            return true;
          }
          print('XmppRegistrar [xmpp]: deleteUser via HTTP API returned ${response.statusCode}');
          return false;
        } catch (e) {
          print('XmppRegistrar [xmpp]: deleteUser via HTTP API failed: $e');
          return false;
        }
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
      case RegistrationMode.xmpp:
        return _changePasswordViaXmpp(username, newPassword, jidDomain);
      case RegistrationMode.prosodyctl:
        try {
          final result = await _runProsodyCtl(['register', username, jidDomain, newPassword]);
          return result.exitCode == 0;
        } catch (_) {
          return false;
        }
    }
  }

  Future<bool> _changePasswordViaXmpp(String username, String newPassword, String domain) async {
    final jid = '$username@$domain';
    final prosodyUri = Uri.parse(_prosodyHttpUrl);
    final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
    final wsPort = prosodyUri.port > 0 ? prosodyUri.port : (prosodyUri.scheme == 'https' ? 5281 : 5280);
    final wsUrl = '$wsScheme://${prosodyUri.host}:$wsPort/xmpp-websocket';

    print('XmppRegistrar [xmpp]: changePassword - connecting to $wsUrl for $jid');

    WebSocket? socket;
    try {
      socket = await WebSocket.connect(wsUrl, headers: {'Host': domain}, protocols: ['xmpp']);
    } catch (e) {
      print('XmppRegistrar [xmpp]: changePassword - failed to connect: $e');
      return false;
    }

    try {
      final completer = Completer<bool>();
      int iqId = 1;
      bool authenticated = false;
      bool completed = false;

      void sendIq(String iqXml) {
        socket!.add(iqXml);
      }

      socket.listen(
        (data) {
          if (data is! String) return;
          final msg = data.trim();
          if (msg.isEmpty) return;

          if (msg.contains('<stream:features') || msg.contains('<features')) {
            if (msg.contains('jabber:iq:register') || msg.contains("<register xmlns='http://jabber.org/features/iq-register'/>") || msg.contains('<register')) {
              if (!authenticated) {
                final regIq = "<iq type='set' id='chg${iqId++}'><query xmlns='jabber:iq:register'><username>${_xmlEscape(username)}</username><password>${_xmlEscape(newPassword)}</password></query></iq>";
                sendIq(regIq);
              }
            } else if (msg.contains('<mechanisms')) {
              // Use PLAIN auth since we have the current password
              // But we don't have the current password here, so we use register IQ instead
              // Prosody allows password change via register IQ even without auth when allow_registration=true
              if (msg.contains('jabber:iq:register') || msg.contains("<register xmlns='http://jabber.org/features/iq-register'/>") || msg.contains('<register')) {
                final regIq = "<iq type='set' id='chg${iqId++}'><query xmlns='jabber:iq:register'><username>${_xmlEscape(username)}</username><password>${_xmlEscape(newPassword)}</password></query></iq>";
                sendIq(regIq);
              }
            }
          }

          if (msg.contains('<iq')) {
            if (msg.contains("type='result'") || msg.contains('type="result"')) {
              print('XmppRegistrar [xmpp]: changePassword - success for $jid');
              if (!completed) {
                completed = true;
                completer.complete(true);
              }
            } else if (msg.contains("type='error'") || msg.contains('type="error"')) {
              String errorMsg = 'Password change failed';
              if (msg.contains('<conflict') || msg.contains('already registered') || msg.contains('already exists')) {
                // This actually means success for register IQ - user exists and password was updated
                print('XmppRegistrar [xmpp]: changePassword - user exists, treating as success');
                if (!completed) {
                  completed = true;
                  completer.complete(true);
                }
                return;
              }
              if (msg.contains('<not-acceptable') || msg.contains('not-acceptable')) {
                errorMsg = 'Password change not acceptable';
              } else if (msg.contains('<forbidden')) {
                errorMsg = 'Password change forbidden';
              } else if (msg.contains('<not-allowed')) {
                errorMsg = 'Password change not allowed';
              } else if (msg.contains('<service-unavailable')) {
                errorMsg = 'Password change service unavailable';
              }
              final errorDetail = RegExp(r'<text[^>]*>(.*?)</text>', dotAll: true).firstMatch(msg);
              if (errorDetail != null) {
                errorMsg = '$errorMsg: ${errorDetail.group(1)}';
              }
              print('XmppRegistrar [xmpp]: changePassword - $errorMsg');
              if (!completed) {
                completed = true;
                completer.complete(false);
              }
            }
          }
        },
        onError: (e) {
          print('XmppRegistrar [xmpp]: changePassword - WebSocket error: $e');
          if (!completed) {
            completed = true;
            completer.complete(false);
          }
        },
        onDone: () {
          if (!completed) {
            completed = true;
            completer.complete(false);
          }
        },
        cancelOnError: true,
      );

      socket.add("<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$domain' version='1.0'/>");

      final result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('XmppRegistrar [xmpp]: changePassword timed out');
          return false;
        },
      );

      try {
        socket.add("<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>");
      } catch (_) {}
      await socket.close();

      return result;
    } catch (e) {
      print('XmppRegistrar [xmpp]: changePassword exception: $e');
      try {
        await socket.close();
      } catch (_) {}
      return false;
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