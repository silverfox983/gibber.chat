import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'dart:async';
import 'dart:io';

void main() async {
  final options = xmpp.XmppAccountSettings(
    'testuser123@movim.eu',
    'testuser123',
    'movim.eu',
    'testuser123',
    5222,
  );
  // Wait, I cannot authenticate to spaces.movim.eu if I don't have an account.
}
