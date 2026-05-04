import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

void main() {
  final msg = xmpp.MessageStanza('123', xmpp.MessageStanzaType.CHAT);
  print('Body when empty: ${msg.body}');
}
