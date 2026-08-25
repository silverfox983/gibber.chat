import 'dart:async';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class OmemoService {
  static const String nsOmemo = 'urn:xmpp:omemo:0';
  static const String nsOmemoLegacy = 'eu.siacs.conversations.axolotl';
  static const String nsPubsub = 'http://jabber.org/protocol/pubsub';

  int? _deviceId;
  xmpp.Connection? _conn;

  int get localDeviceId => _deviceId ?? 0;

  Future<void> initialize(String bareJid) async {}
  void setConnection(xmpp.Connection conn) { _conn = conn; }
  Future<void> generateAndPublishBundle() async {}
  Future<void> publishDeviceList(xmpp.Connection conn, String bareJid, {bool clearOtherDevices = false}) async {}
  Future<void> ensureNodeAccessModels(xmpp.Connection conn) async {}
  Future<void> publishBundle(xmpp.Connection conn) async {}
  Future<void> checkAndReplenishPreKeys() async {}

  Future<String> getLocalFingerprint() async => '';
  Future<Map<int, Map<String, dynamic>>> getFingerprintsDetailed(String chatId) async => <int, Map<String, dynamic>>{};
  Future<void> setDeviceTrust(String jid, int deviceId, int trustLevel) async {}
  Future<List<int>> fetchDeviceList(String bareJid) async => [];
  Future<void> buildSession(String bareJid, int deviceId) async {}
  Future<String?> decryptMessage(xmpp.XmppElement encrypted, {String? fromBareJid, bool isHistorical = false}) async => null;
  Future<List<xmpp.XmppElement>?> encryptMessage(String toJid, String plaintext, {bool strict = false}) async => null;
  Future<List<xmpp.XmppElement>?> encryptMessageForMuc(String roomJid, String plaintext, List<String> participantJids, {bool strict = false}) async => null;
  Future<void> resetIdentity(String bareJid) async {}
  Future<void> clearDatabase() async {}
  Future<void> handleDeviceListUpdate(String fromJid, String rawUpdate) async {}
  Future<void> handleBundleRequest(String jid, int deviceId) async {}
}