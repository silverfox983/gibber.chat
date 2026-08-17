import 'dart:async';
import 'dart:io';
import 'dart:convert' as json;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import '../models/user_profile.dart';
import '../models/space_models.dart';
import 'auth_service_deps.dart';
import 'database_service.dart';
import 'secure_storage_service.dart';
import 'xmpp_omemo_service.dart';
import 'xmpp_room_service.dart';

class XmppContactServiceDependencies {
  final Map<String, xmpp.Connection> xmppConnections;
  final Map<String, String> xmppJids;
  final String? Function() getActiveAccountId;
  final List<Contact> currentContacts;
  final Map<String, StreamSubscription> presenceSubs;
  final Map<String, StreamSubscription> rosterSubs;
  final StreamController<List<Contact>> contactStreamController;
  final Map<String, StreamSubscription> xmppMessageSubs;
  final Map<String, StreamSubscription> jingleEventSubs;
  final Map<String, StreamSubscription> xmppStanzaSubs;
  final List<SavedAccount> savedAccounts;
  final XmppOmemoService omemoService;
  final XmppRoomService roomService;
  final SecureStorageService secureStorage;
  final List<Map<String, String>> pendingSubscriptionRequests;
  final StreamController<List<Map<String, String>>> subscriptionRequestController;
  final StreamController<ChatMessage> messageStreamController;
  final StreamController<List<SpaceNode>> joinedSpacesStreamController;
  final List<SpaceNode> cachedJoinedSpaces;
  final Map<String, bool> carbonsEnabled;
  final Map<String, List<Map<String, dynamic>>> accountIceServers;
  final Set<String> pendingVCardFetches;
  final Map<String, DateTime> vCardLastFetch;
  final Set<String> vCardUnsupportedJids;
  final Map<String, String> contactAvatarHashes;
  final StreamController<List<String>> blockedContactsController;
  final List<String> currentBlockedContacts;
  final bool xmppConnecting;
  final String? Function() lastDiagnostic;
  final void Function() notifyListeners;
  final ContactStatus myStatus;
  final String? myStatusMessage;
  final UserProfile? currentProfile;
  final Future<void> Function() loadSavedAccounts;
  final Future<void> Function(ContactStatus, String?) setPresence;
  final Future<void> Function({String? accountId}) fetchMyVCard;
  final Future<void> Function(String, {String? accountId}) fetchContactVCard;
  final Future<void> Function(String, String, String, {String? fileName, String? filePath, bool isGroup, String? replyToId, MessageType type}) sendMessage;

  XmppContactServiceDependencies({
    required this.xmppConnections,
    required this.xmppJids,
    required this.getActiveAccountId,
    required this.currentContacts,
    required this.presenceSubs,
    required this.rosterSubs,
    required this.contactStreamController,
    required this.xmppMessageSubs,
    required this.jingleEventSubs,
    required this.xmppStanzaSubs,
    required this.savedAccounts,
    required this.omemoService,
    required this.roomService,
    required this.secureStorage,
    required this.pendingSubscriptionRequests,
    required this.subscriptionRequestController,
    required this.messageStreamController,
    required this.joinedSpacesStreamController,
    required this.cachedJoinedSpaces,
    required this.carbonsEnabled,
    required this.accountIceServers,
    required this.pendingVCardFetches,
    required this.vCardLastFetch,
    required this.vCardUnsupportedJids,
    required this.contactAvatarHashes,
    required this.blockedContactsController,
    required this.currentBlockedContacts,
    required this.xmppConnecting,
    required this.lastDiagnostic,
    required this.notifyListeners,
    required this.myStatus,
    required this.myStatusMessage,
    required this.currentProfile,
    required this.loadSavedAccounts,
    required this.setPresence,
    required this.fetchMyVCard,
    required this.fetchContactVCard,
    required this.sendMessage,
  });

  String? get activeAccountId => getActiveAccountId();
}

class XmppContactService {
  final AuthServiceContactDeps _auth;
  late final XmppContactServiceDependencies _d;

