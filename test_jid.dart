import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  final jid = Jid.fromFullJid('spaces.movim.eu');
  print('local: ${jid.local}');
  print('domain: ${jid.domain}');
  print('resource: ${jid.resource}');
  print('full: ${jid.fullJid}');
}
