import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/transport_models.dart';

class TransportService {
  final xmpp.Connection _connection;
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};
  late StreamSubscription<xmpp.AbstractStanza?> _subscription;

  TransportService(this._connection) {
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

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza iq, {int retries = 1}) async {
    if (iq.toJid == null) return Future.error('No toJid');
    
    int attempt = 0;
    while (attempt <= retries) {
      final id = iq.id ?? 'transport_${xmpp.AbstractStanza.getRandomId()}';
      iq.id = id;
      final completer = Completer<xmpp.IqStanza>();
      _pendingIqs[id] = completer;
      _connection.writeStanza(iq);

      try {
        return await completer.future.timeout(const Duration(seconds: 15));
      } catch (e) {
        _pendingIqs.remove(id);
        if (attempt >= retries) {
          debugPrint('Transport IQ failed after ${retries + 1} attempts to ${iq.toJid!.fullJid}: $e');
          rethrow;
        }
        attempt++;
        debugPrint('Retrying Transport IQ to ${iq.toJid!.fullJid} (Attempt ${attempt + 1})...');
        await Future.delayed(Duration(milliseconds: 500 * attempt));
        iq.id = 'transport_retry_${xmpp.AbstractStanza.getRandomId()}';
      }
    }
    return Future.error('Unexpected fallthrough in _sendIq');
  }

  /// Discover gateways on the given domain.
  /// Discover gateways on the given domain.
  Future<List<TransportNode>> discoverTransports(String domain,
      {void Function(TransportNode)? onGatewayDiscovered, int maxDepth = 2, Set<String>? visited}) async {
    final List<TransportNode> gateways = [];
    final Set<String> seen = visited ?? {};
    final Set<String> emitted = {};

    // helper to add without duplicates
    void emit(TransportNode node) {
      if (!emitted.contains(node.jid)) {
        emitted.add(node.jid);
        gateways.add(node);
        onGatewayDiscovered?.call(node);
      }
    }

    // helper to probe a single JID for gateway identity
    Future<void> probeService(String serviceJid, int currentDepth) async {
      if (seen.contains(serviceJid) && currentDepth > 0) return;
      seen.add(serviceJid);

      try {
        final infoIq = xmpp.IqStanza('disco_info_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
        infoIq.toJid = xmpp.Jid.fromFullJid(serviceJid);
        final infoQuery = xmpp.XmppElement()
          ..name = 'query'
          ..addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
        infoIq.addChild(infoQuery);

        final infoRes = await _sendIq(infoIq);
        debugPrint('T_PROBE: Received response for $serviceJid (id=${infoRes.id})');
        
        final infoQueryRes = infoRes.getChild('query') ??
            infoRes.children
                .whereType<xmpp.XmppElement>()
                .where((e) => e.name == 'query' || e.name == 'INVALID')
                .firstOrNull;

        if (infoQueryRes == null) {
          debugPrint('T_PROBE: No query result for $serviceJid. Children: ${infoRes.children.length}');
          return;
        }
        
        debugPrint('T_PROBE: Parsed query for $serviceJid with ${infoQueryRes.children.length} children');

        bool isGateway = false;
        bool isServer = false;

        // Check features first to see if it behaves like a gateway
        bool hasGatewayFeature = false;
        bool hasItemsFeature = false;
        for (var child in infoQueryRes.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'feature' || e.name == 'INVALID')) {
          final varAttr = child.getAttribute('var')?.value;
          if (varAttr == 'jabber:iq:gateway' || varAttr == 'jabber:iq:register') {
            hasGatewayFeature = true;
          }
          if (varAttr == 'http://jabber.org/protocol/disco#items') {
            hasItemsFeature = true;
          }
        }

        for (var identity in infoQueryRes.children
            .whereType<xmpp.XmppElement>()
            .where((e) => e.runtimeType.toString() == 'Identity' || e.name == 'identity' || e.name == 'INVALID')) {
          final cat = identity.getAttribute('category')?.value?.toLowerCase();
          final type = identity.getAttribute('type')?.value?.toLowerCase();
          final name = identity.getAttribute('name')?.value ?? serviceJid;
          
          debugPrint('Probe $serviceJid: category=$cat, type=$type, name=$name (hasGatewayFeature=$hasGatewayFeature)');

          if (cat == 'gateway' || hasGatewayFeature) {
            isGateway = true;
            emit(TransportNode(jid: serviceJid, name: name, type: type ?? 'unknown'));
            debugPrint('Found Gateway: $name ($serviceJid) type=$type');
          } 
          
          if (cat == 'server' || cat == 'im' || cat == 'pubsub' || cat == 'directory') {
            isServer = true;
          }
        }
        
        debugPrint('T_PROBE: $serviceJid evaluation complete. isGateway=$isGateway, isServer=$isServer, hasItems=$hasItemsFeature');

        // If it's a hub/server and we haven't reached maxDepth, discover its items
        if ((isServer || hasItemsFeature) && currentDepth < maxDepth) {
          debugPrint('T_PROBE: Fetching sub-items for $serviceJid (depth $currentDepth < $maxDepth)');
          final subItems = await _fetchItems(serviceJid);
          debugPrint('T_PROBE: Got ${subItems.length} items from $serviceJid');
          for (int i = 0; i < subItems.length; i += 10) {
            final chunk = subItems.skip(i).take(10);
            await Future.wait(chunk.map((jid) => probeService(jid, currentDepth + 1)));
          }
        }
      } catch (e, stack) {
        debugPrint('T_PROBE: Transport probe skipped $serviceJid (depth $currentDepth): $e\n$stack');
      }
    }

    await probeService(domain, 0);
    return gateways;
  }

  Future<List<String>> _fetchItems(String jid) async {
    try {
      final itemsIq = xmpp.IqStanza('disco_items_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
      itemsIq.toJid = xmpp.Jid.fromFullJid(jid);
      final itemsQuery = xmpp.XmppElement()
        ..name = 'query'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
      itemsIq.addChild(itemsQuery);

      final itemsRes = await _sendIq(itemsIq);
      final queryRes = itemsRes.getChild('query') ??
          itemsRes.children
              .whereType<xmpp.XmppElement>()
              .where((e) => e.name == 'query' || e.name == 'INVALID')
              .firstOrNull;

      if (queryRes == null) return [];

      return queryRes.children
          .whereType<xmpp.XmppElement>()
          .where((e) => e.name == 'item' || e.name == 'INVALID')
          .map((e) => e.getAttribute('jid')?.value)
          .whereType<String>()
          .where((jid) => jid.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Failed to fetch items for $jid: $e');
      return [];
    }
  }


  /// Fetch the registration form (XEP-0077) for a gateway
  Future<TransportRegistrationForm?> fetchRegistrationForm(String gatewayJid) async {
    final iq = xmpp.IqStanza('reg_form_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:register'));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.ERROR) {
        throw Exception('Gateway returned an error.');
      }

      final queryRes = response.getChild('query') ?? response.children.where((e) => e.name == 'query' || e.name == 'INVALID').cast<xmpp.XmppElement?>().firstOrNull;
      if (queryRes == null) return null;

      final isRegistered = queryRes.getChild('registered') != null;
      final instructions = queryRes.getChild('instructions')?.textValue;
      final List<FormField> fields = [];

      // Check for XEP-0066 OOB Data (often used for OAuth links)
      String? oobUrl;
      final oobElement = queryRes.children.firstWhere(
        (e) => e.name == 'x' && e.getAttribute('xmlns')?.value == 'jabber:x:oob',
        orElse: () => xmpp.XmppElement()..name = 'NOT_FOUND',
      );
      if (oobElement.name == 'x') {
        oobUrl = oobElement.getChild('url')?.textValue ?? oobElement.children.where((e) => e.name == 'url' || e.name == 'INVALID').firstOrNull?.textValue;
      }

      // Check for XEP-0004 Data Form
      final xForm = queryRes.children.firstWhere(
        (e) => e.name == 'x' && e.getAttribute('xmlns')?.value == 'jabber:x:data',
        orElse: () => xmpp.XmppElement()..name = 'NOT_FOUND',
      );

      String? formType;

      if (xForm.name == 'x') {
        for (var field in xForm.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'field' || e.name == 'INVALID')) {
          final type = field.getAttribute('type')?.value;
          final varName = field.getAttribute('var')?.value;
          
          if (varName == 'FORM_TYPE') {
            formType = field.getChild('value')?.textValue ?? field.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'value' || e.name == 'INVALID').firstOrNull?.textValue;
            continue; // Don't show FORM_TYPE in UI
          }
          if (type == 'hidden' || varName == null) continue; // Skip other hidden fields for UI
          
          final options = <FormFieldOption>[];
          if (type == 'list-single' || type == 'list-multi') {
            for (var opt in field.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'option' || e.name == 'INVALID')) {
              final label = opt.getAttribute('label')?.value ?? '';
              final val = opt.getChild('value')?.textValue ?? opt.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'value' || e.name == 'INVALID').firstOrNull?.textValue ?? '';
              if (val.isNotEmpty) options.add(FormFieldOption(label: label.isNotEmpty ? label : val, value: val));
            }
          }

          fields.add(FormField(
            varName: varName,
            type: type ?? 'text-single',
            label: field.getAttribute('label')?.value ?? varName,
            value: field.getChild('value')?.textValue ?? field.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'value' || e.name == 'INVALID').firstOrNull?.textValue,
            options: options.isNotEmpty ? options : null,
          ));
        }
      } else {
        // Fallback to basic XEP-0077 fields
        for (var child in queryRes.children.where((e) => e.name != 'instructions' && e.name != 'registered')) {
          fields.add(FormField(
            varName: child.name ?? 'unknown',
            type: child.name == 'password' ? 'text-private' : 'text-single',
            label: child.name?.toUpperCase(),
          ));
        }
      }

      return TransportRegistrationForm(
        isRegistered: isRegistered,
        instructions: instructions,
        oobUrl: oobUrl,
        formType: formType,
        fields: fields,
      );
    } catch (e) {
      debugPrint('Error fetching registration form: $e');
      rethrow;
    }
  }

  /// Submit the registration form (XEP-0077)
  Future<bool> submitRegistration(String gatewayJid, Map<String, String> formData, {String? formType}) async {
    final iq = xmpp.IqStanza('reg_submit_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:register'));

    if (formType != null) {
      // Server requested a XEP-0004 Data Form, construct it strictly
      final xForm = xmpp.XmppElement();
      xForm.name = 'x';
      xForm.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
      xForm.addAttribute(xmpp.XmppAttribute('type', 'submit'));

      // Add FORM_TYPE
      final ftField = xmpp.XmppElement();
      ftField.name = 'field';
      ftField.addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'));
      ftField.addAttribute(xmpp.XmppAttribute('type', 'hidden'));
      final ftVal = xmpp.XmppElement();
      ftVal.name = 'value';
      ftVal.textValue = formType;
      ftField.addChild(ftVal);
      xForm.addChild(ftField);

      formData.forEach((key, value) {
        final field = xmpp.XmppElement();
        field.name = 'field';
        field.addAttribute(xmpp.XmppAttribute('var', key));
        if (value.isNotEmpty) {
          final valNode = xmpp.XmppElement();
          valNode.name = 'value';
          valNode.textValue = value;
          field.addChild(valNode);
        }
        xForm.addChild(field);
      });
      query.addChild(xForm);
    } else {
      // Basic XEP-0077 Fields
      formData.forEach((key, value) {
        if (value.isNotEmpty) {
          final field = xmpp.XmppElement();
          field.name = key;
          field.textValue = value;
          query.addChild(field);
        }
      });
    }

    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      return response.type == xmpp.IqStanzaType.RESULT;
    } catch (e) {
      debugPrint('Error submitting registration: $e');
      return false;
    }
  }

  /// Unregister from the gateway
  Future<bool> unregister(String gatewayJid) async {
    final iq = xmpp.IqStanza('unreg_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:register'));
    
    final removeNode = xmpp.XmppElement();
    removeNode.name = 'remove';
    query.addChild(removeNode);
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      return response.type == xmpp.IqStanzaType.RESULT;
    } catch (e) {
      debugPrint('Error unregistering: $e');
      return false;
    }
  }
}
