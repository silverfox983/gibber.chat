import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslAuthenticationFeature.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2ScramHandler.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2PlainHandler.dart';

class Sasl2AuthenticationFeature extends Negotiator {
  final Connection _connection;
  final String _password;

  final Set<SaslMechanism> _offeredMechanisms = {};
  final Set<SaslMechanism> _supportedMechanisms = {};
  List<XmppElement> _inlineFeatures = [];

  bool get hasInlineBind => _inlineFeatures.any(
      (e) => e.name == 'bind' && e.getAttribute('xmlns')?.value == 'urn:xmpp:bind2:0');
  bool get hasInlineSM => _inlineFeatures.any(
      (e) => e.name == 'sm' && e.getAttribute('xmlns')?.value == 'urn:xmpp:sm:3');

  Sasl2AuthenticationFeature(this._connection, this._password) {
    _supportedMechanisms.add(SaslMechanism.SCRAM_SHA_256);
    _supportedMechanisms.add(SaslMechanism.SCRAM_SHA_1);
    _supportedMechanisms.add(SaslMechanism.PLAIN);
    expectedName = 'Sasl2AuthenticationFeature';
    priorityLevel = 50;
  }

  @override
  List<Nonza> match(List<Nonza> requests) {
    var nonza = requests.firstWhereOrNull((element) =>
        element.name == 'authentication' &&
        element.getAttribute('xmlns')?.value == 'urn:xmpp:sasl:2');
    return nonza != null ? [nonza] : [];
  }

  @override
  void negotiate(List<Nonza> nonzas) {
    if (nonzas.isEmpty) {
      state = NegotiatorState.DONE;
      return;
    }
    _populateOfferedMechanisms(nonzas[0]);
    _extractInlineFeatures(nonzas[0]);

    var mechanism = _supportedMechanisms.firstWhere(
        (mch) => _offeredMechanisms.contains(mch),
        orElse: _handleAuthNotSupported);

    if (mechanism == SaslMechanism.NOT_SUPPORTED) return;

    AbstractSaslHandler? saslHandler;
    switch (mechanism) {
      case SaslMechanism.PLAIN:
        saslHandler = Sasl2PlainHandler(
            _connection, _password, hasInlineBind, hasInlineSM);
        break;
      case SaslMechanism.SCRAM_SHA_256:
      case SaslMechanism.SCRAM_SHA_1:
        saslHandler = Sasl2ScramHandler(
            _connection, _password, mechanism, hasInlineBind, hasInlineSM);
        break;
      default:
        break;
    }

    if (saslHandler != null) {
      state = NegotiatorState.NEGOTIATING;
      saslHandler.start().then((result) {
        if (result.successful) {
          _connection.setState(XmppConnectionState.Authenticated);
          if (result.bindJid != null) {
            _connection.fullJidRetrieved(result.bindJid!);
          }
        } else {
          _connection.setState(XmppConnectionState.AuthenticationFailure);
          _connection.errorMessage = result.message;
          _connection.close();
        }
        state = NegotiatorState.DONE_CLEAN_OTHERS;
      });
    }
  }

  void _populateOfferedMechanisms(Nonza nonza) {
    nonza.children
        .where((element) => element.name == 'mechanism')
        .forEach((mechanism) {
      switch (mechanism.textValue) {
        case 'SCRAM-SHA-256':
          _offeredMechanisms.add(SaslMechanism.SCRAM_SHA_256);
          break;
        case 'SCRAM-SHA-1':
          _offeredMechanisms.add(SaslMechanism.SCRAM_SHA_1);
          break;
        case 'PLAIN':
          _offeredMechanisms.add(SaslMechanism.PLAIN);
          break;
      }
    });
  }

  void _extractInlineFeatures(Nonza nonza) {
    var inlineEl = nonza.children.firstWhereOrNull(
        (element) => element.name == 'inline');
    if (inlineEl != null) {
      _inlineFeatures = inlineEl.children
          .whereType<XmppElement>()
          .where((e) => e.name != null && e.getAttribute('xmlns') != null)
          .toList();
    }
  }

  SaslMechanism _handleAuthNotSupported() {
    _connection.setState(XmppConnectionState.AuthenticationNotSupported);
    _connection.close();
    state = NegotiatorState.DONE;
    return SaslMechanism.NOT_SUPPORTED;
  }
}