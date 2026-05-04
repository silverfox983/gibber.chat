import 'dart:async';
import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:sqflite/sqflite.dart';
import './database_service.dart';

class SQLiteSignalStore implements IdentityKeyStore, SessionStore, PreKeyStore, SignedPreKeyStore {
  final DatabaseService _db = DatabaseService();

  // --- IdentityKeyStore ---

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_config',
      where: 'key = ?',
      whereArgs: ['identity_key_pair'],
    );
    if (maps.isNotEmpty) {
      return IdentityKeyPair.fromSerialized(maps.first['value']);
    }
    throw Exception('Identity Key Pair not found');
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_config',
      where: 'key = ?',
      whereArgs: ['registration_id'],
    );
    if (maps.isNotEmpty) {
      final value = maps.first['value']; // It's a BLOB
      final buffer = ByteData.sublistView(value);
      return buffer.getInt32(0);
    }
    return 0;
  }

  Future<void> saveSelfIdentity(IdentityKeyPair pair, int registrationId) async {
    final db = await _db.database;
    await db.insert('signal_config', {'key': 'identity_key_pair', 'value': pair.serialize()}, conflictAlgorithm: ConflictAlgorithm.replace);
    
    final regData = ByteData(4);
    regData.setInt32(0, registrationId);
    await db.insert('signal_config', {'key': 'registration_id', 'value': regData.buffer.asUint8List()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    final db = await _db.database;
    if (identityKey == null) return false;
    
    // Preserve existing trust level if the identity already exists
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_identities',
      columns: ['trust_level'],
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
    int existingTrust = 0;
    if (maps.isNotEmpty) {
      existingTrust = maps.first['trust_level'] as int? ?? 0;
    }

    await db.insert(
      'signal_identities',
      {
        'address_name': address.getName().toLowerCase(),
        'device_id': address.getDeviceId(),
        'identity_key_data': identityKey.serialize(),
        'trust_level': existingTrust,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_identities',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
    if (maps.isEmpty) return true; // Trust on first use (TOFU)
    
    final storedKey = IdentityKey.fromBytes(maps.first['identity_key_data'], 0);
    return storedKey == identityKey;
  }

  @override
  Future<IdentityKey> getIdentity(SignalProtocolAddress address) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_identities',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
    if (maps.isNotEmpty) {
      return IdentityKey.fromBytes(maps.first['identity_key_data'], 0);
    }
    return (await getIdentityKeyPair()).getPublicKey();
  }

  Future<List<Map<String, dynamic>>> getIdentitiesForJid(String bareJid) async {
    final db = await _db.database;
    return await db.query(
      'signal_identities',
      where: 'address_name = ?',
      whereArgs: [bareJid.toLowerCase()],
    );
  }

  Future<List<Map<String, dynamic>>> getAllIdentities() async {
    final db = await _db.database;
    return await db.query('signal_identities');
  }

  Future<String> getLocalFingerprint() async {
    final pair = await getIdentityKeyPair();
    return formatFingerprint(pair.getPublicKey().serialize());
  }

  Future<void> updateTrustLevel(String name, int deviceId, int level) async {
    final db = await _db.database;
    await db.update(
      'signal_identities',
      {'trust_level': level},
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [name.toLowerCase(), deviceId],
    );
  }

  Future<int> getTrustLevel(String name, int deviceId) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_identities',
      columns: ['trust_level'],
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [name.toLowerCase(), deviceId],
    );
    if (maps.isEmpty) return 0; // Unverified / TOFU
    return maps.first['trust_level'] as int? ?? 0;
  }

  String formatFingerprint(Uint8List data) {
    // Standard OMEMO Fingerprint: 64 hex chars, grouped in 4-digit blocks
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final blocks = <String>[];
    for (var i = 0; i < hex.length; i += 8) {
      if (i + 8 <= hex.length) {
        blocks.add(hex.substring(i, i + 8));
      } else {
        blocks.add(hex.substring(i));
      }
    }
    return blocks.join(' ');
  }

  // --- SessionStore ---

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_sessions',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
    if (maps.isNotEmpty) {
      return SessionRecord.fromSerialized(maps.first['session_data']);
    }
    return SessionRecord();
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_sessions',
      columns: ['device_id'],
      where: 'address_name = ?',
      whereArgs: [name.toLowerCase()],
    );
    return maps.map((e) => e['device_id'] as int).toList();
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    final db = await _db.database;
    await db.insert(
      'signal_sessions',
      {
        'address_name': address.getName().toLowerCase(),
        'device_id': address.getDeviceId(),
        'session_data': record.serialize(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_sessions',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
    return maps.isNotEmpty;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final db = await _db.database;
    await db.delete(
      'signal_sessions',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName().toLowerCase(), address.getDeviceId()],
    );
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final db = await _db.database;
    await db.delete(
      'signal_sessions',
      where: 'address_name = ?',
      whereArgs: [name.toLowerCase()],
    );
  }

  // --- PreKeyStore ---

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_pre_keys',
      where: 'pre_key_id = ?',
      whereArgs: [preKeyId],
    );
    if (maps.isNotEmpty) {
      return PreKeyRecord.fromBuffer(maps.first['pre_key_data']);
    }
    throw Exception('PreKey not found');
  }

  Future<List<PreKeyRecord>> loadPreKeys() async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query('signal_pre_keys');
    return maps.map((e) => PreKeyRecord.fromBuffer(e['pre_key_data'])).toList();
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    final db = await _db.database;
    await db.insert(
      'signal_pre_keys',
      {
        'pre_key_id': preKeyId,
        'pre_key_data': record.serialize(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_pre_keys',
      where: 'pre_key_id = ?',
      whereArgs: [preKeyId],
    );
    return maps.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    final db = await _db.database;
    await db.delete(
      'signal_pre_keys',
      where: 'pre_key_id = ?',
      whereArgs: [preKeyId],
    );
  }

  // --- SignedPreKeyStore ---

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_signed_pre_keys',
      where: 'signed_pre_key_id = ?',
      whereArgs: [signedPreKeyId],
    );
    if (maps.isNotEmpty) {
      return SignedPreKeyRecord.fromSerialized(maps.first['signed_pre_key_data']);
    }
    throw Exception('SignedPreKey not found');
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query('signal_signed_pre_keys');
    return maps.map((e) => SignedPreKeyRecord.fromSerialized(e['signed_pre_key_data'])).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    final db = await _db.database;
    await db.insert(
      'signal_signed_pre_keys',
      {
        'signed_pre_key_id': signedPreKeyId,
        'signed_pre_key_data': record.serialize(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'signal_signed_pre_keys',
      where: 'signed_pre_key_id = ?',
      whereArgs: [signedPreKeyId],
    );
    return maps.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    final db = await _db.database;
    await db.delete(
      'signal_signed_pre_keys',
      where: 'signed_pre_key_id = ?',
      whereArgs: [signedPreKeyId],
    );
  }

  Future<void> clearAllData() async {
    final db = await _db.database;
    await db.delete('signal_config');
    await db.delete('signal_identities');
    await db.delete('signal_sessions');
    await db.delete('signal_pre_keys');
    await db.delete('signal_signed_pre_keys');
  }
}
