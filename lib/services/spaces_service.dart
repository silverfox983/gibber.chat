import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/space_models.dart';

class SpacesService extends ChangeNotifier {
  final xmpp.Connection _connection;
  xmpp.Connection get connection => _connection;
  
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  // ── Bounded LRU caches with TTL ──────────────────────────────────────────
  final _discoverCache  = _BoundedCache<String, List<SpaceNode>>(maxSize: 20, ttl: const Duration(minutes: 30));
  final _metadataCache  = _BoundedCache<String, SpaceNode>(maxSize: 100, ttl: const Duration(minutes: 15));
  final _contentCache   = _BoundedCache<String, List<SpaceItem>>(maxSize: 30, ttl: const Duration(minutes: 5));
  final Map<String, Future<dynamic>> _inflight = {};

  // XEP-0060: Real-time PubSub event stream
  final StreamController<SpaceItem> _liveItemController = StreamController<SpaceItem>.broadcast();
  Stream<SpaceItem> get liveItemStream => _liveItemController.stream;

  late StreamSubscription<xmpp.AbstractStanza?> _subscription;

  SpacesService(this._connection) {
    _subscription = _connection.inStanzasStream.listen(_handleStanza);
  }

  Future<SpaceNode> fetchSpaceDetails(SpaceNode space, {bool forceRefresh = false}) async {
    final cacheKey = '${space.domain}|${space.node}';
    if (!forceRefresh && _metadataCache.containsKey(cacheKey)) {
      return _metadataCache[cacheKey]!;
    }
    
    final infoIq = xmpp.IqStanza('fetch_info_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
    final isServiceNode = space.node == space.domain;
    
    if (space.type == 'muc') {
      infoIq.toJid = xmpp.Jid.fromFullJid('${space.node}@${space.domain}');
    } else {
      infoIq.toJid = xmpp.Jid.fromFullJid(space.domain);
    }
    
    final infoQuery = xmpp.XmppElement();
    infoQuery.name = 'query';
    infoQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    
    if (space.type != 'muc' && !isServiceNode) {
      infoQuery.addAttribute(xmpp.XmppAttribute('node', space.node));
    }
    infoIq.addChild(infoQuery);

    try {
      final infoRes = await _sendIq(infoIq);
      if (infoRes.type != xmpp.IqStanzaType.ERROR) {
        final query = infoRes.getChild('query');
        String? newDescription = space.description;
        String? newName = space.name;
        String? newAvatarUrl = space.avatarUrl;
        String? accessModel;
        String? publishModel;
        int? numSubscribers;
        String? ownerJid;

        // XEP-0128 / XEP-0004: parse jabber:x:data extended fields
        final xFields = query?.children.where((e) =>
          e.name == 'x' && e.getAttribute('xmlns')?.value == 'jabber:x:data') ?? [];
        for (var x in xFields) {
          for (var field in x.children.where((e) => e.name == 'field')) {
            final varAttr = field.getAttribute('var')?.value;
            final val = field.getChild('value')?.textValue;

            if (val != null && val.isNotEmpty) {
              if (varAttr == 'pubsub#title' || varAttr == 'muc#roominfo_subject') {
                newName = val;
              } else if (varAttr == 'pubsub#description' || varAttr == 'muc#roominfo_description') {
                newDescription = val;
              } else if (varAttr == 'pubsub#node_avatar_url' || varAttr == 'muc#roomconfig_roomavatar' || varAttr == 'muc#roominfo_avatar') {
                newAvatarUrl = val;
              } else if (varAttr == 'pubsub#access_model') {
                accessModel = val;
              } else if (varAttr == 'pubsub#publish_model') {
                publishModel = val;
              } else if (varAttr == 'pubsub#num_subscribers' || varAttr == 'muc#roominfo_occupants') {
                numSubscribers = int.tryParse(val);
              } else if (varAttr == 'pubsub#owner') {
                ownerJid = val;
              }
            }
          }
        }

        final updatedSpace = space.copyWith(
          name: newName,
          description: newDescription,
          avatarUrl: newAvatarUrl,
          accessModel: accessModel,
          publishModel: publishModel,
          numSubscribers: numSubscribers,
          ownerJid: ownerJid,
        );
        _metadataCache['${space.domain}|${space.node}'] = updatedSpace;
        return updatedSpace;
      }
    } catch (e) {
      debugPrint('fetchSpaceDetails error: $e');
    }
    return space;
  }


  @override
  void dispose() {
    _discoverCache.clear();
    _metadataCache.clear();
    _contentCache.clear();
    _subscription.cancel();
    _liveItemController.close();
    for (final completer in _pendingIqs.values) {
      if (!completer.isCompleted) completer.completeError('Service disposed');
    }
    _pendingIqs.clear();
    super.dispose();
  }

  void _handleStanza(xmpp.AbstractStanza? stanza) {
    if (stanza is xmpp.IqStanza) {
      final id = stanza.id;
      if (id != null && _pendingIqs.containsKey(id)) {
        _pendingIqs[id]!.complete(stanza);
        _pendingIqs.remove(id);
      }
    }

    // XEP-0060 §12: Real-time PubSub event delivery via <message>
    if (stanza is xmpp.MessageStanza) {
      _handlePubSubEvent(stanza);
    }
  }

  void _handlePubSubEvent(xmpp.MessageStanza msg) {
    // PubSub servers deliver events as:
    // <message from='pubsub.domain' to='user@domain'>
    //   <event xmlns='http://jabber.org/protocol/pubsub#event'>
    //     <items node='some-node'><item id='...'> ... </item></items>
    //   </event>
    // </message>
    try {
      final eventEl = msg.children.cast<xmpp.XmppElement?>().firstWhere(
        (c) => c != null && c.name == 'event' &&
               c.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/pubsub#event',
        orElse: () => null,
      );
      if (eventEl == null) return;

      final itemsEl = eventEl.getChild('items');
      if (itemsEl == null) return;

      final node = itemsEl.getAttribute('node')?.value ?? '';
      final fromJid = msg.fromJid?.domain ?? msg.fromJid?.fullJid ?? '';

      for (final itemEl in itemsEl.children.where((c) => c.name == 'item')) {
        final id = itemEl.getAttribute('id')?.value;
        if (id == null) continue;

        // Parse the payload using the same logic as fetchSpaceContent
        String? type;
        String? name;
        String? description;
        String? imageUrl;
        String? author;
        String? rawContent;
        String? contentType;
        DateTime? publishedDate;
        List<MediaAttachment> mediaAttachments = [];
        List<String> categories = [];
        String? replyToId;

        for (final child in itemEl.children) {
          final ns = child.getAttribute('xmlns')?.value;
          if (child.name == 'entry' && ns == 'http://www.w3.org/2005/Atom') {
            type = 'entry';
            name = child.getChild('title')?.textValue;
            description = child.getChild('summary')?.textValue ?? child.getChild('content')?.textValue;
            final authorNode = child.getChild('author');
            author = authorNode?.getChild('name')?.textValue ?? authorNode?.getChild('uri')?.textValue;
            final publishedStr = child.getChild('published')?.textValue;
            if (publishedStr != null) {
              try { publishedDate = DateTime.parse(publishedStr); } catch (_) {}
            }
            for (final link in child.children.where((e) => e.name == 'link')) {
              final rel = link.getAttribute('rel')?.value;
              final href = link.getAttribute('href')?.value;
              final typeAttr = link.getAttribute('type')?.value;
              if (rel == 'enclosure' && href != null) {
                mediaAttachments.add(MediaAttachment(url: href, type: typeAttr));
                if (typeAttr != null && typeAttr.startsWith('image/') && imageUrl == null) imageUrl = href;
              }
            }
            final thr = child.children.where((e) => e.name == 'in-reply-to' || e.name == 'thr:in-reply-to').firstOrNull;
            replyToId = thr?.getAttribute('ref')?.value;
            for (final cat in child.children.where((e) => e.name == 'category')) {
              final term = cat.getAttribute('term')?.value;
              if (term != null) categories.add(term);
            }
            final contentNode = child.getChild('content');
            contentType = contentNode?.getAttribute('type')?.value;
            if (contentNode != null) {
              rawContent = contentNode.children.isNotEmpty
                  ? contentNode.children.map((c) => c.buildXmlString()).join('')
                  : contentNode.textValue;
            }
            rawContent ??= description;
            break;
          }
        }

        if (type != null) {
          final liveItem = SpaceItem(
            id: id,
            type: type,
            name: name,
            description: description,
            imageUrl: imageUrl,
            author: author,
            publishedDate: publishedDate ?? DateTime.now(),
            rawContent: rawContent,
            contentType: contentType,
            mediaAttachments: mediaAttachments,
            categories: categories,
            replyToId: replyToId,
            sourceSpace: SpaceNode(domain: fromJid, node: node, name: node),
          );
          _liveItemController.add(liveItem);
          debugPrint('PubSub Live Event: New item $id on node $node');
        }
      }
    } catch (e) {
      debugPrint('Error handling PubSub event: $e');
    }
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, {int retries = 0, Duration timeout = const Duration(seconds: 15)}) async {
    if (originalIq.toJid == null) return Future.error('No toJid');

    final domain = originalIq.toJid!.domain;
    if (!domain.contains('.') && domain != 'localhost') {
      debugPrint('BLOCKING IQ to non-FQDN: ${originalIq.toJid!.fullJid}');
      return Future.error('Invalid target domain: $domain');
    }

    int attempt = 0;
    while (attempt <= retries) {
      final id = 'spaces_${xmpp.AbstractStanza.getRandomId()}';
      final iq = xmpp.IqStanza(id, originalIq.type);
      iq.toJid = originalIq.toJid;
      iq.fromJid = originalIq.fromJid;
      for (var child in originalIq.children) {
        iq.addChild(child);
      }

      final completer = Completer<xmpp.IqStanza>();
      _pendingIqs[id] = completer;
      _connection.writeStanza(iq);

      try {
        return await completer.future.timeout(timeout);
      } catch (e) {
        _pendingIqs.remove(id);
        if (attempt >= retries) {
          debugPrint('IQ failed after ${retries + 1} attempts to ${iq.toJid!.fullJid}: $e');
          if (e is xmpp.IqStanza) {
            debugPrint('FULL ERROR STANZA: ${e.buildXmlString()}');
          }
          rethrow;
        }
        attempt++;
        debugPrint('Retrying IQ to ${iq.toJid!.fullJid} (Attempt ${attempt + 1})...');
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return Future.error('Unexpected fallthrough in _sendIq');
  }

  Future<List<SpaceNode>> discoverAllSpaces(String domain, {bool forceRefresh = false}) async {
    if (!forceRefresh && _discoverCache.containsKey(domain)) {
      return _discoverCache[domain]!;
    }

    final List<SpaceNode> allSpaces = [];
    final Set<String> checkedJids = {};

    // 1. Query the domain itself
    final domainSpaces = await fetchSpaces(domain);
    allSpaces.addAll(domainSpaces);
    checkedJids.add(domain);

    // 2. Query items of the domain to find sub-services (like pubsub.domain.com)
    final iq = xmpp.IqStanza('disco_items_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      final queryRes = response.getChild('query') ?? response.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'query' || e.name == 'INVALID').firstOrNull;
      if (queryRes != null) {
        final List<String> subServices = [];
        for (var item in queryRes.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'item' || e.name == 'INVALID')) {
          final jid = item.getAttribute('jid')?.value;
          // Only follow JIDs that look like valid domains (contain a dot) 
          // or are subdomains of the target domain.
          // Filter out internal system components (non-FQDN) or exact matches
          if (jid != null && !checkedJids.contains(jid)) {
            final isQualified = jid.contains('.');
            final lowerJid = jid.toLowerCase();
            
            // Filter out common system components that are never PubSub spaces
            final isSystemComponent = lowerJid == 'serverinfo' || 
                                     lowerJid.startsWith('serverinfo/') ||
                                     lowerJid == 'search' || 
                                     lowerJid == 'echo' ||
                                     lowerJid == 'pubsub';

            if (isQualified && !isSystemComponent) {
              subServices.add(jid);
              checkedJids.add(jid); // Mark as checked immediately to prevent parallel duplicates
            }
          }
        }

        // 3. For each sub-service, check if it supports PubSub
        // Process concurrently in chunks to prevent blocking and server timeouts
        final List<List<SpaceNode>> results = [];
        final List<String> level2Servers = [];
        
        for (int i = 0; i < subServices.length; i += 5) {
          final chunk = subServices.skip(i).take(5);
          final List<Future<void>> discoveryFutures = [];

          for (var service in chunk) {
            discoveryFutures.add(() async {
              final infoIq = xmpp.IqStanza('disco_info_spaces_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
              infoIq.toJid = xmpp.Jid.fromFullJid(service);
              final infoQuery = xmpp.XmppElement();
              infoQuery.name = 'query';
              infoQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
              infoIq.addChild(infoQuery);

              try {
                final infoRes = await _sendIq(infoIq);
                final infoQueryRes = infoRes.getChild('query') ?? infoRes.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'query' || e.name == 'INVALID').firstOrNull;
                bool supportsPubSub = false;
                bool isTopLevelService = false;
                bool isServer = false;
                String? serviceName;
                String? serviceType;

                if (infoQueryRes != null) {
                  bool hasGatewayFeature = false;
                  for (var child in infoQueryRes.children.whereType<xmpp.XmppElement>()) {
                    if (child.name == 'feature' || child.name == 'INVALID') {
                      final varAttr = child.getAttribute('var')?.value;
                      if (varAttr == 'http://jabber.org/protocol/pubsub') {
                        supportsPubSub = true;
                      } else if (varAttr == 'jabber:iq:gateway' || varAttr == 'jabber:iq:register') {
                        hasGatewayFeature = true;
                      }
                    }
                  }

                  if (!hasGatewayFeature) {
                    for (var child in infoQueryRes.children.whereType<xmpp.XmppElement>()) {
                      if (child.runtimeType.toString() == 'Identity' || child.name == 'identity' || child.name == 'INVALID') {
                        final cat = child.getAttribute('category')?.value;
                        serviceName = child.getAttribute('name')?.value ?? serviceName;
                        if (cat == 'conference' || cat == 'directory') {
                          isTopLevelService = true;
                          serviceType = cat;
                        } else if (cat == 'server') {
                          isServer = true;
                        }
                      }
                    }
                  }
                }
                
                if (supportsPubSub) {
                  final spaces = await fetchSpaces(service);
                  // Deep probe for metadata on the first 5 spaces to provide rich initial state
                  for (int j = 0; j < (spaces.length > 5 ? 5 : spaces.length); j++) {
                    try {
                      spaces[j] = await fetchSpaceDetails(spaces[j]);
                    } catch (_) {}
                  }
                  results.add(spaces);
                } else if (isTopLevelService) {
                  if (serviceType == 'conference') {
                    final mucRooms = await fetchSpaces(service);
                    if (mucRooms.isNotEmpty) {
                      results.add(mucRooms);
                    } else {
                      results.add([SpaceNode(
                        domain: service,
                        node: service,
                        name: serviceName ?? service,
                        type: serviceType,
                        syncedAt: DateTime.now(),
                      )]);
                    }
                  } else {
                    results.add([SpaceNode(
                      domain: service,
                      node: service,
                      name: serviceName ?? service,
                      type: serviceType,
                      syncedAt: DateTime.now(),
                    )]);
                  }
                } else if (isServer && !isTopLevelService) {
                  level2Servers.add(service);
                }
              } catch (e) {
                debugPrint('Error checking service $service: $e');
              }
            }());
          }
          await Future.wait(discoveryFutures);
        }

        // 4. Level 2 Discovery: Recursively check servers identified in Level 1
        final List<Future<void>> level2Futures = [];
        for (var l2Server in level2Servers) {
          level2Futures.add(() async {
            try {
              final l2ItemsIq = xmpp.IqStanza('disco_items_spaces_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
              l2ItemsIq.toJid = xmpp.Jid.fromFullJid(l2Server);
              final l2ItemsQuery = xmpp.XmppElement();
              l2ItemsQuery.name = 'query';
              l2ItemsQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
              l2ItemsIq.addChild(l2ItemsQuery);

              final l2ItemsRes = await _sendIq(l2ItemsIq);
              final l2QueryRes = l2ItemsRes.getChild('query') ?? l2ItemsRes.children.where((e) => e.name == 'query' || e.name == 'INVALID').cast<xmpp.XmppElement?>().firstOrNull;
              if (l2QueryRes != null) {
                final items = l2QueryRes.children.where((e) => e.name == 'item' || e.name == 'INVALID').cast<xmpp.XmppElement>().toList();
                for (int i = 0; i < items.length; i += 5) {
                  final chunk = items.skip(i).take(5);
                  final List<Future<void>> l2InfoFutures = [];
                  for (var item in chunk) {
                    final jid = item.getAttribute('jid')?.value;
                    if (jid != null && jid.contains('.') && !checkedJids.contains(jid)) {
                      checkedJids.add(jid);
                      l2InfoFutures.add(() async {
                        try {
                          final infoIq = xmpp.IqStanza('disco_info_spaces_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
                          infoIq.toJid = xmpp.Jid.fromFullJid(jid);
                          final infoQuery = xmpp.XmppElement();
                          infoQuery.name = 'query';
                          infoQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
                          infoIq.addChild(infoQuery);

                          final infoRes = await _sendIq(infoIq);
                          final infoQueryRes = infoRes.getChild('query') ?? infoRes.children.where((e) => e.name == 'query' || e.name == 'INVALID').cast<xmpp.XmppElement?>().firstOrNull;
                          bool supportsPubSub = false;
                          bool isTopLevelService = false;
                          String? serviceName;
                          String? serviceType;

                          if (infoQueryRes != null) {
                            bool hasGatewayFeature = false;
                            for (var child in infoQueryRes.children) {
                              if (child.name == 'feature' || child.name == 'INVALID') {
                                final varAttr = child.getAttribute('var')?.value;
                                if (varAttr == 'http://jabber.org/protocol/pubsub') {
                                  supportsPubSub = true;
                                } else if (varAttr == 'jabber:iq:gateway' || varAttr == 'jabber:iq:register') {
                                  hasGatewayFeature = true;
                                }
                              }
                            }

                            if (!hasGatewayFeature) {
                              for (var child in infoQueryRes.children) {
                                if (child.name == 'identity' || child.name == 'INVALID') {
                                  final cat = child.getAttribute('category')?.value;
                                  serviceName = child.getAttribute('name')?.value ?? serviceName;
                                  if (cat == 'conference' || cat == 'directory') {
                                    isTopLevelService = true;
                                    serviceType = cat;
                                  }
                                }
                              }
                            }
                          }
                          
                          if (supportsPubSub) {
                            final spaces = await fetchSpaces(jid);
                            // Deep probe for metadata on the first 3 spaces in L2
                            for (int j = 0; j < (spaces.length > 3 ? 3 : spaces.length); j++) {
                              try {
                                spaces[j] = await fetchSpaceDetails(spaces[j]);
                              } catch (_) {}
                            }
                            results.add(spaces);
                          } else if (isTopLevelService) {
                            results.add([SpaceNode(
                              domain: jid,
                              node: jid,
                              name: serviceName ?? jid,
                              type: serviceType,
                            )]);
                          }
                        } catch (e) {
                          debugPrint('Error checking L2 service $jid: $e');
                        }
                      }());
                    }
                  }
                  await Future.wait(l2InfoFutures);
                }
              }
            } catch (e) {
              debugPrint('Error discovering L2 server $l2Server: $e');
            }
          }());
        }
        await Future.wait(level2Futures);

        for (var res in results) {
          allSpaces.addAll(res);
        }
      }
    } catch (e) {
      debugPrint('Error during deep discovery: $e');
    }

    // Deduplicate by domain|node
    final Map<String, SpaceNode> uniqueSpaces = {};
    for (var s in allSpaces) {
      uniqueSpaces['${s.domain}|${s.node}'] = s;
    }
    
    final finalResult = uniqueSpaces.values.toList();
    _discoverCache[domain] = finalResult;
    return finalResult;
  }

  Future<List<SpaceNode>> fetchSpaces(String pubsubDomain) async {
    final iq = xmpp.IqStanza('fetch_spaces_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
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
      for (var item in queryRes.children.where((e) => e.name == 'item' || e.name == 'INVALID')) {
        final node = item.getAttribute('node')?.value;
        final name = item.getAttribute('name')?.value;
        final jid = item.getAttribute('jid')?.value;
        
        // A valid PubSub node MUST have a node attribute.
        // Items without a node attribute are usually server components, not Spaces.
        if (node != null && node.isNotEmpty) {
          // Filter out internal system nodes that clutter the UI and prevent flooding
          final isSystemNode = node.startsWith('urn:xmpp:microblog:0:comments') ||
                               (node.startsWith('urn:xmpp:') && 
                                !node.startsWith('urn:xmpp:microblog') && 
                                !node.startsWith('urn:xmpp:spaces')) ||
                               node.startsWith('eu.siacs.') ||
                               node.startsWith('storage:') ||
                               node.startsWith('http://') ||
                               node == 'vcard-temp' ||
                               node == 'serverinfo' ||
                               node.startsWith('serverinfo/');
                               
          if (!isSystemNode) {
            spaces.add(SpaceNode(
              domain: jid ?? pubsubDomain,
              node: node,
              name: name ?? node,
              syncedAt: DateTime.now(),
            ));
          }
        } else if (jid != null && jid.contains('@')) {
          // It's a MUC channel! The "node" is the local part of the JID.
          final localPart = jid.split('@')[0];
          final domainPart = jid.split('@')[1];
          spaces.add(SpaceNode(
            domain: domainPart,
            node: localPart,
            name: name ?? localPart,
            type: 'muc',
            syncedAt: DateTime.now(),
          ));
        }
      }
      return spaces;
    } catch (e) {
      debugPrint('Error fetching spaces: $e');
      return [];
    }
  }

  Future<SpaceNode?> fetchSpaceMetadata(String domain, String node, {String? fallbackName, bool forceRefresh = false}) async {
    final cacheKey = '$domain|$node';
    if (!forceRefresh && _metadataCache.containsKey(cacheKey)) {
      return _metadataCache[cacheKey];
    }
    
    final iq = xmpp.IqStanza('fetch_meta_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    
    final isServiceNode = node == domain;
    
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    if (!isServiceNode) {
      query.addAttribute(xmpp.XmppAttribute('node', node));
    }
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return null;

      final queryRes = response.getChild('query');
      String name = fallbackName ?? node;
      String? desc;
      String? avatar;
      final List<String> features = [];
      String? nodeType;
      String? accessModel;
      String? publishModel;
      int? numSubscribers;
      String? ownerJid;
      
      if (queryRes != null) {
        for (var child in queryRes.children) {
          if (child.name == 'identity' || child.name == 'INVALID') {
            name = child.getAttribute('name')?.value ?? name;
            final category = child.getAttribute('category')?.value;
            final type = child.getAttribute('type')?.value;
            if (category == 'pubsub') {
              nodeType = type == 'service' ? 'pubsub_service' : 'pubsub_node';
            } else if (category == 'conference') {
              nodeType = 'muc';
            } else if (category == 'directory') {
              nodeType = 'directory';
            } else if (nodeType == null && type != null) {
              nodeType = type;
            }
          } else if (child.name == 'feature') {
            final varAttr = child.getAttribute('var')?.value;
            if (varAttr != null) features.add(varAttr);
          } else if (child.name == 'x' && child.getAttribute('xmlns')?.value == 'jabber:x:data') {
            for (var field in child.children.where((e) => e.name == 'field' || e.name == 'INVALID')) {
              final varAttr = field.getAttribute('var')?.value;
              final value = field.getChild('value')?.textValue;
              if (varAttr == 'pubsub#description' || varAttr == 'muc#roominfo_description') desc = value;
              if (varAttr == 'pubsub#node_avatar_url' || varAttr == 'muc#roomconfig_roomavatar') avatar = value;
              if (varAttr == 'pubsub#title' || varAttr == 'muc#roominfo_subject') name = value ?? name;
              if (varAttr == 'pubsub#access_model') accessModel = value;
              if (varAttr == 'pubsub#publish_model') publishModel = value;
              if (varAttr == 'pubsub#owner') ownerJid = value;
              if (varAttr == 'pubsub#num_subscribers' || varAttr == 'muc#roominfo_occupants') {
                numSubscribers = int.tryParse(value ?? '');
              }
              if (varAttr == 'pubsub#type' && value != null) {
                // Determine specification from pubsub type
                if (value == 'urn:xmpp:microblog:0') {
                  nodeType = 'microblog';
                } else if (value == 'urn:xmpp:spaces:0' || value == 'urn:xmpp:spaces:1') {
                  nodeType = 'space';
                } else {
                  nodeType = value.split(':').last;
                }
              }
            }
          }
        }
      }

      final result = SpaceNode(
        domain: domain,
        node: node,
        name: name,
        description: desc,
        avatarUrl: avatar,
        features: features,
        type: nodeType,
        accessModel: accessModel,
        publishModel: publishModel,
        numSubscribers: numSubscribers,
        ownerJid: ownerJid,
        syncedAt: DateTime.now(),
      );
      _metadataCache[cacheKey] = result;
      return result;
    } catch (e) {
      debugPrint('Error fetching metadata for $node: $e');
      return null;
    }
  }

  Future<String?> createSpace(String domain, String node, String name, {String? description, String accessModel = 'open', String publishModel = 'publishers'}) async {
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

    void addField(String name, String value, {String? type}) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', name));
      if (type != null) {
        field.addAttribute(xmpp.XmppAttribute('type', type));
      }
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    }

    addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config', type: 'hidden');
    addField('pubsub#title', name);
    if (description != null) addField('pubsub#description', description);
    addField('pubsub#node_type', 'leaf');
    addField('pubsub#access_model', accessModel);
    addField('pubsub#publish_model', publishModel);
    addField('pubsub#type', 'urn:xmpp:spaces:0');
    addField('pubsub#notify_retract', 'true');
    addField('pubsub#persist_items', 'true');
    addField('pubsub#purge_offline', 'false');
    addField('pubsub#notify_sub', 'true');
    addField('pubsub#notify_config', 'true');
    addField('pubsub#notify_delete', 'true');

    configure.addChild(x);
    pubsub.addChild(configure);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        final errorNode = response.getChild('error');
        if (errorNode != null) {
          if (errorNode.children.any((e) => e.name == 'forbidden' || e.name == 'not-authorized' || e.name == 'INVALID')) {
            return 'Permission denied on $domain. This server does not allow public space creation. Try using your own JID (e.g. user@domain.com) as the PubSub Domain.';
          }
          if (errorNode.children.any((e) => e.name == 'conflict')) {
            return 'A space with this Node ID already exists.';
          }
        }
        return 'Server rejected the space creation request.';
      }
      return null;
    } catch (e) {
      return 'Network error: ${e.toString()}';
    }
  }

  Future<String?> updateSpaceConfig(String domain, String node, {
    String? name,
    String? description,
    String? accessModel,
    String? publishModel,
  }) async {
    final iq = xmpp.IqStanza('config_space_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));

    final configure = xmpp.XmppElement();
    configure.name = 'configure';
    configure.addAttribute(xmpp.XmppAttribute('node', node));
    
    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    void addField(String fieldName, String value, {String? type}) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', fieldName));
      if (type != null) {
        field.addAttribute(xmpp.XmppAttribute('type', type));
      }
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    }

    addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config', type: 'hidden');
    if (name != null) addField('pubsub#title', name);
    if (description != null) addField('pubsub#description', description);
    if (accessModel != null) addField('pubsub#access_model', accessModel);
    if (publishModel != null) addField('pubsub#publish_model', publishModel);

    configure.addChild(x);
    pubsub.addChild(configure);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        return 'Server rejected the configuration update.';
      }
      return null;
    } catch (e) {
      return 'Network error: ${e.toString()}';
    }
  }

  Future<bool> setAffiliation(String domain, String node, String jid, String affiliation) async {
    final iq = xmpp.IqStanza('set_aff_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));

    final affiliations = xmpp.XmppElement();
    affiliations.name = 'affiliations';
    affiliations.addAttribute(xmpp.XmppAttribute('node', node));

    final affiliationEl = xmpp.XmppElement();
    affiliationEl.name = 'affiliation';
    affiliationEl.addAttribute(xmpp.XmppAttribute('jid', jid));
    affiliationEl.addAttribute(xmpp.XmppAttribute('affiliation', affiliation)); // owner, publisher, member, none, outcast

    affiliations.addChild(affiliationEl);
    pubsub.addChild(affiliations);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<bool> inviteMember(String domain, String node, String jid, String role) async {
    return setAffiliation(domain, node, jid, role);
  }

  Future<String?> setSpaceAvatar(String domain, String node, String imageData, String contentType, String ownerJid) async {
    final iq = xmpp.IqStanza('set_avatar_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));

    final configure = xmpp.XmppElement();
    configure.name = 'configure';
    configure.addAttribute(xmpp.XmppAttribute('node', node));

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    void addField(String fieldName, String value, {String? type}) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', fieldName));
      if (type != null) {
        field.addAttribute(xmpp.XmppAttribute('type', type));
      }
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    }

    addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config', type: 'hidden');
    addField('pubsub#node_avatar_url', imageData);

    configure.addChild(x);
    pubsub.addChild(configure);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        return 'Server rejected avatar update.';
      }
      return null;
    } catch (e) {
      return 'Network error: ${e.toString()}';
    }
  }

  Future<String?> setSpaceNotificationLevel(String domain, String node, String level) async {
    final iq = xmpp.IqStanza('set_notif_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));

    final configure = xmpp.XmppElement();
    configure.name = 'configure';
    configure.addAttribute(xmpp.XmppAttribute('node', node));

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    void addField(String fieldName, String value, {String? type}) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', fieldName));
      if (type != null) field.addAttribute(xmpp.XmppAttribute('type', type));
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    }

    addField('FORM_TYPE', 'http://jabber.org/protocol/pubsub#node_config', type: 'hidden');
    addField('pubsub#notification_type', level == 'off' ? 'disable' : 'always');

    configure.addChild(x);
    pubsub.addChild(configure);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        return 'Server rejected notification settings.';
      }
      return null;
    } catch (e) {
      return 'Network error: ${e.toString()}';
    }
  }

  Future<bool> createSpaceChannel(String spaceDomain, String spaceNode, String channelName, String channelJid) async {
    final conference = xmpp.XmppElement();
    conference.name = 'conference';
    conference.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:bookmarks:1'));
    conference.addAttribute(xmpp.XmppAttribute('name', channelName));
    conference.addAttribute(xmpp.XmppAttribute('autojoin', 'true'));

    return publishItem(spaceDomain, spaceNode, conference, itemId: channelJid);
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

  Future<bool> publishItem(String domain, String node, xmpp.XmppElement payload, {String? itemId, bool autoCreateNode = false}) async {
    final iq = xmpp.IqStanza('publish_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', node));
    
    final item = xmpp.XmppElement();
    item.name = 'item';
    // Ensure item has an ID if not provided, as many servers require it for persistent nodes
    item.addAttribute(xmpp.XmppAttribute('id', itemId ?? 'post_${DateTime.now().millisecondsSinceEpoch}'));
    
    item.addChild(payload);
    publish.addChild(item);
    pubsub.addChild(publish);

    if (autoCreateNode) {
      final publishOptions = xmpp.XmppElement();
      publishOptions.name = 'publish-options';
      final x = xmpp.XmppElement();
      x.name = 'x';
      x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
      x.addAttribute(xmpp.XmppAttribute('type', 'submit'));
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'));
      field.addAttribute(xmpp.XmppAttribute('type', 'hidden'));
      final value = xmpp.XmppElement();
      value.name = 'value';
      value.textValue = 'http://jabber.org/protocol/pubsub#publish-options';
      field.addChild(value);
      x.addChild(field);
      publishOptions.addChild(x);
      pubsub.addChild(publishOptions);
    }

    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      return response.type != xmpp.IqStanzaType.ERROR;
    } catch (e) {
      return false;
    }
  }

  Future<bool> publishMicroblogEntry(String domain, String node, {required String title, required String content, String? authorName, String? itemId, String? imageUrl, String? replyToId, List<String>? categories, bool autoCreateNode = false}) async {
    final explicitItemId = itemId ?? 'post_${DateTime.now().millisecondsSinceEpoch}-${node.hashCode}';
    final entry = xmpp.XmppElement();
    entry.name = 'entry';
    entry.addAttribute(xmpp.XmppAttribute('xmlns', 'http://www.w3.org/2005/Atom'));

    // Mandatory Atom fields
    final atomId = xmpp.XmppElement();
    atomId.name = 'id';
    atomId.textValue = 'urn:uuid:$explicitItemId';
    entry.addChild(atomId);

    // XEP-0277 requires title to not be empty. If empty, use truncated content.
    String finalTitle = title.trim();
    if (finalTitle.isEmpty) {
      finalTitle = content.trim().replaceAll('\n', ' ');
      if (finalTitle.length > 50) {
        finalTitle = '${finalTitle.substring(0, 47)}...';
      }
      if (finalTitle.isEmpty) finalTitle = 'Post'; // Fallback for purely image/empty posts
    }

    final titleEl = xmpp.XmppElement();
    titleEl.name = 'title';
    titleEl.addAttribute(xmpp.XmppAttribute('type', 'text'));
    titleEl.textValue = finalTitle;
    entry.addChild(titleEl);

    final updatedEl = xmpp.XmppElement();
    updatedEl.name = 'updated';
    updatedEl.textValue = DateTime.now().toUtc().toIso8601String();
    entry.addChild(updatedEl);

    final contentEl = xmpp.XmppElement();
    contentEl.name = 'content';
    contentEl.addAttribute(xmpp.XmppAttribute('type', 'text'));
    contentEl.textValue = content; 
    entry.addChild(contentEl);

    if (authorName != null) {
      final authorEl = xmpp.XmppElement();
      authorEl.name = 'author';
      final nameEl = xmpp.XmppElement();
      nameEl.name = 'name';
      nameEl.textValue = authorName;
      authorEl.addChild(nameEl);
      entry.addChild(authorEl);
    }

    final publishedEl = xmpp.XmppElement();
    publishedEl.name = 'published';
    publishedEl.textValue = DateTime.now().toUtc().toIso8601String();
    entry.addChild(publishedEl);

    if (imageUrl != null) {
      final linkEl = xmpp.XmppElement();
      linkEl.name = 'link';
      linkEl.addAttribute(xmpp.XmppAttribute('rel', 'enclosure'));
      linkEl.addAttribute(xmpp.XmppAttribute('href', imageUrl));
      entry.addChild(linkEl);
    }

    if (replyToId != null) {
      final thrEl = xmpp.XmppElement();
      thrEl.name = 'thr:in-reply-to';
      thrEl.addAttribute(xmpp.XmppAttribute('xmlns:thr', 'http://purl.org/syndication/thread/1.0'));
      thrEl.addAttribute(xmpp.XmppAttribute('ref', replyToId));
      entry.addChild(thrEl);
    }

    if (categories != null) {
      for (final cat in categories) {
        final catEl = xmpp.XmppElement();
        catEl.name = 'category';
        catEl.addAttribute(xmpp.XmppAttribute('term', cat));
        entry.addChild(catEl);
      }
    }

    return publishItem(domain, node, entry, itemId: explicitItemId, autoCreateNode: autoCreateNode);
  }

  Future<bool> retractItem(String domain, String node, String itemId) async {
    final iq = xmpp.IqStanza('retract_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final retract = xmpp.XmppElement();
    retract.name = 'retract';
    retract.addAttribute(xmpp.XmppAttribute('node', node));
    
    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', itemId));
    
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

  Future<String?> fetchAffiliation(String domain, String node) async {
    final iq = xmpp.IqStanza('aff_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));
    final affiliations = xmpp.XmppElement();
    affiliations.name = 'affiliations';
    affiliations.addAttribute(xmpp.XmppAttribute('node', node));
    pubsub.addChild(affiliations);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      final pubsubRes = response.getChild('pubsub');
      final affsRes = pubsubRes?.getChild('affiliations');
      final affEl = affsRes?.getChild('affiliation');
      return affEl?.getAttribute('affiliation')?.value;
    } catch (e) {
      // Fallback: check if we can publish
      return null;
    }
  }


  Future<bool> isSubscribed(String domain, String node, String bareJid) async {
    final iq = xmpp.IqStanza('is_sub_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final subscriptions = xmpp.XmppElement();
    subscriptions.name = 'subscriptions';
    subscriptions.addAttribute(xmpp.XmppAttribute('node', node));
    pubsub.addChild(subscriptions);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      final pubsubRes = response.getChild('pubsub');
      final subsRes = pubsubRes?.getChild('subscriptions');
      for (var sub in (subsRes?.children.where((e) => e.name == 'subscription') ?? []).cast<xmpp.XmppElement>()) {
        if (sub.getAttribute('jid')?.value?.startsWith(bareJid) == true) {
          return sub.getAttribute('subscription')?.value == 'subscribed';
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> subscribeToSpace(String domain, String node, String bareJid, {String? spaceType}) async {
    // MUC rooms require a presence join rather than a pubsub subscribe
    if (spaceType == 'muc') {
      return _joinMucRoom('$node@$domain', bareJid);
    }

    final iq = xmpp.IqStanza('sub_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final subscribe = xmpp.XmppElement();
    subscribe.name = 'subscribe';
    subscribe.addAttribute(xmpp.XmppAttribute('node', node));
    subscribe.addAttribute(xmpp.XmppAttribute('jid', bareJid));
    
    pubsub.addChild(subscribe);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      final ok = response.type != xmpp.IqStanzaType.ERROR;
      if (ok) notifyListeners();
      return ok;
    } catch (e) {
      return false;
    }
  }

  /// Join a MUC room via XEP-0045 presence stanza.
  Future<bool> _joinMucRoom(String roomJid, String bareJid) async {
    try {
      final nick = bareJid.split('@').first;
      final presence = xmpp.PresenceStanza();
      presence.toJid = xmpp.Jid.fromFullJid('$roomJid/$nick');
      final x = xmpp.XmppElement();
      x.name = 'x';
      x.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));
      presence.addChild(x);
      _connection.writeStanza(presence);
      return true;
    } catch (e) {
      debugPrint('MUC join error: $e');
      return false;
    }
  }

  /// Leave a MUC room via presence unavailable.
  Future<bool> leaveMucRoom(String domain, String node, String bareJid) async {
    try {
      final nick = bareJid.split('@').first;
      final presence = xmpp.PresenceStanza.withType(xmpp.PresenceType.UNAVAILABLE);
      presence.toJid = xmpp.Jid.fromFullJid('$node@$domain/$nick');
      _connection.writeStanza(presence);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> unsubscribeFromSpace(String domain, String node, String bareJid, {String? spaceType}) async {
    // MUC rooms require presence unavailable to leave
    if (spaceType == 'muc') {
      return leaveMucRoom(domain, node, bareJid);
    }

    final iq = xmpp.IqStanza('unsub_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final unsubscribe = xmpp.XmppElement();
    unsubscribe.name = 'unsubscribe';
    unsubscribe.addAttribute(xmpp.XmppAttribute('node', node));
    unsubscribe.addAttribute(xmpp.XmppAttribute('jid', bareJid));
    
    pubsub.addChild(unsubscribe);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      final ok = response.type != xmpp.IqStanzaType.ERROR;
      if (ok) notifyListeners();
      return ok;
    } catch (e) {
      return false;
    }
  }

  Future<List<SpaceItem>> fetchUnifiedFeed(List<SpaceNode> joinedSpaces) async {
    // Use a small batch size for parallel fetches to avoid overwhelming the server
    const int batchSize = 3;
    final List<SpaceItem> allItems = [];

    for (int i = 0; i < joinedSpaces.length; i += batchSize) {
      final batch = joinedSpaces.skip(i).take(batchSize);
      final batchFutures = batch.map((space) => 
        fetchSpaceTreeContent(space.domain, space.node, spaceContext: space, maxDepth: 1)
      ).toList();
      
      final batchResults = await Future.wait(batchFutures);
      for (var res in batchResults) {
        allItems.addAll(res);
      }
    }
    
    // Sort items by publishedDate descending (newest first)
    allItems.sort((a, b) {
      final dateA = a.publishedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final dateB = b.publishedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      return dateB.compareTo(dateA);
    });
    
    return allItems;
  }

  Future<List<SpaceItem>> fetchSpaceTreeContent(String pubsubDomain, String node, {SpaceNode? spaceContext, int depth = 0, int maxDepth = 1}) async {
    if (!pubsubDomain.contains('.') && pubsubDomain != 'localhost') {
       return [];
    }
    final List<SpaceItem> allItems = [];
    final rootItems = await fetchSpaceContent(pubsubDomain, node, spaceContext: spaceContext);
    if (depth >= maxDepth) return rootItems;

    final List<Future<List<SpaceItem>>> futures = [];
    for (var item in rootItems) {
      if (item.type == 'subscription' && item.node != null) {
        final targetDomain = item.jid?.split('@').last ?? pubsubDomain;
        final subContext = SpaceNode(
          domain: targetDomain,
          node: item.node!,
          name: item.name ?? 'Sub-Space',
          avatarUrl: item.imageUrl,
        );
        futures.add(fetchSpaceTreeContent(targetDomain, item.node!, spaceContext: subContext, depth: depth + 1, maxDepth: maxDepth));
      }
    }

    if (futures.isEmpty) return rootItems;

    final results = await Future.wait(futures);
    allItems.addAll(rootItems);
    
    for (var res in results) {
      allItems.addAll(res);
    }

    // Sort items: Non-entries (folders) first, then entries (posts) sorted by date descending.
    allItems.sort((a, b) {
      if (a.type != 'entry' && b.type == 'entry') return -1;
      if (a.type == 'entry' && b.type != 'entry') return 1;
      if (a.type != 'entry' && b.type != 'entry') return 0;
      
      final dateA = a.publishedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final dateB = b.publishedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      return dateB.compareTo(dateA);
    });

    return allItems;
  }

  Future<List<SpaceItem>> fetchSpaceContent(String pubsubDomain, String node, {SpaceNode? spaceContext, bool forceRefresh = false}) async {
    final cacheKey = '$pubsubDomain|$node';
    if (!forceRefresh && _contentCache.containsKey(cacheKey)) {
      return _contentCache[cacheKey]!;
    }

    if (_inflight.containsKey('content|$cacheKey')) {
      debugPrint('DEDUPLICATING SpaceContent request for $cacheKey');
      return await _inflight['content|$cacheKey'] as List<SpaceItem>;
    }

    final future = _fetchSpaceContentImpl(pubsubDomain, node, spaceContext: spaceContext);
    _inflight['content|$cacheKey'] = future;
    try {
      final items = await future;
      _contentCache[cacheKey] = items;
      return items;
    } finally {
      _inflight.remove('content|$cacheKey');
    }
  }

  Future<List<SpaceItem>> _fetchSpaceContentImpl(String pubsubDomain, String node, {SpaceNode? spaceContext}) async {
    
    if (!pubsubDomain.contains('.') && pubsubDomain != 'localhost') {
      debugPrint('Skipping fetchSpaceContent for non-FQDN target: $pubsubDomain');
      return [];
    }

    final isServiceNode = node == pubsubDomain;

    final iq = xmpp.IqStanza('fetch_content_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(pubsubDomain);
    
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    
    final items = xmpp.XmppElement();
    items.name = 'items';
    // When isServiceNode=true, the "node" is actually the service JID — don't set it as the
    // pubsub node attribute. Only set it for real node names.
    if (!isServiceNode) {
      items.addAttribute(xmpp.XmppAttribute('node', node));
    }
    items.addAttribute(xmpp.XmppAttribute('max_items', '50')); // Limit items to prevent timeout
    
    pubsub.addChild(items);
    iq.addChild(pubsub);

    List<SpaceItem> spaceItems = [];
    bool isForbidden = false;

    try {
      final response = await _sendIq(iq);
      
      debugPrint('FETCH SPACE RESPONSE: ${response.type} for $pubsubDomain/$node');

      if (response.type == xmpp.IqStanzaType.ERROR) {
        final error = response.getChild('error');
        isForbidden = error?.getChild('forbidden') != null;
        debugPrint('Space error response (forbidden: $isForbidden)! Continuing to disco fallback...');
      } else {
        final pubsubRes = response.getChild('pubsub');
        final itemsRes = pubsubRes?.getChild('items');
        
        if (itemsRes != null) {
          debugPrint('Found ${itemsRes.children.where((e) => e.name == 'item').length} items.');

          for (var item in itemsRes.children.where((e) => e.name == 'item')) {
        final id = item.getAttribute('id')?.value;
        if (id == null) continue;

        String? name;
        String? type;
        String? url;
        String? subNode;
        String? description;
        String? imageUrl;
        bool isPinned = false;
        String? author;
        DateTime? publishedDate;
        DateTime? updatedDate;
        String? replyToId;
        List<String> categories = [];
        List<MediaAttachment> mediaAttachments = [];
        String? rawContent;
        String? contentType;
        String? commentService;
        String? commentNode;

        for (var child in item.children) {
          final ns = child.getAttribute('xmlns')?.value;
          
          // XEP-0203: Delayed Delivery
          if (child.name == 'delay' && (ns == 'urn:xmpp:delay' || ns == 'jabber:x:delay')) {
            final stamp = child.getAttribute('stamp')?.value;
            if (stamp != null) {
              try { publishedDate ??= DateTime.parse(stamp); } catch (_) {}
            }
          }

          // XEP-0048: Bookmarks (modern)
          if (child.name == 'conference' && ns == 'urn:xmpp:bookmarks:1') {
            type = 'room';
            name = child.getAttribute('name')?.value;
            final extensions = child.getChild('extensions');
            if (extensions != null) {
              for (var ext in extensions.children) {
                if (ext.name == 'pinned' && ext.getAttribute('xmlns')?.value == 'urn:xmpp:bookmarks-pinning:0') {
                  isPinned = true;
                  break;
                }
              }
            }
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

          // XEP-0503 / XEP-0457: Spaces Subscriptions
          if ((child.name == 'space' && (ns == 'urn:xmpp:spaces:0' || ns == 'urn:xmpp:spaces:1')) || 
              (child.name == 'subscription' && ns == 'urn:xmpp:pubsub:subscription:0')) {
            type = 'subscription';
            subNode = child.getAttribute('node')?.value;
            final targetJid = child.getAttribute('server')?.value ?? child.getAttribute('jid')?.value;
            final spaceName = child.getAttribute('name')?.value;
            name = spaceName ?? (subNode != null ? 'Sub-Space: $subNode' : 'Sub-Space');
            url = targetJid; // Store targetJid in url temporarily or pass explicitly
            break;
          }

          // Atom Entry (XEP-0277 / Microblogging / News)
          if (child.name == 'entry' && ns == 'http://www.w3.org/2005/Atom') {
            type = 'entry';
            name = child.getChild('title')?.textValue;
            
            String? httpUrl;
            String? fallbackUrl;

            for (var category in child.children.where((e) => e.name == 'category')) {
               final term = category.getAttribute('term')?.value;
               if (term != null && term.isNotEmpty) { categories.add(term); }
            }

            for (var link in child.children.where((e) => e.name == 'link')) {
               final rel = link.getAttribute('rel')?.value;
               final href = link.getAttribute('href')?.value;
               final typeAttr = link.getAttribute('type')?.value;
               final titleAttr = link.getAttribute('title')?.value;
               
               if (rel == 'alternate' && href != null) {
                  if (href.startsWith('http')) {
                     httpUrl = href;
                   } else {
                      fallbackUrl ??= href;
                   }
               } else if (rel == 'enclosure' && href != null) {
                  mediaAttachments.add(MediaAttachment(url: href, type: typeAttr, title: titleAttr));
                  if (typeAttr != null && typeAttr.startsWith('image/') && imageUrl == null) {
                     imageUrl = href;
                  }
               } else if (rel == 'replies' && href != null) {
                  try {
                    final normalized = href.replaceFirst('xmpp:', 'xmpp://').replaceAll('?;', '?');
                    final uri = Uri.parse(normalized);
                    commentService = uri.host.isNotEmpty ? uri.host : (uri.path.isNotEmpty ? uri.path : null);
                    commentNode = uri.queryParameters['node'];
                  } catch (e) {
                    debugPrint('Error parsing replies link: $e');
                  }
               }
            }
            if (commentNode == null) {
              final rawId = id.replaceAll('urn-uuid-', '').replaceAll('urn:uuid:', '');
              commentNode = 'urn:xmpp:microblog:0:comments/$rawId';
            }
            url = httpUrl ?? fallbackUrl ?? child.getChild('link')?.getAttribute('href')?.value;
            
            description = child.getChild('summary')?.textValue ?? child.getChild('content')?.textValue;
            
            final authorNode = child.getChild('author');
            author = authorNode?.getChild('name')?.textValue ?? authorNode?.getChild('uri')?.textValue;
            
            final thr = child.children.where((e) => e.name == 'in-reply-to' || e.name == 'thr:in-reply-to').firstOrNull;
            replyToId = thr?.getAttribute('ref')?.value;
            
            final publishedStr = child.getChild('published')?.textValue;
            if (publishedStr != null) {
               try { publishedDate = DateTime.parse(publishedStr); } catch (_) {}
            }
            
            final updatedStr = child.getChild('updated')?.textValue;
            if (updatedStr != null) {
               try { updatedDate = DateTime.parse(updatedStr); } catch (_) {}
            }
            
            final contentNode = child.getChild('content');
            contentType = contentNode?.getAttribute('type')?.value;

            if (contentNode != null) {
              final hasChildElements = contentNode.children.isNotEmpty;
              if (hasChildElements) {
                // XHTML content: join child XML strings (strips the outer <content> wrapper)
                rawContent = contentNode.children
                    .map((c) => c.buildXmlString())
                    .join('');
                // Normalise content type so renderer knows to convert HTML→MD
                if (contentType == null || contentType == 'xhtml') {
                  contentType = 'text/html';
                }
              } else {
                // Plain text content
                rawContent = contentNode.textValue;
              }
            }

            // Fall back to <summary> if content is still empty
            if (rawContent == null || rawContent.isEmpty) {
              rawContent = child.getChild('summary')?.textValue;
            }

            // Extract media from inline HTML / Markdown content
            var htmlContent = rawContent ?? description ?? '';
            final imgRegex = RegExp('<img[^>]+src=["\']([^"\']+)["\'][^>]*>');
            for (final match in imgRegex.allMatches(htmlContent)) {
              final src = match.group(1);
              if (src != null && src.isNotEmpty &&
                  !mediaAttachments.any((m) => m.url == src)) {
                mediaAttachments.add(MediaAttachment(url: src, type: 'image/jpeg'));
                imageUrl ??= src;
              }
            }
            htmlContent = htmlContent.replaceAll(imgRegex, '');

            final mdRegex = RegExp(r'!\[.*?\]\((.*?)\)');
            for (final match in mdRegex.allMatches(htmlContent)) {
              final src = match.group(1);
              if (src != null && src.isNotEmpty &&
                  !mediaAttachments.any((m) => m.url == src)) {
                mediaAttachments.add(MediaAttachment(url: src, type: 'image/jpeg'));
                imageUrl ??= src;
              }
            }
            htmlContent = htmlContent.replaceAll(mdRegex, '');

            // Replace stored content with media-stripped version to avoid double render
            if (rawContent != null) rawContent = htmlContent;
            if (description != null) description = htmlContent;
            
            break;
          }
        }

        // Fallback: If no date found yet, try to extract from ID if it follows our pattern 'post_timestamp'
        if (publishedDate == null && id.startsWith('post_')) {
          final tsStr = id.split('_').last;
          final ts = int.tryParse(tsStr);
          if (ts != null) {
            // Some IDs might be in ms, some in us. 
            // If > 10^12 it's likely ms. If > 10^15 it's likely us.
            if (ts > 1000000000000000) {
              publishedDate = DateTime.fromMicrosecondsSinceEpoch(ts);
            } else if (ts > 1000000000000) {
              publishedDate = DateTime.fromMillisecondsSinceEpoch(ts);
            } else if (ts > 1000000000) {
               publishedDate = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
            }
          }
        }

        if (type != null) {
          spaceItems.add(SpaceItem(
            id: id,
            type: type,
            name: name ?? id,
            url: type != 'subscription' ? url : null,
            node: subNode,
            description: description,
            jid: type == 'subscription' ? url : null,
            imageUrl: imageUrl,
            mediaAttachments: mediaAttachments,
            categories: categories,
            replyToId: replyToId,
            isPinned: isPinned,
            author: author,
            publishedDate: publishedDate,
            updatedDate: updatedDate,
            rawContent: rawContent,
            contentType: contentType,
            commentNode: commentNode,
            commentService: commentService,
            sourceSpace: spaceContext,
          ));
        } else {
          // FALLBACK: If no payload recognized, infer from ID or presence of children
          if (id.contains('@')) {
            spaceItems.add(SpaceItem(id: id, type: 'room', name: id, sourceSpace: spaceContext));
          } else {
            final firstChild = item.children.isNotEmpty ? item.children.first : null;
            spaceItems.add(SpaceItem(
              id: id,
              type: 'unknown',
              name: firstChild != null ? 'Item: ${firstChild.name}' : id,
              rawContent: firstChild?.buildXmlString() ?? item.buildXmlString(),
            ));
          } // end inner else
        } // end outer else
      } // end for loop
    } // end if itemsRes != null
  } // end else (not error)
} catch (e) {
      debugPrint('Error fetching space content via pubsub: $e');
    }

    // Always attempt disco fallback to fetch associated MUC rooms or sub-nodes
    try {
      final fallbackItems = await _fetchSpaceContentDiscoFallback(pubsubDomain, node, spaceContext: spaceContext, isForbidden: isForbidden);
      for (final item in fallbackItems) {
        if (!spaceItems.any((i) => i.id == item.id)) {
          spaceItems.add(item);
        }
      }
    } catch (e) {
      debugPrint('Error in disco fallback during fetchSpaceContent: $e');
    }

    return spaceItems;
  }

  Future<List<SpaceItem>> _fetchSpaceContentDiscoFallback(String domain, String node, {SpaceNode? spaceContext, bool isForbidden = false}) async {
    final isServiceNode = node == domain;
    String? extractedName;
    String? category;
    String? type;
    
    // Attempt 1: Query disco#info to see what this thing is
    final infoIq = xmpp.IqStanza('fetch_info_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    infoIq.toJid = xmpp.Jid.fromFullJid(domain);
    final infoQuery = xmpp.XmppElement();
    infoQuery.name = 'query';
    infoQuery.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    if (!isServiceNode) {
      infoQuery.addAttribute(xmpp.XmppAttribute('node', node));
    }
    infoIq.addChild(infoQuery);

    try {
      final infoRes = await _sendIq(infoIq);
      debugPrint('DISCO INFO RESPONSE: ${infoRes.type}');
      if (infoRes.type != xmpp.IqStanzaType.ERROR) {
        final query = infoRes.getChild('query');
        xmpp.XmppElement? identity = query?.getChild('identity');
        if (identity == null && query != null) {
          try {
            identity = query.children.firstWhere((e) => e.name == 'INVALID' && e.getAttribute('category') != null);
          } catch (_) {}
        }
        if (identity != null) {
          category = identity.getAttribute('category')?.value;
          type = identity.getAttribute('type')?.value;
          debugPrint('Node identity: $category/$type');
          
          // Parse metadata fields for the SpaceContext if available
          final xFields = query?.children.where((e) => e.name == 'x' || e.name == 'INVALID') ?? [];
          for (var x in xFields) {
            for (var field in x.children.where((e) => e.name == 'field' || e.name == 'INVALID')) {
              final varAttr = field.getAttribute('var')?.value;
              final val = field.getChild('value')?.textValue;
              if (varAttr == 'pubsub#title' && val != null && val.isNotEmpty) {
                extractedName = val;
              }
            }
          }

          // If it's a conference (MUC), it might be that the space node itself IS the room
          if (category == 'conference' || type == 'text') {
            return [SpaceItem(id: node, type: 'room', name: identity.getAttribute('name')?.value ?? extractedName ?? node)];
          }
        }
      }
    } catch (e) {
      debugPrint('Error in disco info: $e');
    }

    // Attempt 2: Query for items
    if (!domain.contains('.') && domain != 'localhost') {
       debugPrint('Skipping disco fallback for non-FQDN target: $domain');
       return [];
    }

    // Optimization: Skip disco#items on confirmed leaf nodes (leaf nodes only contain posts, which we already have)
    if (category == 'pubsub' && type == 'leaf') {
      debugPrint('Skipping disco#items for leaf node $node (redundant)');
      return [];
    }
    
    final iq = xmpp.IqStanza('fetch_disco_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    if (!isServiceNode) {
      query.addAttribute(xmpp.XmppAttribute('node', node));
    }
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type != xmpp.IqStanzaType.ERROR) {
        final queryRes = response.getChild('query');
        if (queryRes != null && queryRes.children.where((e) => e.name == 'item').isNotEmpty) {
          return _parseDiscoItems(queryRes, spaceContext: spaceContext);
        }
      }
    } catch (e) {
      debugPrint('Error in disco fallback attempt 1: $e');
    }

    if (isForbidden) {
      return [SpaceItem(id: 'forbidden', type: 'error', name: extractedName ?? 'Access Denied', rawContent: 'You must subscribe to this space to view its content.', sourceSpace: spaceContext)];
    }

    return [];
  }

  Future<List<SpaceMember>> fetchMembers(String domain, String node) async {
    final cacheKey = 'members|$domain|$node';
    if (_inflight.containsKey(cacheKey)) {
      debugPrint('DEDUPLICATING Members request for $domain|$node');
      return await _inflight[cacheKey] as List<SpaceMember>;
    }

    final future = _fetchMembersImpl(domain, node);
    _inflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  Future<List<SpaceMember>> _fetchMembersImpl(String domain, String node) async {
    final iq = xmpp.IqStanza('members_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#owner'));
    final affiliations = xmpp.XmppElement();
    affiliations.name = 'affiliations';
    affiliations.addAttribute(xmpp.XmppAttribute('node', node));
    pubsub.addChild(affiliations);
    iq.addChild(pubsub);

    try {
      final response = await _sendIq(iq);
      
      if (response.type == xmpp.IqStanzaType.ERROR) {
        debugPrint('fetchMembers: pubsub#owner request failed. Trying disco#items fallback for $domain/$node');
        // Fallback: try disco#items to see if subscribers are listed
        return await _fetchMembersViaDisco(domain, node);
      }

      final pubsubRes = response.getChild('pubsub');
      final affsRes = pubsubRes?.getChild('affiliations');
      final List<SpaceMember> members = [];
      for (var aff in (affsRes?.children.where((e) => e.name == 'affiliation') ?? []).cast<xmpp.XmppElement>()) {
        final jid = aff.getAttribute('jid')?.value;
        final affiliation = aff.getAttribute('affiliation')?.value;
        if (jid != null && affiliation != null) {
          members.add(SpaceMember(jid: jid, affiliation: affiliation));
        }
      }
      return members;
    } catch (e) {
      debugPrint('Error fetching members: $e');
      return [];
    }
  }

  Future<List<SpaceMember>> _fetchMembersViaDisco(String domain, String node) async {
    final iq = xmpp.IqStanza('disco_members_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(domain);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    if (node.isNotEmpty) {
      query.addAttribute(xmpp.XmppAttribute('node', node));
    }

    // Add RSM to limit results and prevent timeouts on large nodes
    final set = xmpp.XmppElement();
    set.name = 'set';
    set.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'));
    final maxItems = xmpp.XmppElement();
    maxItems.name = 'max';
    maxItems.textValue = '50';
    set.addChild(maxItems);
    query.addChild(set);
    
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) return [];

      final queryRes = response.getChild('query');
      if (queryRes == null) return [];

      final List<SpaceMember> members = [];
      for (var item in queryRes.children.where((e) => e.name == 'item')) {
        final jid = item.getAttribute('jid')?.value;
        final name = item.getAttribute('name')?.value;
        // If it's a JID without a node, it's likely a subscriber/member
        if (jid != null && !item.attributes.any((a) => a.name == 'node')) {
          members.add(SpaceMember(jid: jid, affiliation: 'member', displayName: name));
        }
      }
      return members;
    } catch (e) {
      debugPrint('Error in _fetchMembersViaDisco: $e');
      return [];
    }
  }

  List<SpaceItem> _parseDiscoItems(xmpp.XmppElement queryRes, {SpaceNode? spaceContext}) {
    final List<SpaceItem> spaceItems = [];
    for (var item in queryRes.children.where((e) => e.name == 'item')) {
      final jid = item.getAttribute('jid')?.value;
      final name = item.getAttribute('name')?.value;
      final nodeAttr = item.getAttribute('node')?.value;
      if (jid != null) {
        final isRoom = jid.contains('@') && nodeAttr == null;
        spaceItems.add(SpaceItem(
          id: item.getAttribute('id')?.value ?? jid, // Some disco items have id, else use jid
          type: isRoom ? 'room' : 'subscription',
          name: name ?? (nodeAttr ?? jid),
          node: nodeAttr,
          jid: jid,
          sourceSpace: spaceContext,
        ));
      }
    }
    return spaceItems;
  }

  /// XEP-0444 simplified: publish emoji reaction for a pubsub item.
  /// Reactions are published to a sub-node named "$node/$itemId/reactions".
  Future<bool> publishReaction(String domain, String node, String itemId, String emoji, String userJid) async {
    final reactionNode = '$node/$itemId/reactions';
    final reaction = xmpp.XmppElement();
    reaction.name = 'reactions';
    reaction.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
    reaction.addAttribute(xmpp.XmppAttribute('id', itemId));
    final emojiEl = xmpp.XmppElement();
    emojiEl.name = 'reaction';
    emojiEl.textValue = emoji;
    reaction.addChild(emojiEl);
    return publishItem(domain, reactionNode, reaction, itemId: userJid.replaceAll('@', '_'));
  }

  /// Fetch aggregated emoji reaction counts for a pubsub item.
  Future<Map<String, int>> fetchReactions(String domain, String node, String itemId) async {
    final reactionNode = '$node/$itemId/reactions';
    try {
      final items = await fetchSpaceContent(domain, reactionNode);
      final Map<String, int> counts = {};
      for (final item in items) {
        final content = item.rawContent ?? '';
        if (content.isNotEmpty) {
          counts[content] = (counts[content] ?? 0) + 1;
        }
      }
      return counts;
    } catch (_) {
      return {};
    }
  }

  /// Pin a pubsub item by re-publishing it with a pinned extension.
  Future<bool> pinItem(String domain, String node, String itemId) async {
    // Fetch the item first, then re-publish with pinned extension
    try {
      final iq = xmpp.IqStanza('pin_${DateTime.now().microsecondsSinceEpoch}', xmpp.IqStanzaType.GET);
      iq.toJid = xmpp.Jid.fromFullJid(domain);
      final pubsub = xmpp.XmppElement();
      pubsub.name = 'pubsub';
      pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
      final items = xmpp.XmppElement();
      items.name = 'items';
      items.addAttribute(xmpp.XmppAttribute('node', node));
      final item = xmpp.XmppElement();
      item.name = 'item';
      item.addAttribute(xmpp.XmppAttribute('id', itemId));
      items.addChild(item);
      pubsub.addChild(items);
      iq.addChild(pubsub);

      final response = await _sendIq(iq);
      final itemsRes = response.getChild('pubsub')?.getChild('items');
      final itemEl = itemsRes?.getChild('item');
      if (itemEl == null) return false;

      // Clone the payload and add pinned extension
      final payload = itemEl.children.isNotEmpty ? itemEl.children.first : null;
      if (payload == null) return false;

      final pinned = xmpp.XmppElement();
      pinned.name = 'pinned';
      pinned.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:bookmarks-pinning:0'));

      final conference = itemEl.getChild('conference');
      if (conference != null) {
        var extensions = conference.getChild('extensions');
        if (extensions == null) {
          extensions = xmpp.XmppElement();
          extensions.name = 'extensions';
          conference.addChild(extensions);
        }
        extensions.addChild(pinned);
      }

      return publishItem(domain, node, payload, itemId: itemId);
    } catch (e) {
      debugPrint('pinItem error: $e');
      return false;
    }
  }

  /// Client-side post search — fetches items and filters by query string.
  Future<List<SpaceItem>> searchPosts(String domain, String node, String query) async {
    if (query.trim().isEmpty) return fetchSpaceContent(domain, node);
    final all = await fetchSpaceContent(domain, node);
    final q = query.toLowerCase();
    return all.where((item) {
      return (item.name?.toLowerCase().contains(q) ?? false) ||
             (item.rawContent?.toLowerCase().contains(q) ?? false) ||
             (item.description?.toLowerCase().contains(q) ?? false) ||
             (item.author?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  Future<bool> postReply(String domain, String node, String text, {String? replyToId, String? imageUrl, String? authorName, bool autoCreateNode = true}) async {
    // XEP-0277 / XEP-0060 posting logic
    // We reuse the publishMicroblogEntry logic but specifically for a reply node
    return await publishMicroblogEntry(
      domain,
      node,
      title: '',
      content: text,
      replyToId: replyToId,
      imageUrl: imageUrl,
      authorName: authorName,
      autoCreateNode: autoCreateNode,
    );
  }
  // --- Draft Persistence ---

  Future<Map<String, dynamic>?> loadDraft(String node) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('draft_$node');
    if (jsonStr != null) {
      try {
        return json.decode(jsonStr) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('Failed to decode draft for $node: $e');
      }
    }
    return null;
  }

  Future<void> saveDraft(String node, {String? title, String? content, String? tags, String? imageUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    final draft = {
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (tags != null) 'tags': tags,
      if (imageUrl != null) 'imageUrl': imageUrl,
      'savedAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString('draft_$node', json.encode(draft));
  }

  Future<void> deleteDraft(String node) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('draft_$node');
  }

  Future<List<SpaceNode>> discoverMucRoomsAsSpaces(String serviceJid, {bool forceRefresh = false}) async {
    final cacheKey = 'muc_rooms|$serviceJid';
    if (!forceRefresh && _discoverCache.containsKey(cacheKey)) {
      final cached = _discoverCache[cacheKey]!;
      if (cached.isNotEmpty) return cached;
    }

    final iq = xmpp.IqStanza('disco_muc_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iq.addChild(query);

    try {
      final res = await _sendIq(iq);
      if (res.type == xmpp.IqStanzaType.ERROR) {
        debugPrint('SpacesService: MUC discovery failed for $serviceJid');
        return [];
      }

      final items = <SpaceNode>[];
      final queryEl = res.getChild('query');
      if (queryEl != null) {
        for (final child in queryEl.children) {
          if (child.name == 'item' || child.name == 'INVALID') {
            final jid = child.getAttribute('jid')?.value;
            final name = child.getAttribute('name')?.value ?? jid?.split('@').first ?? 'Unknown Room';
            if (jid != null && !jid.startsWith('echo.') && !jid.startsWith('pubsub.')) {
              items.add(SpaceNode(
                domain: serviceJid,
                node: jid.split('@').first,
                name: name,
                type: 'muc',
                description: null,
              ));
            }
          }
        }
      }

      _discoverCache[cacheKey] = items;
      return items;
    } catch (e) {
      debugPrint('SpacesService: discoverMucRoomsAsSpaces error: $e');
      return [];
    }
  }
}

// -- Bounded LRU Cache with TTL ------------------------------------------------
/// Generic in-memory cache that evicts the oldest entry (LRU) when [maxSize]
/// is exceeded, and considers values stale after [ttl].
class _BoundedCache<K, V> {
  final int maxSize;
  final Duration ttl;

  final _store = <K, _CacheEntry<V>>{};

  _BoundedCache({required this.maxSize, required this.ttl});

  bool containsKey(K key) {
    final entry = _store[key];
    if (entry == null) return false;
    if (DateTime.now().difference(entry.timestamp) > ttl) {
      _store.remove(key);
      return false;
    }
    return true;
  }

  V? operator [](K key) {
    final entry = _store[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.timestamp) > ttl) {
      _store.remove(key);
      return null;
    }
    // LRU: promote to front by updating timestamp on access
    _store[key] = _CacheEntry(entry.value, DateTime.now());
    return entry.value;
  }

  void operator []=(K key, V value) {
    _store.remove(key);
    if (_store.length >= maxSize) {
      _store.remove(_store.keys.first);
    }
    _store[key] = _CacheEntry(value, DateTime.now());
  }

  void remove(K key) => _store.remove(key);
  void clear() => _store.clear();
}

class _CacheEntry<V> {
  final V value;
  final DateTime timestamp;
  _CacheEntry(this.value, this.timestamp);
}