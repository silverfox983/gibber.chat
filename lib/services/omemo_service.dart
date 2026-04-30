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
    if (_conn == null || _conn!.state != xmpp.XmppConnectionState.Ready) {
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
  static const String nsPubsub = 'http://jabber.org/protocol/pubsub';
  
  final _aes = AesGcm.with128bits();

  Future<void> initialize() async {
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
      await resetIdentity();
    }
  }

  Future<void> resetIdentity() async {
    await _generateNewKeys();
    if (_conn != null && _conn!.state == xmpp.XmppConnectionState.Ready) {
      await publishDeviceList(_conn!);
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

  Future<Map<int, Map<String, dynamic>>> getFingerprintsDetailed(String chatId) async {
    final results = await _store.getIdentitiesForJid(chatId.toLowerCase());
    final Map<int, Map<String, dynamic>> details = {};
    for (var row in results) {
      final deviceId = row['device_id'] as int;
      final keyData = row['identity_key_data'] as Uint8List;
      details[deviceId] = {
        'fingerprint': _store.formatFingerprint(keyData),
        'trustLevel': row['trust_level'] as int? ?? 0,
      };
    }
    return details;
  }

  Future<void> setDeviceTrust(String jid, int deviceId, int trustLevel) async {
    await _store.updateTrustLevel(jid.toLowerCase(), deviceId, trustLevel);
  }

  // --- PEP (PubSub) Logic ---

  Future<void> publishDeviceList(xmpp.Connection conn) async {
    final iq = xmpp.IqStanza(DateTime.now().millisecondsSinceEpoch.toString(), xmpp.IqStanzaType.SET);
    final pubsub = xmpp.XmppElement()..name = 'pubsub'..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
    final publish = xmpp.XmppElement()..name = 'publish'..addAttribute(xmpp.XmppAttribute('node', '$nsOmemo:devices'));
    final item = xmpp.XmppElement()..name = 'item';
    final list = xmpp.XmppElement()..name = 'list'..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemo));
    final device = xmpp.XmppElement()..name = 'device'..addAttribute(xmpp.XmppAttribute('id', _deviceId.toString()));
    
    list.addChild(device);
    item.addChild(list);
    publish.addChild(item);
    pubsub.addChild(publish);
    iq.addChild(pubsub);
    conn.writeStanza(iq);
  }

  Future<void> publishBundle(xmpp.Connection conn) async {
    final identityKeyPair = await _store.getIdentityKeyPair();
    final signedPreKey = await _store.loadSignedPreKey(1);
    
    final iq = xmpp.IqStanza(DateTime.now().millisecondsSinceEpoch.toString(), xmpp.IqStanzaType.SET);
    final pubsub = xmpp.XmppElement()..name = 'pubsub'..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
    final publish = xmpp.XmppElement()..name = 'publish'..addAttribute(xmpp.XmppAttribute('node', '$nsOmemo:bundles:$_deviceId'));
    final item = xmpp.XmppElement()..name = 'item';
    final bundle = xmpp.XmppElement()..name = 'bundle'..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemo));
    
    bundle.addChild(xmpp.XmppElement()..name = 'signedPreKeyPublic'..addAttribute(xmpp.XmppAttribute('id', '1'))..textValue = base64Encode(signedPreKey.getKeyPair().publicKey.serialize()));
    bundle.addChild(xmpp.XmppElement()..name = 'signedPreKeySignature'..textValue = base64Encode(signedPreKey.signature));
    bundle.addChild(xmpp.XmppElement()..name = 'identityKey'..textValue = base64Encode(identityKeyPair.getPublicKey().serialize()));
    
    final prekeys = await _store.loadPreKeys();
    for (var pk in prekeys) {
      final pkEl = xmpp.XmppElement()..name = 'preKeyPublic'..addAttribute(xmpp.XmppAttribute('id', pk.id.toString()));
      pkEl.textValue = base64Encode(pk.getKeyPair().publicKey.serialize());
      bundle.addChild(pkEl);
    }
    
    item.addChild(bundle);
    publish.addChild(item);
    pubsub.addChild(publish);
    iq.addChild(pubsub);
    conn.writeStanza(iq);
  }

  Future<List<int>> fetchDeviceList(String bareJid) async {
    final iq = xmpp.IqStanza('omemo_dev_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);
    
    final pubsub = xmpp.XmppElement()..name = 'pubsub'..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
    final items = xmpp.XmppElement()..name = 'items'..addAttribute(xmpp.XmppAttribute('node', '$nsOmemo:devices'));
    
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return [];

      final pubsubRes = response.getChild('pubsub');
      final itemsRes = pubsubRes?.getChild('items');
      final itemRes = itemsRes?.getChild('item');
      final listRes = itemRes?.getChild('list');
      
      if (listRes == null) return [];

      final List<int> devices = [];
      for (var device in listRes.children.where((c) => c.name == 'device')) {
        final idStr = device.getAttribute('id')?.value;
        if (idStr != null) {
          final id = int.tryParse(idStr);
          if (id != null) devices.add(id);
        }
      }
      return devices;
    } catch (e) {
      debugPrint('OMEMO: Failed to fetch device list for $bareJid: $e');
      return [];
    }
  }

  Future<void> buildSession(String bareJid, int deviceId) async {
    try {
      final iq = xmpp.IqStanza('omemo_bun_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
      iq.toJid = xmpp.Jid.fromFullJid(bareJid);
      
      final pubsub = xmpp.XmppElement()..name = 'pubsub'..addAttribute(xmpp.XmppAttribute('xmlns', nsPubsub));
      final items = xmpp.XmppElement()..name = 'items'..addAttribute(xmpp.XmppAttribute('node', '$nsOmemo:bundles:$deviceId'));
      
      pubsub.addChild(items);
      iq.addChild(pubsub);

      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return;

      final pubsubRes = response.getChild('pubsub');
      final itemsRes = pubsubRes?.getChild('items');
      final itemRes = itemsRes?.getChild('item');
      final bundle = itemRes?.getChild('bundle');
      
      if (bundle == null) return;

      final spkPublicBase64 = bundle.getChild('signedPreKeyPublic')?.textValue;
      final spkSigBase64 = bundle.getChild('signedPreKeySignature')?.textValue;
      final ikBase64 = bundle.getChild('identityKey')?.textValue;
      
      final prekeys = bundle.children.where((c) => c.name == 'preKeyPublic').toList();
      if (prekeys.isEmpty || spkPublicBase64 == null || spkSigBase64 == null || ikBase64 == null) {
        debugPrint('OMEMO: Incomplete bundle received for $bareJid:$deviceId');
        return;
      }

      final pkEl = prekeys.first;
      final pkBase64 = pkEl.textValue;
      final pkId = pkEl.getAttribute('id')?.value;
      if (pkBase64 == null || pkId == null) return;

      final spkIdEl = bundle.getChild('signedPreKeyPublic');
      final spkIdStr = spkIdEl?.getAttribute('id')?.value ?? '1';

      final ikBytes = base64Decode(ikBase64);
      final spkPublic = base64Decode(spkPublicBase64);
      final spkSig = base64Decode(spkSigBase64);
      final pkBytes = base64Decode(pkBase64);

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

  Future<xmpp.XmppElement?> encryptMessage(String toJid, String plaintext, {bool strict = false}) async {
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

    final encryptedElement = xmpp.XmppElement()..name = 'encrypted'..addAttribute(xmpp.XmppAttribute('xmlns', nsOmemo));
    final header = xmpp.XmppElement()..name = 'header'..addAttribute(xmpp.XmppAttribute('sid', _deviceId.toString()));
    
    // Add IV
    header.addChild(xmpp.XmppElement()..name = 'iv'..textValue = base64Encode(iv));

    // Get recipient devices
    final store = SQLiteSignalStore();
    List<Map<String, dynamic>> devices = await store.getIdentitiesForJid(bareJid);
    
    // Dynamic Discovery: If we don't have devices, fetch them
    if (devices.isEmpty) {
      debugPrint('OMEMO: No devices known for $bareJid. Fetching from PubSub...');
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
       debugPrint('OMEMO: Strict mode blocked message to $bareJid due to unverified devices');
       return null; // Block
    }

    bool addedKeys = false;
    for (var device in devices) {
      final rDeviceId = device['device_id'] as int;
      final trustLevel = device['trust_level'] as int? ?? 0;
      
      // BLOCK if distrusted
      if (trustLevel == 2) {
         debugPrint('OMEMO: Skipping distrusted device $rDeviceId for $bareJid');
         continue;
      }

      final address = SignalProtocolAddress(bareJid, rDeviceId);
      
      // Ensure session exists
      if (!await store.containsSession(address)) {
        debugPrint('OMEMO: Missing session for $bareJid:$rDeviceId. Fetching bundle...');
        await buildSession(bareJid, rDeviceId);
      }

      try {
        final cipher = SessionCipher(store, store, store, store, address);
        final encryptedKey = await cipher.encrypt(encryptionKey);
        
        final keyElement = xmpp.XmppElement()..name = 'key'..addAttribute(xmpp.XmppAttribute('rid', rDeviceId.toString()));
        keyElement.textValue = base64Encode(encryptedKey.serialize());
        if (encryptedKey.getType() == CiphertextMessage.PREKEY_TYPE) {
          keyElement.addAttribute(xmpp.XmppAttribute('prekey', 'true'));
        }
        header.addChild(keyElement);
        addedKeys = true;
      } catch (e) {
        debugPrint('OMEMO: Failed to encrypt for device $rDeviceId: $e');
      }
    }

    if (!addedKeys) return null;

    encryptedElement.addChild(header);
    encryptedElement.addChild(xmpp.XmppElement()..name = 'payload'..textValue = base64Encode(Uint8List.fromList(ciphertext + tag)));

    return encryptedElement;
  }

  Future<String?> decryptMessage(xmpp.XmppElement encrypted, {String? fromBareJid}) async {
    final bareFrom = fromBareJid ?? '';
    final header = encrypted.getChild('header');
    if (header == null) return null;

    final ivBase64 = header.getChild('iv')?.textValue;
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

    if (myKeyElement.name != 'key') return null;

    final isPrekey = myKeyElement.getAttribute('prekey')?.value == 'true' || myKeyElement.getAttribute('prekey')?.value == '1';
    final encryptedKey = base64Decode(myKeyElement.textValue!);
    final payloadBase64 = encrypted.getChild('payload')?.textValue;
    if (payloadBase64 == null) return null;
    final payloadWithTag = base64Decode(payloadBase64);

    final store = SQLiteSignalStore();
    final address = SignalProtocolAddress(bareFrom, int.parse(header.getAttribute('sid')!.value!));
    final cipher = SessionCipher(store, store, store, store, address);

    try {
      Uint8List decryptedKey;
      if (isPrekey) {
        decryptedKey = await cipher.decrypt(PreKeySignalMessage(encryptedKey));
      } else {
        decryptedKey = await cipher.decryptFromSignal(SignalMessage.fromSerialized(encryptedKey));
      }
      final encryptionKey = decryptedKey;

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
      return null;
    }
  }

  Uint8List _generateRandomKey(int length) {
    final rand = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rand.nextInt(256)));
  }
}
