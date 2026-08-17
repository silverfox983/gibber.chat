import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/registration_models.dart';

class RegistrationService {
  final xmpp.Connection? _connection;
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  late StreamSubscription<xmpp.AbstractStanza?> _subscription;

  xmpp.Connection? get connection => _connection;

  RegistrationService([this._connection]) {
    if (_connection != null) {
      _subscription = _connection.inStanzasStream.listen(_handleStanza);
    }
  }

  void dispose() {
    if (_connection != null) {
      _subscription.cancel();
    }
    for (final completer in _pendingIqs.values) {
      if (!completer.isCompleted) completer.completeError('Service disposed');
    }
    _pendingIqs.clear();
  }

  void _handleStanza(xmpp.AbstractStanza? stanza) {
    if (stanza is xmpp.IqStanza) {
      final id = stanza.id;
      if (id != null && _pendingIqs.containsKey(id)) {
        _pendingIqs[id]!.complete(stanza);
        _pendingIqs.remove(id);
      }
    }
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza iq) {
    if (_connection == null) {
      throw Exception('Not connected');
    }

    final id = iq.id ?? 'reg_${xmpp.AbstractStanza.getRandomId()}';
    iq.id = id;
    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    _connection.writeStanza(iq);

    Future.delayed(const Duration(seconds: 15), () {
      if (_pendingIqs.containsKey(id)) {
        _pendingIqs[id]!.completeError(
          TimeoutException('IQ request timed out'),
        );
        _pendingIqs.remove(id);
      }
    });

    return completer.future;
  }

