/// Where the user wants to go right after authenticating.
///
/// Encoded into the `room` query parameter of the join-room route:
/// `<urlencoded-channel>|<urlencoded-network>`. The network part may be empty.
class JoinIntent {
  final String channel;
  final String? network;

  const JoinIntent({required this.channel, this.network});

  static const _separator = '|';

  factory JoinIntent.forRoom({required String channel, String? network}) {
    return JoinIntent(
      channel: channel.startsWith('#') ? channel : '#$channel',
      network: (network == null || network.isEmpty) ? null : network,
    );
  }

  /// Parses a `channel|network` encoded payload; returns null when malformed.
  static JoinIntent? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parts = raw.split(_separator);
    if (parts.isEmpty || parts.length > 2) return null;
    try {
      final channel = Uri.decodeComponent(parts[0]).trim();
      if (channel.isEmpty) return null;
      final network =
          parts.length > 1 ? Uri.decodeComponent(parts[1]).trim() : '';
      return JoinIntent(
        channel: channel.startsWith('#') ? channel : '#$channel',
        network: network.isEmpty ? null : network,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() {
    final enc = Uri.encodeComponent;
    return '${enc(channel)}$_separator${enc(network ?? '')}';
  }

  /// Room JID on an IRC gateway component (`#linux@irc.example.com`).
  String roomJid(String gatewayComponentJid) =>
      '$channel@${gatewayComponentJid.split('/').first}';
}