import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/visitor_service.dart';

void main() {
  group('VisitorService credentials', () {
    test('guest usernames are jid-safe and unique-ish', () {
      for (var i = 0; i < 50; i++) {
        final u = VisitorService.guestUsername();
        expect(u, startsWith('guest'));
        expect(u.length, 15, reason: 'guest + 10 chars');
        expect(RegExp(r'^[a-z0-9]+$').hasMatch(u), isTrue,
            reason: 'must be valid in XMPP localpart: $u');
      }
      final seen = <String>{};
      for (var i = 0; i < 30; i++) {
        seen.add(VisitorService.guestUsername());
      }
      expect(seen.length, greaterThan(20), reason: 'random suffix should differ');
    });

    test('guest passwords are alphanumeric and long', () {
      for (var i = 0; i < 20; i++) {
        final p = VisitorService.guestPassword();
        expect(p.length, 24);
        expect(RegExp(r'^[a-z0-9]+$').hasMatch(p), isTrue,
            reason: 'XML/JSON-in-band friendly: $p');
      }
    });
  });
}