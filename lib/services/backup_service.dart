import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import './auth_service.dart';
import './database_service.dart';
import '../models/chat_models.dart';

class BackupService {
  final AuthService authService;
  final DatabaseService dbService = DatabaseService();

  BackupService(this.authService);

  Future<String> generateBackup() async {
    try {
      final Map<String, dynamic> backup = {
        'version': '1.0',
        'timestamp': DateTime.now().toIso8601String(),
        'origin_docs_dir': (await getApplicationDocumentsDirectory()).path,
        'accounts': authService.savedAccounts.map((a) => a.toJson()).toList(),
        'secrets': await authService.exportAccountSecrets(),
        'database': await dbService.exportAllData(),
        'settings': await authService.exportSettings(),
        'contacts': authService.exportContacts(),
      };

      return json.encode(backup);
    } catch (e) {
      debugPrint('Backup Generation Error: $e');
      rethrow;
    }
  }

  Future<void> restoreBackup(String jsonStr) async {
    try {
      final Map<String, dynamic> backup = json.decode(jsonStr);
      
      // 1. Wipe current data
      await authService.clearAllData();
      
      // 2. Restore Database
      if (backup.containsKey('database')) {
        dynamic dbPayload = backup['database'];
        if (backup.containsKey('origin_docs_dir')) {
          final oldPath = backup['origin_docs_dir'] as String;
          final newPath = (await getApplicationDocumentsDirectory()).path;
          if (oldPath != newPath) {
             dbPayload = _replacePathsRecursively(dbPayload, oldPath, newPath);
          }
        }
        await dbService.importAllData(dbPayload);
      }

      // 3. Restore Settings (includes Profile)
      if (backup.containsKey('settings')) {
        await authService.importSettings(backup['settings']);
      }

      // 4. Restore Accounts
      if (backup.containsKey('accounts')) {
        final List<dynamic> accList = backup['accounts'];
        final accounts = accList.map((j) => SavedAccount.fromJson(j)).toList();
        await authService.importSavedAccounts(accounts);
      }

      // 5. Restore Secrets
      if (backup.containsKey('secrets')) {
        final Map<String, dynamic> secretsRaw = backup['secrets'];
        final Map<String, String> secrets = secretsRaw.map((k, v) => MapEntry(k, v.toString()));
        await authService.importAccountSecrets(secrets);
      }

      // 6. Restore Contacts
      if (backup.containsKey('contacts')) {
        final List<dynamic> contactsList = backup['contacts'];
        await authService.importContacts(contactsList);
      }

      debugPrint('Backup Restoration Complete');
    } catch (e) {
      debugPrint('Backup Restoration Error: $e');
      rethrow;
    }
  }

  // --- Encryption Layer (Phase 3) ---

  /// Encrypts the backup JSON string using AES-GCM and a password-derived key.
  /// Result is a base64 encoded string with 'GIB1' header.
  Future<String> encryptBackup(String plainJson, String password) async {
    // 1. Generate salt
    final salt = SecretKeyData.random(length: 16).bytes;

    // 2. Derive key from password using PBKDF2
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    // 3. Encrypt via AES-GCM
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(
      utf8.encode(plainJson),
      secretKey: secretKey,
      nonce: nonce,
    );

    // 4. Pack into binary format: [Header (4) | Salt (16) | Nonce (12) | Mac (16) | Ciphertext]
    final packed = <int>[];
    packed.addAll([0x47, 0x49, 0x42, 0x31]); // 'GIB1'
    packed.addAll(salt);
    packed.addAll(nonce);
    packed.addAll(secretBox.mac.bytes);
    packed.addAll(secretBox.cipherText);

    return base64.encode(packed);
  }

  /// Decrypts a base64 encoded backup string. Supports 'GIB1' encrypted format
  /// and legacy plain JSON backups (graceful degradation).
  Future<String> decryptBackup(String encodedData, String password) async {
    try {
      final packed = base64.decode(encodedData);
      
      // Check for 'GIB1' header
      if (packed.length > 4 && 
          packed[0] == 0x47 && packed[1] == 0x49 && packed[2] == 0x42 && packed[3] == 0x31) {
        
        final salt = packed.sublist(4, 20);
        final nonce = packed.sublist(20, 32);
        final mac = packed.sublist(32, 48);
        final ciphertext = packed.sublist(48);

        // 1. Re-derive key
        final pbkdf2 = Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 100000,
          bits: 256,
        );
        final secretKey = await pbkdf2.deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: salt,
        );

        // 2. Decrypt
        final algorithm = AesGcm.with256bits();
        final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
        final decryptedBytes = await algorithm.decrypt(
          secretBox,
          secretKey: secretKey,
        );

        return utf8.decode(decryptedBytes);
      } else {
        // Legacy support: Attempt to decode as plain UTF-8 JSON
        try {
          final plain = utf8.decode(packed);
          json.decode(plain); // Validate JSON
          return plain;
        } catch (_) {
          throw Exception('Unsupported file format or incorrect password.');
        }
      }
    } catch (e) {
      debugPrint('Decryption Error: $e');
      throw Exception('Incorrect password or corrupted backup file.');
    }
  }

  Future<void> saveBackupToFile(String data, String filePath) async {
    final file = File(filePath);
    await file.writeAsString(data);
  }

  Future<String> loadBackupFromFile(String filePath) async {
    final file = File(filePath);
    return await file.readAsString();
  }

  /// Recursively replaces oldPath with newPath in Maps and Lists
  dynamic _replacePathsRecursively(dynamic data, String oldPath, String newPath) {
    if (data is String) {
      return data.replaceAll(oldPath, newPath);
    } else if (data is List) {
      return data.map((item) => _replacePathsRecursively(item, oldPath, newPath)).toList();
    } else if (data is Map) {
      final newMap = <String, dynamic>{};
      data.forEach((key, value) {
        newMap[key as String] = _replacePathsRecursively(value, oldPath, newPath);
      });
      return newMap;
    }
    return data;
  }
}
