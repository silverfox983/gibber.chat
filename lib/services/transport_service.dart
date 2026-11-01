import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/transport_models.dart';
import 'database_service.dart';
import 'iq_request_manager.dart';

class TransportService {
  final xmpp.Connection _connection;
  final IqRequestManager _iqReqs = IqRequestManager();
  DatabaseService? _db;
  String? _accountId;

  /// Gateway component jids currently being paired/tracked: messages from
  /// these bare components are routed to [pairingEvents] instead of the chat
  /// pipeline (or in addition to it — the sheet decides).
  final Set<String> _trackedGateways = {};

  final Map<String, StreamController<GatewayPairingEvent>> _pairingControllers = {};

  TransportService(this._connection);

  void setDatabase(DatabaseService db) {
    _db = db;
  }

  void setAccountId(String? accountId) {
    _accountId = accountId;
  }

  /// Start streaming pairing events (QR codes, status text, error messages)
  /// for [gatewayJid]. The returned stream is a broadcast listener per call;
  /// close the subscription when the UI goes away.
  Stream<GatewayPairingEvent> listenPairing(String gatewayJid) {
    final lower = gatewayJid.toLowerCase();
    _trackedGateways.add(lower);
    return (_pairingControllers[lower] ??= StreamController<GatewayPairingEvent>.broadcast())
        .stream;
  }

  void stopPairing(String gatewayJid) {
    final lower = gatewayJid.toLowerCase();
    _trackedGateways.remove(lower);
    _pairingControllers.remove(lower)?.close();
  }

  /// Central-dispatch entry point: the connection owner routes incoming
  /// stanzas here (no per-service inStanzasStream subscription).
  void handleStanza(xmpp.AbstractStanza? stanza) {
    if (stanza is xmpp.IqStanza) {
      _iqReqs.complete(stanza.id, stanza);
    }
    if (stanza is xmpp.MessageStanza && _trackedGateways.isNotEmpty) {
      final from = stanza.fromJid;
      if (from == null) return;
      final local = from.local;
      final bare = from.domain.toLowerCase();
      final target = (local == null || local.isEmpty) ? bare : '$local@$bare';
      if (_trackedGateways.contains(target)) {
        _emitPairing(parsePairingMessage(stanza, target));
      }
    }
  }

  void _emitPairing(GatewayPairingEvent? event) {
    if (event == null) return;
    final controller = _pairingControllers[event.gatewayJid];
    controller?.add(event);
  }

