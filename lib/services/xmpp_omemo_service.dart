import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import './omemo_service_stub.dart' if (dart.library.io) './omemo_service.dart';
import './omemo_storage_stub.dart' if (dart.library.io) './omemo_storage.dart';

class XmppOmemoService with ChangeNotifier {
  static const String nsOmemo = OmemoService.nsOmemo;

  final OmemoService _omemo = OmemoService();
  final Map<String, bool> _omemoEnabled = {};
  bool _isStrictVerificationEnabled = false;

  final Map<String, xmpp.Connection> _connections = {};
  final Map<String, String> _jids = {};
  final Map<String, Set<String>> _serverFeatures = {};

  OmemoService get omemo => _omemo;
  bool get isStrictVerificationEnabled => _isStrictVerificationEnabled;

  void registerConnection(String accountId, xmpp.Connection conn, String fullJid) {
    _connections[accountId] = conn;
    _jids[accountId] = fullJid;
    _omemo.setConnection(conn);
  }

  void unregisterConnection(String accountId) {
    _connections.remove(accountId);
    _jids.remove(accountId);
  }

  void registerServerFeatures(String accountId, Set<String> features) {
    _serverFeatures[accountId] = features;
  }

  void setJid(String accountId, String fullJid) {
    _jids[accountId] = fullJid;
  }

  Future<void> initialize(String bareJid) async {
    await _omemo.initialize(bareJid);
  }

  Future<void> publishKeys(xmpp.Connection conn, String bareJid) async {
    _omemo.ensureNodeAccessModels(conn);
    _omemo.publishDeviceList(conn, bareJid);
    _omemo.publishBundle(conn);
    _omemo.checkAndReplenishPreKeys();
  }

  bool isOmemoEnabled(String chatId) {
    return _omemoEnabled[chatId.toLowerCase()] ?? false;
  }

  void toggleOmemo(String chatId) {
    final id = chatId.toLowerCase();
    _omemoEnabled[id] = !(_omemoEnabled[id] ?? false);
    notifyListeners();
  }

  void setOmemoEnabled(String chatId, bool enabled) {
    final id = chatId.toLowerCase();
    if ((_omemoEnabled[id] ?? false) != enabled) {
      _omemoEnabled[id] = enabled;
      notifyListeners();
    }
  }

  bool isOmemoSupportedByServer(String accountId) {
    return _serverFeatures[accountId]?.contains(OmemoService.nsOmemo) ?? false;
  }

  Future<void> setStrictVerification(bool enabled) async {
    _isStrictVerificationEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('omemo_strict_verification', enabled);
    notifyListeners();
  }

  Future<bool> hasUnverifiedDevices(String jid) async {
    if (kIsWeb) return false;
    final store = SQLiteSignalStore();
    final identities = await store.getIdentitiesForJid(
      jid.split('/').first.toLowerCase(),
    );
    return identities.any((iden) => (iden['trust_level'] as int? ?? 0) == 0);
  }

  Future<int> getChatSecurityStatus(String chatId, {bool isGroup = false}) async {
    if (!isOmemoEnabled(chatId)) return -1;

    if (isGroup) {
      return await _getGroupChatSecurityStatus(chatId);
    }

    final fingerprints = await _omemo.getFingerprintsDetailed(chatId);
    if (fingerprints.isEmpty) return -1;

    bool hasDistrusted = false;
    bool hasUnverified = false;

    for (var device in fingerprints.values) {
      final level = device['trustLevel'] as int;
      if (level == 2) hasDistrusted = true;
      if (level == 0) hasUnverified = true;
    }

    if (hasDistrusted) return 2;
    if (hasUnverified) return 0;
    return 1;
  }