  XmppContactService(this._auth) {
    _d = XmppContactServiceDependencies(
      xmppConnections: _auth.xmppConnections,
      xmppJids: _auth.xmppJids,
      getActiveAccountId: () => _auth.activeAccountId,
      currentContacts: _auth.currentContacts,
      presenceSubs: _auth.presenceSubs,
      rosterSubs: _auth.rosterSubs,
      contactStreamController: _auth.contactStreamController,
      xmppMessageSubs: _auth.xmppMessageSubs,
      jingleEventSubs: _auth.jingleEventSubs,
      xmppStanzaSubs: _auth.xmppStanzaSubs,
      savedAccounts: _auth.savedAccounts,
      omemoService: _auth.omemoService,
      roomService: _auth.roomService,
      secureStorage: _auth.secureStorage,
      pendingSubscriptionRequests: _auth.pendingSubscriptionRequests,
      subscriptionRequestController: _auth.subscriptionRequestController,
      messageStreamController: _auth.messageStreamController,
      joinedSpacesStreamController: _auth.joinedSpacesStreamController,
      cachedJoinedSpaces: _auth.cachedJoinedSpaces,
      carbonsEnabled: _auth.carbonsEnabled,
      accountIceServers: _auth.accountIceServers,
      pendingVCardFetches: _auth.pendingVCardFetches,
      vCardLastFetch: _auth.vCardLastFetch,
      vCardUnsupportedJids: _auth.vCardUnsupportedJids,
      contactAvatarHashes: _auth.contactAvatarHashes,
      blockedContactsController: _auth.blockedContactsController,
      currentBlockedContacts: _auth.currentBlockedContacts,
      xmppConnecting: _auth.xmppConnecting,
      lastDiagnostic: () => _auth.lastDiagnostic,
      notifyListeners: _auth.notifyListeners,
      myStatus: _auth.myStatus,
      myStatusMessage: _auth.myStatusMessage,
      currentProfile: _auth.currentProfile,
      loadSavedAccounts: _auth.loadSavedAccounts,
      setPresence: _auth.setPresence,
      fetchMyVCard: _auth.fetchMyVCard,
      fetchContactVCard: _auth.fetchContactVCard,
      sendMessage: _auth.sendMessage,
    );
  }

  ContactStatus mapPresenceToShow(xmpp.PresenceShowElement? show) {
    if (show == null || show == xmpp.PresenceShowElement.CHAT) {
      return ContactStatus.online;
    } else if (show == xmpp.PresenceShowElement.AWAY) {
      return ContactStatus.away;
    } else if (show == xmpp.PresenceShowElement.XA) {
      return ContactStatus.xa;
    } else if (show == xmpp.PresenceShowElement.DND) {
      return ContactStatus.dnd;
    } else {
      return ContactStatus.offline;
    }
  }

  void handleXmppStreamError(dynamic e) {
    debugPrint('XMPP Stream Error: $e');
    _auth.xmppConnecting = false;
    _auth.lastDiagnostic = 'XMPP stream error: $e';
    _auth.notifyListeners();
  }

