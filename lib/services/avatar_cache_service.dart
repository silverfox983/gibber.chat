import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class AvatarCacheService {
  static final AvatarCacheService _instance = AvatarCacheService._internal();
  factory AvatarCacheService() => _instance;
  AvatarCacheService._internal();

  Directory? _cacheDir;
  final Map<String, Uint8List> _memoryCache = {};
  SharedPreferences? _prefs;

  Future<void> init() async {
    if (kIsWeb) {
      _prefs = await SharedPreferences.getInstance();
      return;
    }
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory(p.join(appDir.path, 'avatars'));
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  String _getFileName(String id, {String? protocol}) {
    return '${id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}.png';
  }

  Future<Uint8List?> getAvatar(String id, {String? protocol}) async {
    final fileName = _getFileName(id, protocol: protocol);
    if (_memoryCache.containsKey(fileName)) {
      return _memoryCache[fileName];
    }

    if (kIsWeb) {
      _prefs ??= await SharedPreferences.getInstance();
      final encoded = _prefs!.getString('avatar_$fileName');
      if (encoded != null) {
        final bytes = base64Decode(encoded);
        _memoryCache[fileName] = bytes;
        return bytes;
      }
      return null;
    }

    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, fileName));
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        _memoryCache[fileName] = bytes;
        return bytes;
      } catch (e) {
        debugPrint('AVATAR CACHE READ ERROR: $e');
        return null;
      }
    }
    return null;
  }

  Future<void> saveAvatar(String id, Uint8List bytes, {String? protocol}) async {
    final fileName = _getFileName(id, protocol: protocol);
    _memoryCache[fileName] = bytes;

    if (kIsWeb) {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString('avatar_$fileName', base64Encode(bytes));
      return;
    }

    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, fileName));
    try {
      await file.writeAsBytes(bytes);
    } catch (e) {
      debugPrint('AVATAR CACHE WRITE ERROR: $e');
    }
  }

  Future<bool> hasAvatar(String id, {String? protocol}) async {
    if (kIsWeb) {
      _prefs ??= await SharedPreferences.getInstance();
      return _prefs!.containsKey('avatar_${_getFileName(id, protocol: protocol)}');
    }
    if (_cacheDir == null) await init();
    final file = File(p.join(_cacheDir!.path, _getFileName(id, protocol: protocol)));
    return await file.exists();
  }

  Future<void> clearCache() async {
    _memoryCache.clear();
    if (kIsWeb) {
      _prefs ??= await SharedPreferences.getInstance();
      final keys = _prefs!.getKeys().where((k) => k.startsWith('avatar_'));
      for (final k in keys) {
        await _prefs!.remove(k);
      }
      return;
    }
    if (_cacheDir == null) await init();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create(recursive: true);
    }
  }
}
