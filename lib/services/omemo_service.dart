import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import './omemo_storage.dart';

class OmemoService {
  final SQLiteSignalStore _store = SQLiteSignalStore();
  int? _deviceId;
  xmpp.Connection? _conn;

  final Map<String, Completer<dynamic>> _iqCompleters = {};
  StreamSubscription? _stanzaSub;

  void setConnection(xmpp.Connection conn) {
    _conn = conn;
    _stanzaSub?.cancel();
    _stanzaSub = _conn!.inStanzasStream.listen(_handleStanza);
  }

  void _handleStanza(dynamic stanza) {
    if (stanza is xmpp.IqStanza) {
      if (_iqCompleters.containsKey(stanza.id)) {
        _iqCompleters[stanza.id]!.complete(stanza);
        _iqCompleters.remove(stanza.id);
      }
    }
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza iq) async {
    if (_conn == null ||
        (_conn!.state != xmpp.XmppConnectionState.Ready &&
            _conn!.state != xmpp.XmppConnectionState.Resumed)) {
      throw Exception('XMPP connection not ready');
    }
    final completer = Completer<dynamic>();
    _iqCompleters[iq.id!] = completer;
    _conn!.writeStanza(iq);

    final result = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _iqCompleters.remove(iq.id);
        throw TimeoutException('IQ request timed out');
      },
    );
    return result as xmpp.IqStanza;
  }

  int get localDeviceId => _deviceId ?? 0;

  Future<String> getLocalFingerprint() async {
    return await _store.getLocalFingerprint();
  }

  static const String nsOmemo = 'urn:xmpp:omemo:0';
  static const String nsOmemoLegacy = 'eu.siacs.conversations.axolotl';
  static const String nsPubsub = 'http://jabber.org/protocol/pubsub';

  final _aes = AesGcm.with128bits();

  Future<void> initialize(String bareJid) async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getInt('omemo_device_id');

    // Check if identity exists in DB
    bool exists = false;
    try {
      await _store.getIdentityKeyPair();
      exists = true;
    } catch (_) {}

    if (_deviceId == null || !exists) {
      _deviceId ??= Random().nextInt(2147483647);
      await prefs.setInt('omemo_device_id', _deviceId!);
      await resetIdentity(bareJid);
    }
  }

  Future<void> resetIdentity(String bareJid) async {
    await _generateNewKeys();
    if (_conn != null &&
        (_conn!.state == xmpp.XmppConnectionState.Ready ||
            _conn!.state == xmpp.XmppConnectionState.Resumed)) {
      await publishDeviceList(_conn!, bareJid);
      await publishBundle(_conn!);
    }
  }

  Future<void> clearDatabase() async {
    await _store.clearAllData();
  }

  Future<void> _generateNewKeys() async {
    final identityKeyPair = KeyHelper.generateIdentityKeyPair();
    final registrationId = KeyHelper.generateRegistrationId(false);
    final preKeys = KeyHelper.generatePreKeys(1, 100);
    final signedPreKey = KeyHelper.generateSignedPreKey(identityKeyPair, 1);

    await _store.saveSelfIdentity(identityKeyPair, registrationId);

    for (var p in preKeys) {
      await _store.storePreKey(p.id, p);
    }
    await _store.storeSignedPreKey(signedPreKey.id, signedPreKey);
    debugPrint('OMEMO: Keys generated and stored for Device ID $_deviceId');
  }

  Future<void> checkAndReplenishPreKeys() async {
    try {
      final prekeys = await _store.loadPreKeys();
      if (prekeys.length < 20) {
        debugPrint(
          'OMEMO: PreKeys depleted (${prekeys.length} remaining). Replenishing...',
        );
        int maxId = 0;
        for (var p in prekeys) {
          if (p.id > maxId) maxId = p.id;
        }
        final newPreKeys = KeyHelper.generatePreKeys(maxId + 1, 100);
        for (var p in newPreKeys) {
          await _store.storePreKey(p.id, p);
        }
        if (_conn != null &&
            (_conn!.state == xmpp.XmppConnectionState.Ready ||
                _conn!.state == xmpp.XmppConnectionState.Resumed)) {
          await publishBundle(_conn!);
        }
        debugPrint('OMEMO: Successfully replenished PreKeys.');
      }
    } catch (e) {
      debugPrint('OMEMO: Failed to replenish PreKeys - $e');
    }
  }

  // Fingerprints for UI
  Future<Map<int, String>> getFingerprints(String chatId) async {
    final results = await _store.getIdentitiesForJid(chatId.toLowerCase());
    final Map<int, String> fingerprints = {};
    for (var row in results) {
      final deviceId = row['device_id'] as int;
      final keyData = row['identity_key_data'] as Uint8List;
      fingerprints[deviceId] = _store.formatFingerprint(keyData);
    }
    return fingerprints;
  }

  Future<Map<int, Map<String, dynamic>>> getFingerprintsDetailed(
    String chatId,
  ) async {
    final results = await _store.getIdentitiesForJid(chatId.toLowerCase());
    final Map<int, Map<String, dynamic>> details = {};

    // Add local device first
    try {
      final myIdentity = await _store.getIdentityKeyPair();
      final myFingerprint = _store.formatFingerprint(
        myIdentity.getPublicKey().serialize(),
      );
      details[_deviceId ?? 0] = {
        'fingerprint': myFingerprint,
        'trustLevel': 1, // Always trust yourself
        'isOwn': true,
      };
    } catch (e) {
      debugPrint('OMEMO: Failed to load local identity for trust dialog: $e');
    }

    for (var row in results) {
      final deviceId = row['device_id'] as int;
      final keyData = row['identity_key_data'] as Uint8List;
      details[deviceId] = {
        'fingerprint': _store.formatFingerprint(keyData),
        'trustLevel': row['trust_level'] as int? ?? 0,
        'isOwn': false,
      };
    }
    return details;
  }

  Future<void> setDeviceTrust(String jid, int deviceId, int trustLevel) async {
    await _store.updateTrustLevel(jid.toLowerCase(), deviceId, trustLevel);
  }

  // --- PEP (PubSub) Logic ---

  Future<void> publishDeviceList(
    xmpp.Connection conn,
    String bareJid, {
    bool clearOtherDevices = false,
  }) async {
    final Set<int> activeDevices = {};
    if (!clearOtherDevices) {
      final existing = await fetchDeviceList(bareJid);
      activeDevices.addAll(existing);
    }
    activeDevices.add(_deviceId!);

    // Helper to publish to a specific namespace
    Future<void> publish0(String nodePrefix, String listXmlns) async {
      final iq = xmpp.IqStanza(
        '${nodePrefix}_${DateTime.now().millisecondsSinceEpoch}',
        xmpp.IqStanzaType.SET,
      );
      final pubsub = xmpp.XmppElement()
        ..name = 'pubsub'
        ..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
      final publish = xmpp.XmppElement()
        ..name = 'publish'
        ..addAttribute(xmpp.XmppAttribute('node', '$nodePrefix:devicelist'));

      // Note: Modern OMEMO uses node="urn:xmpp:omemo:0:devices"
      // Legacy uses node="eu.siacs.conversations.axolotl:devicelist"
      if (nodePrefix == nsOmemo) {
        publish.addAttribute(xmpp.XmppAttribute('node', '$nodePrefix:devices'));
      }

      final item = xmpp.XmppElement()..name = 'item';
      final listName = nodePrefix == nsOmemo ? 'devices' : 'list';
      final list = xmpp.XmppElement()
        ..name = listName
        ..addAttribute(xmpp.XmppAttribute('xmlns', listXmlns));

      for (var devId in activeDevices) {
        final device = xmpp.XmppElement()
          ..name = 'device'
          ..addAttribute(xmpp.XmppAttribute('id', devId.toString()));
        list.addChild(device);
      }

      item.addChild(list);
      publish.addChild(item);

      // Add publish-options to ensure 'open' access model (XEP-0384)
      final publishOptions = xmpp.XmppElement()..name = 'publish-options';
      final xForm = xmpp.XmppElement()
        ..name = 'x'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
        ..addAttribute(xmpp.XmppAttribute('type', 'submit'));

      final fieldFormType = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'))
        ..addAttribute(xmpp.XmppAttribute('type', 'hidden'));
      fieldFormType.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'http://jabber.org/protocol/pubsub#publish-options',
      );

      final fieldAccessModel = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'pubsub#access_model'));
      fieldAccessModel.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'open',
      );

      xForm.addChild(fieldFormType);
      xForm.addChild(fieldAccessModel);
      publishOptions.addChild(xForm);

      pubsub.addChild(publish);
      pubsub.addChild(publishOptions);
      iq.addChild(pubsub);
      conn.writeStanza(iq);
    }

    // Publish to Modern OMEMO
    await publish0(nsOmemo, nsOmemo);
    // Publish to Legacy OMEMO
    await publish0(nsOmemoLegacy, nsOmemoLegacy);

    debugPrint(
      'OMEMO: Published device list: $activeDevices to both namespaces',
    );
  }

  Future<void> ensureNodeAccessModels(xmpp.Connection conn) async {
    final nodes = [
      '$nsOmemo:devices',
      '$nsOmemo:bundles:$_deviceId',
      '$nsOmemoLegacy:devicelist',
      '$nsOmemoLegacy:bundles:$_deviceId',
    ];
    for (var node in nodes) {
      final iq = xmpp.IqStanza(
        'config_${node.hashCode.abs()}',
        xmpp.IqStanzaType.SET,
      );
      final pubsub = xmpp.XmppElement()
        ..name = 'pubsub'
        ..addAttribute(
          xmpp.XmppAttribute(
            'xmlns',
            'http://jabber.org/protocol/pubsub#owner',
          ),
        );
      final configure = xmpp.XmppElement()
        ..name = 'configure'
        ..addAttribute(xmpp.XmppAttribute('node', node));

      final xForm = xmpp.XmppElement()
        ..name = 'x'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
        ..addAttribute(xmpp.XmppAttribute('type', 'submit'));

      final fieldFormType = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'))
        ..addAttribute(xmpp.XmppAttribute('type', 'hidden'));
      fieldFormType.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'http://jabber.org/protocol/pubsub#node_config',
      );

      final fieldAccessModel = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'pubsub#access_model'));
      fieldAccessModel.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'open',
      );

      xForm.addChild(fieldFormType);
      xForm.addChild(fieldAccessModel);
      configure.addChild(xForm);
      pubsub.addChild(configure);
      iq.addChild(pubsub);
      conn.writeStanza(iq);
    }
  }

  Future<void> publishBundle(xmpp.Connection conn) async {
    final identityKeyPair = await _store.getIdentityKeyPair();
    final signedPreKey = await _store.loadSignedPreKey(1);
    final prekeys = await _store.loadPreKeys();

    // Helper to publish to a specific namespace
    Future<void> publish0(String nodePrefix, String bundleXmlns) async {
      final iq = xmpp.IqStanza(
        '${nodePrefix}_bundle_${DateTime.now().millisecondsSinceEpoch}',
        xmpp.IqStanzaType.SET,
      );
      final pubsub = xmpp.XmppElement()
        ..name = 'pubsub'
        ..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
      final publish = xmpp.XmppElement()
        ..name = 'publish'
        ..addAttribute(
          xmpp.XmppAttribute('node', '$nodePrefix:bundles:$_deviceId'),
        );
      final item = xmpp.XmppElement()..name = 'item';
      final bundle = xmpp.XmppElement()
        ..name = 'bundle'
        ..addAttribute(xmpp.XmppAttribute('xmlns', bundleXmlns));

      bundle.addChild(
        xmpp.XmppElement()
          ..name = 'signedPreKeyPublic'
          ..addAttribute(xmpp.XmppAttribute('id', '1'))
          ..textValue = base64Encode(
            signedPreKey.getKeyPair().publicKey.serialize(),
          ),
      );
      bundle.addChild(
        xmpp.XmppElement()
          ..name = 'signedPreKeySignature'
          ..textValue = base64Encode(signedPreKey.signature),
      );
      bundle.addChild(
        xmpp.XmppElement()
          ..name = 'identityKey'
          ..textValue = base64Encode(
            identityKeyPair.getPublicKey().serialize(),
          ),
      );

      for (var pk in prekeys) {
        final pkEl = xmpp.XmppElement()
          ..name = 'preKeyPublic'
          ..addAttribute(xmpp.XmppAttribute('id', pk.id.toString()));
        pkEl.textValue = base64Encode(pk.getKeyPair().publicKey.serialize());
        bundle.addChild(pkEl);
      }

      item.addChild(bundle);
      publish.addChild(item);

      // Add publish-options to ensure 'open' access model (XEP-0384)
      final publishOptions = xmpp.XmppElement()..name = 'publish-options';
      final xForm = xmpp.XmppElement()
        ..name = 'x'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
        ..addAttribute(xmpp.XmppAttribute('type', 'submit'));

      final fieldFormType = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'))
        ..addAttribute(xmpp.XmppAttribute('type', 'hidden'));
      fieldFormType.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'http://jabber.org/protocol/pubsub#publish-options',
      );

      final fieldAccessModel = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'pubsub#access_model'));
      fieldAccessModel.addChild(
        xmpp.XmppElement()
          ..name = 'value'
          ..textValue = 'open',
      );

      xForm.addChild(fieldFormType);
      xForm.addChild(fieldAccessModel);
      publishOptions.addChild(xForm);

      pubsub.addChild(publish);
      pubsub.addChild(publishOptions);
      iq.addChild(pubsub);
      conn.writeStanza(iq);
    }

    // Publish to Modern OMEMO
    await publish0(nsOmemo, nsOmemo);
    // Publish to Legacy OMEMO
    await publish0(nsOmemoLegacy, nsOmemoLegacy);

    debugPrint('OMEMO: Published bundle to both namespaces');
  }

  final Map<String, DateTime> _failedDeviceFetches = {};

  Future<List<int>> fetchDeviceList(String bareJid) async {
    final now = DateTime.now();
    if (_failedDeviceFetches.containsKey(bareJid)) {
      if (now.difference(_failedDeviceFetches[bareJid]!) <
          const Duration(minutes: 5)) {
        debugPrint(
          'OMEMO: Skipping device fetch for $bareJid (recent failure)',
        );
        return [];
      }
    }

    // 1. Try Modern OMEMO
    final iqModern = xmpp.IqStanza(
      'omemo_dev_mod_${now.microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iqModern.toJid = xmpp.Jid.fromFullJid(bareJid);
    final pubsubMod = xmpp.XmppElement()
      ..name = 'pubsub'
      ..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
    pubsubMod.addChild(
      xmpp.XmppElement()
        ..name = 'items'
        ..addAttribute(xmpp.XmppAttribute('node', '$nsOmemo:devices')),
    );
    iqModern.addChild(pubsubMod);

    try {
      var response = await _sendIq(iqModern);

      // 2. FALLBACK: If modern OMEMO node not found, try legacy namespace
      if (response.type == xmpp.IqStanzaType.ERROR) {
        debugPrint(
          'OMEMO: Modern device list not found for $bareJid, trying legacy...',
        );
        final iqLegacy = xmpp.IqStanza(
          'omemo_dev_leg_${now.microsecondsSinceEpoch}',
          xmpp.IqStanzaType.GET,
        );
        iqLegacy.toJid = xmpp.Jid.fromFullJid(bareJid);
        final pubsubLeg = xmpp.XmppElement()
          ..name = 'pubsub'
          ..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
        pubsubLeg.addChild(
          xmpp.XmppElement()
            ..name = 'items'
            ..addAttribute(
              xmpp.XmppAttribute('node', '$nsOmemoLegacy:devicelist'),
            ),
        );
        iqLegacy.addChild(pubsubLeg);
        response = await _sendIq(iqLegacy);
      }

      if (response.type == xmpp.IqStanzaType.ERROR) {
        _failedDeviceFetches[bareJid] = now;
        return [];
      }

      final pubsubRes = response.getChild('pubsub');
      final itemsRes = pubsubRes?.getChild('items');
      final itemRes = itemsRes?.getChild('item');
      final listRes = itemRes?.getChild('devices') ?? itemRes?.getChild('list');

      if (listRes == null) {
        _failedDeviceFetches[bareJid] = now;
        return [];
      }

      final List<int> devices = [];
      for (var device in listRes.children.where((c) => c.name == 'device')) {
        final idStr = device.getAttribute('id')?.value;
        if (idStr != null) {
          final id = int.tryParse(idStr);
          if (id != null) devices.add(id);
        }
      }

      if (devices.isNotEmpty) {
        _failedDeviceFetches.remove(bareJid);
      } else {
        _failedDeviceFetches[bareJid] = now;
      }
      return devices;
    } catch (e) {
      debugPrint('OMEMO: Failed to fetch device list for $bareJid: $e');
      _failedDeviceFetches[bareJid] = now;
      return [];
    }
  }

  Future<void> buildSession(String bareJid, int deviceId) async {
    final address = SignalProtocolAddress(bareJid, deviceId);
    if (await _store.containsSession(address)) {
      return; // Session already established
    }

    try {
      final iq = xmpp.IqStanza(
        'omemo_bun_${DateTime.now().microsecondsSinceEpoch}',
        xmpp.IqStanzaType.GET,
      );
      iq.toJid = xmpp.Jid.fromFullJid(bareJid);

      final pubsub = xmpp.XmppElement()
        ..name = 'pubsub'
        ..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
      final items = xmpp.XmppElement()
        ..name = 'items'
        ..addAttribute(
          xmpp.XmppAttribute('node', '$nsOmemo:bundles:$deviceId'),
        );

      pubsub.addChild(items);
      iq.addChild(pubsub);

      var response = await _sendIq(iq);

      // FALLBACK: If modern bundle not found, try legacy
      if (response.type == xmpp.IqStanzaType.ERROR) {
        iq.id = 'omemo_bun_legacy_${DateTime.now().microsecondsSinceEpoch}';
        items.addAttribute(
          xmpp.XmppAttribute('node', '$nsOmemoLegacy:bundles:$deviceId'),
        );
        response = await _sendIq(iq);
      }

      if (response.type == xmpp.IqStanzaType.ERROR) return;

      final pubsubRes = response.getChild('pubsub');
      final itemsRes = pubsubRes?.getChild('items');
      final itemRes = itemsRes?.getChild('item');
      final bundle = itemRes?.getChild('bundle');

      if (bundle == null) return;

      final spkPublicBase64 = bundle.getChild('signedPreKeyPublic')?.textValue;
      final spkSigBase64 = bundle.getChild('signedPreKeySignature')?.textValue;
      final ikBase64 = bundle.getChild('identityKey')?.textValue;

      final prekeys = bundle.children
          .where((c) => c.name == 'preKeyPublic')
          .toList();
      if (prekeys.isEmpty ||
          spkPublicBase64 == null ||
          spkSigBase64 == null ||
          ikBase64 == null) {
        debugPrint('OMEMO: Incomplete bundle received for $bareJid:$deviceId');
        return;
      }

      final pkEl = prekeys.first;
      final pkBase64 = pkEl.textValue;
      final pkId = pkEl.getAttribute('id')?.value;
      if (pkBase64 == null || pkId == null) return;

      final spkIdEl = bundle.getChild('signedPreKeyPublic');
      final spkIdStr = spkIdEl?.getAttribute('id')?.value ?? '1';

      final ikBytes = base64Decode(ikBase64.replaceAll(RegExp(r'\s+'), ''));
      final spkPublic = base64Decode(
        spkPublicBase64.replaceAll(RegExp(r'\s+'), ''),
      );
      final spkSig = base64Decode(spkSigBase64.replaceAll(RegExp(r'\s+'), ''));
      final pkBytes = base64Decode(pkBase64.replaceAll(RegExp(r'\s+'), ''));

      final identityKey = IdentityKey.fromBytes(ikBytes, 0);
      final preKeyPublic = Curve.decodePoint(pkBytes, 0);
      final signedPreKeyPublic = Curve.decodePoint(spkPublic, 0);

      final preKeyBundle = PreKeyBundle(
        0, // registrationId (not strict)
        deviceId,
        int.parse(pkId),
        preKeyPublic,
        int.parse(spkIdStr),
        signedPreKeyPublic,
        spkSig,
        identityKey,
      );

      final address = SignalProtocolAddress(bareJid, deviceId);
      final builder = SessionBuilder(_store, _store, _store, _store, address);
      await builder.processPreKeyBundle(preKeyBundle);

      // Save identity for UI tracking
      await _store.saveIdentity(address, identityKey);

      debugPrint('OMEMO: Built session for $bareJid:$deviceId');
    } catch (e) {
      debugPrint('OMEMO: Failed to build session for $bareJid:$deviceId: $e');
    }
  }

  // --- Encryption/Decryption ---

  Future<List<xmpp.XmppElement>?> encryptMessage(
    String toJid,
    String plaintext, {
    bool strict = false,
  }) async {
    final bareJid = toJid.split('/').first.toLowerCase();
    final encryptionKey = _generateRandomKey(16);
    final iv = _generateRandomKey(12);

    final secretKey = SecretKey(encryptionKey);
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: iv,
    );
    final ciphertext = box.cipherText;
    final tag = box.mac.bytes;

    final encryptedElement = xmpp.XmppElement()
      ..name = 'encrypted'
      ..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemo));
    final header = xmpp.XmppElement()
      ..name = 'header'
      ..addAttribute(xmpp.XmppAttribute('sid', _deviceId.toString()));

    // Add IV
    header.addChild(
      xmpp.XmppElement()
        ..name = 'iv'
        ..textValue = base64Encode(iv),
    );

    // Get recipient devices
    final store = SQLiteSignalStore();
    List<Map<String, dynamic>> devices = await store.getIdentitiesForJid(
      bareJid,
    );

    // Dynamic Discovery: If we don't have devices, fetch them
    if (devices.isEmpty) {
      debugPrint(
        'OMEMO: No devices known for $bareJid. Fetching from PubSub...',
      );
      final fetchedIds = await fetchDeviceList(bareJid);
      for (final devId in fetchedIds) {
        await buildSession(bareJid, devId);
      }
      devices = await store.getIdentitiesForJid(bareJid);
    }

    if (devices.isEmpty) {
      debugPrint('OMEMO: No devices found for $bareJid, sending unencrypted?');
      return null;
    }

    if (strict && devices.any((d) => (d['trust_level'] as int? ?? 0) == 0)) {
      debugPrint(
        'OMEMO: Strict mode blocked message to $bareJid due to unverified devices',
      );
      return null; // Block
    }

    // Add our own devices to the recipient list so we can decrypt our own sent messages (MAM)
    final myBareJid = _conn?.fullJid.userAtDomain.toLowerCase();

    // Create a wrapper class or use Map to track which device belongs to which JID
    final List<Map<String, dynamic>> allDevicesToEncrypt = [];

    for (var d in devices) {
      allDevicesToEncrypt.add({
        'jid': bareJid,
        'device_id': d['device_id'],
        'trust_level': d['trust_level'],
      });
    }

    if (myBareJid != null && myBareJid != bareJid) {
      final myDevices = await store.getIdentitiesForJid(myBareJid);
      for (var d in myDevices) {
        if (d['device_id'] != _deviceId) {
          allDevicesToEncrypt.add({
            'jid': myBareJid,
            'device_id': d['device_id'],
            'trust_level': d['trust_level'],
          });
        }
      }
    }

    bool addedKeys = false;
    final keysWrapper = xmpp.XmppElement()..name = 'keys';

    for (var device in allDevicesToEncrypt) {
      final deviceJid = device['jid'] as String;
      final rDeviceId = device['device_id'] as int;
      final trustLevel = device['trust_level'] as int? ?? 0;

      // Skip our own device to prevent encrypting to ourselves
      if (deviceJid == myBareJid && rDeviceId == _deviceId) {
        continue;
      }

      // BLOCK if distrusted
      if (trustLevel == 2) {
        debugPrint(
          'OMEMO: Skipping distrusted device $rDeviceId for $deviceJid',
        );
        continue;
      }

      final address = SignalProtocolAddress(deviceJid, rDeviceId);

      // Ensure session exists
      if (!await store.containsSession(address)) {
        debugPrint(
          'OMEMO: Missing session for $deviceJid:$rDeviceId. Fetching bundle...',
        );
        await buildSession(deviceJid, rDeviceId);
      }

      try {
        final cipher = SessionCipher(store, store, store, store, address);
        final encryptedKey = await cipher.encrypt(encryptionKey);

        final keyElement = xmpp.XmppElement()
          ..name = 'key'
          ..addAttribute(xmpp.XmppAttribute('rid', rDeviceId.toString()));
        keyElement.textValue = base64Encode(encryptedKey.serialize());
        if (encryptedKey.getType() == CiphertextMessage.PREKEY_TYPE) {
          keyElement.addAttribute(xmpp.XmppAttribute('prekey', 'true'));
        }
        keysWrapper.addChild(keyElement);
        addedKeys = true;
      } catch (e) {
        debugPrint(
          'OMEMO: Failed to encrypt for device $rDeviceId: $e. Attempting session heal...',
        );
        // Session Healing: Delete corrupted session, rebuild from fresh bundle, and retry once.
        await store.deleteSession(address);
        await buildSession(deviceJid, rDeviceId);
        try {
          final cipher = SessionCipher(store, store, store, store, address);
          final encryptedKey = await cipher.encrypt(encryptionKey);
          final keyElement = xmpp.XmppElement()
            ..name = 'key'
            ..addAttribute(xmpp.XmppAttribute('rid', rDeviceId.toString()));
          keyElement.textValue = base64Encode(encryptedKey.serialize());
          if (encryptedKey.getType() == CiphertextMessage.PREKEY_TYPE) {
            keyElement.addAttribute(xmpp.XmppAttribute('prekey', 'true'));
          }
          keysWrapper.addChild(keyElement);
          addedKeys = true;
          debugPrint('OMEMO: Session healed for $rDeviceId!');
        } catch (healError) {
          debugPrint('OMEMO: Session heal failed for $rDeviceId: $healError');
        }
      }
    }

    if (!addedKeys) return null;

    // XEP-0384: keys element MUST be inside header
    header.addChild(keysWrapper);
    final encryptedElements = <xmpp.XmppElement>[];

    // Modern OMEMO
    final modernEncrypted = xmpp.XmppElement()
      ..name = 'encrypted'
      ..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemo));
    modernEncrypted.addChild(header);
    modernEncrypted.addChild(
      xmpp.XmppElement()
        ..name = 'payload'
        ..textValue = base64Encode(Uint8List.fromList(ciphertext + tag)),
    );
    encryptedElements.add(modernEncrypted);

    // Legacy OMEMO Fallback (Dual-stack for interoperability)
    final legacyEncrypted = xmpp.XmppElement()
      ..name = 'encrypted'
      ..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemoLegacy));
    legacyEncrypted.addChild(header); // Same header/keys work for both
    legacyEncrypted.addChild(
      xmpp.XmppElement()
        ..name = 'payload'
        ..textValue = base64Encode(Uint8List.fromList(ciphertext + tag)),
    );
    encryptedElements.add(legacyEncrypted);

    return encryptedElements;
  }

  Future<String?> decryptMessage(
    xmpp.XmppElement encrypted, {
    String? fromBareJid,
    bool isHistorical = false,
  }) async {
    final bareFrom = fromBareJid ?? '';
    final header = encrypted.getChild('header');
    if (header == null) return null;

    final ivBase64 = header
        .getChild('iv')
        ?.textValue
        ?.replaceAll(RegExp(r'\s+'), '');
    if (ivBase64 == null) return null;
    final iv = base64Decode(ivBase64);

    final keysWrapper = header.getChild('keys');
    final keysElements = keysWrapper != null
        ? keysWrapper.children.where((c) => c.name == 'key')
        : header.children.where((c) => c.name == 'key');

    final myKeyElement = keysElements.firstWhere(
      (k) => k.getAttribute('rid')?.value == _deviceId.toString(),
      orElse: () => xmpp.XmppElement(),
    );

    if (myKeyElement.name != 'key') {
      debugPrint(
        'OMEMO: Incoming message not encrypted for our device ($_deviceId).',
      );
      if (!isHistorical) {
        debugPrint('OMEMO: Live message, republishing our device list...');
        if (_conn != null &&
            (_conn!.state == xmpp.XmppConnectionState.Ready ||
                _conn!.state == xmpp.XmppConnectionState.Resumed)) {
          publishDeviceList(_conn!, _conn!.fullJid.userAtDomain).catchError(
            (e) => debugPrint('OMEMO: Failed to republish device list: $e'),
          );
        }
      } else {
        debugPrint(
          'OMEMO: Historical message, ignoring missing device key to prevent flood.',
        );
      }
      return null;
    }

    final isPrekey =
        myKeyElement.getAttribute('prekey')?.value == 'true' ||
        myKeyElement.getAttribute('prekey')?.value == '1';
    final encryptedKeyBase64 = myKeyElement.textValue?.replaceAll(
      RegExp(r'\s+'),
      '',
    );
    if (encryptedKeyBase64 == null) return null;
    final encryptedKey = base64Decode(encryptedKeyBase64);

    final payloadBase64 = encrypted
        .getChild('payload')
        ?.textValue
        ?.replaceAll(RegExp(r'\s+'), '');
    if (payloadBase64 == null) return null;
    final payloadWithTag = base64Decode(payloadBase64);

    final sidStr = header.getAttribute('sid')?.value;
    if (sidStr == null) return null;

    final store = SQLiteSignalStore();
    final address = SignalProtocolAddress(bareFrom, int.parse(sidStr));
    final cipher = SessionCipher(store, store, store, store, address);

    try {
      Uint8List decryptedKey;
      if (isPrekey) {
        decryptedKey = await cipher.decrypt(PreKeySignalMessage(encryptedKey));
      } else {
        decryptedKey = await cipher.decryptFromSignal(
          SignalMessage.fromSerialized(encryptedKey),
        );
      }
      final encryptionKey = decryptedKey;

      if (payloadWithTag.length < 16) {
        debugPrint(
          'OMEMO Decryption Error: Payload too short to contain auth tag',
        );
        return null;
      }

      final ciphertext = payloadWithTag.sublist(0, payloadWithTag.length - 16);
      final tag = payloadWithTag.sublist(payloadWithTag.length - 16);

      final secretKey = SecretKey(encryptionKey);
      final decrypted = await _aes.decrypt(
        SecretBox(ciphertext, nonce: iv, mac: Mac(tag)),
        secretKey: secretKey,
      );

      return utf8.decode(decrypted);
    } catch (e) {
      debugPrint('OMEMO Decryption Error: $e');

      // Session Healing: If decryption fails (due to desynchronized ratchets, lost keys, etc.),
      // we delete the corrupted session and fetch a fresh bundle. The next time we send a message,
      // it will establish a new session, automatically healing the connection.
      debugPrint(
        'OMEMO: Decryption failed - rebuilding session for $bareFrom:${address.getDeviceId()}',
      );
      try {
        await store.deleteSession(address);
        await buildSession(bareFrom, address.getDeviceId());

        if (isPrekey) {
          // If we failed to decrypt a PreKey message, it's likely our local PreKeys were lost/reset
          // but the remote user used an old one. We must republish our bundle and trigger a PEP notification
          // to force the remote client to re-fetch our new PreKeys.
          if (_conn != null &&
              (_conn!.state == xmpp.XmppConnectionState.Ready ||
                  _conn!.state == xmpp.XmppConnectionState.Resumed)) {
            await publishBundle(_conn!);
            await publishDeviceList(_conn!, _conn!.fullJid.userAtDomain);
          }
        }
      } catch (healError) {
        debugPrint(
          'OMEMO: Failed to rebuild session during healing: $healError',
        );
      }

      return null;
    }
  }

  Uint8List _generateRandomKey(int length) {
    final rand = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rand.nextInt(256)));
  }
}
