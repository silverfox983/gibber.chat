import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

import 'package:gibber/models/transport_models.dart';
import 'package:gibber/services/transport_service.dart';

xmpp.XmppElement _el(String name, {String? xmlns, Map<String, String> attrs = const {}}) {
  final e = xmpp.XmppElement()
    ..name = name
    ..addAttribute(xmpp.XmppAttribute('xmlns', xmlns));
  attrs.forEach((k, v) => e.addAttribute(xmpp.XmppAttribute(k, v)));
  return e;
}

xmpp.MessageStanza _message({String? body, xmpp.XmppElement? child, required String fromJid}) {
  final m = xmpp.MessageStanza(
    'msg_${DateTime.now().millisecondsSinceEpoch}',
    xmpp.MessageStanzaType.CHAT,
  );
  m.fromJid = xmpp.Jid.fromFullJid(fromJid);
  if (body != null) {
    m.addChild(_el('body')..textValue = body);
  }
  if (child != null) {
    m.addChild(child);
  }
  return m;
}

void main() {
  group('parsePairingMessage', () {
    test('emits qr event from oob url data', () {
      final oob = _el('x', xmlns: 'jabber:x:oob');
      final url = _el('url')..textValue = 'http://gibberapp.online:5280/upload/uuid/qr.png';
      oob.addChild(url);
      final msg = _message(
        body: 'Scan this QR code to pair your WhatsApp',
        child: oob,
        fromJid: 'whatsapp.gibberapp.online',
      );

      final event = TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online');

      expect(event, isNotNull);
      expect(event!.isQr, isTrue);
      expect(event.oobUrl, contains('/upload/'));
      expect(event.text, contains('Scan'));
    });

    test('parses XEP-0446/0447 stateless file sharing QR (reference uri)', () {
      final sources = _el('sources');
      final ref = _el('reference', xmlns: 'urn:xmpp:reference:0')
        ..addAttribute(xmpp.XmppAttribute('type', 'data'))
        ..addAttribute(xmpp.XmppAttribute('uri', 'https://gibberapp.online:5281/upload/slotx/qr.png'));
      sources.addChild(ref);

      final msg = _message(body: 'Scan the QR', child: sources, fromJid: 'whatsapp.gibberapp.online');
      final ev = TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online');
      expect(ev, isNotNull);
      expect(ev!.isQr, isTrue);
      expect(ev.oobUrl, 'https://gibberapp.online:5281/upload/slotx/qr.png');
      expect(ev.text, 'Scan the QR');
    });

    test('parses url-data target fallback', () {
      final sources = _el('sources');
      final urlData = _el('url-data', xmlns: 'http://jabber.org/protocol/url-data')
        ..addAttribute(xmpp.XmppAttribute('target', 'https://gibberapp.online:5281/upload/sloty/qr2.png'));
      sources.addChild(urlData);

      final msg = _message(child: sources, fromJid: 'whatsapp.gibberapp.online');
      final ev = TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online');
      expect(ev!.isQr, isTrue);
      expect(ev.oobUrl, 'https://gibberapp.online:5281/upload/sloty/qr2.png');
    });

    test('emits form event from a jabber:x:data form message', () {
      final x = _el('x', xmlns: 'jabber:x:data');
      x.addAttribute(xmpp.XmppAttribute('type', 'form'));
      final field = xmpp.XmppElement()
        ..name = 'field'
        ..addAttribute(xmpp.XmppAttribute('var', 'code'))
        ..addAttribute(xmpp.XmppAttribute('type', 'text-single'))
        ..addAttribute(xmpp.XmppAttribute('label', 'Login code'));
      x.addChild(field);
      final msg = _message(child: x, fromJid: 'telegram.gibberapp.online');

      final event = TransportService.parsePairingMessage(msg, 'telegram.gibberapp.online');

      expect(event, isNotNull);
      expect(event!.kind, 'form');
      expect(event.form, isNotNull);
      expect(event.form!.fields.single.varName, 'code');
    });

    test('emits success event on paired phrasing', () {
      final msg = _message(
        body: 'You are logged in as +15551234567. You can close this page.',
        fromJid: 'whatsapp.gibberapp.online',
      );

      final event = TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online');

      expect(event, isNotNull);
      expect(event!.isSuccess, isTrue);
    });

    test('emits text event for other gateway status messages', () {
      final msg = _message(
        body: 'Waiting for you to link the device.',
        fromJid: 'whatsapp.gibberapp.online',
      );

      final event = TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online');
      expect(event!.kind, 'text');
    });

    test('returns null for empty component messages', () {
      final msg = _message(fromJid: 'whatsapp.gibberapp.online');
      expect(TransportService.parsePairingMessage(msg, 'whatsapp.gibberapp.online'), isNull);
    });
  });

  group('parseComponentItems', () {
    test('extracts chats with local parts and skips component-level items', () {
      final iq = xmpp.IqStanza('items', xmpp.IqStanzaType.RESULT);
      final query = _el('query', xmlns: 'http://jabber.org/protocol/disco#items');
      final roomItem = _el('item')
        ..addAttribute(xmpp.XmppAttribute('jid', 'general@discord.gibberapp.online'))
        ..addAttribute(xmpp.XmppAttribute('name', '#general'));
      final adHocItem = _el('item')
        ..addAttribute(xmpp.XmppAttribute('jid', 'discord.gibberapp.online'))
        ..addAttribute(xmpp.XmppAttribute('node', 'pair-phone'));
      query.addChild(roomItem);
      query.addChild(adHocItem);
      iq.addChild(query);

      final chats = TransportService.parseComponentItems(iq);
      expect(chats, hasLength(1));
      expect(chats.single.jid, 'general@discord.gibberapp.online');
      expect(chats.single.name, '#general');
    });

    test('ignores error responses', () {
      final iq = xmpp.IqStanza('items', xmpp.IqStanzaType.ERROR);
      expect(TransportService.parseComponentItems(iq), isEmpty);
    });
  });

  group('parsed forms', () {
    test('isEmptyForm detects instruction-only WhatsApp form', () {
      final form = TransportRegistrationForm(
        isRegistered: false,
        instructions: 'Scan the QR',
        fields: const [],
      );
      expect(form.isEmptyForm, isTrue);
    });
  });
}