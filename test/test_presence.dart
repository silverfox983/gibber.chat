import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

void main() {
  final roomJidObj = xmpp.Jid.fromFullJid('digdeeper@conference.jabb3r.org/silverfox');
  final presence = xmpp.PresenceStanza();
  presence.toJid = roomJidObj;
  
  final mucX = xmpp.XmppElement();
  mucX.name = 'x';
  mucX.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));
  presence.addChild(mucX);

  print(presence.buildXmlString());
}
