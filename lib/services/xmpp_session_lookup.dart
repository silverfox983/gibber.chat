import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

/// A resolved XMPP session: the live connection for an account plus its JID.
class XmppSession {
  final String accountId;
  final xmpp.Connection connection;
  final String fullJid;

  XmppSession({required this.accountId, required this.connection, required this.fullJid});

  String get bareJid => fullJid.split('/').first;
  String get domain => fullJid.split('@').last.split('/').first;
  String get localPart => fullJid.split('@').first.split('/').first;
  String get resource => fullJid.contains('/') ? fullJid.split('/').last : '';
}

/// Read-only view over the account sessions owned by the connection manager.
///
/// Lets sub-services resolve an account's connection/JID without sharing the
/// underlying mutable maps.
abstract interface class XmppSessionLookup {
  xmpp.Connection? connectionFor(String? accountId);
  String? fullJidFor(String? accountId);
  String? get activeAccountId;
}