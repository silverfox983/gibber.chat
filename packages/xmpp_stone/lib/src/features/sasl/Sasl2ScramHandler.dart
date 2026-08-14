import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptoutils/utils.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslAuthenticationFeature.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../logger/Log.dart';

class Sasl2ScramHandler implements AbstractSaslHandler {
  static const CLIENT_NONCE_LENGTH = 48;
  static const String TAG = 'Sasl2ScramHandler';

  final Connection _connection;
  late StreamSubscription<Nonza> subscription;
  final _completer = Completer<AuthenticationResult>();
  ScramStates _scramState = ScramStates.INITIAL;
  String? _password;
  String? _username;
  late String _clientNonce;
  String? _initialMessage;

  final SaslMechanism _mechanism;
  late Hash _hash;
  String? _mechanismString;

  late var serverSignature;

  final bool _inlineBind;
  final bool _inlineSM;

  Sasl2ScramHandler(this._connection, String? password, this._mechanism,
      this._inlineBind, this._inlineSM) {
    _username = _connection.fullJid.local;
    _password = password;
    _inlineBind;
    _inlineSM;
    initMechanism();
    generateRandomClientNonce();
  }

  void initMechanism() {
    if (_mechanism == SaslMechanism.SCRAM_SHA_1) {
      _hash = sha1;
      _mechanismString = 'SCRAM-SHA-1';
    } else if (_mechanism == SaslMechanism.SCRAM_SHA_256) {
      _hash = sha256;
      _mechanismString = 'SCRAM-SHA-256';
    }
  }

  void generateRandomClientNonce() {
    var bytes = List<int>.generate(
        CLIENT_NONCE_LENGTH, (index) => Random.secure().nextInt(256));
    _clientNonce = base64.encode(bytes);
  }

  @override
  Future<AuthenticationResult> start() {
    subscription = _connection.inNonzasStream.listen(_parseAnswer);
    _sendInitialMessage();
    return _completer.future;
  }

  void _sendInitialMessage() {
    _initialMessage = 'n=${_saslEscape(_normalize(_username!))},r=$_clientNonce';
    var gs2Header = 'n,,';
    var bytes = utf8.encode('$gs2Header$_initialMessage');
    var message = CryptoUtils.bytesToBase64(bytes, false, false);

    var authElement = Nonza();
    authElement.name = 'authenticate';
    authElement.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sasl:2'));
    authElement.addAttribute(XmppAttribute('mechanism', _mechanismString));

    var initialResponseEl = XmppElement();
    initialResponseEl.name = 'initial-response';
    initialResponseEl.textValue = message;
    authElement.addChild(initialResponseEl);

    var userAgent = XmppElement();
    userAgent.name = 'user-agent';
    userAgent.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sasl:2'));
    var software = XmppElement();
    software.name = 'software';
    software.textValue = 'Gibber';
    userAgent.addChild(software);
    authElement.addChild(userAgent);

    if (_inlineBind || _inlineSM) {
      var inlineEl = XmppElement();
      inlineEl.name = 'inline';
      if (_inlineBind) {
        var bindEl = XmppElement();
        bindEl.name = 'bind';
        bindEl.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind2:0'));
        var resource = _connection.account.resource;
        if (resource != null && resource.isNotEmpty) {
          var tagEl = XmppElement();
          tagEl.name = 'tag';
          tagEl.textValue = resource;
          bindEl.addChild(tagEl);
        }
        inlineEl.addChild(bindEl);
      }
      if (_inlineSM) {
        var smEl = XmppElement();
        smEl.name = 'sm';
        smEl.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sm:3'));
        if (_connection.account.smResumable) {
          // Resume is handled by StreamManagementModule after auth
        }
        inlineEl.addChild(smEl);
      }
      authElement.addChild(inlineEl);
    }

    _scramState = ScramStates.AUTH_SENT;
    _connection.writeNonza(authElement);
  }

  void _parseAnswer(Nonza nonza) {
    if (_scramState == ScramStates.AUTH_SENT) {
      if (nonza.name == 'failure') {
        _fireAuthFailed('SASL2 Auth Error');
      } else if (nonza.name == 'challenge') {
        var ns = nonza.getAttribute('xmlns')?.value;
        if (ns == 'urn:xmpp:sasl:2') {
          _handleChallenge(nonza.textValue!);
        } else {
          _handleChallenge(nonza.textValue!);
        }
      }
    } else if (_scramState == ScramStates.RESPONSE_SENT) {
      if (nonza.name == 'failure') {
        _fireAuthFailed('SASL2 Auth Error in challenge');
      } else if (nonza.name == 'success') {
        var ns = nonza.getAttribute('xmlns')?.value;
        if (ns == 'urn:xmpp:sasl:2') {
          _verifyAndCompleteSasl2(nonza);
        } else {
          _verifyServerHasKey(nonza.textValue ?? '');
        }
      }
    }
  }

