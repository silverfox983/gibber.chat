import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

/// Live probe of the slidge gateways' registration/adhoc flows.
///
/// Opt-in: LIVE_STACK=1. Prints raw XML for registration forms, adhoc command
/// discovery (XEP-0050 on own bare jid), the WhatsApp pair-phone start, the
/// QR/status messages captured after a WhatsApp submit, and the roster.
const _api = 'http://127.0.0.1:8080';
const _xmppHost = '127.0.0.1';
const _xmppPort = 5222;
const _domain = 'gibberapp.online';
const _components = [
  'whatsapp.gibberapp.online',
  'telegram.gibberapp.online',
  'discord.gibberapp.online',
  'matrix.gibberapp.online',
];

String _trunc(String s, [int max = 1400]) =>
    s.length <= max ? s : '${s.substring(0, max)}...<${s.length - max} more>';

xmpp.XmppElement _queryEl(String xmlns) {
  final q = xmpp.XmppElement()
    ..name = 'query'
    ..addAttribute(xmpp.XmppAttribute('xmlns', xmlns));
  return q;
}

Future<xmpp.IqStanza> _sendIq(xmpp.Connection conn, xmpp.IqStanza iq) async {
  final id = iq.id;
  final completer = Completer<xmpp.IqStanza>();
  final sub = conn.inStanzasStream.listen((stanza) {
    if (stanza is xmpp.IqStanza && stanza.id == id && !completer.isCompleted) {
      completer.complete(stanza);
    }
  });
  conn.writeStanza(iq);
  try {
    return await completer.future.timeout(const Duration(seconds: 12));
  } finally {
    await sub.cancel();
  }
}

