import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class XmppServerInfoService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppServerInfoService(this._connections, this._xmppJids);

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  Future<ServerContactInfo?> fetchContactInfo(String accountId) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final domain = _xmppJids[accountId]?.split('@').lastOrNull ?? '';
    if (domain.isEmpty) return null;

    final iq = xmpp.IqStanza(
      'contact_info_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(domain);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:serverinfo:0'));
    iq.addChild(query);

    try {
      final res = await _sendIq(iq, conn);
      final queryRes = res.getChild('query');
      if (queryRes == null) return null;

      final contactAddresses = <ServerContactAddress>[];

      for (var addr in queryRes.children.where((e) => e.name == 'contact')) {
        final type = addr.getAttribute('type')?.value;
        final value = addr.textValue;
        if (type != null && value != null) {
          contactAddresses.add(ServerContactAddress(type: type, address: value));
        }
      }

      return ServerContactInfo(addresses: contactAddresses);
    } catch (e) {
      debugPrint('ServerInfo: Contact info fetch failed: $e');
      return null;
    }
  }

  Future<List<AdHocCommand>> fetchAdHocCommands(String accountId, {String? targetJid}) async {
    final conn = _connections[accountId];
    if (conn == null) return [];

    final domain = _xmppJids[accountId]?.split('@').lastOrNull ?? '';
    if (domain.isEmpty) return [];

    final target = targetJid ?? domain;
    final bareJid = target.split('/').first;

    final iq = xmpp.IqStanza(
      'adhoc_list_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    query.addAttribute(xmpp.XmppAttribute('node', 'http://jabber.org/protocol/commands'));
    iq.addChild(query);

    try {
      final res = await _sendIq(iq, conn);
      final queryRes = res.getChild('query');
      if (queryRes == null) return [];

      final commands = <AdHocCommand>[];
      for (var item in queryRes.children.where((e) => e.name == 'item' || e.name == 'INVALID')) {
        final jid = item.getAttribute('jid')?.value;
        final node = item.getAttribute('node')?.value;
        final name = item.getAttribute('name')?.value;
        if (jid != null && node != null) {
          commands.add(AdHocCommand(
            jid: jid,
            node: node,
            name: name ?? node,
          ));
        }
      }
      return commands;
    } catch (e) {
      debugPrint('AdHoc: Command list fetch failed: $e');
      return [];
    }
  }

  Future<AdHocCommandResult> executeAdHocCommand({
    required String accountId,
    required String commandJid,
    required String commandNode,
    String? sessionId,
    Map<String, String>? formValues,
    String action = 'execute',
  }) async {
    final conn = _connections[accountId];
    if (conn == null) {
      return AdHocCommandResult(status: 'error', message: 'Not connected');
    }

    final iq = xmpp.IqStanza(
      'adhoc_exec_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(commandJid.split('/').first);

    final command = xmpp.XmppElement();
    command.name = 'command';
    command.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/commands'));
    command.addAttribute(xmpp.XmppAttribute('node', commandNode));
    command.addAttribute(xmpp.XmppAttribute('action', action));
    if (sessionId != null) {
      command.addAttribute(xmpp.XmppAttribute('sessionid', sessionId));
    }

    if (formValues != null) {
      final x = xmpp.XmppElement();
      x.name = 'x';
      x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
      x.addAttribute(xmpp.XmppAttribute('type', 'submit'));
      formValues.forEach((varAttr, value) {
        final field = xmpp.XmppElement()..name = 'field';
        field.addAttribute(xmpp.XmppAttribute('var', varAttr));
        final val = xmpp.XmppElement()..name = 'value'..textValue = value;
        field.addChild(val);
        x.addChild(field);
      });
      command.addChild(x);
    }

    iq.addChild(command);

    try {
      final res = await _sendIq(iq, conn);
      final cmdRes = res.getChild('command');
      if (cmdRes == null) {
        return AdHocCommandResult(
          status: res.type == xmpp.IqStanzaType.ERROR ? 'error' : 'completed',
        );
      }

      final status = cmdRes.getAttribute('status')?.value ?? 'completed';
      final resSessionId = cmdRes.getAttribute('sessionid')?.value;

      final note = cmdRes.getChild('note');
      final noteType = note?.getAttribute('type')?.value;
      final noteText = note?.textValue;

      final xDataForms = <AdHocForm>[];
      for (var x in cmdRes.children.where((e) => e.name == 'x')) {
        final xmlns = x.getAttribute('xmlns')?.value;
        if (xmlns == 'jabber:x:data') {
          final formType = x.children
              .where((f) => f.name == 'field' && f.getAttribute('var')?.value == 'FORM_TYPE')
              .firstOrNull
              ?.getChild('value')
              ?.textValue;
          final title = x.getChild('title')?.textValue;
          final instructions = <String>[];
          final fields = <AdHocFormField>[];

          for (var field in x.children.where((f) => f.name == 'field')) {
            final varAttr = field.getAttribute('var')?.value ?? '';
            final type = field.getAttribute('type')?.value ?? 'text-single';
            final label = field.getAttribute('label')?.value;
            final values = field.children
                .where((v) => v.name == 'value')
                .map((v) => v.textValue ?? '')
                .toList();
            final options = field.children
                .where((o) => o.name == 'option')
                .map((o) {
                  final optLabel = o.getAttribute('label')?.value;
                  final optValue = o.getChild('value')?.textValue ?? '';
                  return AdHocOption(label: optLabel, value: optValue);
                })
                .toList();
            final isRequired = field.children.any((r) => r.name == 'required');
            fields.add(AdHocFormField(
              varAttr: varAttr,
              type: type,
              label: label,
              values: values,
              options: options,
              isRequired: isRequired,
            ));
          }

          for (var instr in x.children.where((i) => i.name == 'instructions')) {
            if (instr.textValue != null) instructions.add(instr.textValue!);
          }

          xDataForms.add(AdHocForm(
            formType: formType,
            title: title,
            instructions: instructions,
            fields: fields,
          ));
        }
      }

      return AdHocCommandResult(
        status: status,
        sessionId: resSessionId,
        noteType: noteType,
        noteText: noteText,
        forms: xDataForms,
      );
    } catch (e) {
      debugPrint('AdHoc: Command execution failed: $e');
      return AdHocCommandResult(status: 'error', message: e.toString());
    }
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, xmpp.Connection conn,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final id = 'serverinfo_${xmpp.AbstractStanza.getRandomId()}';
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

class ServerContactInfo {
  final List<ServerContactAddress> addresses;

  ServerContactInfo({required this.addresses});

  String? get email => addresses.where((a) => a.type == 'email').firstOrNull?.address;
  String? get website => addresses.where((a) => a.type == 'web').firstOrNull?.address;
  String? get xmpp => addresses.where((a) => a.type == 'xmpp').firstOrNull?.address;
}

class ServerContactAddress {
  final String type;
  final String address;

  ServerContactAddress({required this.type, required this.address});
}

class AdHocCommand {
  final String jid;
  final String node;
  final String name;

  AdHocCommand({required this.jid, required this.node, required this.name});
}

class AdHocCommandResult {
  final String status;
  final String? sessionId;
  final String? noteType;
  final String? noteText;
  final String? message;
  final List<AdHocForm> forms;

  AdHocCommandResult({
    required this.status,
    this.sessionId,
    this.noteType,
    this.noteText,
    this.message,
    this.forms = const [],
  });

  bool get isCompleted => status == 'completed';
  bool get isExecuting => status == 'executing';
  bool get hasForm => forms.isNotEmpty;
  bool get isError => status == 'error' || noteType == 'error';
}

class AdHocForm {
  final String? formType;
  final String? title;
  final List<String> instructions;
  final List<AdHocFormField> fields;

  AdHocForm({
    this.formType,
    this.title,
    this.instructions = const [],
    this.fields = const [],
  });
}

class AdHocFormField {
  final String varAttr;
  final String type;
  final String? label;
  final List<String> values;
  final List<AdHocOption> options;
  final bool isRequired;

  AdHocFormField({
    required this.varAttr,
    required this.type,
    this.label,
    this.values = const [],
    this.options = const [],
    this.isRequired = false,
  });
}

class AdHocOption {
  final String? label;
  final String value;

  AdHocOption({this.label, required this.value});
}