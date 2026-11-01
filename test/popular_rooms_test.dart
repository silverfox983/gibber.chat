import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/popular_room.dart';
import 'package:gibber/services/popular_rooms_parser.dart';

const String _netsplitFixture = '''
#linux Libera.Chat
Chat Room - 2350 users -
73 minutes ago -
current topic: Welcome to #linux! New community Code of Conduct -- Need an op? !ops
category: Linux -
network: Libera.Chat

#polska IRCnet
Chat Room - 1265 users -
68 minutes ago -
current topic: :: Daily News :: ig0r: daily feed
category: Poland -
network: IRCnet

##rust Libera.Chat
Chat Room - 1007 users -
73 minutes ago -
current topic: Unofficial channel for the Rust programming language
category: Rust -
network: Libera.Chat

#KualaLumpur SkyChatz
Chat Room - 2419 users -
61 minutes ago -
current topic:  |[ Welcome ]| to #KualaLumpur @ SkyChatz.Org
category: Kuala Lumpur -
network: SkyChatz

#hub SkyChatz
Chat Room - 925 users -
61 minutes ago -
current topic: [ Status ] : Online

network: SkyChatz
''';

void main() {
  group('parseNetsplitPopular', () {
    test('parses channels, networks and users', () {
      final rooms = parseNetsplitPopular(_netsplitFixture);
      expect(rooms, hasLength(5));
      expect(rooms.first.channel, '#linux');
      expect(rooms.first.network, 'Libera.Chat');
      expect(rooms.first.users, 2350);
      expect(rooms.first.topic, contains('Welcome to #linux'));
      expect(rooms.first.category, 'Linux');
    });

    test('handles double-hash channels', () {
      final rooms = parseNetsplitPopular(_netsplitFixture);
      final rust = rooms.firstWhere((r) => r.channel == '##rust');
      expect(rust.network, 'Libera.Chat');
      expect(rust.users, 1007);
    });

    test('entries without stats are dropped, later network line wins', () {
      final rooms = parseNetsplitPopular(_netsplitFixture);
      final hub = rooms.firstWhere((r) => r.channel == '#hub');
      expect(hub.network, 'SkyChatz');
      expect(hub.users, 925);
    });

    test('returns empty list for garbage input', () {
      expect(parseNetsplitPopular(''), isEmpty);
      expect(parseNetsplitPopular('random text\nmore text'), isEmpty);
    });

    test('live-data sanity gate (matches service rules)', () {
      final rooms = parseNetsplitPopular(_netsplitFixture);
      final passesGate =
          rooms.length >= 10 && rooms.every((r) => r.users > 0 && r.network.isNotEmpty);
      // The fixture is intentionally small; a live page must produce >=10.
      expect(passesGate, isFalse);
      expect(rooms.every((r) => r.users > 0), isTrue);
    });
  });

  group('parseNetsplitSnapshot', () {
    test('parses bundled JSON shape', () {
      const jsonStr = '''
{
  "source": "test",
  "rooms": [
    {"channel": "#linux", "network": "Libera.Chat", "users": 2350, "category": "Linux", "topic": "Welcome"},
    {"channel": "", "network": "Bad", "users": 10},
    {"channel": "#polska", "network": "IRCnet", "users": 1265}
  ]
}''';
      final rooms = parseNetsplitSnapshot(jsonStr);
      expect(rooms, hasLength(2));
      expect(rooms.first.displayName, 'linux');
      expect(rooms.last.users, 1265);
    });

    test('tolerates malformed JSON by returning empty', () {
      expect(parseNetsplitSnapshot('not-json'), isEmpty);
    });
  });

  test('PopularRoom.fromJson defaults', () {
    final room = PopularRoom.fromJson({});
    expect(room.channel, '');
    expect(room.users, 0);
    expect(room.displayName, '');
  });
}