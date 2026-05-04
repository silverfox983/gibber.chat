import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

void main() {
  final jid = xmpp.Jid.fromFullJid('digdeeper@conference.jabb3r.org/digdeeper');
  print('local: ${jid.local}');
  print('domain: ${jid.domain}');
  print('resource: ${jid.resource}');
  print('fullJid: ${jid.fullJid}');
}
