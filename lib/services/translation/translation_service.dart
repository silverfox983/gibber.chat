import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class TranslationService {
  static const _apiUrl = 'https://api.mymemory.translated.net/get';

  static Future<String?> translate(String text, {String fromLang = 'auto', String toLang = 'en'}) async {
    if (text.trim().isEmpty) return null;
    try {
      final uri = Uri.parse('$_apiUrl?q=${Uri.encodeComponent(text)}&langpair=$fromLang|$toLang');
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final json = await compute(_parseJson, resp.body);
        return json['responseData']?['translatedText'];
      }
    } catch (e) {
      debugPrint('Translation error: $e');
    }
    return null;
  }

  static Map<String, dynamic> _parseJson(String body) {
    return Map<String, dynamic>.from(
      const JsonDecoder().convert(body) as Map,
    );
  }
}
