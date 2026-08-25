import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class XmppMucSelfPingService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppMucSelfPingService(this._connections, this._xmppJids);

  final Map<String, DateTime> _lastPingTime = {};
  final Map<String, bool> _roomOccupancy = {};

  Future<bool> selfPingRoom(String accountId, String roomJid) async {
    final conn = _connections[accountId];
    if (conn == null) return false;

    final bareRoomJid = roomJid.split('/').first;
    final nick = _getNicknameForRoom(accountId, bareRoomJid);
    if (nick == null) return false;

    final pingJid = '$bareRoomJid/$nick';

    final iq = xmpp.IqStanza(
      'selfping_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(pingJid);

    try {
      final completer = Completer<bool>();
      final timeout = Duration(seconds: 5);

      final sub = conn.inStanzasStream.listen((stanza) {
        if (stanza is xmpp.IqStanza) {
          final stanzaId = iq.id;
          if (stanza.id == stanzaId) {
            if (stanza.type == xmpp.IqStanzaType.RESULT) {
              completer.complete(true);
            } else if (stanza.type == xmpp.IqStanzaType.ERROR) {
              final error = stanza.getChild('error');
              final errorType = error?.getAttribute('type')?.value;
              if (errorType == 'auth' || errorType == 'modify') {
                completer.complete(false);
              } else {
                completer.complete(false);
              }
            }
          }
        }
      });

      conn.writeStanza(iq);
      _lastPingTime[bareRoomJid] = DateTime.now();

      final result = await completer.future.timeout(timeout);
      sub.cancel();
      _roomOccupancy[bareRoomJid] = result;
      return result;
    } catch (e) {
      debugPrint('MUC Self-Ping: Failed for $bareRoomJid: $e');
      return false;
    }
  }

  String? _getNicknameForRoom(String accountId, String roomJid) {
    return _xmppJids[accountId]?.split('@').first ?? 'gibber';
  }

  bool isOccupant(String roomJid) => _roomOccupancy[roomJid] ?? false;
  DateTime? lastPingTime(String roomJid) => _lastPingTime[roomJid];
}

class XmppMdsService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppMdsService(this._connections, this._xmppJids);

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  Future<void> markDisplayed(String accountId, String roomJid, String messageId) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      'mds_display_${DateTime.now().millisecondsSinceEpoch}',
      xmpp.MessageStanzaType.CHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(roomJid.split('/').first);

    final displayed = xmpp.XmppElement();
    displayed.name = 'displayed';
    displayed.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:mds:display:0'));
    displayed.addAttribute(xmpp.XmppAttribute('jid', roomJid.split('/').first));
    msg.addChild(displayed);

    final stanzaId = xmpp.XmppElement();
    stanzaId.name = 'stanza-id';
    stanzaId.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
    stanzaId.addAttribute(xmpp.XmppAttribute('by', roomJid.split('/').first));
    stanzaId.addAttribute(xmpp.XmppAttribute('id', messageId));
    msg.addChild(stanzaId);

    final store = xmpp.XmppElement();
    store.name = 'store';
    store.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
    msg.addChild(store);

    conn.writeStanza(msg);
  }

  Future<void> setMdsAffiliation(String accountId, String roomJid) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final iq = xmpp.IqStanza(
      'mds_affil_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final affiliations = xmpp.XmppElement();
    affiliations.name = 'affiliations';
    affiliations.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:mds:display:0'));

    final affiliation = xmpp.XmppElement();
    affiliation.name = 'affiliation';
    affiliation.addAttribute(xmpp.XmppAttribute('jid', roomJid.split('/').first));
    affiliation.addAttribute(xmpp.XmppAttribute('affiliation', 'member'));
    affiliations.addChild(affiliation);
    pubsub.addChild(affiliations);
    iq.addChild(pubsub);

    conn.writeStanza(iq);
  }
}

class XmppChannelSearchService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppChannelSearchService(this._connections, _xmppJids) : _xmppJids = _xmppJids;

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  Future<List<ChannelSearchResult>> searchChannels({
    required String accountId,
    required String searchService,
    String? query,
    String? order,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return [];

    final iq = xmpp.IqStanza(
      'channel_search_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(searchService);

    final search = xmpp.XmppElement();
    search.name = 'search';
    search.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:channel-search:0'));

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    final formType = _makeField('FORM_TYPE', 'hidden', 'urn:xmpp:channel-search:0');
    x.addChild(formType);

    if (query != null && query.isNotEmpty) {
      final qField = _makeField('q', null, query);
      x.addChild(qField);
    }
    if (order != null) {
      final orderField = _makeField('order', null, order);
      x.addChild(orderField);
    }

    search.addChild(x);
    iq.addChild(search);

    try {
      final res = await _sendIq(iq, conn);
      final searchRes = res.getChild('search');
      if (searchRes == null) return [];

      final results = <ChannelSearchResult>[];
      final items = searchRes.children.where((e) => e.name == 'item');
      for (var item in items) {
        final jid = item.getAttribute('jid')?.value ?? '';
        String? name;
        String? description;
        String? language;
        int? occupants;
        bool? isOpen;

        for (var field in item.children.where((f) => f.name == 'field')) {
          final varAttr = field.getAttribute('var')?.value;
          final val = field.getChild('value')?.textValue;
          switch (varAttr) {
            case 'name':
              name = val;
            case 'description':
              description = val;
            case 'language':
              language = val;
            case 'occupants':
              occupants = val != null ? int.tryParse(val) : null;
            case 'is-open':
              isOpen = val == 'true' || val == '1';
          }
        }

        if (jid.isNotEmpty) {
          results.add(ChannelSearchResult(
            jid: jid,
            name: name,
            description: description,
            language: language,
            occupants: occupants,
            isOpen: isOpen,
          ));
        }
      }
      return results;
    } catch (e) {
      debugPrint('Channel Search: Failed: $e');
      return [];
    }
  }

  xmpp.XmppElement _makeField(String varAttr, String? type, String value) {
    final field = xmpp.XmppElement()..name = 'field';
    field.addAttribute(xmpp.XmppAttribute('var', varAttr));
    if (type != null) field.addAttribute(xmpp.XmppAttribute('type', type));
    final val = xmpp.XmppElement()..name = 'value'..textValue = value;
    field.addChild(val);
    return field;
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, xmpp.Connection conn,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final id = 'chsearch_${xmpp.AbstractStanza.getRandomId()}';
    final iq = xmpp.IqStanza(id, originalIq.type);
    iq.toJid = originalIq.toJid;
    for (var child in originalIq.children) {
      iq.addChild(child);
    }

    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    conn.writeStanza(iq);

    try {
      return await completer.future.timeout(timeout);
    } catch (e) {
      _pendingIqs.remove(id);
      rethrow;
    }
  }

  void handleIqResponse(xmpp.IqStanza iq) {
    final id = iq.id;
    if (id != null && _pendingIqs.containsKey(id)) {
      _pendingIqs[id]!.complete(iq);
      _pendingIqs.remove(id);
    }
  }
}

class ChannelSearchResult {
  final String jid;
  final String? name;
  final String? description;
  final String? language;
  final int? occupants;
  final bool? isOpen;

  ChannelSearchResult({
    required this.jid,
    this.name,
    this.description,
    this.language,
    this.occupants,
    this.isOpen,
  });
}