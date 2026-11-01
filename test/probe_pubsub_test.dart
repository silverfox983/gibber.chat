import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

const _api = 'http://127.0.0.1:8080';
const _domain = 'gibberapp.online';

xmpp.XmppElement _q(String xmlns, [String name = 'query']) {
  return xmpp.XmppElement()
    ..name = name
    ..addAttribute(xmpp.XmppAttribute('xmlns', xmlns));
}

Future<xmpp.IqStanza> _sendIq(xmpp.Connection conn, xmpp.IqStanza iq) async {
  final completer = Completer<xmpp.IqStanza>();
  final sub = conn.inStanzasStream.listen((s) {
    if (s is xmpp.IqStanza && s.id == iq.id && !completer.isCompleted) {
      completer.complete(s);
    }
  });
  conn.writeStanza(iq);
  try {
    return await completer.future.timeout(const Duration(seconds: 12));
  } finally {
    await sub.cancel();
  }
}

Future<void> main() async {
  if (Platform.environment['LIVE_STACK'] != '1') {
    // ignore: avoid_print
    print('SKIP: LIVE_STACK != 1');
    return;
  }
  final username =
      'probe${DateTime.now().millisecondsSinceEpoch % 100000000}${Random().nextInt(90) + 10}';
  final password = 'S$username-pw';

  await http.post(
    Uri.parse('$_api/register'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'username': username, 'password': password, 'host': _domain}),
  ).timeout(const Duration(seconds: 20));

  final account = xmpp.XmppAccountSettings.fromJid('$username@$_domain', password);
  account.host = '127.0.0.1';
  account.port = 5222;
  final conn = xmpp.Connection(account);
  final ready = Completer<void>();
  conn.connectionStateStream.listen((s) {
    if (s == xmpp.XmppConnectionState.Ready && !ready.isCompleted) ready.complete();
  });
  conn.connect();
  await ready.future.timeout(const Duration(seconds: 20));

  // 1. Default node config form (XEP-0060 8.1.2)
  final defIq = xmpp.IqStanza('def_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  defIq.toJid = xmpp.Jid.fromFullJid('pubsub.$_domain');
  final po = _q('http://jabber.org/protocol/pubsub#owner', 'pubsub');
  po.addChild(xmpp.XmppElement()..name = 'default');
  defIq.addChild(po);
  final res1 = await _sendIq(conn, defIq);
  // ignore: avoid_print
  print('=== USER DEFAULT FORM ===');
  // ignore: avoid_print
  print(res1.buildXmlString());

  // 2. Node-level config form shape: create a node, then GET its config form
  final node = 'cfgprobe${DateTime.now().millisecondsSinceEpoch % 100000}';
  final createIq = xmpp.IqStanza('c_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  createIq.toJid = xmpp.Jid.fromFullJid('pubsub.$_domain');
  final ps = _q('http://jabber.org/protocol/pubsub', 'pubsub');
  ps.addChild(xmpp.XmppElement()
    ..name = 'create'
    ..addAttribute(xmpp.XmppAttribute('node', node)));
  createIq.addChild(ps);
  final res2 = await _sendIq(conn, createIq);
  // ignore: avoid_print
  print('=== CREATE $node ===');
  // ignore: avoid_print
  print(res2.buildXmlString());

  final cfgGet = xmpp.IqStanza('cfg_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  cfgGet.toJid = xmpp.Jid.fromFullJid('pubsub.$_domain');
  final po2 = _q('http://jabber.org/protocol/pubsub#owner', 'pubsub');
  final cfg = xmpp.XmppElement()..name = 'configure';
  cfg.addAttribute(xmpp.XmppAttribute('node', node));
  po2.addChild(cfg);
  cfgGet.addChild(po2);
  final res3 = await _sendIq(conn, cfgGet);
  // ignore: avoid_print
  print('=== NODE CONFIG FORM ===');
  // ignore: avoid_print
  print(res3.buildXmlString());

  // 3. Disco#info on the node (what our metadata discovery reads)
  final ddIq = xmpp.IqStanza('di_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  ddIq.toJid = xmpp.Jid.fromFullJid('$node@pubsub.$_domain');
  ddIq.addChild(_q('http://jabber.org/protocol/disco#info'));
  final res4 = await _sendIq(conn, ddIq);
  // ignore: avoid_print
  print('=== NODE DISCO INFO ===');
  // ignore: avoid_print
  print(res4.buildXmlString());

  // 4. Configure: trimmed form with prosody-correct booleans (1/0)
  final setIq = xmpp.IqStanza('cfgset_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.SET);
  setIq.toJid = xmpp.Jid.fromFullJid('pubsub.$_domain');
  final po3 = _q('http://jabber.org/protocol/pubsub#owner', 'pubsub');
  final cfgSet = xmpp.XmppElement()..name = 'configure';
  cfgSet.addAttribute(xmpp.XmppAttribute('node', node));
  final xSubmit = xmpp.XmppElement()
    ..name = 'x'
    ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'))
    ..addAttribute(xmpp.XmppAttribute('type', 'submit'));
  void addField(String varName, String value, {String? type}) {
    final f = xmpp.XmppElement()..name = 'field';
    f.addAttribute(xmpp.XmppAttribute('var', varName));
    if (type != null) f.addAttribute(xmpp.XmppAttribute('type', type));
    xSubmit.addChild(f);
    if (value.isNotEmpty) {
      final v = xmpp.XmppElement()..name = 'value';
      v.textValue = value;
      f.addChild(v);
    }
  }

  addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config', type: 'hidden');
  addField('pubsub#title', 'Probe Space Title');
  addField('pubsub#description', 'Configured title probe');
  addField('pubsub#access_model', 'open');
  addField('pubsub#publish_model', 'publishers');
  addField('pubsub#type', 'urn:xmpp:spaces:0');
  addField('pubsub#persist_items', '1');
  addField('pubsub#max_items', '10000');
  addField('pubsub#deliver_notifications', '1');
  addField('pubsub#deliver_payloads', '1');
  addField('pubsub#notify_retract', '1');
  addField('pubsub#notify_delete', '1');
  addField('pubsub#itemreply', 'publisher');
  cfgSet.addChild(xSubmit);
  po3.addChild(cfgSet);
  setIq.addChild(po3);
  final res5 = await _sendIq(conn, setIq);
  // ignore: avoid_print
  print('=== CONFIGURE RESULT ===');
  // ignore: avoid_print
  print(res5.buildXmlString());

  // 5. Read the metadata back through disco
  final diq2 = xmpp.IqStanza('di2_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  diq2.toJid = xmpp.Jid.fromFullJid('$node%pubsub.$_domain@spaces.$_domain');
  diq2.addChild(_q('http://jabber.org/protocol/disco#info'));
  try {
    final res6 = await _sendIq(conn, diq2);
    // ignore: avoid_print
    print('=== NODE DISCO (spaces service) ===');
    // ignore: avoid_print
    print(res6.buildXmlString());
  } catch (e) {
    // ignore: avoid_print
    print('spaces disco failed: $e');
  }
  final diq3 = xmpp.IqStanza('di3_${DateTime.now().millisecondsSinceEpoch}', xmpp.IqStanzaType.GET);
  diq3.toJid = xmpp.Jid.fromFullJid('$node@pubsub.$_domain');
  diq3.addChild(_q('http://jabber.org/protocol/disco#info'));
  try {
    final res7 = await _sendIq(conn, diq3);
    // ignore: avoid_print
    print('=== NODE DISCO (pubsub service) ===');
    // ignore: avoid_print
    print(res7.buildXmlString());
  } catch (e) {
    // ignore: avoid_print
    print('pubsub disco failed: $e');
  }

  conn.close();
}