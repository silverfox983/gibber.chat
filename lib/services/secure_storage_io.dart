import 'secure_storage_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageIO extends SecureStorageService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) =>
      _storage.read(key: key);

  @override
  Future<void> delete({required String key}) =>
      _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() =>
      _storage.readAll();

  @override
  Future<void> writeAll(Map<String, String> entries) async {
    for (final entry in entries.entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
  }

  @override
  Future<void> deleteAll() =>
      _storage.deleteAll();
}

SecureStorageService createSecureStorage() => SecureStorageIO();