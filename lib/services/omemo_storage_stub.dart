import 'dart:typed_data';

class _StubPublicKey {
  Uint8List serialize() => Uint8List(0);
}

class _StubIdentityKeyPair {
  _StubPublicKey getPublicKey() => _StubPublicKey();
}

class SQLiteSignalStore {
  Future<void> clearAllData() async {}
  Future<List<Map<String, dynamic>>> getIdentitiesForJid(String jid) async => [];
  Future<List<Map<String, dynamic>>> getAllIdentities() async => [];
  Future<_StubIdentityKeyPair> getIdentityKeyPair() async => _StubIdentityKeyPair();
  String formatFingerprint(Uint8List keyData) => '';
}