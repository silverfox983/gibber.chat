import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class CsiStanza extends xmpp.AbstractStanza {
  CsiStanza(String name) {
    this.name = name;
  }
}
