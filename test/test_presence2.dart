import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

void main() {
  final presence = xmpp.PresenceStanza();
  presence.addAttribute(xmpp.XmppAttribute('to', 'digdeeper@conference.jabb3r.org/silverfox'));
  
  final mucX = xmpp.XmppElement();
  mucX.name = 'x';
  mucX.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));
  presence.addChild(mucX);

  print(presence.buildXmlString());
}
