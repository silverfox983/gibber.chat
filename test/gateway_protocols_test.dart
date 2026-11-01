import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/gateway_protocols.dart';

void main() {
  test('maps gateway contact jids to bridged protocols', () {
    expect(
      GatewayProtocols.protocolForJid('12025550123@whatsapp.gibberapp.online'),
      'WhatsApp',
    );
    expect(
      GatewayProtocols.protocolForJid('453211234@telegram.gibberapp.online'),
      'Telegram',
    );
    expect(
      GatewayProtocols.protocolForJid('87654321@discord.gibberapp.online'),
      'Discord',
    );
    expect(
      GatewayProtocols.protocolForJid('alice:example.org@matrix.gibberapp.online'),
      'Matrix',
    );
    expect(
      GatewayProtocols.protocolForJid('%libera.chat@irc.gibberapp.online'),
      'IRC',
    );
  });

  test('maps alternative slidge subdomains', () {
    expect(
      GatewayProtocols.protocolForJid('123@slidgram.gibberapp.online'),
      'Telegram',
    );
    expect(
      GatewayProtocols.protocolForJid('123@slidcord.gibberapp.online'),
      'Discord',
    );
    expect(
      GatewayProtocols.protocolForJid('123@matridge.gibberapp.online'),
      'Matrix',
    );
    expect(
      GatewayProtocols.protocolForJid('123@slidge-whatsapp.gibberapp.online'),
      'WhatsApp',
    );
  });

  test('loose match requires the jid to be on the local deployment domain', () {
    // A custom host: only maps when ownDomain matches the domain suffix.
    expect(
      GatewayProtocols.protocolForJid('123@whatsapp.myselfhosted.org',
          ownDomain: 'myselfhosted.org'),
      'WhatsApp',
    );
    // A federated matrix contact must NOT be classified as a gateway contact.
    expect(
      GatewayProtocols.protocolForJid('someuser@matrix.org',
          ownDomain: 'gibberapp.online'),
      isNull,
    );
    // And a plain internal user stays XMPP.
    expect(GatewayProtocols.protocolForJid('bob@gibberapp.online'), isNull);
  });

  test('maps bare component domains but not unrelated servers', () {
    expect(GatewayProtocols.protocolForJid('whatsapp.gibberapp.online'), 'WhatsApp');
    expect(GatewayProtocols.protocolForJid('conference.gibberapp.online'), isNull);
    expect(GatewayProtocols.protocolForJid('pubsub.gibberapp.online'), isNull);
    expect(GatewayProtocols.protocolForJid(null), isNull);
    expect(GatewayProtocols.protocolForJid(''), isNull);
  });

  test('metadata exists for each mapped protocol', () {
    for (final p in ['WhatsApp', 'Telegram', 'Discord', 'Matrix', 'IRC']) {
      expect(GatewayProtocols.metaByProtocol[p], isNotNull, reason: 'meta for $p');
      expect(GatewayProtocols.metaByProtocol[p]!.icon, isNotNull);
    }
    expect(
      GatewayProtocols.metaByProtocol['WhatsApp']!.usesQrPairing,
      isTrue,
    );
  });
}