import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:share_plus/share_plus.dart';
import './auth_service.dart';
import './backup_service.dart';

class DataExportService {
  final AuthService authService;

  DataExportService(this.authService);

  /// Generates a comprehensive ZIP export of all user data, including
  /// the encrypted profile backup and raw media files (voice notes, calls).
  Future<String> createFullExport(String password) async {
    if (kIsWeb) throw UnsupportedError('Not available on web');
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final exportDirPath = '${tempDir.path}/Gibber_Export_$timestamp';
      final exportDir = Directory(exportDirPath);
      await exportDir.create();

      // 1. Generate secure profile backup (.gibber)
      final backupService = BackupService(authService);
      final jsonStr = await backupService.generateBackup();
      final encryptedData = await backupService.encryptBackup(jsonStr, password);
      
      final backupFile = File('${exportDir.path}/profile_backup.gibber');
      await backupFile.writeAsString(encryptedData);

      // 2. Gather Media and Application Files
      final docsDir = await getApplicationDocumentsDirectory();
      final targetMediaDir = Directory('${exportDir.path}/AppFiles');
      
      if (await docsDir.exists()) {
        // Copy entire Application Documents structure, excluding SQLite DB files
        // (which are already securely exported inside the JSON backup)
        await _copyDirectory(
          docsDir, 
          targetMediaDir,
          excludeExtensions: ['.db', '-shm', '-wal'],
        );
      }

      // 3. Create the ZIP Archive
      final zipFilePath = '${tempDir.path}/Gibber_Full_Export_$timestamp.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipFilePath);
      encoder.addDirectory(exportDir);
      encoder.close();

      // 4. Cleanup the temporary build folder
      if (await exportDir.exists()) {
        await exportDir.delete(recursive: true);
      }

      return zipFilePath;
    } catch (e) {
      debugPrint('DataExportService Error: $e');
      rethrow;
    }
  }

  /// Imports a comprehensive backup from either a ZIP archive or a legacy .gibber file.
  Future<void> importFullBackup(String filePath, String password) async {
    if (kIsWeb) throw UnsupportedError('Not available on web');
    try {
      final isZip = filePath.toLowerCase().endsWith('.zip');
      final backupService = BackupService(authService);

      if (isZip) {
        final tempDir = await getTemporaryDirectory();
        final extractDirPath = '${tempDir.path}/Gibber_Extract_${DateTime.now().millisecondsSinceEpoch}';
        final extractDir = Directory(extractDirPath);
        await extractDir.create();

        // 1. Extract ZIP
        extractFileToDisk(filePath, extractDir.path);

        // 2. Restore Media files first (so they exist when DB is restored)
        final extractedAppFilesDir = Directory('${extractDir.path}/AppFiles');
        if (await extractedAppFilesDir.exists()) {
          final docsDir = await getApplicationDocumentsDirectory();
          await _copyDirectory(extractedAppFilesDir, docsDir);
        } else {
          // Legacy support for GibberExport
          final extractedMediaDir = Directory('${extractDir.path}/Media');
          if (await extractedMediaDir.exists()) {
            final docsDir = await getApplicationDocumentsDirectory();
            final targetMediaDir = Directory('${docsDir.path}/GibberExport');
            await _copyDirectory(extractedMediaDir, targetMediaDir);
          }
        }

        // 3. Locate and restore profile backup (automatically replaces paths)
        final backupFile = File('${extractDir.path}/profile_backup.gibber');
        if (!await backupFile.exists()) {
          throw Exception('Invalid ZIP backup: Missing profile_backup.gibber');
        }

        final encodedData = await backupFile.readAsString();
        final jsonStr = await backupService.decryptBackup(encodedData, password);
        await backupService.restoreBackup(jsonStr);

        // 4. Cleanup
        await extractDir.delete(recursive: true);
      } else {
        // Legacy support: Just a .gibber file
        final encodedData = await backupService.loadBackupFromFile(filePath);
        final jsonStr = await backupService.decryptBackup(encodedData, password);
        await backupService.restoreBackup(jsonStr);
      }
    } catch (e) {
      debugPrint('DataExportService Import Error: $e');
      rethrow;
    }
  }

  /// Utility to trigger the OS Share sheet for the exported file
  Future<void> shareExport(String zipFilePath) async {
    final xFile = XFile(zipFilePath);
    await Share.shareXFiles(
      [xFile],
      text: 'Gibber Data Export',
      subject: 'Gibber Data Export',
    );
  }

  /// Recursive directory copy utility
  Future<void> _copyDirectory(Directory source, Directory destination, {List<String>? excludeExtensions}) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = entity.path.split(RegExp(r'[/\\]')).last;
      
      if (excludeExtensions != null && entity is File) {
        if (excludeExtensions.any((ext) => name.toLowerCase().endsWith(ext))) {
          continue;
        }
      }

      if (entity is Directory) {
        final newDirectory = Directory('${destination.path}/$name');
        await newDirectory.create();
        await _copyDirectory(entity.absolute, newDirectory, excludeExtensions: excludeExtensions);
      } else if (entity is File) {
        await entity.copy('${destination.path}/$name');
      }
    }
  }
}
