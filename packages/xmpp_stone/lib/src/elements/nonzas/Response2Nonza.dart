import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

class Response2Nonza extends Nonza {
  static const String NAME = 'response';
  static const String XMLNS = 'urn:xmpp:sasl:2';

  static bool match(Nonza nonza) =>
      nonza.name == NAME &&
      nonza.getAttribute('xmlns')?.value == XMLNS;

  Response2Nonza({String? textValue}) {
    name = NAME;
    addAttribute(XmppAttribute('xmlns', XMLNS));
    if (textValue != null) {
      this.textValue = textValue;
    }
  }
}