import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class AppPaths {
  static Future<String> get documentsDirectory async {
    if (kIsWeb) return '/web-docs';
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static Future<String> get temporaryDirectory async {
    if (kIsWeb) return '/web-tmp';
    final dir = await getTemporaryDirectory();
    return dir.path;
  }

  static String basename(String filePath) {
    return filePath.split(RegExp(r'[/\\]')).last;
  }

  static String join(String part1, String part2, [String? part3]) {
    if (kIsWeb) {
      var result = '$part1/$part2';
      if (part3 != null) result = '$result/$part3';
      return result;
    }
    return part3 != null ? p.join(part1, part2, part3) : p.join(part1, part2);
  }

  static bool get isWeb => kIsWeb;
}