import 'secure_storage_io.dart' if (dart.library.html) 'secure_storage_web.dart';

abstract class SecureStorageService {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
  Future<Map<String, String>> readAll();
  Future<void> writeAll(Map<String, String> entries);
  Future<void> deleteAll();

  static SecureStorageService? _instance;
  static SecureStorageService get instance {
    _instance ??= createSecureStorage();
    return _instance!;
  }
}