  /// Pure message parser: turns a message from a gateway component into a
  /// pairing event. Handles:
  ///  - XEP-0066 oob data (jabber:x:oob → url),
  ///  - XEP-0446/0447 Stateless File Sharing (the QR PNG arrives this way in
  ///    current slidge: <sources><reference type="data" uri="..."/>,
  ///    plus the legacy url-data alternative),
  ///  - data forms (next-step forms),
  ///  - regular body text as status lines,
  ///  - success phrasing slidge uses after a completed pairing.
  static GatewayPairingEvent? parsePairingMessage(
    xmpp.MessageStanza stanza,
    String gatewayJid,
  ) {
    final body = stanza.getChild('body')?.textValue;

    String? url;
    xmpp.XmppElement? xForm;
    for (final child in stanza.children.whereType<xmpp.XmppElement>()) {
      final ns = child.getAttribute('xmlns')?.value;
      if (child.name == 'x' && ns == 'jabber:x:oob') {
        url ??= child.getChild('url')?.textValue ?? child.textValue;
      }
      if (child.name == 'x' && ns == 'jabber:x:data') xForm = child;
      if (child.name == 'sources') {
        for (final ref in child.children.whereType<xmpp.XmppElement>()) {
          if (ref.name == 'reference' && ref.getAttribute('type')?.value == 'data') {
            url ??= ref.getAttribute('uri')?.value;
          }
          if (ref.name == 'url-data') {
            url ??= ref.getAttribute('target')?.value;
          }
        }
      }
    }
    if (url == null) {
      final oobX = stanza.getChild('x');
      if (oobX != null && oobX.getAttribute('xmlns')?.value == 'jabber:x:oob') {
        url = oobX.getChild('url')?.textValue;
      }
    }

    if (url != null && url.trim().isNotEmpty) {
      return GatewayPairingEvent(
        kind: 'qr',
        gatewayJid: gatewayJid,
        oobUrl: url.trim(),
        text: body,
      );
    }

    if (xForm != null) {
      final nextForm = parseFormElement(xForm);
      if (nextForm != null) {
        return GatewayPairingEvent(
          kind: 'form',
          gatewayJid: gatewayJid,
          text: body,
          form: TransportRegistrationForm(
            isRegistered: false,
            instructions: nextForm.instructions ?? body,
            formType: nextForm.formType,
            fields: nextForm.fields,
          ),
        );
      }
    }

    final text = body?.trim();
    if (text == null || text.isEmpty) return null;

    final lower = text.toLowerCase();
    if (lower.contains('you can close this') ||
        lower.contains('logged in') ||
        lower.contains('connected to') ||
        lower.contains('successfully paired') ||
        lower.contains('pairing complete') ||
        lower.contains('logged as') ||
        lower.contains('registration complete')) {
      return GatewayPairingEvent(
        kind: 'success',
        gatewayJid: gatewayJid,
        text: text,
      );
    }

    return GatewayPairingEvent(
      kind: 'text',
      gatewayJid: gatewayJid,
      text: text,
    );
  }