  Future<bool> autoLogin() async {
    await _d.loadSavedAccounts();
    if (_d.savedAccounts.isEmpty) return false;

    final acc = _d.savedAccounts.first;
    final pass = await _d.secureStorage.read(key: 'pass_${acc.fullJid}');

    final prefs = await SharedPreferences.getInstance();
    final savedStatusIdx = prefs.getInt('my_presence_status');
    if (savedStatusIdx != null) {
      _auth.myStatus = ContactStatus.values[savedStatusIdx];
    }
    _auth.myStatusMessage = prefs.getString('my_presence_message');

    if (pass != null) {
      try {
        await _auth.connectXmpp(
          user: acc.user,
          domain: acc.domain,
          pass: pass,
          port: acc.port,
          host: acc.host,
          accountId: acc.fullJid,
          configData: acc,
        );

        _d.setPresence(_auth.myStatus, _auth.myStatusMessage);

        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  Future<String> testSocketConnection(String host, int port) async {
    if (kIsWeb) {
      return 'Web: Socket probe not available — use WebSocket URL instead';
    }
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      _auth.lastDiagnostic =
          'Socket probe to $host:$port succeeded. Server is reachable.';
      _auth.notifyListeners();
      return 'Success: $host:$port is reachable';
    } on SocketException catch (e) {
      _auth.lastDiagnostic = 'Socket probe failed: $host:$port — ${e.message}';
      _auth.notifyListeners();
      return 'Failed: ${e.message}';
    } catch (e) {
      _auth.lastDiagnostic = 'Socket probe error: $e';
      _auth.notifyListeners();
      return 'Error: $e';
    }
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

  Future<void> fetchXmppHistory(
    String jid, {
    String? accountId,
    DateTime? since,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return;
    try {
      final mamManager = xmpp.MessageArchiveManager.getInstance(conn);
      mamManager.queryByTime(jid: xmpp.Jid.fromFullJid(jid), start: since);

      debugPrint(
        'MAM: Requested history for $jid ${since != null ? "since $since" : ""}',
      );
    } catch (e) {
      debugPrint('MAM Error: $e');
    }
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

  void logCallEvent(
    String targetId,
    String text,
    bool isSent, {
    String? filePath,
    MessageType type = MessageType.call,
  }) {
    _d.messageStreamController.add(
      ChatMessage(
        id: 'call_log_${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        timestamp: DateTime.now(),
        type: type,
        filePath: filePath,
        isSent: isSent,
        senderId: isSent ? 'me' : targetId,
        accountId: _d.activeAccountId,
        protocol: 'XMPP',
      ),
    );
  }

  Future<List<Map<String, dynamic>>> fetchIceServers(String accountId) async {
    if (_d.accountIceServers.containsKey(accountId) &&
        _d.accountIceServers[accountId]!.isNotEmpty) {
      return _d.accountIceServers[accountId]!;
    }

    final conn = _d.xmppConnections[accountId];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return [];

    final iqId = 'extdisco_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(conn.account.domain);

    final services = xmpp.XmppElement();
    services.name = 'services';
    services.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:extdisco:2'));
    iq.addChild(services);

    final completer = Completer<List<Map<String, dynamic>>>();
    late StreamSubscription sub;

    sub = conn.inStanzasStream.listen((stanza) {
      if (stanza is xmpp.IqStanza && stanza.id == iqId) {
        sub.cancel();
        final List<Map<String, dynamic>> discovered = [];
        final servicesRes = stanza.getChild('services');
        if (servicesRes != null) {
          for (var service in servicesRes.children) {
            if (service.name == 'service') {
              final type = service.getAttribute('type')?.value;
              final transport = service.getAttribute('transport')?.value;
              final host = service.getAttribute('host')?.value;
              final port = service.getAttribute('port')?.value;
              final username = service.getAttribute('username')?.value;
              final password = service.getAttribute('password')?.value;

              if (host != null && (type == 'stun' || type == 'turn')) {
                final urlPref = (type == 'stun' && transport == 'udp')
                    ? 'stun'
                    : (type == 'stun' && transport == 'tcp')
                    ? 'stuns'
                    : (type == 'turn' && transport == 'udp')
                    ? 'turn'
                    : 'turns';

                final serverMap = {
                  'urls': '$urlPref:$host${port != null ? ":$port" : ""}',
                };
                if (username != null) serverMap['username'] = username;
                if (password != null) serverMap['credential'] = password;

                discovered.add(serverMap);
              }
            }
          }
        }
        _d.accountIceServers[accountId] = discovered;
        completer.complete(discovered);
      }
    });

    conn.writeStanza(iq);

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub.cancel();
        return _d.accountIceServers[accountId] ?? [];
      },
    );
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

  List<SpaceNode> get joinedSpaces => _d.cachedJoinedSpaces;

  void emitJoinedSpaces() {
    _d.joinedSpacesStreamController.add(joinedSpaces);
  }

  Future<void> joinPersistedSpace(
    String domain,
    String node,
    String name,
  ) async {
    final index = _d.cachedJoinedSpaces.indexWhere((s) => s.domain == domain && s.node == node);
    if (index == -1) {
      final space = SpaceNode(domain: domain, node: node, name: name, isSubscribed: true);
      _d.cachedJoinedSpaces.add(space);
      await DatabaseService().upsertSpace(space, isJoined: true);
      emitJoinedSpaces();
      _auth.notifyListeners();
    }
  }

  Future<void> leavePersistedSpace(String domain, String node) async {
    _d.cachedJoinedSpaces.removeWhere((s) => s.domain == domain && s.node == node);
    await DatabaseService().deleteSpace(domain, node);
    emitJoinedSpaces();
    _auth.notifyListeners();
  }

  Future<void> updatePersistedSpace(SpaceNode space) async {
    final index = _d.cachedJoinedSpaces.indexWhere((s) => s.domain == space.domain && s.node == space.node);
    if (index != -1) {
      _d.cachedJoinedSpaces[index] = space;
      await DatabaseService().upsertSpace(space, isJoined: true);
      emitJoinedSpaces();
      _auth.notifyListeners();
    }
  }

  Future<void> createProfile(String name, {String? bio}) async {
    final profile = UserProfile(
      id: 'profile_${DateTime.now().millisecondsSinceEpoch}',
      displayName: name,
      bio: bio,
      accountIds: [],
    );
    _auth.currentProfile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_profile', json.json.encode(profile.toJson()));
    _auth.notifyListeners();
  }

  Future<Map<String, String>> exportAccountSecrets() async {
    final all = await _d.secureStorage.readAll();
    final Map<String, String> secrets = {};
    for (var key in all.keys) {
      if (key.startsWith('pass_')) {
        secrets[key] = all[key]!;
      }
    }
    return secrets;
  }

  Future<void> importAccountSecrets(Map<String, String> secrets) async {
    for (var entry in secrets.entries) {
      await _d.secureStorage.write(key: entry.key, value: entry.value);
    }
  }

  Future<void> importSavedAccounts(List<SavedAccount> accounts) async {
    _d.savedAccounts.clear();
    _d.savedAccounts.addAll(accounts);

    final prefs = await SharedPreferences.getInstance();
    final jsonList = _d.savedAccounts.map((a) => a.toJson()).toList();
    await prefs.setString('saved_accounts_json', json.json.encode(jsonList));
    _auth.notifyListeners();
  }

  List<Map<String, dynamic>> exportContacts() {
    return _d.currentContacts.map((c) => c.toJson()).toList();
  }

  Future<void> importContacts(List<dynamic> contactsJson) async {
    final Map<String, Contact> newContacts = {};
    for (var c in _d.currentContacts) {
      newContacts[c.id] = c;
    }

    for (var j in contactsJson) {
      try {
        final contact = Contact.fromJson(j as Map<String, dynamic>);
        if (newContacts.containsKey(contact.id)) {
           final existing = newContacts[contact.id]!;
           existing.bio ??= contact.bio;
           existing.fullName ??= contact.fullName;
           existing.email ??= contact.email;
           existing.phone ??= contact.phone;
           existing.url ??= contact.url;
           existing.organization ??= contact.organization;
           existing.title ??= contact.title;
           existing.role ??= contact.role;
           existing.birthday ??= contact.birthday;
        } else {
           newContacts[contact.id] = contact;
        }
      } catch (e) {
        debugPrint('Error importing contact: $e');
      }
    }
    
    _d.currentContacts.clear();
    _d.currentContacts.addAll(newContacts.values);
    _d.contactStreamController.add(List.from(_d.currentContacts));
  }

  Future<Map<String, dynamic>> exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final Map<String, dynamic> settings = {};
    for (var key in keys) {
      settings[key] = prefs.get(key);
    }
    return settings;
  }

  Future<void> importSettings(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    for (var entry in settings.entries) {
      final val = entry.value;
      if (val is String) {
        await prefs.setString(entry.key, val);
      } else if (val is bool) {
        await prefs.setBool(entry.key, val);
      } else if (val is int) {
        await prefs.setInt(entry.key, val);
      } else if (val is double) {
        await prefs.setDouble(entry.key, val);
      } else if (val is List<String>) {
        await prefs.setStringList(entry.key, val);
      }
    }
    await _d.loadSavedAccounts();
  }

  Future<void> fetchContactVCard(String jid, {String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return;

    final iq = xmpp.IqStanza(
      'vcard_${DateTime.now().millisecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(jid);
    final vCard = xmpp.XmppElement();
    vCard.name = 'vCard';
    vCard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));
    iq.addChild(vCard);
    conn.writeStanza(iq);
  }

  void fetchAllVCards(String accountId) {
    final jids = _d.currentContacts
        .where((c) => c.protocol == 'XMPP')
        .map((c) => c.id.split('/').first)
        .toSet();

    for (var jid in jids) {
      Future.delayed(
        Duration(milliseconds: 100 + (jids.toList().indexOf(jid) * 50)),
        () {
          fetchContactVCard(jid, accountId: accountId);
        },
      );
    }
  }

  Stream<List<String>> get blockedContactsStream => _d.blockedContactsController.stream;

  Future<void> fetchBlockedContacts({String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iqId = 'get_blocklist_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.GET);
    final blocklist = xmpp.XmppElement();
    blocklist.name = 'blocklist';
    blocklist.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:blocking'));
    iq.addChild(blocklist);

    conn.writeStanza(iq);
    debugPrint('SOCIAL: Requested blocklist for $id');
  }

  Future<void> updatePresence(
    ContactStatus status, {
    String? message,
    String? accountId,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    switch (status) {
      case ContactStatus.online:
        presence.show = xmpp.PresenceShowElement.CHAT;
        break;
      case ContactStatus.away:
        presence.show = xmpp.PresenceShowElement.AWAY;
        break;
      case ContactStatus.xa:
        presence.show = xmpp.PresenceShowElement.XA;
        break;
      case ContactStatus.dnd:
        presence.show = xmpp.PresenceShowElement.DND;
        break;
      case ContactStatus.offline:
        break;
    }

    if (message != null) {
      presence.status = message;
    }

    conn.writeStanza(presence);

    _auth.myStatus = status;
    _auth.myStatusMessage = message;
    _auth.notifyListeners();
    debugPrint('SOCIAL: Updated my presence to $status ($message) for $id');
  }

  void acceptSubscription(String jid, {String? accountId}) {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.SUBSCRIBED;
    conn.writeStanza(presence);

    final subRequest = xmpp.PresenceStanza();
    subRequest.toJid = xmpp.Jid.fromFullJid(jid);
    subRequest.type = xmpp.PresenceType.SUBSCRIBE;
    conn.writeStanza(subRequest);

    debugPrint('SOCIAL: Accepted subscription and requested mutual from $jid');
    _d.pendingSubscriptionRequests.removeWhere((req) => req['jid'] == jid || req['jid'] == xmpp.Jid.fromFullJid(jid).userAtDomain);
    _d.subscriptionRequestController.add(List.from(_d.pendingSubscriptionRequests));
  }

  void declineSubscription(String jid, {String? accountId}) {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.UNSUBSCRIBED;
    conn.writeStanza(presence);

    debugPrint('SOCIAL: Declined subscription from $jid');
    _d.pendingSubscriptionRequests.removeWhere((req) => req['jid'] == jid || req['jid'] == xmpp.Jid.fromFullJid(jid).userAtDomain);
    _d.subscriptionRequestController.add(List.from(_d.pendingSubscriptionRequests));
  }

  Future<void> blockContact(String jid, {String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      'block_${DateTime.now().millisecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    final block = xmpp.XmppElement();
    block.name = 'block';
    block.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:blocking'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('jid', jid));
    block.addChild(item);

    iq.addChild(block);
    conn.writeStanza(iq);
    debugPrint('SOCIAL: Sent XEP-0191 block command for $jid');

    if (!_d.currentBlockedContacts.contains(jid)) {
      _d.currentBlockedContacts.add(jid);
      _d.blockedContactsController.add(List.from(_d.currentBlockedContacts));
    }
  }

  Future<void> unblockContact(String jid, {String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      'unblock_${DateTime.now().millisecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    final unblock = xmpp.XmppElement();
    unblock.name = 'unblock';
    unblock.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:blocking'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('jid', jid));
    unblock.addChild(item);

    iq.addChild(unblock);
    conn.writeStanza(iq);
    debugPrint('SOCIAL: Sent XEP-0191 unblock command for $jid');

    _d.currentBlockedContacts.remove(jid);
    _d.blockedContactsController.add(List.from(_d.currentBlockedContacts));
  }

  Future<void> renameContact(
    String jid,
    String newName, {
    String? accountId,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:roster'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('jid', jid));
    item.addAttribute(xmpp.XmppAttribute('name', newName));
    query.addChild(item);

    iq.addChild(query);
    conn.writeStanza(iq);
    debugPrint('SOCIAL: Sent Roster Push to rename $jid to $newName');

    final index = _d.currentContacts.indexWhere((c) => c.id == jid);
    if (index != -1) {
      _d.currentContacts[index].name = newName;
      _d.contactStreamController.add(List.from(_d.currentContacts));
    }
  }

  Future<void> removeContact(String jid, {String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:roster'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('jid', jid));
    item.addAttribute(xmpp.XmppAttribute('subscription', 'remove'));
    query.addChild(item);

    iq.addChild(query);
    conn.writeStanza(iq);

    debugPrint('SOCIAL: Removed $jid from roster.');

    _d.currentContacts.removeWhere((c) => c.id == jid);
    _d.contactStreamController.add(List.from(_d.currentContacts));
  }

  void addContact(String jid, {String? nickname, String? group, String? accountId}) {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final query = xmpp.XmppElement()
      ..name = 'query'
      ..addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:iq:roster'));
    final item = xmpp.XmppElement()
      ..name = 'item'
      ..addAttribute(xmpp.XmppAttribute('jid', jid));
    if (nickname != null) {
      item.addAttribute(xmpp.XmppAttribute('name', nickname));
    }
    if (group != null && group.isNotEmpty) {
      final groupElement = xmpp.XmppElement()..name = 'group'..textValue = group;
      item.addChild(groupElement);
    }
    query.addChild(item);
    iq.addChild(query);
    conn.writeStanza(iq);

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.SUBSCRIBE;
    conn.writeStanza(presence);

    if (!_d.currentContacts.any((c) => c.id == jid)) {
      _d.currentContacts.add(
        Contact(
          id: jid,
          name: nickname ?? xmpp.Jid.fromFullJid(jid).local,
          protocol: 'XMPP',
          groups: group != null && group.isNotEmpty ? [group] : [],
        ),
      );
      _d.contactStreamController.add(List.from(_d.currentContacts));
      debugPrint('SOCIAL: Optimistically added $jid to _currentContacts.');
    }

    debugPrint('SOCIAL: Added $jid to roster and sent subscribe request.');
  }

  Future<List<String>> getBlockList({String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return [];

    final stanzaId = 'blocks_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(stanzaId, xmpp.IqStanzaType.GET);
    iq.addChild(
      xmpp.XmppElement()
        ..name = 'blocklist'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:blocking')),
    );

    final completer = Completer<List<String>>();
    StreamSubscription? sub;
    sub = conn.inStanzasStream.listen((stanza) {
      if (stanza is xmpp.IqStanza && stanza.id == stanzaId) {
        if (stanza.type == xmpp.IqStanzaType.RESULT) {
          final list = stanza.getChild('blocklist');
          final jids =
              list?.children
                  .where((c) => c.name == 'item')
                  .map((c) => c.getAttribute('jid')?.value ?? '')
                  .toList() ??
              [];
          completer.complete(jids);
        } else {
          completer.complete([]);
        }
        sub?.cancel();
      }
    });

    conn.writeStanza(iq);
    return await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => [],
    );
  }

  Future<void> clearAllData() async {
    await _auth.logout();
     await _d.omemoService.clearDatabase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await _d.secureStorage.deleteAll();
    _d.savedAccounts.clear();
    _auth.currentProfile = null;
    _auth.notifyListeners();
  }
}
