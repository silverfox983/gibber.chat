import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

class ContinueNonza extends Nonza {
  static const String NAME = 'continue';
  static const String XMLNS = 'urn:xmpp:sasl:2';

  static bool match(Nonza nonza) =>
      nonza.name == NAME &&
      nonza.getAttribute('xmlns')?.value == XMLNS;

  ContinueNonza() {
    name = NAME;
    addAttribute(XmppAttribute('xmlns', XMLNS));
  }

  String? get text => getChild('text')?.textValue;
  List<XmppElement> get tasks => children.where((e) => e.name == 'task').toList();
}