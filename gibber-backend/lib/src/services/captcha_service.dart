import 'dart:convert';
import 'dart:io';

class CaptchaService {
  final String _secretKey;
  final bool _enabled;

  CaptchaService({String secretKey = ''}) : _secretKey = secretKey, _enabled = secretKey.isNotEmpty;

  bool get enabled => _enabled;

  Future<bool> verifyToken(String token, {String? remoteIp}) async {
    if (!_enabled) return true;

    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('https://challenges.cloudflare.com/turnstile/v0/siteverify'));
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      final body = 'secret=${Uri.encodeQueryComponent(_secretKey)}'
          '&response=${Uri.encodeQueryComponent(token)}'
          '${remoteIp != null ? '&remoteip=${Uri.encodeQueryComponent(remoteIp)}' : ''}';
      request.write(body);
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      return json['success'] == true;
    } catch (e) {
      return false;
    }
  }
}