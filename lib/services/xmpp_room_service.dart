import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';

class XmppRoomService with ChangeNotifier {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _jids;
  String? Function()? _getActiveAccountId;

  final List<Room> _joinedRooms = [];
  List<Room> get joinedRooms => List.unmodifiable(_joinedRooms);

  final StreamController<List<Room>> _joinedRoomsStreamController =
      StreamController<List<Room>>.broadcast();
  Stream<List<Room>> get joinedRoomsStream =>
      _joinedRoomsStreamController.stream;

  Set<String> _persistedRooms = {};
  final Map<String, String> _roomNicknames = {};
  final Map<String, Set<RoomParticipant>> _roomParticipants = {};
  final _roomParticipantStreamController =
      StreamController<Map<String, List<RoomParticipant>>>.broadcast();
  Stream<Map<String, List<RoomParticipant>>> get roomParticipantsStream =>
      _roomParticipantStreamController.stream;

  final StreamController<Map<String, dynamic>> _groupInviteStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get groupInviteStream =>
      _groupInviteStreamController.stream;

  final Map<String, Completer<List<Map<String, String>>>> _discoveryCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>> _roomInfoCompleters = {};
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  XmppRoomService(this._connections, this._jids);

  void setActiveAccountIdGetter(String? Function() getter) {
    _getActiveAccountId = getter;
  }

  String? get _activeAccountId => _getActiveAccountId?.call();

  String getResolvedNickname(String? accountId) {
    final id = accountId ?? _activeAccountId;
    if (id == null) return 'me';
    return _roomNicknames['$id|'] ?? id.split('@').first;
  }

  // --- Room joining / leaving ---

  Future<String?> joinRoom(String accountId, String roomJid, String nickname) async {
    return await joinXmppRoom(roomJid, nickname, accountId: accountId);
  }

  Future<void> leaveRoom(String accountId, String roomJid) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    debugPrint('MUC: Leaving Room $roomJid');
    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(roomJid);
    presence.type = xmpp.PresenceType.UNAVAILABLE;
    conn.writeStanza(presence);

