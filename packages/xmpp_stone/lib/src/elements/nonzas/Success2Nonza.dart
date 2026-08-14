import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

class Success2Nonza extends Nonza {
  static const String NAME = 'success';
  static const String XMLNS = 'urn:xmpp:sasl:2';

  static bool match(Nonza nonza) =>
      nonza.name == NAME &&
      nonza.getAttribute('xmlns')?.value == XMLNS;

  Success2Nonza() {
    name = NAME;
    addAttribute(XmppAttribute('xmlns', XMLNS));
  }

  String? get additionalData => getChild('additional-data')?.textValue;
  String? get authorizationIdentifier => getChild('authorization-identifier')?.textValue;

  List<XmppElement> get inlineElements {
    var inline = getChild('inline');
    if (inline == null) return [];
    return inline.children;
  }
}