import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/services/backup_service.dart';
import 'package:chat_app/services/auth_service.dart';

void main() {
  late BackupService backupService;
  late AuthService authService;

  setUp(() {
    authService = AuthService();
    backupService = BackupService(authService);
  });

  group('BackupService Encryption Tests', () {
    const plainJson = '{"version": "1.0", "accounts": [{"user": "alice"}]}';
    const password = 'test_password_123';

    test('Encrypt and Decrypt cycle', () async {
      final encrypted = await backupService.encryptBackup(plainJson, password);
      
      // Verify it's base64 and not plain text
      expect(encrypted, isNot(contains('alice')));
      
      final decrypted = await backupService.decryptBackup(encrypted, password);
      expect(decrypted, plainJson);
    });

    test('Wrong password should fail', () async {
      final encrypted = await backupService.encryptBackup(plainJson, password);
      
      expect(
        () => backupService.decryptBackup(encrypted, 'wrong_pass'),
        throwsA(anything),
      );
    });

    test('Legacy plain JSON support', () async {
      final legacyJson = '{"version": "0.9", "legacy": true}';
      final base64Legacy = base64.encode(utf8.encode(legacyJson));
      
      // decryptBackup should detect it's not GIB1 and return decoded string if it's valid JSON
      final decrypted = await backupService.decryptBackup(base64Legacy, 'any_pass');
      expect(decrypted, legacyJson);
    });
  });
}