    _persistedRooms.removeWhere((r) => r.startsWith('$accountId|$roomJid'));
    await saveJoinedRooms();
  }

  Future<void> destroyRoom(String accountId, String roomJid, {String? reason}) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    debugPrint('MUC: Destroying Room $roomJid');

    final iqId = 'destroy_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid.split('/').first);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'));

    final destroy = xmpp.XmppElement();
    destroy.name = 'destroy';
    if (reason != null && reason.isNotEmpty) {
      final reasonEl = xmpp.XmppElement();
      reasonEl.name = 'reason';
      reasonEl.textValue = reason;
      destroy.addChild(reasonEl);
    }
    query.addChild(destroy);
    iq.addChild(query);

    conn.writeStanza(iq);

    _persistedRooms.removeWhere((r) => r.startsWith('$accountId|$roomJid'));
    await saveJoinedRooms();

    debugPrint('MUC: Room $roomJid destruction request sent');
  }

  Future<String?> joinGenericRoom(String destination, {String? accountId}) async {
    return await joinXmppRoom(
      destination,
      getResolvedNickname(accountId),
      accountId: accountId,
    );
  }

  Future<String?> createRoom(String accountId, String roomJid, String nickname) async {
    final error = await createXmppRoom(roomJid, nickname, accountId: accountId);
    if (error != null) return error;

    final configError = await configureXmppRoom(
      roomJid,
      accountId: accountId,
      isPublic: true,
      isPersistent: true,
      isMembersOnly: false,
      allowMemberInvites: true,
      changeSubject: true,
    );
    return configError;
  }

  // --- MUC Invitations (XEP-0045, XEP-0249) ---

  Future<void> inviteToRoom(
    String accountId,
    String roomJid,
    String userJid, {
    String? reason,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.NORMAL,
    );
    msg.toJid = xmpp.Jid.fromFullJid(roomJid);

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'));

    final invite = xmpp.XmppElement();
    invite.name = 'invite';
    invite.addAttribute(xmpp.XmppAttribute('to', userJid));

    if (reason != null && reason.isNotEmpty) {
      final reasonEl = xmpp.XmppElement();
      reasonEl.name = 'reason';
      reasonEl.textValue = reason;
      invite.addChild(reasonEl);
    }

    x.addChild(invite);
    msg.addChild(x);

    conn.writeStanza(msg);
    debugPrint('MUC: Sent mediated invite to $userJid for room $roomJid');
  }

  Future<void> inviteToRoomDirect(
    String accountId,
    String roomJid,
    String userJid, {
    String? reason,
    String? password,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(userJid);

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:conference'));
    x.addAttribute(xmpp.XmppAttribute('jid', roomJid));

    if (reason != null && reason.isNotEmpty) {
      x.addAttribute(xmpp.XmppAttribute('reason', reason));
    }
    if (password != null && password.isNotEmpty) {
      x.addAttribute(xmpp.XmppAttribute('password', password));
    }

    msg.addChild(x);
    conn.writeStanza(msg);
    debugPrint('MUC: Sent direct invite to $userJid for room $roomJid');
  }

  // --- Room Discovery (XEP-0030) ---

  Future<List<Map<String, String>>> discoverMucRooms(
    String accountId,
    String serviceJid,
  ) async {
    final conn = _connections[accountId];
    if (conn == null) return [];
    final id = 'disco_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iq.addChild(query);
    final completer = Completer<List<Map<String, String>>>();
    _discoveryCompleters[id] = completer;
    conn.writeStanza(iq);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _discoveryCompleters.remove(id);
        return [];
      },
    );
  }

  Future<Map<String, dynamic>> getMucRoomInfo(
    String accountId,
    String roomJid,
  ) async {
    final conn = _connections[accountId];
    if (conn == null) {
      return {'jid': roomJid, 'name': roomJid, 'description': ''};
    }
    final id = 'roominfo_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    iq.addChild(query);
    final completer = Completer<Map<String, dynamic>>();
    _roomInfoCompleters[id] = completer;
    conn.writeStanza(iq);
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _roomInfoCompleters.remove(id);
        return {'jid': roomJid, 'name': roomJid, 'description': ''};
      },
    );
  }

  // --- Room Configuration (XEP-0045) ---

  Future<void> requestRoomConfig(String accountId, String roomJid) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final id = 'config_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'));
    iq.addChild(query);
    conn.writeStanza(iq);
  }

  Future<void> submitRoomConfig(
    String accountId,
    String roomJid,
    Map<String, String> fields,
  ) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final id = 'submit_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'));

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    fields.forEach((key, value) {
      final field = xmpp.XmppElement();
      field.name = 'field';
      field.addAttribute(xmpp.XmppAttribute('var', key));
      final val = xmpp.XmppElement();
      val.name = 'value';
      val.textValue = value;
      field.addChild(val);
      x.addChild(field);
    });

    query.addChild(x);
    iq.addChild(query);
    conn.writeStanza(iq);
  }

  Future<Map<String, dynamic>?> fetchRoomConfig(String accountId, String roomJid) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final id = 'config_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'));
    iq.addChild(query);

    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    conn.writeStanza(iq);

    try {
      final response = await completer.future.timeout(const Duration(seconds: 10));
      if (response.type == xmpp.IqStanzaType.ERROR) return null;

      final q = response.getChild('query');
      final x = q?.getChild('x');
      if (x == null) return null;

      final config = <String, dynamic>{};
      for (var field in x.children.where((c) => c.name == 'field')) {
        final varName = field.getAttribute('var')?.value;
        if (varName == null) continue;
        final values = field.children.where((c) => c.name == 'value').map((c) => c.textValue).toList();
        if (values.isEmpty) continue;
        if (values.length == 1) {
          config[varName] = values.first;
        } else {
          config[varName] = values;
        }
      }
      return config;
    } catch (e) {
      return null;
    } finally {
      _pendingIqs.remove(id);
    }
  }

  Future<List<Map<String, String>>> fetchRoomAffiliations(String accountId, String roomJid, String affiliation) async {
    final conn = _connections[accountId];
    if (conn == null) return [];

    final id = 'affil_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('affiliation', affiliation));
    query.addChild(item);
    iq.addChild(query);

    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    conn.writeStanza(iq);

    try {
      final response = await completer.future.timeout(const Duration(seconds: 10));
      if (response.type == xmpp.IqStanzaType.ERROR) return [];

      final q = response.getChild('query');
      if (q == null) return [];

      final items = <Map<String, String>>[];
      for (var it in q.children.where((c) => c.name == 'item')) {
        final jid = it.getAttribute('jid')?.value;
        if (jid != null) {
          items.add({'jid': jid, 'affiliation': affiliation});
        }
      }
      return items;
    } catch (e) {
      return [];
    } finally {
      _pendingIqs.remove(id);
    }
  }

  // --- MUC Administration ---

  Future<void> setMucRole(
    String accountId,
    String roomJid,
    String nick,
    String role, {
    String? reason,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final id = 'role_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('nick', nick));
    item.addAttribute(xmpp.XmppAttribute('role', role));

    if (reason != null && reason.isNotEmpty) {
      final reasonEl = xmpp.XmppElement();
      reasonEl.name = 'reason';
      reasonEl.textValue = reason;
      item.addChild(reasonEl);
    }

    query.addChild(item);
    iq.addChild(query);
    conn.writeStanza(iq);
  }

  Future<void> setMucAffiliation(
    String accountId,
    String roomJid,
    String userJid,
    String affiliation, {
    String? reason,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final id = 'affil_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('jid', userJid));
    item.addAttribute(xmpp.XmppAttribute('affiliation', affiliation));

    if (reason != null && reason.isNotEmpty) {
      final reasonEl = xmpp.XmppElement();
      reasonEl.name = 'reason';
      reasonEl.textValue = reason;
      item.addChild(reasonEl);
    }

    query.addChild(item);
    iq.addChild(query);
    conn.writeStanza(iq);
  }

  Future<void> sendXmppSubject(String roomJid, String subject, {String? accountId}) async {
    final conn = _connections[accountId ?? _activeAccountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.GROUPCHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(roomJid);

    final subjEl = xmpp.XmppElement();
    subjEl.name = 'subject';
    subjEl.textValue = subject;
    msg.addChild(subjEl);

    conn.writeStanza(msg);
  }

  Future<void> kickUser(String accountId, String roomJid, String nick, {String? reason}) async {
    await setMucRole(accountId, roomJid, nick, 'none', reason: reason);
  }

  Future<void> banUser(String accountId, String roomJid, String userJid, {String? reason}) async {
    await setMucAffiliation(accountId, roomJid, userJid, 'outcast', reason: reason);
  }

  List<RoomParticipant> getRoomParticipants(String roomJid) {
    return _roomParticipants[roomJid]?.toList() ?? [];
  }

  // --- Room Creation & Joining (XEP-0045) ---

  Future<String?> createXmppRoom(String roomJid, String nick, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _connections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
      return 'XMPP not connected';
    }

    try {
      final roomJidObj = xmpp.Jid.fromFullJid('$roomJid/$nick');
      final presence = xmpp.PresenceStanza();
      presence.toJid = roomJidObj;
      presence.addAttribute(xmpp.XmppAttribute('to', '$roomJid/$nick'));
      presence.show = xmpp.PresenceShowElement.CHAT;
      presence.status = 'Creating room...';

      final mucX = xmpp.XmppElement();
      mucX.name = 'x';
      mucX.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));
      presence.addChild(mucX);

      conn.writeStanza(presence);

      bool exists = false;
      for (var r in _joinedRooms) {
        if (r.id == roomJid) exists = true;
      }

      _roomNicknames['$id|${roomJid.toLowerCase()}'] = nick;

      if (!exists) {
        _joinedRooms.add(Room(id: roomJid, name: roomJid.split('@').first, participants: [], protocol: 'XMPP'));
        _joinedRoomsStreamController.add(List.from(_joinedRooms));
        notifyListeners();
      }

      final persistStr = '$id|$roomJid|$nick';
      if (!_persistedRooms.contains(persistStr)) {
        _persistedRooms.add(persistStr);
        await saveJoinedRooms();
      }

      return null;
    } catch (e) {
      debugPrint('XMPP Room Creation Error: $e');
      return e.toString();
    }
  }

  Future<String?> configureXmppRoom(
    String roomJid, {
    String? accountId,
    String? name,
    String? description,
    bool isPublic = true,
    bool isPersistent = true,
    bool isMembersOnly = false,
    bool allowMemberInvites = true,
    bool changeSubject = true,
    int historyLength = 50,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _connections[id];
    if (conn == null) return 'No connection';

    final iqId = 'mucConfig_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'));

    final xForm = xmpp.XmppElement();
    xForm.name = 'x';
    xForm.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    xForm.addAttribute(xmpp.XmppAttribute('type', 'submit'));

    final fields = <xmpp.XmppElement>[];

    final formType = xmpp.XmppElement();
    formType.name = 'field';
    formType.addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'));
    formType.addAttribute(xmpp.XmppAttribute('type', 'hidden'));
    final formTypeValue = xmpp.XmppElement();
    formTypeValue.name = 'value';
    formTypeValue.textValue = 'http://jabber.org/protocol/muc#roomconfig';
    formType.addChild(formTypeValue);
    fields.add(formType);

    if (name != null) {
      fields.add(_makeField('muc#roomconfig_roomname', name));
    }
    if (description != null) {
      fields.add(_makeField('muc#roomconfig_roomdesc', description));
    }
    fields.add(_makeField('muc#roomconfig_publicroom', isPublic ? '1' : '0'));
    fields.add(_makeField('muc#roomconfig_persistentroom', isPersistent ? '1' : '0'));
    fields.add(_makeField('muc#roomconfig_membersonly', isMembersOnly ? '1' : '0'));
    fields.add(_makeField('muc#roomconfig_allowmemberinvites', allowMemberInvites ? '1' : '0'));
    fields.add(_makeField('muc#roomconfig_changesubject', changeSubject ? '1' : '0'));
    fields.add(_makeField('muc#roomconfig_historylength', historyLength.toString()));

    for (final field in fields) {
      xForm.addChild(field);
    }

    query.addChild(xForm);
    iq.addChild(query);

    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[iqId] = completer;
    conn.writeStanza(iq);

    try {
      final response = await completer.future.timeout(const Duration(seconds: 10));
      if (response.type == xmpp.IqStanzaType.ERROR) {
        final error = response.getChild('error');
        return error?.textValue ?? 'Room configuration failed';
      }
      return null;
    } catch (e) {
      debugPrint('Room configuration error: $e');
      return e.toString();
    } finally {
      _pendingIqs.remove(iqId);
    }
  }

  xmpp.XmppElement _makeField(String varName, String value) {
    final field = xmpp.XmppElement();
    field.name = 'field';
    field.addAttribute(xmpp.XmppAttribute('var', varName));
    final valEl = xmpp.XmppElement();
    valEl.name = 'value';
    valEl.textValue = value;
    field.addChild(valEl);
    return field;
  }

  Future<String?> joinXmppRoom(
    String roomJid,
    String nick, {
    String? accountId,
    String? password,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _connections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
      return 'XMPP not connected';
    }
    try {
      final roomJidObj = xmpp.Jid.fromFullJid('$roomJid/$nick');
      final presence = xmpp.PresenceStanza();
      presence.toJid = roomJidObj;
      presence.addAttribute(xmpp.XmppAttribute('to', '$roomJid/$nick'));
      presence.show = xmpp.PresenceShowElement.CHAT;
      presence.status = 'Joining room...';

      final mucX = xmpp.XmppElement();
      mucX.name = 'x';
      mucX.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));

      if (password != null && password.isNotEmpty) {
        final passEl = xmpp.XmppElement();
        passEl.name = 'password';
        passEl.textValue = password;
        mucX.addChild(passEl);
      }

      presence.addChild(mucX);
      conn.writeStanza(presence);

      bool exists = false;
      for (var r in _joinedRooms) {
        if (r.id == roomJid) exists = true;
      }

      _roomNicknames['$id|${roomJid.toLowerCase()}'] = nick;

      if (!exists) {
        _joinedRooms.add(Room(id: roomJid, name: roomJid.split('@').first, participants: [], protocol: 'XMPP'));
        _joinedRoomsStreamController.add(List.from(_joinedRooms));
        notifyListeners();
      }

      final persistStr = '$id|$roomJid|$nick';
      if (!_persistedRooms.contains(persistStr)) {
        _persistedRooms.add(persistStr);
        await saveJoinedRooms();
      }

      return null;
    } catch (e) {
      debugPrint('Failed to join room: $e');
      return e.toString();
    }
  }

  // XEP-0503: MUC Subscriptions — subscribe to a room without joining
  Future<String?> subscribeToRoom(String roomJid, String nickname, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _connections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
      return 'XMPP not connected';
    }
    try {
      final iq = xmpp.IqStanza(
        'muc_sub_${DateTime.now().microsecondsSinceEpoch}',
        xmpp.IqStanzaType.SET,
      );
      iq.toJid = xmpp.Jid.fromFullJid(roomJid);

      final subscribe = xmpp.XmppElement();
      subscribe.name = 'subscribe';
      subscribe.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:muc-subscribe:0'));
      subscribe.addAttribute(xmpp.XmppAttribute('nick', nickname));
      subscribe.addAttribute(xmpp.XmppAttribute('room', roomJid));

      iq.addChild(subscribe);
      conn.writeStanza(iq);

      return null;
    } catch (e) {
      debugPrint('Failed to subscribe to room: $e');
      return e.toString();
    }
  }

  Future<String?> unsubscribeFromRoom(String roomJid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _connections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
      return 'XMPP not connected';
    }
    try {
      final iq = xmpp.IqStanza(
        'muc_unsub_${DateTime.now().microsecondsSinceEpoch}',
        xmpp.IqStanzaType.SET,
      );
      iq.toJid = xmpp.Jid.fromFullJid(roomJid);

      final unsubscribe = xmpp.XmppElement();
      unsubscribe.name = 'unsubscribe';
      unsubscribe.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:muc-subscribe:0'));
      unsubscribe.addAttribute(xmpp.XmppAttribute('room', roomJid));

      iq.addChild(unsubscribe);
      conn.writeStanza(iq);

      return null;
    } catch (e) {
      debugPrint('Failed to unsubscribe from room: $e');
      return e.toString();
    }
  }

  // --- Room Persistence & Bookmarks ---

  Future<void> saveJoinedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('joined_rooms', _persistedRooms.toList());
    publishBookmarks();
  }

  void publishBookmarks() {
    final accountGroups = <String, List<String>>{};
    for (final room in _persistedRooms) {
      final parts = room.split('|');
      if (parts.length >= 2) {
        final acc = parts[0];
        final jid = parts[1];
        accountGroups[acc] ??= [];
        accountGroups[acc]!.add(jid);
      }
    }

    for (final acc in accountGroups.keys) {
      final conn = _connections[acc];
      if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
        continue;
      }

      try {
        final id = 'pub_bm_${DateTime.now().millisecondsSinceEpoch}';
        final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);

        final pubsub = xmpp.XmppElement();
        pubsub.name = 'pubsub';
        pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

        final publish = xmpp.XmppElement();
        publish.name = 'publish';
        publish.addAttribute(xmpp.XmppAttribute('node', 'storage:bookmarks'));

        final item = xmpp.XmppElement();
        item.name = 'item';
        item.addAttribute(xmpp.XmppAttribute('id', 'current'));

        final storage = xmpp.XmppElement();
        storage.name = 'storage';
        storage.addAttribute(xmpp.XmppAttribute('xmlns', 'storage:bookmarks'));

        for (final jid in accountGroups[acc]!) {
          final conf = xmpp.XmppElement();
          conf.name = 'conference';
          conf.addAttribute(xmpp.XmppAttribute('autojoin', '1'));
          conf.addAttribute(xmpp.XmppAttribute('jid', jid));
          conf.addAttribute(xmpp.XmppAttribute('name', jid.split('@').first));
          storage.addChild(conf);
        }

        item.addChild(storage);
        publish.addChild(item);

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
        final val = xmpp.XmppElement();
        val.name = 'value';
        val.textValue = 'http://jabber.org/protocol/pubsub#publish-options';
        field.addChild(val);
        x.addChild(field);

        final accessModel = xmpp.XmppElement();
        accessModel.name = 'field';
        accessModel.addAttribute(xmpp.XmppAttribute('var', 'pubsub#access_model'));
        final accessVal = xmpp.XmppElement();
        accessVal.name = 'value';
        accessVal.textValue = 'whitelist';
        accessModel.addChild(accessVal);
        x.addChild(accessModel);

        publishOptions.addChild(x);

        pubsub.addChild(publish);
        pubsub.addChild(publishOptions);
        iq.addChild(pubsub);

        conn.writeStanza(iq);
        debugPrint('SYNC: Published bookmarks for $acc');
      } catch (e) {
        debugPrint('SYNC: Failed to publish bookmarks for $acc: $e');
      }
    }
  }

  Future<void> loadJoinedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('joined_rooms') ?? [];
    _persistedRooms = list.toSet();
  }

  Future<void> autoJoinRooms(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('joined_rooms') ?? [];
    _persistedRooms = list.toSet();

    for (var roomInfo in list) {
      final parts = roomInfo.split('|');
      if (parts.length == 3 && parts[0] == accountId) {
        _roomNicknames['${parts[0]}|${parts[1].toLowerCase()}'] = parts[2];
        await joinRoom(parts[0], parts[1], parts[2]);
      }
    }
  }

  // --- Participant tracking ---

  void updateParticipant(String roomJid, RoomParticipant participant) {
    _roomParticipants[roomJid] ??= {};
    final existing = _roomParticipants[roomJid]!.where((p) => p.nickname == participant.nickname).firstOrNull;
    if (existing != null) {
      _roomParticipants[roomJid]!.remove(existing);
    }
    _roomParticipants[roomJid]!.add(participant);
    _emitParticipants();
  }

  void removeParticipant(String roomJid, String nickname) {
    _roomParticipants[roomJid]?.removeWhere((p) => p.nickname == nickname);
    _emitParticipants();
  }

  void _emitParticipants() {
    final cloned = <String, List<RoomParticipant>>{};
    for (final e in _roomParticipants.entries) {
      cloned[e.key] = e.value.toList();
    }
    _roomParticipantStreamController.add(cloned);
  }

  // --- IQ response routing ---

  Map<String, Completer<List<Map<String, String>>>> get discoveryCompleters => _discoveryCompleters;
  Map<String, Completer<Map<String, dynamic>>> get roomInfoCompleters => _roomInfoCompleters;
  Map<String, Completer<xmpp.IqStanza>> get pendingIqs => _pendingIqs;

  // --- Group invite emission ---

  void emitGroupInvite(Map<String, dynamic> invite) {
    _groupInviteStreamController.add(invite);
  }

  // --- Nickname tracking ---

  String? getNickname(String accountId, String roomJid) {
    return _roomNicknames['$accountId|${roomJid.toLowerCase()}'];
  }

  void setNickname(String accountId, String roomJid, String nick) {
    _roomNicknames['$accountId|${roomJid.toLowerCase()}'] = nick;
  }

  @override
  void dispose() {
    _joinedRoomsStreamController.close();
    _roomParticipantStreamController.close();
    _groupInviteStreamController.close();
    super.dispose();
  }
}