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