  Future<InviteResult?> generateUserInvitation(String domain) async {
    final iq = xmpp.IqStanza(
      'invite_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final command = xmpp.XmppElement();
    command.name = 'command';
    command.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/commands'),
    );
    command.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:invite#invite'));
    command.addAttribute(xmpp.XmppAttribute('action', 'execute'));
    iq.addChild(command);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return null;

      var cmdRes = response.getChild('command');
      if (cmdRes == null) return null;

      final status = cmdRes.getAttribute('status')?.value;
      final sessionId = cmdRes.getAttribute('sessionid')?.value;

      // XEP-0050 Multi-stage command handling
      if (status == 'executing' && sessionId != null) {
        // Submit the default form to complete generation
        final iq2 = xmpp.IqStanza(
          'invite_submit_${xmpp.AbstractStanza.getRandomId()}',
          xmpp.IqStanzaType.SET,
        );
        iq2.toJid = xmpp.Jid.fromFullJid(domain);

        final cmd2 = xmpp.XmppElement();
        cmd2.name = 'command';
        cmd2.addAttribute(
          xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/commands'),
        );
        cmd2.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:invite#invite'));
        cmd2.addAttribute(xmpp.XmppAttribute('sessionid', sessionId));
        cmd2.addAttribute(xmpp.XmppAttribute('action', 'complete'));

        final xSubmit = xmpp.XmppElement();
        xSubmit.name = 'x';
        xSubmit.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
        xSubmit.addAttribute(xmpp.XmppAttribute('type', 'submit'));

        // Basic hidden form type field required by XEP-0004
        final fieldType = xmpp.XmppElement();
        fieldType.name = 'field';
        fieldType.addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'));
        fieldType.addAttribute(xmpp.XmppAttribute('type', 'hidden'));
        final valType = xmpp.XmppElement();
        valType.name = 'value';
        valType.textValue = 'urn:xmpp:invite#invite';
        fieldType.addChild(valType);

        xSubmit.addChild(fieldType);
        cmd2.addChild(xSubmit);
        iq2.addChild(cmd2);

        final response2 = await _sendIq(iq2);
        if (response2.type == xmpp.IqStanzaType.ERROR) return null;

        cmdRes = response2.getChild('command');
        if (cmdRes == null ||
            cmdRes.getAttribute('status')?.value != 'completed') {
          return null;
        }
      } else if (status != 'completed') {
        return null;
      }

      final xData = cmdRes.getChild('x');
      if (xData == null) return null;

      String? uri;
      String? landingUrl;
      DateTime? expire;

      for (var field in xData.children.where((e) => e.name == 'field')) {
        final varAttr = field.getAttribute('var')?.value;
        final valNode = field.getChild('value');
        final value = valNode?.textValue;

        if (varAttr == 'uri') uri = value;
        if (varAttr == 'landing-url') landingUrl = value;
        if (varAttr == 'expire' && value != null) {
          expire = DateTime.tryParse(value);
        }
      }

      if (uri != null) {
        return InviteResult(uri: uri, landingUrl: landingUrl, expire: expire);
      }
      return null;
    } catch (e) {
      debugPrint('Error generating invitation: $e');
      return null;
    }
  }

  static Future<bool> registerAccountInBand(
    String domain,
    String username,
    String password, [
    String? token,
  ]) async {
    if (kIsWeb) {
      throw UnsupportedError('In-band registration requires TCP sockets, not available on web');
    }
    Socket? socket;
    try {
      // Connect to standard XMPP client port
      socket = await Socket.connect(
        domain,
        5222,
        timeout: const Duration(seconds: 10),
      );

      final completer = Completer<bool>();
      bool isSecure = false;
      bool tlsRequested = false;
      bool streamRestarted = false;

      String buffer = '';

      void sendXml(String xml) {
        socket?.write(xml);
      }

      void handleData(String data) async {
        buffer += data;

        // 1. Check for STARTTLS feature
        if (!isSecure &&
            !tlsRequested &&
            buffer.contains(
              '<starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls"',
            )) {
          tlsRequested = true;
          buffer = '';
          sendXml('<starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls"/>');
        }
        // 2. Check for PROCEED to upgrade to TLS
        else if (tlsRequested &&
            !isSecure &&
            buffer.contains(
              '<proceed xmlns="urn:ietf:params:xml:ns:xmpp-tls"',
            )) {
          isSecure = true;
          buffer = '';
          socket = await SecureSocket.secure(
            socket!,
            onBadCertificate: (_) => true,
          );
          socket!.listen((data) => handleData(utf8.decode(data)));

          // Restart stream
          sendXml(
            '<stream:stream to="$domain" xmlns="jabber:client" xmlns:stream="http://etherx.jabber.org/streams" version="1.0">',
          );
          streamRestarted = true;
        }
        // 3. Check for register feature after TLS upgrade
        else if (isSecure &&
            streamRestarted &&
            buffer.contains(
              '<register xmlns="http://jabber.org/features/iq-register"',
            )) {
          streamRestarted = false;
          buffer = '';

          final preauthBlock = (token != null && token.isNotEmpty)
              ? '<preauth xmlns="urn:xmpp:ibr-token:0">$token</preauth>'
              : '';

          final regIq =
              '''
          <iq type="set" id="reg1">
            <query xmlns="jabber:iq:register">
              <username>$username</username>
              <password>$password</password>
              $preauthBlock
            </query>
          </iq>
          ''';
          sendXml(regIq);
        }
        // 4. Check registration result
        else if (isSecure && buffer.contains('id="reg1"')) {
          if (buffer.contains('type="result"')) {
            if (!completer.isCompleted) completer.complete(true);
          } else if (buffer.contains('type="error"')) {
            if (!completer.isCompleted) completer.complete(false);
          }
        }
      }

      socket?.listen(
        (data) => handleData(utf8.decode(data)),
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      // Start handshake
      sendXml(
        '<?xml version="1.0"?><stream:stream to="$domain" xmlns="jabber:client" xmlns:stream="http://etherx.jabber.org/streams" version="1.0">',
      );

      final result = await completer.future.timeout(
        const Duration(seconds: 15),
      );
      socket?.destroy();
      return result;
    } catch (e) {
      debugPrint('In-band registration error: $e');
      socket?.destroy();
      return false;
    }
  }

  static Future<RegistrationResult> registerViaBackend({
    required String apiUrl,
    required String username,
    required String password,
    String? host,
    String? captchaToken,
  }) async {
    if (username.trim().length < 3) {
      return const RegistrationResult(
        status: RegistrationStatus.validationError,
        message: 'Username must be at least 3 characters.',
      );
    }
    if (password.length < 8) {
      return const RegistrationResult(
        status: RegistrationStatus.validationError,
        message: 'Password must be at least 8 characters.',
      );
    }
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(username)) {
      return const RegistrationResult(
        status: RegistrationStatus.validationError,
        message: 'Username can only contain letters, numbers, dots, hyphens, and underscores.',
      );
    }

    try {
      final uri = Uri.parse('$apiUrl/register');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          'password': password,
          if (host != null) 'host': host,
          if (captchaToken != null) 'captchaToken': captchaToken,
        }),
      );

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final accessToken = body['accessToken'] as String?;
        final refreshToken = body['refreshToken'] as String?;

        if (accessToken != null && refreshToken != null) {
          return RegistrationResult(
            status: RegistrationStatus.success,
            jid: body['jid'] as String?,
            accessToken: accessToken,
            refreshToken: refreshToken,
            message: body['message'] as String? ?? 'Registration successful',
          );
        }

        try {
          final loginResult = await loginWithJwt(
            apiUrl: apiUrl,
            username: username.trim(),
            password: password,
            host: host,
          );
          return RegistrationResult(
            status: RegistrationStatus.success,
            jid: body['jid'] as String?,
            accessToken: loginResult.accessToken,
            refreshToken: loginResult.refreshToken,
            message: body['message'] as String? ?? 'Registration successful',
          );
        } catch (_) {
          return RegistrationResult(
            status: RegistrationStatus.success,
            jid: body['jid'] as String?,
            message: body['message'] as String? ?? 'Registration successful (JWT unavailable)',
          );
        }
      } else if (response.statusCode == 403 && (body['error'] ?? '').toString().contains('Captcha')) {
        return RegistrationResult(
          status: RegistrationStatus.captchaFailed,
          message: body['error'] as String? ?? 'Captcha verification failed. Please try again.',
        );
      } else if (response.statusCode == 429) {
        return RegistrationResult(
          status: RegistrationStatus.validationError,
          message: body['error'] as String? ?? 'Too many attempts. Please try again later.',
        );
      } else if (response.statusCode == 409 || (body['error'] ?? '').toString().contains('already exists')) {
        return RegistrationResult(
          status: RegistrationStatus.userExists,
          jid: body['jid'] as String?,
          message: 'Username already taken.',
        );
      } else {
        return RegistrationResult(
          status: RegistrationStatus.networkError,
          message: body['error'] as String? ?? 'Registration failed (${response.statusCode}).',
        );
      }
    } on SocketException {
      return const RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Could not reach the server. Check your network connection.',
      );
    } on FormatException {
      return const RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Invalid server response.',
      );
    } catch (e) {
      return RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Error: $e',
      );
    }
  }

  static Future<bool> checkUsernameAvailable({
    required String apiUrl,
    required String username,
    String? host,
  }) async {
    try {
      final uri = Uri.parse('$apiUrl/register/check');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          if (host != null) 'host': host,
        }),
      );
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return body['available'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<RegistrationResult> loginWithJwt({
    required String apiUrl,
    required String username,
    required String password,
    String? host,
  }) async {
    try {
      final uri = Uri.parse('$apiUrl/auth/token');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          'password': password,
          if (host != null) 'host': host,
        }),
      );

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        return RegistrationResult(
          status: RegistrationStatus.success,
          jid: body['jid'] as String?,
          accessToken: body['accessToken'] as String?,
          refreshToken: body['refreshToken'] as String?,
          message: 'Login successful',
        );
      } else if (response.statusCode == 401) {
        return const RegistrationResult(
          status: RegistrationStatus.validationError,
          message: 'Invalid username or password.',
        );
      } else if (response.statusCode == 429) {
        return const RegistrationResult(
          status: RegistrationStatus.validationError,
          message: 'Too many attempts. Please try again later.',
        );
      } else if (response.statusCode == 503) {
        return const RegistrationResult(
          status: RegistrationStatus.unsupported,
          message: 'JWT authentication is not configured on this server.',
        );
      } else {
        return RegistrationResult(
          status: RegistrationStatus.networkError,
          message: body['error'] as String? ?? 'Login failed (${response.statusCode}).',
        );
      }
    } on SocketException {
      return const RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Could not reach the server. Check your network connection.',
      );
    } on FormatException {
      return const RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Invalid server response.',
      );
    } catch (e) {
      return RegistrationResult(
        status: RegistrationStatus.networkError,
        message: 'Error: $e',
      );
    }
  }

  static Future<String?> refreshJwtToken({
    required String apiUrl,
    required String refreshToken,
  }) async {
    try {
      final uri = Uri.parse('$apiUrl/auth/refresh');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}),
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return body['accessToken'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
