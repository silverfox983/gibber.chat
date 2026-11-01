import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'backend_config.dart';
import 'database_service.dart';
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

/// Outcome of a guest account claim.
class GuestClaimResult {
  final bool ok;
  final String? error;
  final GuestAccount? account;
  final int migratedItems;
  final int contactsRestored;
  final int roomsRestored;

  const GuestClaimResult({
    required this.ok,
    this.error,
    this.account,
    this.migratedItems = 0,
    this.contactsRestored = 0,
    this.roomsRestored = 0,
  });

  const GuestClaimResult.failure(this.error)
      : ok = false,
        account = null,
        migratedItems = 0,
        contactsRestored = 0,
        roomsRestored = 0;
}

extension VisitorClaim on VisitorService {
  /// The jid of the auto-created guest, when this device uses one.
  static const _guestFlagKey = 'gibber_visitor_jid';
  static const _joinedRoomsKey = 'joined_rooms';
  static const _joinedSpacesKey = 'joined_spaces';

  Future<String?> guestJid() async {
    final prefs = await SharedPreferences.getInstance();
    final flag = prefs.getString(_guestFlagKey);
    if (flag == null) return null;
    return flag.contains('@') && flag.split('@').first.startsWith('guest') ? flag : null;
  }

  /// Claims a real username for an auto-created guest and migrates the
  /// guest's local data (messages, conversations, joined rooms/spaces) to the
  /// new account. Gateway transports are NOT migrated: slidge registrations
  /// are bound to the guest jid, so they are removed and must be re-linked
  /// from the networks sheet under the new account.
  Future<GuestClaimResult> claimAccount({
    required AuthService authService,
    required DatabaseService databaseService,
    required String newUsername,
    required String newPassword,
    String? domain,
    List<Contact> captureContacts = const [],
    List<String> captureRooms = const [],
    List<String> captureSpaces = const [],
  }) async {
    if (!kIsWeb) {
      return const GuestClaimResult.failure('Claim is only needed on the web.');
    }
    final backendConfig = BackendConfig();
    final host = domain ?? backendConfig.domain ?? Uri.parse(backendConfig.apiUrl).host;
    if (host.isEmpty) {
      return const GuestClaimResult.failure('Server domain unknown yet.');
    }

    // The active login must be the guest we created.
    final guestFlagJid = await guestJid();
    final activeAccountJid = authService.activeAccountId;
    if (activeAccountJid == null || guestFlagJid == null ||
        (activeAccountJid.toLowerCase() != guestFlagJid.toLowerCase() &&
            activeAccountJid.toLowerCase() != guestFlagJid.toLowerCase())) {
      return const GuestClaimResult.failure('Sign in as the guest first, then claim.');
    }

    // 1. Register the real account.
    final result = await RegistrationService.registerViaBackend(
      apiUrl: backendConfig.apiUrl,
      username: newUsername,
      password: newPassword,
      host: host,
    );
    if (!result.isOk) {
      return GuestClaimResult.failure(result.message);
    }

    // 2. Migrate local data before switching accounts.
    int migrated = 0;
    try {
      migrated = await databaseService
          .reassignAccountIds(activeAccountJid, result.jid ?? '$newUsername@$host');
    } catch (e) {
      debugPrint('VisitorService: data migration failed: $e');
    }

    // Gateway transports are jid-bound: drop them so the networks sheet
    // offers a fresh "Connect" under the claimed account.
    try {
      await databaseService.deleteRegisteredTransportsForAccount(activeAccountJid);
    } catch (e) {
      debugPrint('VisitorService: transport rows cleanup failed: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    // Joined rooms/spaces: re-point to the new account.
    final roomEntries = prefs.getStringList(_joinedRoomsKey) ?? [];
    final newRooms = <String>[];
    for (final entry in roomEntries) {
      final parts = entry.split('|');
      if (parts.length >= 3 && parts[0].toLowerCase() == activeAccountJid.toLowerCase()) {
        newRooms.add([
          result.jid ?? '$newUsername@$host',
          parts[1],
          parts[2],
        ].join('|'));
      } else {
        newRooms.add(entry);
      }
    }
    await prefs.setStringList(_joinedRoomsKey, newRooms);
    final spaces = prefs.getStringList(_joinedSpacesKey);
    if (spaces != null) {
      await prefs.setStringList(_joinedSpacesKey, spaces);
    }
    await prefs.remove(_guestFlagKey);

    // 3. Switch: sign out of the guest, sign in the real account.
    try {
      await authService.logout();
    } catch (e) {
      debugPrint('VisitorService: logout during claim failed: $e');
    }
    if (result.accessToken != null) {
      await JwtTokenService().saveTokens(
        accessToken: result.accessToken!,
        refreshToken: result.refreshToken,
        jid: result.jid,
        apiUrl: backendConfig.apiUrl,
      );
    }

    final newUser = (result.jid ?? '$newUsername@$host').split('@').first;
    final newDomain = (result.jid ?? '$newUsername@$host').split('@').length > 1
        ? (result.jid ?? '$newUsername@$host').split('@')[1]
        : host;
    try {
      await authService.connectXmpp(
        user: newUser,
        domain: newDomain,
        pass: newPassword,
        port: kIsWeb ? 443 : 5222,
      );
    } catch (e) {
      debugPrint('VisitorService: claimed account connect failed: $e');
      return GuestClaimResult(
        ok: false,
        error: 'Account claimed, but connecting to the server failed: $e',
        account: GuestAccount(jid: '$newUser@$newDomain', username: newUser, domain: newDomain),
        migratedItems: migrated,
      );
    }

    try {
      await authService.saveAccount(
        SavedAccount(
          user: newUser,
          domain: newDomain,
          port: kIsWeb ? 443 : 5222,
          protocol: 'XMPP',
        ),
        newPassword,
      );
    } catch (e) {
      debugPrint('VisitorService: saving claimed account failed: $e');
    }

    // 4. Restore contacts on the new account (roster set + subscribe).
    int contactsRestored = 0;
    for (final contact in captureContacts) {
      if (!contact.id.contains('@')) continue;
      try {
        authService.addContact(contact.id, nickname: contact.name);
        contactsRestored++;
      } catch (e) {
        debugPrint('VisitorService: contact restore failed for ${contact.id}: $e');
      }
    }

    return GuestClaimResult(
      ok: true,
      account: GuestAccount(jid: '$newUser@$newDomain', username: newUser, domain: newDomain),
      migratedItems: migrated,
      contactsRestored: contactsRestored,
      roomsRestored: newRooms.length,
    );
  }
}