  void _handleChallenge(String content) {
    var serverFirstMessage = base64.decode(content);
    var tokens = _tokenizeGS2header(serverFirstMessage);

    var serverNonce = '';
    var iterationsNo = -1;
    var salt = '';
    tokens.forEach((token) {
      if (token[1] == '=') {
        switch (token[0]) {
          case 'i':
            try {
              iterationsNo = int.parse(token.substring(2));
            } catch (e) {
              _fireAuthFailed('Unable to parse iteration number');
              return;
            }
            break;
          case 's':
            salt = token.substring(2);
            break;
          case 'r':
            serverNonce = token.substring(2);
            break;
          case 'm':
            _fireAuthFailed('Server sent m token!');
            break;
        }
      }
    });

    if (iterationsNo < 0) {
      _fireAuthFailed('No iterations number received');
      return;
    }
    if (serverNonce.isEmpty || !serverNonce.startsWith(_clientNonce)) {
      _fireAuthFailed('Server nonce not same as client nonce');
      return;
    }
    if (salt.isEmpty) {
      _fireAuthFailed('Salt not sent');
      return;
    }

    var clientFinalMessageBare = 'c=biws,r=$serverNonce';
    var authMessage = utf8.encode(
        '$_initialMessage,${utf8.decode(serverFirstMessage)},$clientFinalMessageBare');
    var saltB = base64.decode(salt);
    var saltedPassword = _PBKDF2(utf8.encode(_password!), saltB, iterationsNo);
    serverSignature = _hmac(saltedPassword, utf8.encode('Server Key'));
    var clientKey = _hmac(saltedPassword, utf8.encode('Client Key'));
    late List<int> clientSignature;
    try {
      var storedKey = _hash.convert(clientKey).bytes;
      clientSignature = _hmac(storedKey, authMessage);
    } catch (e) {
      _fireAuthFailed('Invalid key');
      return;
    }

    var clientProof = List<int>.generate(
        clientKey.length, (i) => clientKey[i] ^ clientSignature[i]);
    var clientFinalMessage =
        '$clientFinalMessageBare,p=${base64.encode(clientProof)}';

    var response = Nonza();
    response.name = 'response';
    response.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sasl:2'));
    response.textValue = base64.encode(utf8.encode(clientFinalMessage));
    _scramState = ScramStates.RESPONSE_SENT;
    _connection.writeNonza(response);
  }

  void _verifyAndCompleteSasl2(Nonza successNonza) {
    var additionalData = successNonza.getChild('additional-data')?.textValue;
    if (additionalData != null) {
      var decoded = utf8.decode(base64.decode(additionalData));
      var expectedServerFinalMessage = 'v=${base64.encode(serverSignature)}';
      if (decoded != expectedServerFinalMessage) {
        _fireAuthFailed('SASL2 server final message does not match expected one');
        return;
      }
    }

    Jid? bindJid;
    var authIdentifier = successNonza.getChild('authorization-identifier');
    if (authIdentifier != null && authIdentifier.textValue != null) {
      bindJid = Jid.fromFullJid(authIdentifier.textValue!);
    }

    subscription.cancel();
    _completer.complete(AuthenticationResult(true, '', bindJid: bindJid));
  }

  void _verifyServerHasKey(String serverResponse) {
    var expectedServerFinalMessage = 'v=${base64.encode(serverSignature)}';
    if (utf8.decode(base64.decode(serverResponse)) != expectedServerFinalMessage) {
      _fireAuthFailed('Server final message does not match expected one');
    } else {
      subscription.cancel();
      _completer.complete(AuthenticationResult(true, ''));
    }
  }

  void _fireAuthFailed(String message) {
    Log.e(TAG, message);
    subscription.cancel();
    _completer.complete(AuthenticationResult(false, message));
  }

  static String _saslEscape(String input) {
    return input.replaceAll('=', '=2C').replaceAll(',', '=3D');
  }

  static String _normalize(String input) {
    return unorm.nfkd(input);
  }

  static List<String> _tokenizeGS2header(var list) {
    return utf8.decode(list).split(',').map((i) => i.trim()).toList();
  }

  List<int> _hmac(List<int> key, List<int> input) {
    var hmac = crypto.Hmac(_hash, key);
    return hmac.convert(input).bytes;
  }

  List<int> _PBKDF2(List<int> password, List<int> salt, int c) {
    var u = _hmac(password, salt + [0, 0, 0, 1]);
    var out = List<int>.from(u);
    for (var i = 1; i < c; i++) {
      u = _hmac(password, u);
      for (var j = 0; j < u.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }
}

enum ScramStates {
  INITIAL,
  AUTH_SENT,
  RESPONSE_SENT,
}