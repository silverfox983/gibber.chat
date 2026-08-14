import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'secure_storage_service.dart';

class SecureStorageWeb extends SecureStorageService {
  static const _prefix = 'gibber_secure_';
  SharedPreferences? _prefs;
  AesGcm? _aesGcm;
  SecretKey? _masterKey;

  SecureStorageWeb();

  Future<SharedPreferences> get _prefsFuture async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<SecretKey> _getOrCreateMasterKey() async {
    if (_masterKey != null) return _masterKey!;
    _aesGcm = AesGcm.with128bits();

    final prefs = await _prefsFuture;
    final stored = prefs.getString('${_prefix}master_key');
    if (stored != null) {
      final keyBytes = base64Decode(stored);
      _masterKey = SecretKey(keyBytes);
      return _masterKey!;
    }

    final algorithm = _aesGcm!;
    final key = await algorithm.newSecretKey();
    final keyBytes = await key.extractBytes();
    _masterKey = SecretKey(keyBytes);
    await prefs.setString('${_prefix}master_key', base64Encode(keyBytes));
    return _masterKey!;
  }

  String _obfuscateKey(String key) =>
      '$_prefix${sha256.convert(utf8.encode(key)).toString().substring(0, 16)}';

  @override
  Future<void> write({required String key, required String value}) async {
    final masterKey = await _getOrCreateMasterKey();
    final algorithm = _aesGcm ?? AesGcm.with128bits();
    final nonce = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(
      utf8.encode(value),
      secretKey: masterKey,
      nonce: nonce,
    );
    final encoded = base64Encode(secretBox.concatenation(nonce: true));
    final prefs = await _prefsFuture;
    await prefs.setString(_obfuscateKey(key), encoded);
  }

  @override
  Future<String?> read({required String key}) async {
    final prefs = await _prefsFuture;
    final encoded = prefs.getString(_obfuscateKey(key));
    if (encoded == null) return null;

    try {
      final masterKey = await _getOrCreateMasterKey();
      final algorithm = _aesGcm ?? AesGcm.with128bits();
      final combined = base64Decode(encoded);
      final secretBox = SecretBox.fromConcatenation(
        combined,
        nonceLength: AesGcm.with128bits().nonceLength,
        macLength: AesGcm.with128bits().macAlgorithm.macLength,
      );
      final decrypted = await algorithm.decrypt(
        secretBox,
        secretKey: masterKey,
      );
      return utf8.decode(decrypted);
    } catch (_) {
      final stored = prefs.getString(_obfuscateKey(key));
      if (stored != null && !stored.contains('+') && !stored.contains('/') && !stored.contains('=')) {
        return stored;
      }
      return null;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    final prefs = await _prefsFuture;
    await prefs.remove(_obfuscateKey(key));
  }

  @override
  Future<Map<String, String>> readAll() async {
    final prefs = await _prefsFuture;
    final result = <String, String>{};
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix) && k != '${_prefix}master_key');
    for (final k in keys) {
      final v = prefs.getString(k);
      if (v != null) result[k] = v;
    }
    return result;
  }

  @override
  Future<void> writeAll(Map<String, String> entries) async {
    for (final e in entries.entries) {
      await write(key: e.key, value: e.value);
    }
  }

  @override
  Future<void> deleteAll() async {
    final prefs = await _prefsFuture;
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
    _masterKey = null;
  }
}

SecureStorageService createSecureStorage() => SecureStorageWeb();