  /// Parse a `jabber:x:data` form element into a [TransportRegistrationForm].
  /// Reusable for iq-register responses that carry a follow-up form.
  static TransportRegistrationForm? parseFormElement(xmpp.XmppElement xForm) {
    final fields = <FormField>[];
    String? formType;
    for (var field in xForm.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'field' || e.name == 'INVALID')) {
      final varName = field.getAttribute('var')?.value;
      final type = field.getAttribute('type')?.value;
      if (type == 'hidden') {
        if (varName == 'FORM_TYPE') {
          formType = field.getChild('value')?.textValue;
        }
        continue;
      }
      if (varName == null) continue;
      final options = <FormFieldOption>[];
      if (type == 'list-single' || type == 'list-multi') {
        for (var opt in field.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'option' || e.name == 'INVALID')) {
          final label = opt.getAttribute('label')?.value ?? '';
          final val = opt.getChild('value')?.textValue ??
              opt.children.whereType<xmpp.XmppElement>().firstOrNull?.textValue ?? '';
          if (val.isNotEmpty) options.add(FormFieldOption(label: label.isNotEmpty ? label : val, value: val));
        }
      }
      fields.add(FormField(
        varName: varName,
        type: type ?? 'text-single',
        label: field.getAttribute('label')?.value ?? varName,
        value: field.getChild('value')?.textValue,
        options: options.isNotEmpty ? options : null,
      ));
    }
    return TransportRegistrationForm(
      isRegistered: false,
      formType: formType,
      fields: fields,
    );
  }

  void dispose() {
    _iqReqs.failAll('Service disposed');
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, {int retries = 1}) async {
    if (originalIq.toJid == null) return Future.error('No toJid');

    int attempt = 0;
    while (attempt <= retries) {
      final id = 'transport_${xmpp.AbstractStanza.getRandomId()}';
      final iq = xmpp.IqStanza(id, originalIq.type);
      iq.toJid = originalIq.toJid;
      if (originalIq.fromJid != null) iq.fromJid = originalIq.fromJid;
      for (var child in originalIq.children) {
        iq.addChild(child);
      }

      final completer = Completer<xmpp.IqStanza>();
      _iqReqs.register(id, completer);
      _connection.writeStanza(iq);

      try {
        return await completer.future.timeout(const Duration(seconds: 15));
      } catch (e) {
        _iqReqs.forget(id);
        if (attempt >= retries) {
          debugPrint('Transport IQ failed after ${retries + 1} attempts to ${iq.toJid!.fullJid}: $e');
          rethrow;
        }
        attempt++;
        debugPrint('Retrying Transport IQ to ${iq.toJid!.fullJid} (Attempt ${attempt + 1})...');
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return Future.error('Unexpected fallthrough in _sendIq');
  }

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
        // Fallback to basic XEP-0077 fields — skip instructions, registered, key, oob, x, etc.
        final skipNames = {'instructions', 'registered', 'key', 'oob', 'x', 'query', 'stream:error'};
        for (var child in queryRes.children.whereType<xmpp.XmppElement>().where((e) => !skipNames.contains(e.name))) {
          fields.add(FormField(
            varName: child.name ?? 'unknown',
            type: child.name == 'password' ? 'text-private' : 'text-single',
            label: child.name?.toUpperCase() ?? 'UNKNOWN',
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

  /// Submit the registration form (XEP-0077) and return a structured result:
  /// success (or a follow-up form for multi-step flows like Telegram's code
  /// entry), the parsed error text, and post-success side effects
  /// (persisting the transport + a roster refresh so gateway contacts appear).
  Future<GatewaySubmitResult> submitRegistration(
    String gatewayJid,
    Map<String, String> formData, {
    String? formType,
  }) async {
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
    final lowerGw = gatewayJid.toLowerCase();
    _trackedGateways.add(lowerGw); // expect pairing messages after submit

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.RESULT) {
        // Persist the transport for re-discovery + contact mapping.
        if (_db != null) {
          try {
            await _db!.saveRegisteredTransport(
              gatewayJid: gatewayJid,
              gatewayName: gatewayJid.split('.').first,
              gatewayType: gatewayJid.contains('telegram') ? 'telegram' :
                           gatewayJid.contains('discord') ? 'discord' :
                           gatewayJid.contains('matrix') ? 'matrix' :
                           gatewayJid.contains('whatsapp') ? 'whatsapp' :
                           gatewayJid.contains('irc') ? 'irc' : 'gateway',
              username: formData['username'],
              password: formData['password'],
              accountId: _accountId,
            );
          } catch (e) {
            debugPrint('Transport: failed to persist registered transport: $e');
          }
        }
        _refreshRoster();

        // A RESULT may carry a follow-up form (gateway-driven multi-step).
        final queryRes = response.getChild('query');
        final xRes = queryRes?.children
            .whereType<xmpp.XmppElement>()
            .firstWhere((e) => e.name == 'x' && e.getAttribute('xmlns')?.value == 'jabber:x:data',
                orElse: () => xmpp.XmppElement()..name = 'NONE');
        if (xRes != null && xRes.name == 'x') {
          final parsed = parseFormElement(xRes);
          if (parsed != null && parsed.fields.any((f) => f.type != 'hidden')) {
            return GatewaySubmitResult(success: true, nextForm: parsed);
          }
        }
        return const GatewaySubmitResult(success: true);
      }

      // ERROR: extract the human-readable reason.
      String? text;
      final errorEl = response.getChild('error');
      if (errorEl != null) {
        final known = errorEl.children
            .whereType<xmpp.XmppElement>()
            .map((e) => e.name)
            .whereType<String>()
            .where((n) => n != 'text')
            .join(', ');
        final textEl = errorEl.getChild('text')?.textValue;
        text = [
          if (known.isNotEmpty) known,
          if (textEl != null && textEl.isNotEmpty) textEl,
        ].join(': ');
      }
      return GatewaySubmitResult(success: false, errorText: text ?? 'Registration failed');
    } catch (e) {
      debugPrint('Error submitting registration: $e');
      _trackedGateways.remove(lowerGw);
      return GatewaySubmitResult(success: false, errorText: 'Network error: $e');
    }
  }

  static String matrixComponentPrefix() => 'matrix';

  /// Re-fetch the roster so mid-session gateway registration contact imports
  /// flow through the RosterManager's rosterStream.
  void _refreshRoster() {
    try {
      xmpp.RosterManager.getInstance(_connection).queryForRoster();
    } catch (e) {
      debugPrint('Transport: roster refresh failed: $e');
    }
  }

  /// List the chats a registered gateway exposes (Discord guild channels,
  /// Telegram group chats...) via disco#items on the component jid.
  Future<List<GatewayChatItem>> fetchComponentChats(String gatewayJid) async {
    final iq = xmpp.IqStanza('gw_items_${xmpp.AbstractStanza.getRandomId()}', xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      return parseComponentItems(response);
    } catch (e) {
      debugPrint('Transport: component chats failed for $gatewayJid: $e');
      return [];
    }
  }

  /// Pure parser for a disco#items response → gateway chats (MUC rooms only
  /// have meaningful jids with a local part; the component's own adhoc command
  /// items have no local part and are skipped).
  static List<GatewayChatItem> parseComponentItems(xmpp.IqStanza response) {
    final items = <GatewayChatItem>[];
    if (response.type != xmpp.IqStanzaType.RESULT) return items;
    final queryEl = response.getChild('query') ??
        response.children
            .whereType<xmpp.XmppElement>()
            .where((e) => e.name == 'query')
            .firstOrNull;
    if (queryEl == null) return items;
    for (final item in queryEl.children.whereType<xmpp.XmppElement>().where((e) => e.name == 'item')) {
      final jid = item.getAttribute('jid')?.value;
      if (jid == null || jid.isEmpty) continue;
      final local = jid.contains('@') ? jid.split('@').first : jid;
      if (local == jid) continue; // component-level item (adhoc command)
      final name = item.getAttribute('name')?.value ?? local;
      items.add(GatewayChatItem(jid: jid, name: name));
    }
    return items;
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
      final success = response.type == xmpp.IqStanzaType.RESULT;
      if (success && _db != null) {
        await _db!.removeRegisteredTransport(gatewayJid);
      }
      return success;
    } catch (e) {
      debugPrint('Error unregistering: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getRegisteredTransports() async {
    if (_db == null) return [];
    return await _db!.getRegisteredTransports();
  }

  Future<String?> translateGatewayAddress(String gatewayJid, String legacyAddress) async {
    final iq = xmpp.IqStanza(
      'gw_translate_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:gateway'));

    final prompt = xmpp.XmppElement();
    prompt.name = 'prompt';
    prompt.textValue = legacyAddress;
    query.addChild(prompt);
    iq.addChild(query);

    try {
      final response = await _sendIq(iq);
      if (response.type == xmpp.IqStanzaType.RESULT) {
        final queryEl = response.getChild('query');
        if (queryEl != null) {
          return queryEl.getChild('prompt')?.textValue;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error translating gateway address: $e');
      return null;
    }
  }

  Future<List<Map<String, String>>> searchGatewayContacts(
    String gatewayJid,
    String query,
  ) async {
    final iqId = 'gw_search_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(gatewayJid);

    final search = xmpp.XmppElement();
    search.name = 'query';
    search.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:search'));

    search.addChild(
      xmpp.XmppElement()..name = 'nick'..textValue = query,
    );

    iq.addChild(search);

    try {
      final response = await _sendIq(iq);
      final results = <Map<String, String>>[];
      if (response.type == xmpp.IqStanzaType.RESULT) {
        final queryEl = response.getChild('query');
        if (queryEl != null) {
          for (var item in queryEl.children.where((c) => c.name == 'item')) {
            final result = <String, String>{};
            result['jid'] = item.getAttribute('jid')?.value ?? '';
            for (var field in item.children.whereType<xmpp.XmppElement>()) {
              if (field.name != null && field.textValue != null) {
                result[field.name!] = field.textValue!;
              }
            }
            results.add(result);
          }
        }
      }
      return results;
    } catch (e) {
      debugPrint('Error searching gateway contacts: $e');
      return [];
    }
  }
}
