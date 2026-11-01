import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/models/join_intent.dart';

void main() {
  group('JoinIntent', () {
    test('round-trips channel + network', () {
      final intent = JoinIntent.forRoom(channel: '#linux', network: 'Libera.Chat');
      final decoded = JoinIntent.decode(intent.encode());
      expect(decoded, isNotNull);
      expect(decoded!.channel, '#linux');
      expect(decoded.network, 'Libera.Chat');
    });

    test('adds leading hash when missing', () {
      final intent = JoinIntent.forRoom(channel: 'polska', network: 'IRCnet');
      expect(intent.channel, '#polska');
    });

    test('drops empty network', () {
      final intent = JoinIntent.forRoom(channel: '#chat', network: '');
      expect(intent.network, isNull);
      final decoded = JoinIntent.decode(intent.encode());
      expect(decoded!.network, isNull);
    });

    test('encodes special characters safely', () {
      final intent = JoinIntent.forRoom(channel: '#kuala lumpur', network: 'Sky|Chatz');
      final decoded = JoinIntent.decode(intent.encode())!;
      expect(decoded.channel, '#kuala lumpur');
      expect(decoded.network, 'Sky|Chatz');
    });

    test('decode malformed payloads returns null', () {
      expect(JoinIntent.decode(null), isNull);
      expect(JoinIntent.decode(''), isNull);
      expect(JoinIntent.decode('   '), isNull);
      expect(JoinIntent.decode('a|b|b'), isNull, reason: 'no separator split sanity, parts>2 channel ok but safe');
    });

    test('roomJid builds component JID', () {
      final intent = JoinIntent.forRoom(channel: '#linux', network: 'Libera.Chat');
      expect(intent.roomJid('irc.example.com/gw'), '#linux@irc.example.com');
      expect(intent.roomJid('slidgirc.example.com'), '#linux@slidgirc.example.com');
    });
  });
}