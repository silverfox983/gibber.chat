import 'package:xmpp_stone/src/data/Jid.dart';

abstract class AbstractSaslHandler {
  Future<AuthenticationResult> start();
}

class AuthenticationResult {
  bool successful;
  String message;
  Jid? bindJid;

  AuthenticationResult(this.successful, this.message, {this.bindJid});
}
