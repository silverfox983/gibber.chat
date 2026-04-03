import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

class AvatarCacheService {
  static final AvatarCacheService _instance = AvatarCacheService._internal();
  factory AvatarCacheService() => _instance;
  AvatarCacheService._internal();

  Directory? _cacheDir;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory(p.join(appDir.path, 'avatars'));
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  String _getFileName(String id, {String? protocol}) {
    // Sanitize ID for filename and add optional protocol prefix to avoid collisions
    final prefix = protocol != null ? '${protocol.toLowerCase()}_' : '';
    return '$prefix${id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.png';
  }

  Future<Uint8List?> getAvatar(String id, {String? protocol}) async {
    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, _getFileName(id, protocol: protocol)));
    if (await file.exists()) {
      try {
        return await file.readAsBytes();
      } catch (e) {
        debugPrint('AVATAR CACHE READ ERROR: $e');
        return null;
      }
    }
    return null;
  }

  Future<void> saveAvatar(String id, Uint8List bytes, {String? protocol}) async {
    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, _getFileName(id, protocol: protocol)));
    try {
      await file.writeAsBytes(bytes);
    } catch (e) {
      debugPrint('AVATAR CACHE WRITE ERROR: $e');
    }
  }

  Future<bool> hasAvatar(String id, {String? protocol}) async {
    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, _getFileName(id, protocol: protocol)));
    return await file.exists();
  }

  Future<void> clearCache() async {
    if (_cacheDir == null) await init();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create(recursive: true);
    }
  }
}
