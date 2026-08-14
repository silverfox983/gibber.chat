import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

class AuthenticateNonza extends Nonza {
  static const String NAME = 'authenticate';
  static const String XMLNS = 'urn:xmpp:sasl:2';

  static bool match(Nonza nonza) =>
      nonza.name == NAME &&
      nonza.getAttribute('xmlns')?.value == XMLNS;

  AuthenticateNonza(String mechanism, {String? initialResponse, List<XmppElement>? inlineElements}) {
    name = NAME;
    addAttribute(XmppAttribute('xmlns', XMLNS));
    addAttribute(XmppAttribute('mechanism', mechanism));
    if (initialResponse != null) {
      var initialResponseEl = XmppElement();
      initialResponseEl.name = 'initial-response';
      initialResponseEl.textValue = initialResponse;
      addChild(initialResponseEl);
    }
    if (inlineElements != null) {
      var inlineEl = XmppElement();
      inlineEl.name = 'inline';
      for (var el in inlineElements) {
        inlineEl.addChild(el);
      }
      addChild(inlineEl);
    }
  }
}