import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/space_models.dart';

class SpacesService {
  final xmpp.Connection _connection;
  xmpp.Connection get connection => _connection;
  
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  late StreamSubscription<xmpp.AbstractStanza?> _subscription;

  SpacesService(this._connection) {
    _subscription = _connection.inStanzasStream.listen(_handleStanza);
  }

  void dispose() {
    _subscription.cancel();
    for (final completer in _pendingIqs.values) {
      if (!completer.isCompleted) completer.completeError('Service disposed');
    }
    _pendingIqs.clear();
  }

  void _handleStanza(xmpp.AbstractStanza? stanza) {
    if (stanza is xmpp.IqStanza) {
      final id = stanza.id;
      if (id != null && _pendingIqs.containsKey(id)) {
        _pendingIqs[id]!.complete(stanza);
        _pendingIqs.remove(id);
      }
    }
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza iq) {
    final id = iq.id ?? 'spaces_${DateTime.now().microsecondsSinceEpoch}';
    iq.id = id;
    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    _connection.writeStanza(iq);

    // Timeout after 15 seconds
    Future.delayed(const Duration(seconds: 15), () {
      if (_pendingIqs.containsKey(id)) {
        _pendingIqs[id]!.completeError(TimeoutException('IQ request timed out'));
        _pendingIqs.remove(id);
      }
    });

    return completer.future;
  }

