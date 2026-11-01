import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'backend_config.dart';
import 'jwt_token_service.dart';
import '../models/registration_models.dart';
import '../models/chat_models.dart';
import 'registration_service.dart';

/// Credentials of an auto-created guest account.
class GuestAccount {
  final String jid;
  final String username;
  final String domain;

  const GuestAccount({required this.jid, required this.username, required this.domain});

  String get displayName => username;
}

/// Signs every web visitor in automatically with a disposable guest account.
///
/// Guests are created once per browser: the credentials are saved via the
/// normal account store (SecureStorage on web), so on return visits the
/// standard auto-login connects with the SAME guest account instead of
/// spawning a new one per page load.
class VisitorService {
  static final Random _rng = Random.secure();

  static const String _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  static const int _usernameSuffixLen = 10;

  /// JID-safe lowercase alphanumeric guest username (e.g. `guest4f9z2wvq1c`).
  static String guestUsername() {
    final code = List.generate(
      _usernameSuffixLen,
      (_) => _alphabet[_rng.nextInt(_alphabet.length)],
    ).join();
    return 'guest$code';
  }

  /// Alphanumeric password (XML + JSON friendly, no shell/symbol pitfalls).
  static String guestPassword() =>
      List.generate(24, (_) => _alphabet[_rng.nextInt(_alphabet.length)]).join();

  static const String _guestFlagKey = 'gibber_visitor_jid';

  /// Returns the guest identity when one was created this session.
  Future<GuestAccount?> ensureGuestAccount({
    required AuthService authService,
    required BackendConfig backendConfig,
  }) async {
    if (!kIsWeb) return null;
    if (authService.savedAccounts.isNotEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_guestFlagKey) != null) {
      // A guest was created before but the account store is empty (cleared
      // cookies etc.) - reset the flag so a new guest can be minted.
      await prefs.remove(_guestFlagKey);
    }

    final domain = backendConfig.domain ?? Uri.parse(backendConfig.apiUrl).host;
    if (domain.isEmpty) {
      debugPrint('VisitorService: no backend domain yet - skipping guest bootstrap');
      return null;
    }

    debugPrint('VisitorService: creating guest account on $domain...');
    String username = guestUsername();
    String password = guestPassword();
    RegistrationResult? result;
    for (var attempt = 0; attempt < 6; attempt++) {
      final res = await RegistrationService.registerViaBackend(
        apiUrl: backendConfig.apiUrl,
        username: username,
        password: password,
        host: domain,
      );
      if (res.isOk) {
        result = res;
        break;
      }
      if (res.status == RegistrationStatus.userExists) {
        debugPrint('VisitorService: guest name collision, retrying');
        username = guestUsername();
        password = guestPassword();
        continue;
      }
      debugPrint('VisitorService: guest registration failed: ${res.message}');
      return null;
    }
    if (result == null) return null;

    if (result.accessToken != null) {
      await JwtTokenService().saveTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        jid: result.jid,
        apiUrl: backendConfig.apiUrl,
      );
    }

    try {
      await authService.connectXmpp(
        user: username,
        domain: domain,
        pass: password,
        port: kIsWeb ? 443 : 5222,
      );
      await authService.saveAccount(
        SavedAccount(
          user: username,
          domain: domain,
          port: kIsWeb ? 443 : 5222,
          protocol: 'XMPP',
        ),
        password,
      );
      await prefs.setString(_guestFlagKey, '$username@$domain');
      debugPrint('VisitorService: guest signed in as $username@$domain');
      return GuestAccount(jid: '$username@$domain', username: username, domain: domain);
    } catch (e) {
      debugPrint('VisitorService: guest account created but XMPP connect failed: $e');
      return null;
    }
  }
}