import 'dart:async';
import 'dart:convert';

import 'package:cryptoutils/utils.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';

class Sasl2PlainHandler implements AbstractSaslHandler {
  final Connection _connection;
  late StreamSubscription<Nonza> subscription;
  final _completer = Completer<AuthenticationResult>();

  String? _password;
  final bool _inlineBind;
  final bool _inlineSM;

  Sasl2PlainHandler(this._connection, String? password, this._inlineBind, this._inlineSM) {
    _password = password;
  }

  @override
  Future<AuthenticationResult> start() {
    subscription = _connection.inNonzasStream.listen(_parseAnswer);
    _sendPlainAuthMessage();
    return _completer.future;
  }

  void _parseAnswer(Nonza nonza) {
    if (nonza.name == 'failure') {
      subscription.cancel();
      _completer.complete(
          AuthenticationResult(false, 'Invalid username or password'));
    } else if (nonza.name == 'success') {
      var ns = nonza.getAttribute('xmlns')?.value;
      if (ns == 'urn:xmpp:sasl:2') {
        Jid? bindJid;
        var authIdentifier = nonza.getChild('authorization-identifier');
        if (authIdentifier != null && authIdentifier.textValue != null) {
          bindJid = Jid.fromFullJid(authIdentifier.textValue!);
        }
        subscription.cancel();
        _completer.complete(AuthenticationResult(true, '', bindJid: bindJid));
      } else {
        subscription.cancel();
        _completer.complete(AuthenticationResult(true, ''));
      }
    }
  }

  void _sendPlainAuthMessage() {
    var authString =
        '\u0000' + _connection.fullJid.local + '\u0000' + _password!;
    var bytes = utf8.encode(authString);
    var base64Str = CryptoUtils.bytesToBase64(bytes);

    var authElement = Nonza();
    authElement.name = 'authenticate';
    authElement.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sasl:2'));
    authElement.addAttribute(XmppAttribute('mechanism', 'PLAIN'));

    var initialResponseEl = XmppElement();
    initialResponseEl.name = 'initial-response';
    initialResponseEl.textValue = base64Str;
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
        inlineEl.addChild(smEl);
      }
      authElement.addChild(inlineEl);
    }

    _connection.writeNonza(authElement);
  }
}