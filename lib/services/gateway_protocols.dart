import 'package:flutter/material.dart';

/// Maps gateway component JIDs to their protocol metadata.
///
/// The gateway components live on subdomains of the XMPP domain, e.g.
/// `1234567890@telegram.gibberapp.online` is a Telegram contact bridged by
/// the slidgram component on `telegram.gibberapp.online`. Contacts arriving
/// through roster pushes from a gateway get their `protocol` mapped here so
/// the contact list, conversation list and badges show the right network.
class GatewayProtocolMeta {
  final String protocol; // 'WhatsApp', 'Telegram', ...
  final String name; // human display name
  final IconData icon;
  final Color color;
  final bool usesQrPairing;

  const GatewayProtocolMeta({
    required this.protocol,
    required this.name,
    required this.icon,
    required this.color,
    this.usesQrPairing = false,
  });
}

class GatewayProtocols {
  GatewayProtocols._();

  /// Subdomain prefixes slidge/biboumi components use for each protocol.
  static const _byPrefixes = <String, String>{
    'whatsapp': 'WhatsApp',
    'telegram': 'Telegram',
    'discord': 'Discord',
    'matrix': 'Matrix',
    'irc': 'IRC',
    'steam': 'Steam',
  };

  /// Alternative subdomains used by some slidge deployments (mirrors of the
  /// upstream project's image names).
  static const _aliasedPrefixes = <String, String>{
    'slidgram': 'Telegram',
    'slidcord': 'Discord',
    'matridge': 'Matrix',
    'slidge-whatsapp': 'WhatsApp',
  };

  /// Protocol label for a bare JID (e.g. `12025550123@whatsapp.tld`) or a
  /// component domain (e.g. `discord.tld`). Returns null when the JID does
  /// not belong to a known gateway. Prefers exact full-domain matches; the
  /// first-label match only applies when the domain ends with [ownDomain]
  /// to avoid misclassifying federated jids like `user@matrix.org`.
  static String? protocolForJid(String? jid, {String? ownDomain}) {
    if (jid == null || jid.isEmpty) return null;
    // Skip full jids (resources) and MUC-style local parts.
    if (jid.split('@').length > 2) return null;
    final domainPart = jid.contains('@') ? jid.split('@').last : jid;
    final d = domainPart.toLowerCase();
    for (final entry in _aliasedPrefixes.entries) {
      if (d == '${entry.key}.gibberapp.online') return entry.value;
    }
    for (final entry in _byPrefixes.entries) {
      if (d == '${entry.key}.gibberapp.online') return entry.value;
    }
    final firstLabel = d.split('.').first;
    for (final entry in _aliasedPrefixes.entries) {
      if (firstLabel == entry.key &&
          ownDomain != null &&
          ownDomain.isNotEmpty &&
          d.endsWith('.${ownDomain.toLowerCase()}')) {
        return entry.value;
      }
    }
    for (final entry in _byPrefixes.entries) {
      if (firstLabel == entry.key &&
          ownDomain != null &&
          ownDomain.isNotEmpty &&
          d.endsWith('.${ownDomain.toLowerCase()}')) {
        return entry.value;
      }
    }
    return null;
  }

  /// Protocol for a jid whose domain is on the given host suffix, e.g.
  /// `discord.` + the configured site domain — used when the deployment does
  /// not run on gibberapp.online.
  static String? protocolForDomainSuffix(String jid, String siteDomain) {
    if (jid.isEmpty || siteDomain.isEmpty) return null;
    final domainPart = jid.contains('@') ? jid.split('@').last : jid;
    final suffix = siteDomain.toLowerCase();
    if (!domainPart.toLowerCase().endsWith('.$suffix')) return null;
    return protocolForBareDomain(domainPart);
  }

  /// Match a component DOMAIN against the known prefixes. Loose (first-label)
  /// matching is opt-in via [loose]; used for gateway component discovery.
  static String? protocolForBareDomain(String domain, {bool loose = false}) {
    final d = domain.toLowerCase();
    for (final entry in _aliasedPrefixes.entries) {
      if (d == '${entry.key}.gibberapp.online') return entry.value;
    }
    for (final entry in _byPrefixes.entries) {
      if (d == '${entry.key}.gibberapp.online') return entry.value;
    }
    if (loose) {
      final first = d.split('.').first;
      for (final entry in _aliasedPrefixes.entries) {
        if (first == entry.key) return entry.value;
      }
      for (final entry in _byPrefixes.entries) {
        if (first == entry.key) return entry.value;
      }
    }
    return null;
  }

  static const metaByProtocol = <String, GatewayProtocolMeta>{
    'WhatsApp': GatewayProtocolMeta(
      protocol: 'WhatsApp',
      name: 'WhatsApp',
      icon: Icons.chat_rounded,
      color: Color(0xFF25D366),
      usesQrPairing: true,
    ),
    'Telegram': GatewayProtocolMeta(
      protocol: 'Telegram',
      name: 'Telegram',
      icon: Icons.send_rounded,
      color: Color(0xFF26A5E4),
    ),
    'Discord': GatewayProtocolMeta(
      protocol: 'Discord',
      name: 'Discord',
      icon: Icons.forum_rounded,
      color: Color(0xFF5865F2),
    ),
    'Matrix': GatewayProtocolMeta(
      protocol: 'Matrix',
      name: 'Matrix',
      icon: Icons.grid_view_rounded,
      color: Color(0xFF0DBD8B),
    ),
    'IRC': GatewayProtocolMeta(
      protocol: 'IRC',
      name: 'IRC',
      icon: Icons.tag_rounded,
      color: Color(0xFF7B68EE),
    ),
    'Steam': GatewayProtocolMeta(
      protocol: 'Steam',
      name: 'Steam',
      icon: Icons.sports_esports_rounded,
      color: Color(0xFF66C0F4),
    ),
  };

  /// Icon/color/display metadata for a contact JID (falls back to [fallbackColor]
  /// when the jid does not belong to a gateway).
  static IconData iconForJid(String? jid,
      {String? ownDomain, IconData fallback = Icons.person_rounded}) =>
      metaByProtocol[protocolForJid(jid, ownDomain: ownDomain)]?.icon ?? fallback;

  static Color colorForJid(String? jid,
      {String? ownDomain, Color fallback = const Color(0xFF8B5CF6)}) =>
      metaByProtocol[protocolForJid(jid, ownDomain: ownDomain)]?.color ?? fallback;
}