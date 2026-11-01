import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/utils/pstn_gateway.dart';

void main() {
  group('isPstnGatewayJid', () {
    test('known gateway domains', () {
      expect(isPstnGatewayJid('+1234567890@cheogram.com'), isTrue);
      expect(isPstnGatewayJid('gateway@sip2jabber.org'), isTrue);
      expect(isPstnGatewayJid('room@conference.jit.si'), isTrue);
      expect(isPstnGatewayJid('user@jabber.ccc.de'), isTrue);
      expect(isPstnGatewayJid('trunk@pstn.example.com'), isTrue);
    });

    test('phone-number local parts', () {
      expect(isPstnGatewayJid('+15551234567@some-gw.example.com'), isTrue);
      expect(isPstnGatewayJid('1555-123-4567@sip.example.com'), isTrue);
      expect(isPstnGatewayJid('+15551234567'), isFalse,
          reason: 'needs a resource @domain');
    });

    test('regular XMPP JIDs are not gateways', () {
      expect(isPstnGatewayJid('alice@example.com'), isFalse);
      expect(isPstnGatewayJid('room@conference.example.com'), isFalse);
      expect(isPstnGatewayJid(''), isFalse);
    });

    test('case-insensitive domain match', () {
      expect(isPstnGatewayJid('USER@CHEOGRAM.COM'), isTrue);
    });
  });
}