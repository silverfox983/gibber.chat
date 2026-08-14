import 'dart:convert';
import 'dart:io';

class CaptchaService {
  final String _secretKey;
  final bool _enabled;
  final String _expectedAction;
  final Set<String> _allowedHostnames;

  CaptchaService({
    String secretKey = '',
    String expectedAction = 'signup',
    Set<String>? allowedHostnames,
  }) : _secretKey = secretKey,
       _enabled = secretKey.isNotEmpty,
       _expectedAction = expectedAction,
       _allowedHostnames = allowedHostnames ?? const {'gibberapp.online', 'localhost', '127.0.0.1'};

  bool get enabled => _enabled;

  Future<bool> verifyToken(String token, {String? remoteIp}) async {
    if (!_enabled) return true;

    if (token.isEmpty || token.length > 2048) return false;
    if (_allowedHostnames.isEmpty) return false;

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

      if (json['success'] != true) return false;

      final action = json['action'] as String?;
      if (action != _expectedAction) return false;

      final hostname = json['hostname'] as String?;
      if (hostname == null || !_allowedHostnames.contains(hostname)) return false;

      return true;
    } catch (_) {
      return false;
    }
  }
}