  Future<int> _getGroupChatSecurityStatus(String chatId) async {
    final fingerprints = await _omemo.getFingerprintsDetailed(chatId);
    if (fingerprints.isEmpty) return -1;

    int unverifiedCount = 0;
    int distrustedCount = 0;
    int verifiedCount = 0;

    for (var device in fingerprints.values) {
      final level = device['trustLevel'] as int;
      final isOwn = device['isOwn'] as bool? ?? false;
      if (isOwn) continue;
      if (level == 2) distrustedCount++;
      if (level == 0) unverifiedCount++;
      if (level == 1) verifiedCount++;
    }

    if (distrustedCount > 0) return 2;
    if (unverifiedCount > 0) return 0;
    if (verifiedCount > 0) return 1;
    return 1;
  }

  Future<int> getGroupParticipantKeyStatus(String chatId) async {
    final fingerprints = await _omemo.getFingerprintsDetailed(chatId);
    if (fingerprints.isEmpty) return 0;

    int verifiedCount = 0;
    int unverifiedCount = 0;

    for (var device in fingerprints.values) {
      final level = device['trustLevel'] as int;
      final isOwn = device['isOwn'] as bool? ?? false;
      if (isOwn) continue;
      if (level >= 1) verifiedCount++;
      if (level == 0) unverifiedCount++;
    }

    return verifiedCount + unverifiedCount;
  }

  Future<void> updateOmemoTrust(String jid, int deviceId, int trustLevel) async {
    await _omemo.setDeviceTrust(jid, deviceId, trustLevel);
    notifyListeners();
  }

  Future<Map<int, Map<String, dynamic>>> getOmemoFingerprintsDetailed(String chatId) {
    return _omemo.getFingerprintsDetailed(chatId);
  }

  Future<void> refreshOmemoDevices(String chatId, {String? accountId}) async {
    final id = accountId;
    if (id != null && _connections.containsKey(id)) {
      _omemo.setConnection(_connections[id]!);
    }

    final devices = await _omemo.fetchDeviceList(chatId);
    for (var devId in devices) {
      await _omemo.buildSession(chatId, devId);
    }
  }

  Future<String> getMyOmemoFingerprint() async {
    return await _omemo.getLocalFingerprint();
  }

  Future<List<Map<String, dynamic>>> fetchOmemoIdentities({String? activeAccountId, Map<String, String>? jidsMap}) async {
    if (kIsWeb) return [];
    final store = SQLiteSignalStore();
    final List<Map<String, dynamic>> identities = List.from(
      await store.getAllIdentities(),
    );

    try {
      final myIdentity = await store.getIdentityKeyPair();
      final myJid = activeAccountId != null && jidsMap != null
          ? jidsMap[activeAccountId]?.split('/').first.toLowerCase()
          : 'My Account';
      identities.insert(0, {
        'address_name': myJid ?? 'My Account',
        'device_id': _omemo.localDeviceId,
        'identity_key_data': myIdentity.getPublicKey().serialize(),
        'trust_level': 1,
      });
    } catch (e) {
      debugPrint('Error loading own identity: $e');
    }

    return identities;
  }

  int getLocalOmemoDeviceId() => _omemo.localDeviceId;

  Future<void> resetOmemoKeys(String accountId) async {
    final bareJid = _jids[accountId]?.split('/').first.toLowerCase();
    if (bareJid != null) {
      await _omemo.resetIdentity(bareJid);
    }
    notifyListeners();
  }

  Future<String?> decryptMessage(xmpp.XmppElement encrypted, {String? fromBareJid, bool isHistorical = false}) {
    return _omemo.decryptMessage(encrypted, fromBareJid: fromBareJid, isHistorical: isHistorical);
  }

  Future<List<xmpp.XmppElement>?> encryptMessage(String toJid, String plaintext, {bool strict = false}) {
    return _omemo.encryptMessage(toJid, plaintext, strict: strict);
  }

  Future<List<int>> fetchDeviceList(String bareJid) {
    return _omemo.fetchDeviceList(bareJid);
  }

  Future<void> buildSession(String bareJid, int deviceId) {
    return _omemo.buildSession(bareJid, deviceId);
  }

  Future<void> clearDatabase() {
    return _omemo.clearDatabase();
  }
}