Future<xmpp.IqStanza> _adhocStart(
  xmpp.Connection conn,
  String component,
  String node,
) async {
  final iq = xmpp.IqStanza('cmd_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  iq.toJid = xmpp.Jid.fromFullJid(component);
  final cmd = xmpp.XmppElement()
    ..name = 'command'
    ..addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/commands'))
    ..addAttribute(xmpp.XmppAttribute('node', node))
    ..addAttribute(xmpp.XmppAttribute('action', 'execute'));
  iq.addChild(cmd);
  return _sendIq(conn, iq);
}

Future<void> main() async {
  if (Platform.environment['LIVE_STACK'] != '1') {
    // ignore: avoid_print
    print('SKIP: LIVE_STACK != 1');
    return;
  }

  final username =
      'probe${DateTime.now().millisecondsSinceEpoch % 100000000}${Random().nextInt(90) + 10}';
  final password = 'S${username}xyzpass';

  final reg = await http.post(
    Uri.parse('$_api/register'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'username': username, 'password': password, 'host': _domain}),
  ).timeout(const Duration(seconds: 20));
  // ignore: avoid_print
  print('REG: ${reg.statusCode}');

  final account = xmpp.XmppAccountSettings.fromJid('$username@$_domain', password);
  account.host = _xmppHost;
  account.port = _xmppPort;
  account.totalReconnections = 1;

  final conn = xmpp.Connection(account);
  final ready = Completer<void>();
  conn.connectionStateStream.listen((state) {
    if (state == xmpp.XmppConnectionState.Ready && !ready.isCompleted) {
      ready.complete();
    }
  });
  conn.connect();
  await ready.future.timeout(const Duration(seconds: 20));
  // Broadcast presence so component messages route live to this session.
  final initialPresence = xmpp.PresenceStanza();
  initialPresence.toJid = xmpp.Jid.fromFullJid('$username@$_domain');
  conn.writeStanza(initialPresence);
  // ignore: avoid_print
  print('CONNECTED: $username@$_domain');

  final captured = <String>[];
  final msgSub = conn.inStanzasStream.listen((abstract) {
    if (abstract == null) return;
    final from = abstract.fromJid?.userAtDomain ?? '';
    if (from.isEmpty) return;
    for (final comp in _components) {
      if (from == comp) {
        captured.add('${abstract.runtimeType} FROM=$from\n${_trunc(abstract.buildXmlString() ?? '')}');
        break;
      }
    }
  });

  // --- 1. XEP-0050 command discovery on our own bare jid -------------------
  final ownIq = xmpp.IqStanza('own_items_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  ownIq.toJid = xmpp.Jid.fromFullJid('$username@$_domain');
  ownIq.addChild(_queryEl('http://jabber.org/protocol/disco#items'));
  try {
    final res = await _sendIq(conn, ownIq);
    // ignore: avoid_print
    print('\n=== OWN DISCO ITEMS (adhoc command list) ===\n${_trunc(res.buildXmlString() ?? '', 4000)}');
  } catch (e) {
    // ignore: avoid_print
    print('OWN ITEMS FAILED: $e');
  }

  // --- 2. WhatsApp: submit empty registration (form from GET, no fields) --
  final waGet = xmpp.IqStanza('reg_get_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  waGet.toJid = xmpp.Jid.fromFullJid('whatsapp.gibberapp.online');
  waGet.addChild(_queryEl('jabber:iq:register'));
  await _sendIq(conn, waGet);

  final waIq = xmpp.IqStanza('reg_set_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  waIq.toJid = xmpp.Jid.fromFullJid('whatsapp.gibberapp.online');
  final x = xmpp.XmppElement()
    ..name = 'x'
    ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
    ..addAttribute(xmpp.XmppAttribute('type', 'submit'));
  final ftField = xmpp.XmppElement()
    ..name = 'field'
    ..addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'))
    ..addAttribute(xmpp.XmppAttribute('type', 'hidden'));
  final ftVal = xmpp.XmppElement()..name = 'value'..textValue = 'jabber:iq:register';
  ftField.addChild(ftVal);
  x.addChild(ftField);
  final q = _queryEl('jabber:iq:register');
  q.addChild(x);
  waIq.addChild(q);
  try {
    final res = await _sendIq(conn, waIq);
    // ignore: avoid_print
    print('\n=== WHATSAPP SUBMIT ===\n${_trunc(res.buildXmlString() ?? '')}');
  } catch (e) {
    // ignore: avoid_print
    print('WHATSAPP SUBMIT FAILED: $e');
  }

  // --- 3. Wait ~80s for QR/status messages to arrive -----------------------
  await Future.delayed(const Duration(seconds: 80));
  // ignore: avoid_print
  print('\n=== CAPTURED FROM COMPONENTS (${captured.length}) ===');
  for (final c in captured.take(12)) {
    // ignore: avoid_print
    print('---\n$c');
  }

  // --- 3b. Fresh submit → wait → capture oob ------------------------------
  final wa2 = xmpp.IqStanza('reg_set2_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  wa2.toJid = xmpp.Jid.fromFullJid('whatsapp.gibberapp.online');
  final x2 = xmpp.XmppElement()
    ..name = 'x'
    ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
    ..addAttribute(xmpp.XmppAttribute('type', 'submit'));
  final ft2 = xmpp.XmppElement()
    ..name = 'field'
    ..addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'))
    ..addAttribute(xmpp.XmppAttribute('type', 'hidden'));
  final ft2v = xmpp.XmppElement()..name = 'value'..textValue = 'jabber:iq:register';
  ft2.addChild(ft2v);
  x2.addChild(ft2);
  final q2 = _queryEl('jabber:iq:register');
  q2.addChild(x2);
  wa2.addChild(q2);
  try {
    final res = await _sendIq(conn, wa2);
    // ignore: avoid_print
    print('\n=== WHATSAPP SUBMIT 2 ===\n${_trunc(res.buildXmlString() ?? '')}');
    await Future.delayed(const Duration(seconds: 45));
    // ignore: avoid_print
    print('\n=== CAPTURED 2 (${captured.length}) ===');
    for (final c in captured.take(12)) {
      // ignore: avoid_print
      print('---\n$c');
    }
  } catch (e) {
    // ignore: avoid_print
    print('WA SUBMIT 2 FAILED: $e');
  }

  // --- 3c. adhoc node candidates + tg iq set -------------------------------
  for (final node in ['jabber:iq:gateway:none', 'registration', 'gateway', 'none']) {
    try {
      final res = await _adhocStart(conn, 'telegram.gibberapp.online', node);
      // ignore: avoid_print
      print('\n=== TG ADHOC $node ===\n${_trunc(res.buildXmlString() ?? '', 1000)}');
    } catch (e) {
      // ignore: avoid_print
      print('TG ADHOC $node FAILED: $e');
    }
  }
  final tgIq = xmpp.IqStanza('tgset_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  tgIq.toJid = xmpp.Jid.fromFullJid('telegram.gibberapp.online');
  final tgq = _queryEl('jabber:iq:register');
  final ph = xmpp.XmppElement()..name = 'phone'..textValue = '+15551234567';
  tgq.addChild(ph);
  tgIq.addChild(tgq);
  try {
    final res = await _sendIq(conn, tgIq);
    // ignore: avoid_print
    print('\n=== TG IQ SET phone ===\n${_trunc(res.buildXmlString() ?? '', 1000)}');
  } catch (e) {
    // ignore: avoid_print
    print('TG IQ SET FAILED: $e');
  }

  // --- 4. Adhoc command discovery per component (disco features) -----------
  for (final comp in _components) {
    final diq = xmpp.IqStanza('di_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    diq.toJid = xmpp.Jid.fromFullJid(comp);
    diq.addChild(_queryEl('http://jabber.org/protocol/disco#info'));
    try {
      final res = await _sendIq(conn, diq);
      final xml = res.buildXmlString() ?? '';
      final hasCommands = xml.contains('http://jabber.org/protocol/commands');
      // ignore: avoid_print
      print('\n=== DISCO INFO $comp (supports commands: $hasCommands) ===\n${_trunc(xml, 1200)}');
    } catch (e) {
      // ignore: avoid_print
      print('DISCO INFO $comp FAILED: $e');
    }
  }

  // --- 5. Try executing adhoc commands on the components -------------------
  try {
    final res = await _adhocStart(conn, 'telegram.gibberapp.online', 'register');
    // ignore: avoid_print
    print('\n=== TELEGRAM REGISTER (adhoc execute) ===\n${_trunc(res.buildXmlString() ?? '')}');
  } catch (e) {
    // ignore: avoid_print
    print('TG REGISTER FAILED: $e');
  }
  try {
    final res = await _adhocStart(conn, 'telegram.gibberapp.online', 'login');
    // ignore: avoid_print
    print('\n=== TELEGRAM LOGIN (adhoc execute) ===\n${_trunc(res.buildXmlString() ?? '')}');
  } catch (e) {
    // ignore: avoid_print
    print('TG LOGIN FAILED: $e');
  }
  try {
    final res = await _adhocStart(conn, 'whatsapp.gibberapp.online', 'pair-phone');
    // ignore: avoid_print
    print('\n=== WA PAIR-PHONE (adhoc execute) ===\n${_trunc(res.buildXmlString() ?? '')}');
  } catch (e) {
    // ignore: avoid_print
    print('WA PAIR-PHONE FAILED: $e');
  }

  // Roster snapshot
  final rosterIq = xmpp.IqStanza('roster_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  rosterIq.addChild(_queryEl('jabber:iq:roster'));
  try {
    final res = await _sendIq(conn, rosterIq);
    // ignore: avoid_print
    print('\n=== ROSTER AFTER WHATSAPP SUBMIT ===\n${_trunc(res.buildXmlString() ?? '', 1800)}');
  } catch (e) {
    // ignore: avoid_print
    print('ROSTER FAILED: $e');
  }

  await msgSub.cancel();
  conn.close();
  // ignore: avoid_print
  print('PROBE DONE');
  return;
}

String runtimeTypeOf(xmpp.AbstractStanza s) => s.runtimeType.toString();

