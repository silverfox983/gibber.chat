import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'auth_service_deps.dart';

class XmppSyncService {
  final AuthServiceSyncDeps _d;

  XmppSyncService(this._d);

  Future<List<Map<String, String>>> searchUsers(
    String query, {
    String? accountId,
    String? searchHost,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) throw Exception('Not connected');

    final host = searchHost ?? 'search.${_d.xmppJids[id]?.split('@').last}';
    final stanzaId = 'search_${DateTime.now().millisecondsSinceEpoch}';

    final iq = xmpp.IqStanza(stanzaId, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(host);
    final search = xmpp.XmppElement()
      ..name = 'query'
      ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:search'));

    search.addChild(
      xmpp.XmppElement()
        ..name = 'nick'
        ..textValue = query,
    );
    search.addChild(
      xmpp.XmppElement()
        ..name = 'first'
        ..textValue = query,
    );
    search.addChild(
      xmpp.XmppElement()
        ..name = 'last'
        ..textValue = query,
    );
    search.addChild(
      xmpp.XmppElement()
        ..name = 'email'
        ..textValue = query,
    );

    iq.addChild(search);
    final completer = Completer<List<Map<String, String>>>();

    StreamSubscription? sub;
    sub = conn.inStanzasStream.listen((stanza) {
      if (stanza is xmpp.IqStanza && stanza.id == stanzaId) {
        if (stanza.type == xmpp.IqStanzaType.RESULT) {
          final results = <Map<String, String>>[];
          final queryEl = stanza.getChild('query');
          if (queryEl != null) {
            for (var item in queryEl.children.where((c) => c.name == 'item')) {
              final result = <String, String>{};
              result['jid'] = item.getAttribute('jid')?.value ?? '';
              for (var field in item.children) {
                if (field.name != null && field.textValue != null) {
                  result[field.name!] = field.textValue!;
                }
              }
              results.add(result);
            }
          }
          completer.complete(results);
        } else {
          completer.completeError(
            'Search service error or not supported by $host',
          );
        }
        sub?.cancel();
      }
    });

    conn.writeStanza(iq);
    return await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        sub?.cancel();
        throw Exception('Search timeout');
      },
    );
  }

  void enableCarbons(String accountId) {
    final conn = _d.xmppConnections[accountId];
    if (conn == null || _d.carbonsEnabled[accountId] == true) return;

    _d.carbonsEnabled[accountId] = true;
    final iq = xmpp.IqStanza(
      'enable_carbons_${DateTime.now().millisecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    final enable = xmpp.XmppElement();
    enable.name = 'enable';
    enable.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:carbons:2'));
    iq.addChild(enable);
    conn.writeStanza(iq);
    debugPrint('XEP-0280: Carbons enabled for $accountId');
  }

  void syncAllXmppData(String accountId, xmpp.Connection conn) {
    debugPrint('SYNC: Triggering full account sync for $accountId');

    _d.fetchMyVCard(accountId: accountId);

    try {
      final iqId = 'mam_sync_${DateTime.now().millisecondsSinceEpoch}';
      final iq = xmpp.IqStanza(
        iqId,
        xmpp.IqStanzaType.SET,
      );
      final query = xmpp.XmppElement();
      query.name = 'query';
      query.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      final setEl = xmpp.XmppElement();
      setEl.name = 'set';
      setEl.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'));
      final maxEl = xmpp.XmppElement();
      maxEl.name = 'max';
      maxEl.textValue = '50';
      setEl.addChild(maxEl);
      final beforeEl = xmpp.XmppElement();
      beforeEl.name = 'before';
      setEl.addChild(beforeEl);
      query.addChild(setEl);
      iq.addChild(query);
      conn.writeStanza(iq);
      debugPrint('SYNC: Dispatched global MAM request (last 50 messages).');
    } catch (e) {
      debugPrint('SYNC: Failed to dispatch global MAM - $e');
    }

    try {
      final iq1 = xmpp.IqStanza(
        'bookmark_sync_legacy_${DateTime.now().millisecondsSinceEpoch}',
        xmpp.IqStanzaType.GET,
      );
      final pubsub1 = xmpp.XmppElement();
      pubsub1.name = 'pubsub';
      pubsub1.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
      );
      final items1 = xmpp.XmppElement();
      items1.name = 'items';
      items1.addAttribute(xmpp.XmppAttribute('node', 'storage:bookmarks'));
      pubsub1.addChild(items1);
      iq1.addChild(pubsub1);
      conn.writeStanza(iq1);

      final iq2 = xmpp.IqStanza(
        'bookmark_sync_modern_${DateTime.now().millisecondsSinceEpoch}',
        xmpp.IqStanzaType.GET,
      );
      final pubsub2 = xmpp.XmppElement();
      pubsub2.name = 'pubsub';
      pubsub2.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
      );
      final items2 = xmpp.XmppElement();
      items2.name = 'items';
      items2.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:bookmarks:1'));
      pubsub2.addChild(items2);
      iq2.addChild(pubsub2);
      conn.writeStanza(iq2);

      debugPrint('SYNC: Dispatched bookmark fetch requests (Legacy + Modern).');
    } catch (e) {
      debugPrint('SYNC: Failed to dispatch bookmark fetch - $e');
    }
  }

  Future<void> discoverServiceFeatures(String accountId, String domain) async {
    final conn = _d.xmppConnections[accountId];
    if (conn == null) return;

    debugPrint('DISCO: Starting discovery for $domain');

    final infoId = 'disco_info_server_${DateTime.now().millisecondsSinceEpoch}';
    final infoIq = xmpp.IqStanza(infoId, xmpp.IqStanzaType.GET);
    infoIq.toJid = xmpp.Jid.fromFullJid(domain);
    final infoQuery = xmpp.XmppElement();
    infoQuery.name = 'query';
    infoQuery.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'),
    );
    infoIq.addChild(infoQuery);

    final itemsId = 'disco_items_${DateTime.now().millisecondsSinceEpoch}';
    final itemsIq = xmpp.IqStanza(itemsId, xmpp.IqStanzaType.GET);
    itemsIq.toJid = xmpp.Jid.fromFullJid(domain);
    final itemsQuery = xmpp.XmppElement();
    itemsQuery.name = 'query';
    itemsQuery.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'),
    );
    itemsIq.addChild(itemsQuery);

    conn.writeStanza(infoIq);
    conn.writeStanza(itemsIq);
  }
}