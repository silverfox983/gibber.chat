class InviteResult {
  final String uri;
  final String? landingUrl;
  final DateTime? expire;

  InviteResult({
    required this.uri,
    this.landingUrl,
    this.expire,
  });

  String? get preauthToken {
    final uriParts = uri.split('?');
    if (uriParts.length > 1) {
      final queryParams = uriParts[1].split(';');
      for (final param in queryParams) {
        if (param.startsWith('preauth=')) {
          return param.substring(8);
        }
      }
    }
    return null;
  }
}

enum RegistrationStatus { success, userExists, networkError, validationError, unsupported, captchaFailed }

class RegistrationResult {
  final RegistrationStatus status;
  final String? jid;
  final String? message;
  final String? accessToken;
  final String? refreshToken;

  const RegistrationResult({
    required this.status,
    this.jid,
    this.message,
    this.accessToken,
    this.refreshToken,
  });

  bool get isOk => status == RegistrationStatus.success;
}