  Future<List<SpaceNode>> fetchSpaces(String pubsubDomain) async {
    final iq = xmpp.IqStanza('fetch_spaces_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(pubsubDomain);
    
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        return [];
      }

      final queryRes = response.getChild('query');
      if (queryRes == null) return [];

      final List<SpaceNode> spaces = [];
      for (var item in queryRes.children.where((e) => e.name == 'item')) {
        final node = item.getAttribute('node')?.value;
        final name = item.getAttribute('name')?.value;
        final jid = item.getAttribute('jid')?.value;
        
        final resolvedNode = node ?? jid;
        if (resolvedNode != null) {
          // Fetch more info for each space in parallel
          spaces.add(SpaceNode(
            domain: pubsubDomain,
            node: resolvedNode,
            name: name ?? resolvedNode,
          ));
        }
      }
      return spaces;
    } catch (e) {
      debugPrint('Error fetching spaces: $e');
      return [];
    }
  }

  Future<SpaceNode?> fetchSpaceMetadata(String domain, String node) async {
    final iq = xmpp.IqStanza('fetch_meta_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    query.addAttribute(xmpp.XmppAttribute('node', node));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return null;

      final queryRes = response.getChild('query');
      String name = node;
      String? desc;
      String? avatar;
      
      for (var identity in queryRes?.children.where((e) => e.name == 'identity') ?? []) {
        name = identity.getAttribute('name')?.value ?? name;
      }

      // Look for data forms (XEP-0004)
      for (var x in queryRes?.children.where((e) => e.name == 'x' && e.getAttribute('xmlns')?.value == 'jabber:x:data') ?? []) {
        for (var field in x.children.where((e) => e.name == 'field')) {
          final varAttr = field.getAttribute('var')?.value;
          final value = field.getChild('value')?.textValue;
          if (varAttr == 'pubsub#description') desc = value;
          if (varAttr == 'pubsub#node_avatar_url') avatar = value;
        }
      }

      return SpaceNode(
        domain: domain,
        node: node,
        name: name,
        description: desc,
        avatarUrl: avatar,
      );
    } catch (e) {
      return null;
    }
  }

  Future<bool> createSpace(String domain, String node, String name, {String? description}) async {
    final iq = xmpp.IqStanza('create_space_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final create = xmpp.XmppElement();
    create.name = 'create';
    create.addAttribute(xmpp.XmppAttribute('node', node));
    pubsub.addChild(create);

    final configure = xmpp.XmppElement();
    configure.name = 'configure';
    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    void addField(String name, String value) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', name));
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    }

    addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config');
    addField('pubsub#title', name);
    if (description != null) addField('pubsub#description', description);
    addField('pubsub#node_type', 'leaf');
    addField('pubsub#access_model', 'open');
    addField('pubsub#publish_model', 'publishers');

    configure.addChild(x);
    pubsub.addChild(configure);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteSpace(String domain, String node) async {
    final iq = xmpp.IqStanza('del_space_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));
    final delete = xmpp.XmppElement();
    delete.name = 'delete';
    delete.addAttribute(xmpp.XmppAttribute('node', node));
    pubsub.addChild(delete);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<bool> addRoomToSpace(String domain, String node, String roomJid, {String? roomName}) async {
    final iq = xmpp.IqStanza('add_room_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', node));
    
    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', roomJid));
    
    final conference = xmpp.XmppElement();
    conference.name = 'conference';
    conference.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:bookmarks:1'));
    conference.addAttribute(xmpp.XmppAttribute('name', roomName ?? roomJid));
    conference.addAttribute(xmpp.XmppAttribute('autojoin', 'true'));
    
    item.addChild(conference);
    publish.addChild(item);
    pubsub.addChild(publish);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<bool> removeRoomFromSpace(String domain, String node, String roomJid) async {
    final iq = xmpp.IqStanza('rem_room_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final retract = xmpp.XmppElement();
    retract.name = 'retract';
    retract.addAttribute(xmpp.XmppAttribute('node', node));
    
    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', roomJid));
    
    retract.addChild(item);
    pubsub.addChild(retract);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<List<SpaceItem>> fetchSpaceContent(String pubsubDomain, String node) async {
    final iq = xmpp.IqStanza('fetch_content_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(pubsubDomain);
    
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', node));
    
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      
      debugPrint('FETCH SPACE RESPONSE: ${response.buildXmlString()}');

      if (response.type == xmpp.IqStanzaType.ERROR) {
        final error = response.getChild('error');
        final isForbidden = error?.getChild('forbidden') != null;
        debugPrint('Space error response (forbidden: $isForbidden)! Trying disco#info/items fallback...');
        return await _fetchSpaceContentDiscoFallback(pubsubDomain, node);
      }

      final pubsubRes = response.getChild('pubsub');
      final itemsRes = pubsubRes?.getChild('items');
      if (itemsRes == null) {
        debugPrint('No items element found in pubsub response. Trying disco fallback...');
        return await _fetchSpaceContentDiscoFallback(pubsubDomain, node);
      }

      debugPrint('Found ${itemsRes.children.where((e) => e.name == 'item').length} items.');

      final List<SpaceItem> spaceItems = [];
      for (var item in itemsRes.children.where((e) => e.name == 'item')) {
        final id = item.getAttribute('id')?.value;
        if (id == null) continue;

        String? name;
        String? type;
        String? url;
        String? subNode;

        for (var child in item.children) {
          final ns = child.getAttribute('xmlns')?.value;
          
          // XEP-0048: Bookmarks (modern)
          if (child.name == 'conference' && ns == 'urn:xmpp:bookmarks:1') {
            type = 'room';
            name = child.getAttribute('name')?.value;
            break;
          }

          // Legacy Conference
          if (child.name == 'x' && ns == 'jabber:x:conference') {
            type = 'room';
            name = child.getAttribute('name')?.value;
            break;
          }

          // XEP-0066: Out of Band Data (URLs)
          if (child.name == 'x' && ns == 'jabber:x:oob') {
            type = 'url';
            url = child.getChild('url')?.textValue;
            name = url;
            break;
          }

          // XEP-0457: Spaces Subscriptions
          if (child.name == 'subscription' && ns == 'urn:xmpp:pubsub:subscription:0') {
            type = 'subscription';
            subNode = child.getAttribute('node')?.value;
            name = subNode != null ? 'Sub-Space: $subNode' : 'Sub-Space';
            break;
          }
        }

        if (type != null) {
          spaceItems.add(SpaceItem(
            id: id,
            type: type,
            name: name ?? id,
            url: url,
            node: subNode,
          ));
        } else {
          // FALLBACK: If no payload recognized, infer from ID or presence of children
          if (id.contains('@')) {
            spaceItems.add(SpaceItem(id: id, type: 'room', name: id));
          } else {
            final firstChild = item.children.isNotEmpty ? item.children.first : null;
            spaceItems.add(SpaceItem(
              id: id,
              type: 'unknown',
              name: firstChild != null ? 'Item: ${firstChild.name}' : id,
              url: firstChild?.buildXmlString() ?? item.buildXmlString(),
            ));
          }
        }
      }
      return spaceItems;
    } catch (e) {
      debugPrint('Error fetching space content via pubsub: $e. Trying disco#items fallback...');
      return await _fetchSpaceContentDiscoFallback(pubsubDomain, node);
    }
  }

  Future<List<SpaceItem>> _fetchSpaceContentDiscoFallback(String domain, String node) async {
    // Attempt 1: Query disco#info to see what this thing is
    final infoIq = xmpp.IqStanza('fetch_info_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    infoIq.toJid = xmpp.Jid.fromFullJid(domain);
    final infoQuery = xmpp.XmppElement();
    infoQuery.name = 'query';
    infoQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    infoQuery.addAttribute(xmpp.XmppAttribute('node', node));
    infoIq.addChild(infoQuery);

    try {
      final infoRes = await _sendIq(infoIq);
      debugPrint('DISCO INFO RESPONSE: ${infoRes.buildXmlString()}');
      if (infoRes.type != xmpp.IqStanzaType.ERROR) {
        final query = infoRes.getChild('query');
        final identity = query?.getChild('identity');
        if (identity != null) {
          final category = identity.getAttribute('category')?.value;
          final type = identity.getAttribute('type')?.value;
          debugPrint('Node identity: $category/$type');
          
          // If it's a conference (MUC), it might be that the space node itself IS the room
          if (category == 'conference' || type == 'text') {
            return [SpaceItem(id: node, type: 'room', name: identity.getAttribute('name')?.value ?? node)];
          }
        }
      }
    } catch (e) {
      debugPrint('Error in disco info: $e');
    }

    // Attempt 2: Query the domain with the node attribute
    final iq = xmpp.IqStanza('fetch_disco_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    query.addAttribute(xmpp.XmppAttribute('node', node));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type != xmpp.IqStanzaType.ERROR) {
        final queryRes = response.getChild('query');
        if (queryRes != null && queryRes.children.where((e) => e.name == 'item').isNotEmpty) {
          return _parseDiscoItems(queryRes);
        }
      }
    } catch (e) {
      debugPrint('Error in disco fallback attempt 1: $e');
    }

    // Attempt 3: The 'node' might actually be a JID! Query it directly.
    debugPrint('Disco fallbacks 1&2 failed or empty. Trying to query the node as a JID directly.');
    final iq2 = xmpp.IqStanza('fetch_disco2_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    try {
      final jid = xmpp.Jid.fromFullJid(node);
      iq2.toJid = jid;
      final query2 = xmpp.XmppElement();
      query2.name = 'query';
      query2.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
      iq2.addChild(query2);

      final response2 = await _sendIq(iq2);
      if (response2.type != xmpp.IqStanzaType.ERROR) {
        final queryRes2 = response2.getChild('query');
        if (queryRes2 != null) {
          return _parseDiscoItems(queryRes2);
        }
      }
    } catch (e) {
      debugPrint('Error in disco fallback attempt 3: $e');
    }

    return [];
  }

  List<SpaceItem> _parseDiscoItems(xmpp.XmppElement queryRes) {
    final List<SpaceItem> spaceItems = [];
    for (var item in queryRes.children.where((e) => e.name == 'item')) {
      final jid = item.getAttribute('jid')?.value;
      final name = item.getAttribute('name')?.value;
      final nodeAttr = item.getAttribute('node')?.value;
      if (jid != null) {
        spaceItems.add(SpaceItem(
          id: jid,
          type: 'room', // Treat disco items as rooms by default, user can join them
          name: name ?? jid,
          node: nodeAttr,
        ));
      }
    }
    return spaceItems;
  }
}
