import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

class Challenge2Nonza extends Nonza {
  static const String NAME = 'challenge';
  static const String XMLNS = 'urn:xmpp:sasl:2';

  static bool match(Nonza nonza) =>
      nonza.name == NAME &&
      nonza.getAttribute('xmlns')?.value == XMLNS;

  Challenge2Nonza() {
    name = NAME;
    addAttribute(XmppAttribute('xmlns', XMLNS));
  }
}