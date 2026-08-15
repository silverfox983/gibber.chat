class InputValidator {
  static final _jidLocalRegex = RegExp(r'^[a-zA-Z0-9._-]{3,64}$');
  static final _jidRegex = RegExp(r'^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
  static final _tierRegex = RegExp(r'^(free|pro|ultimate)$');
  static final _protocolRegex = RegExp(r'^(XMPP|Slack|Discord|IRC|Teams|Matrix|Telegram|SMS)$');
  static final _codeRegex = RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$');

  static String? validateUsername(String? username) {
    if (username == null || username.isEmpty) return 'Username is required';
    if (username.length < 3) return 'Username must be at least 3 characters';
    if (username.length > 64) return 'Username must be at most 64 characters';
    if (!_jidLocalRegex.hasMatch(username)) return 'Username must contain only letters, numbers, dots, hyphens, and underscores';
    return null;
  }

  static String? validatePassword(String? password) {
    if (password == null || password.isEmpty) return 'Password is required';
    if (password.length < 8) return 'Password must be at least 8 characters';
    if (password.length > 256) return 'Password must be at most 256 characters';
    return null;
  }

  static String? validateJid(String? jid) {
    if (jid == null || jid.isEmpty) return 'JID is required';
    if (!_jidRegex.hasMatch(jid)) return 'Invalid JID format (expected user@domain.tld)';
    return null;
  }

  static String? validateTier(String? tier) {
    if (tier == null || tier.isEmpty) return 'Tier is required';
    if (!_tierRegex.hasMatch(tier)) return 'Tier must be one of: free, pro, ultimate';
    return null;
  }

  static String? validateProtocol(String? protocol) {
    if (protocol == null || protocol.isEmpty) return 'Protocol is required';
    if (!_protocolRegex.hasMatch(protocol)) return 'Protocol not supported';
    return null;
  }

  static String? validateRedemptionCode(String? code) {
    if (code == null || code.isEmpty) return 'Code is required';
    if (!_codeRegex.hasMatch(code)) return 'Invalid code format (expected XXXX-XXXX-XXXX-XXXX)';
    return null;
  }

  static String? validateCpuCap(double? cpuCap) {
    if (cpuCap == null) return null;
    if (cpuCap < 0.01 || cpuCap > 1.0) return 'CPU cap must be between 0.01 and 1.0';
    return null;
  }

  static String? validateHost(String? host) {
    if (host == null || host.isEmpty) return null;
    if (host.length > 255) return 'Host must be at most 255 characters';
    if (!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host)) return 'Host contains invalid characters';
    return null;
  }
}