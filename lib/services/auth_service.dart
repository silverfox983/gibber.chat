import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_models.dart';
import '../models/user_profile.dart';
import './jingle_signaling_service.dart';
import './xmpp_proxy_service.dart' if (dart.library.html) './xmpp_proxy_service_web.dart';
import './http_upload_service.dart';
import './avatar_cache_service.dart';
import './secure_storage_service.dart';
import './otr_service.dart';
import './spaces_service.dart';
import '../models/space_models.dart';
import './database_service.dart';
import './offline_queue_service.dart';
import './connection_lifecycle_service.dart';
import './xmpp_omemo_service.dart';
import './xmpp_room_service.dart';
import './backend_config.dart';
import './auth_service_deps.dart';
import './xmpp_contact_service.dart';
import './xmpp_message_service.dart';

enum ConnectionProtocol { xmpp, none }

class AuthService with ChangeNotifier {
  void Function(String bareJid)? onAuthenticated;
  bool _xmppConnecting = false;

  ConnectionStatus getAccountStatus(String accountId) {
    if (_xmppConnections.containsKey(accountId)) {
      final state = _xmppConnections[accountId]?.state;
      if (state == xmpp.XmppConnectionState.Ready ||
          state == xmpp.XmppConnectionState.Resumed) {
        return ConnectionStatus.online;
      }

      // Map all intermediate states to 'connecting'
      if (state == xmpp.XmppConnectionState.SocketOpening ||
          state == xmpp.XmppConnectionState.SocketOpened ||
          state == xmpp.XmppConnectionState.Authenticating ||
          state == xmpp.XmppConnectionState.Authenticated ||
          state == xmpp.XmppConnectionState.SessionInitialized ||
          state == xmpp.XmppConnectionState.Reconnecting) {
        return ConnectionStatus.connecting;
      }
    }
    return ConnectionStatus.offline;
  }

  bool get xmppConnected => _xmppConnections.values.any(
    (c) => c.state == xmpp.XmppConnectionState.Ready,
  );
  List<String> get connectedAccountIds {
    final ids = <String>{..._xmppConnections.keys};
    final sorted = ids.toList()..sort();
    return sorted;
  }

  List<String> get authenticatedAccountIds =>
      List.unmodifiable(_authenticatedAccountIds);
  List<String> getAccountsStatusLines() {
    final lines = <String>[];
    for (final account in _savedAccounts) {
      final id = account.fullJid;
      final status = getAccountStatus(id);
      final statusText = switch (status) {
        ConnectionStatus.online => 'Online',
        ConnectionStatus.connecting => 'Connecting',
        ConnectionStatus.offline => 'Offline',
      };
      lines.add('${account.protocol}: ${account.user} - $statusText');
    }
    if (lines.isEmpty) {
      // Include transient in-memory accounts if saved list is empty.
      for (final id in connectedAccountIds) {
        final status = getAccountStatus(id);
        final statusText = switch (status) {
          ConnectionStatus.online => 'Online',
          ConnectionStatus.connecting => 'Connecting',
          ConnectionStatus.offline => 'Offline',
        };
        lines.add('$id - $statusText');
      }
    }
    return lines;
  }

  bool get isConnecting => _xmppConnecting;
  bool get isAuthenticated => _authenticatedAccountIds.isNotEmpty;
  bool get xmppConnecting => _xmppConnecting;

  String? _lastDiagnostic;
  String? get lastDiagnostic => _lastDiagnostic;

  // Unified Message Stream
  final StreamController<ChatMessage> _messageStreamController =
      StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get messages => _messageStreamController.stream;

  // Unified Contact Stream
  final StreamController<List<Contact>> _contactStreamController =
      StreamController<List<Contact>>.broadcast();
  Stream<List<Contact>> get contacts => _contactStreamController.stream;
  final List<Contact> _currentContacts = [];

  // Unified Jingle Signaling Stream
  final StreamController<JingleEvent> _jingleEventController =
      StreamController<JingleEvent>.broadcast();
  Stream<JingleEvent> get jingleEvents => _jingleEventController.stream;

  final List<Map<String, String>> _pendingSubscriptionRequests = [];
  List<Map<String, String>> get currentSubscriptionRequests => List.unmodifiable(_pendingSubscriptionRequests);

  // Unified Subscription Request Stream (Friend Requests)
  final StreamController<List<Map<String, String>>> _subscriptionRequestController =
      StreamController<List<Map<String, String>>>.broadcast();
  Stream<List<Map<String, String>>> get subscriptionRequests =>
      _subscriptionRequestController.stream;

  final List<SavedAccount> _savedAccounts = [];
  List<SavedAccount> get savedAccounts => List.unmodifiable(_savedAccounts);

  // XEP-0359: Track sent message origin-Ids for carbon deduplication
  // Maps originId -> accountId, so carbon echoes can update existing messages
  final Map<String, String> _sentOriginIds = {};

  final StreamController<List<SpaceNode>> _joinedSpacesStreamController =
      StreamController<List<SpaceNode>>.broadcast();
  Stream<List<SpaceNode>> get joinedSpacesStream =>
      _joinedSpacesStreamController.stream;

  ContactStatus _myStatus = ContactStatus.online;
  ContactStatus get myStatus => _myStatus;
  String? _myStatusMessage;
  String? get myStatusMessage => _myStatusMessage;

  // Multi-Account Storages
  final Map<String, xmpp.Connection> _xmppConnections = {};
  final Map<String, String> _xmppJids = {};
  List<SpaceNode> _cachedJoinedSpaces = [];
  final Map<String, Completer<List<Map<String, String>>>> _discoveryCompleters =
      {};
  final Map<String, Completer<Map<String, dynamic>>> _roomInfoCompleters = {};
  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};
  final Map<String, XmppProxyService> _xmppProxies = {};
  final Map<String, StreamSubscription> _xmppMessageSubs = {};
  final Map<String, StreamSubscription> _xmppStanzaSubs = {};
  final Map<String, StreamSubscription> _connectionStateSubs = {};
  final Map<String, StreamSubscription> _jingleEventSubs = {};
  final Map<String, StreamSubscription> _rosterSubs = {};
  final Map<String, StreamSubscription> _presenceSubs = {};
  final Set<String> _pendingVCardFetches = {};
  final Map<String, DateTime> _vCardLastFetch = {};

  // Track failed vcard supports to avoid spamming feature-not-implemented
  final Set<String> _vCardUnsupportedJids = {};
  Set<String> get vCardUnsupportedJids => _vCardUnsupportedJids;

  // XEP-0153: Track avatar hashes to avoid redundant fetches and trigger updates
  final Map<String, String> _contactAvatarHashes = {};
  Map<String, String> get contactAvatarHashes => _contactAvatarHashes;

  final Map<String, JingleSignalingService> _jingleServices = {};
  final Map<String, HttpUploadService> _uploadServices = {};
  final Map<String, bool> _carbonsEnabled = {};
  Map<String, bool> get carbonsEnabled => _carbonsEnabled;
  final Map<String, List<Map<String, dynamic>>> _accountIceServers = {};
  Map<String, List<Map<String, dynamic>>> get accountIceServers => _accountIceServers;
  Set<String> get pendingVCardFetches => _pendingVCardFetches;
  Map<String, DateTime> get vCardLastFetch => _vCardLastFetch;
  final Map<String, SpacesService> _spacesServices = {};
  final OfflineQueueService _offlineQueue = OfflineQueueService();
  late final XmppRoomService _roomService;
  late final XmppContactService _contactService;
  late final XmppMessageService _messageService;

  final Map<String, Set<String>> _serverFeatures = {};

  final Map<String, String?> _uploadServiceJids = {};

  final OtrService _otr = OtrService();
  OtrService get otrService => _otr;

  xmpp.Connection? get activeXmppConnection =>
      _activeAccountId != null ? _xmppConnections[_activeAccountId] : null;

  SpacesService? get spacesService =>
      _activeAccountId != null ? getSpacesService(_activeAccountId!) : null;

  HttpUploadService? get activeUploadService =>
      _activeAccountId != null ? _uploadServices[_activeAccountId] : null;

  SpacesService? getSpacesService(String accountId) {
    if (_spacesServices.containsKey(accountId)) {
      return _spacesServices[accountId];
    }
    final conn = _xmppConnections[accountId];
    if (conn != null) {
      final service = SpacesService(conn);
      _spacesServices[accountId] = service;
      return service;
    }
    return null;
  }

  List<Contact> get currentContacts => List.unmodifiable(_currentContacts);

  UserProfile? _currentProfile;
  UserProfile? get currentProfile => _currentProfile;

  String getResolvedNickname(String? accountId) {
    final id = accountId ?? _activeAccountId;
    String? localPart;
    if (id != null && _xmppJids.containsKey(id)) {
      localPart = _xmppJids[id]!.split('@').first.split('/').first;
    }

    final profile = _currentProfile;
    if (profile != null &&
        profile.nickName != null &&
        profile.nickName!.isNotEmpty) {
      return profile.nickName!;
    }

    if (localPart != null && localPart.isNotEmpty) {
      return localPart;
    }

    if (profile != null && profile.displayName.isNotEmpty) {
      return profile.displayName;
    }

    return 'User';
  }

  AuthService() {
    _roomService = XmppRoomService(_xmppConnections, _xmppJids);
    _roomService.setActiveAccountIdGetter(() => _activeAccountId);
    _contactService = XmppContactService(_AuthContactDeps(this));
    _messageService = XmppMessageService(_AuthMessageDeps(this));
    _otr.injectMessage = (bareJid, text) {
      _messageService.sendMessage(_activeAccountId ?? '', bareJid, text, isGroup: false);
    };
  }

  XmppRoomService get roomService => _roomService;
  List<Room> get joinedRooms => _roomService.joinedRooms;
  Stream<List<Room>> get joinedRoomsStream => _roomService.joinedRoomsStream;
  Stream<Map<String, List<RoomParticipant>>> get roomParticipantsStream => _roomService.roomParticipantsStream;
  Stream<Map<String, dynamic>> get groupInviteStream => _roomService.groupInviteStream;
  List<RoomParticipant> getRoomParticipants(String roomJid) => _roomService.getRoomParticipants(roomJid);
  String? getRoomNickname(String? accountId, String roomJid) => _roomService.getNickname(accountId ?? _activeAccountId ?? '', roomJid);

  String? _activeAccountId;
  String? get activeAccountId => _activeAccountId;

  Future<String?> getActiveAccountPassword() async {
    if (_activeAccountId == null) return null;
    return await _secureStorage.read(key: 'pass_$_activeAccountId');
  }

  BackendConfig? _backendConfig;

  void setBackendConfig(BackendConfig config) {
    _backendConfig = config;
  }

  // Track accounts that are intentionally logged in, even if temporarily disconnected.
  // This prevents the "Login Screen Flap" during network transitions.
  final Set<String> _authenticatedAccountIds = {};

  static ConnectionProtocol detectProtocol(String rawInput) {
    final input = rawInput.trim();

    // XMPP Detection
    if (input.contains('@')) {
      return ConnectionProtocol.xmpp;
    }

    return ConnectionProtocol.none;
  }

  final XmppOmemoService _omemoService = XmppOmemoService();
  XmppOmemoService get omemoService => _omemoService;

  bool isOmemoEnabled(String chatId) => _omemoService.isOmemoEnabled(chatId);

  bool get isStrictVerificationEnabled => _omemoService.isStrictVerificationEnabled;

  Future<void> setStrictVerification(bool enabled) => _omemoService.setStrictVerification(enabled);

  Future<bool> hasUnverifiedDevices(String jid) => _omemoService.hasUnverifiedDevices(jid);

  Future<int> getChatSecurityStatus(String chatId) => _omemoService.getChatSecurityStatus(chatId);

  Future<void> updateOmemoTrust(String jid, int deviceId, int trustLevel) => _omemoService.updateOmemoTrust(jid, deviceId, trustLevel);

  void toggleOmemo(String chatId) => _omemoService.toggleOmemo(chatId);

  bool isOmemoSupportedByServer(String accountId) => _omemoService.isOmemoSupportedByServer(accountId);

  Future<Map<int, Map<String, dynamic>>> getOmemoFingerprintsDetailed(String chatId) => _omemoService.getOmemoFingerprintsDetailed(chatId);

  Future<void> refreshOmemoDevices(String chatId, {String? accountId}) => _omemoService.refreshOmemoDevices(chatId, accountId: accountId);

  Future<String> getMyOmemoFingerprint() => _omemoService.getMyOmemoFingerprint();

  Future<List<Map<String, dynamic>>> fetchOmemoIdentities() => _omemoService.fetchOmemoIdentities(activeAccountId: _activeAccountId, jidsMap: _xmppJids);

  int getLocalOmemoDeviceId() => _omemoService.getLocalOmemoDeviceId();

  Future<void> resetOmemoKeys(String accountId) => _omemoService.resetOmemoKeys(accountId);

  final _secureStorage = SecureStorageService.instance;
  SecureStorageService get secureStorage => _secureStorage;

  // Helper to get Jingle service for call provider
  JingleSignalingService? get jingleSignaling => _activeAccountId != null
      ? _jingleServices[_activeAccountId]
      : _jingleServices.values.firstOrNull;

  JingleSignalingService? getJingleService(String accountId) =>
      _jingleServices[accountId];

  void setJingleProceedCallback(
    Function(String sessionId, String sdp, String toJid)? callback,
  ) {
    final service = jingleSignaling;
    if (service != null) {
      service.onProceedReceived = callback;
      debugPrint('Auth: Set Jingle proceed callback');
    }
  }

  // Search (XEP-0055)
  Future<List<Map<String, String>>> searchUsers(
    String query, {
    String? accountId,
    String? searchHost,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) throw Exception('Not connected');

    final host = searchHost ?? 'search.${_xmppJids[id]?.split('@').last}';
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

  // Send typing state (XEP-0085)
  void sendTypingState(String accountId, String toJid, String state) {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(toJid);

    final stateEl = xmpp.XmppElement();
    stateEl.name = state; // composing, paused, active, gone
    stateEl.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/chatstates'),
    );
    msg.addChild(stateEl);
    conn.writeStanza(msg);
  }

  Future<void> setPresence(ContactStatus status, String? message) async {
    await updateMyStatus(status, message: message);
  }

  // --- MEDIA & FILE TRANSFERS (XEP-0363) ---

  Stream<double>? getUploadProgress(String? accountId) {
    if (accountId == null) {
      return null;
    }
    return _uploadServices[accountId]?.uploadProgress;
  }

  /// Sends a file to a recipient using XEP-0363 (HTTP File Upload)
  Future<void> sendFile(
    String accountId,
    String toJid,
    File file, {
    MessageType type = MessageType.image,
  }) async {
    final conn = _xmppConnections[accountId];
    final uploadService = _uploadServices[accountId];
    if (conn == null || uploadService == null) {
      throw Exception('Upload service not available for this account.');
    }

    final fileName = file.path.split(RegExp(r'[/\\]')).last;
    final size = await file.length();
    final contentType = type == MessageType.image
        ? 'image/jpeg'
        : 'application/octet-stream';

    debugPrint('XEP-0363: Requesting slot for $fileName ($size bytes)...');
    final slot = await uploadService.requestUploadSlot(
      fileName,
      size,
      contentType: contentType,
    );

    if (slot == null) {
      throw Exception(
        'Server rejected file upload request. (Slot request failed)',
      );
    }

    final putUrl = slot['put']!;
    final getUrl = slot['get']!;

    debugPrint('XEP-0363: Uploading to $putUrl...');
    final success = await uploadService.uploadFile(putUrl, file, contentType);

    if (!success) {
      throw Exception('Failed to upload file to the server.');
    }

    debugPrint('XEP-0363: Upload success. Sending URL to $toJid');

    // Send the message with the GET URL
    sendMessage(
      accountId,
      toJid,
      getUrl,
      type: type,
      fileName: fileName,
      filePath: file.path,
    );
  }

  /// High-level method to send image/file with automatic protocol-specific handling
  Future<void> sendMediaMessage(
    String toJid,
    File file,
    MessageType type, {
    String? accountId,
    bool isGroup = false,
    String? caption,
  }) async {
    final id = accountId ?? _activeAccountId;
    if (id == null) return;

    if (_xmppConnections.containsKey(id)) {
      // XMPP: Use HTTP File Upload (XEP-0363)
      await sendFile(id, toJid, file, type: type);
    }
  }

  // Update VCard (XEP-0054)
  Future<void> updateMyVCard({
    required String accountId,
    String? fullName,
    String? nickName,
    String? description,
    String? email,
    String? phone,
    String? url,
    String? organization,
    String? title,
    String? role,
    String? birthday,
  }) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));

    if (fullName != null) {
      final fn = xmpp.XmppElement();
      fn.name = 'FN';
      fn.textValue = fullName;
      vcard.addChild(fn);
    }

    if (nickName != null) {
      final nick = xmpp.XmppElement();
      nick.name = 'NICKNAME';
      nick.textValue = nickName;
      vcard.addChild(nick);
    }

    if (description != null) {
      final desc = xmpp.XmppElement();
      desc.name = 'DESC';
      desc.textValue = description;
      vcard.addChild(desc);
    }

    if (email != null) {
      final el = xmpp.XmppElement()..name = 'EMAIL';
      el.addChild(xmpp.XmppElement()..name = 'USERID'..textValue = email);
      vcard.addChild(el);
    }
    if (phone != null) {
      final el = xmpp.XmppElement()..name = 'TEL';
      el.addChild(xmpp.XmppElement()..name = 'NUMBER'..textValue = phone);
      vcard.addChild(el);
    }
    if (url != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'URL'..textValue = url);
    }
    if (organization != null) {
      final el = xmpp.XmppElement()..name = 'ORG';
      el.addChild(xmpp.XmppElement()..name = 'ORGNAME'..textValue = organization);
      vcard.addChild(el);
    }
    if (title != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'TITLE'..textValue = title);
    }
    if (role != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'ROLE'..textValue = role);
    }
    if (birthday != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'BDAY'..textValue = birthday);
    }

    iq.addChild(vcard);
    conn.writeStanza(iq);

    // Refresh local cache
    if (_currentProfile != null) {
      _currentProfile!.displayName = fullName ?? _currentProfile!.displayName;
      _currentProfile!.nickName = nickName ?? _currentProfile!.nickName;
      _currentProfile!.bio = description ?? _currentProfile!.bio;
      _currentProfile!.email = email ?? _currentProfile!.email;
      _currentProfile!.phone = phone ?? _currentProfile!.phone;
      _currentProfile!.url = url ?? _currentProfile!.url;
      _currentProfile!.organization = organization ?? _currentProfile!.organization;
      _currentProfile!.title = title ?? _currentProfile!.title;
      _currentProfile!.role = role ?? _currentProfile!.role;
      _currentProfile!.birthday = birthday ?? _currentProfile!.birthday;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'current_profile',
        json.encode(_currentProfile!.toJson()),
      );
      notifyListeners();
    }
  }

  Future<void> fetchMyVCard({String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    if (id != null) {
      await fetchVCard(id, _xmppJids[id]!.split('/').first);
    }
  }

  // Set My Avatar (XEP-0054)
  Future<void> setMyAvatar(String accountId, File image) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final bytes = await image.readAsBytes();
    final photoBase64 = base64Encode(bytes);

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));

    final photo = xmpp.XmppElement();
    photo.name = 'PHOTO';
    final type = xmpp.XmppElement();
    type.name = 'TYPE';
    type.textValue = 'image/jpeg';
    photo.addChild(type);
    final binval = xmpp.XmppElement();
    binval.name = 'BINVAL';
    binval.textValue = photoBase64;
    photo.addChild(binval);
    vcard.addChild(photo);

    iq.addChild(vcard);
    conn.writeStanza(iq);

    // Cache locally as well
    final myJid = _xmppJids[accountId];
    if (myJid != null) {
      await AvatarCacheService().saveAvatar(myJid.split('/').first, bytes);
      notifyListeners();
      
      // XEP-0153: Broadcast new presence with updated avatar hash
      await updateMyStatus(_myStatus, message: _myStatusMessage);
    }
  }

  // Fetch VCard (XEP-0054)
  Future<void> fetchVCard(String accountId, String jid) async {
    if (jid.isEmpty) return;

    // Normalize JID and check blacklist
    String cleanJid = jid.toLowerCase();

    // Fix common typos
    if (cleanJid.endsWith('.vom')) {
      cleanJid = cleanJid.replaceFirst('.vom', '.com');
    }

    final cacheKey = '$accountId:$cleanJid';

    if (_vCardUnsupportedJids.contains(cleanJid)) return;

    final now = DateTime.now();
    if (_vCardLastFetch.containsKey(cacheKey)) {
      if (now.difference(_vCardLastFetch[cacheKey]!) <
          const Duration(hours: 1)) {
        return; // Don't fetch more than once per hour
      }
    }

    if (_pendingVCardFetches.contains(cacheKey)) return;
    _pendingVCardFetches.add(cacheKey);

    final conn = _xmppConnections[accountId];
    if (conn == null) {
      _pendingVCardFetches.remove(cacheKey);
      return;
    }

    _vCardLastFetch[cacheKey] = now;

    // Small random jitter to prevent simultaneous bursts
    await Future.delayed(Duration(milliseconds: 50 + (jid.hashCode % 450)));

    final iq = xmpp.IqStanza(
      'vcard_${DateTime.now().millisecondsSinceEpoch}_${jid.hashCode}',
      xmpp.IqStanzaType.GET,
    );

    // XEP-0054: Do NOT include a 'to' address when requesting your own vCard.
    final myBareJid = _xmppJids[accountId]?.split('/').first.toLowerCase();
    if (cleanJid != myBareJid) {
      iq.toJid = xmpp.Jid.fromFullJid(jid);
    }

    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));
    iq.addChild(vcard);
    conn.writeStanza(iq);

    // Keep it in pending for a bit to avoid rapid fire
    Timer(const Duration(seconds: 15), () {
      _pendingVCardFetches.remove(cacheKey);
    });
  }

  // Function to connect to XMPP
  Future<void> connectXmpp({
    required String user,
    required String domain,
    required String pass,
    required int port,
    String? host,
    String? accountId,
    SavedAccount? configData,
  }) async {
    final fullJidStr = user.contains('@') ? user : '$user@$domain';
    final id = accountId ?? fullJidStr.split('/').first.toLowerCase();

    _xmppConnecting = true;
    _lastDiagnostic = null;
    notifyListeners();

    try {
      final jid = xmpp.Jid.fromFullJid(fullJidStr);

      final Completer<void> connectionCompleter = Completer<void>();

      late final xmpp.XmppAccountSettings accountSettings;

      if (kIsWeb) {
        // Web: connect via WebSocket using BackendConfig URL if available
        String wsHost;
        int wsPort;
        String wsPath;

        if (_backendConfig != null) {
          final wsUrl = _backendConfig!.derivedWebsocketUrl;
          final uri = Uri.parse(wsUrl);
          wsHost = uri.host;
          wsPort = uri.port > 0 ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
          wsPath = uri.path.isNotEmpty ? uri.path : '/xmpp-websocket';
        } else {
          wsHost = host ?? domain;
          wsPort = 443;
          wsPath = configData?.wsPath ?? '/xmpp-websocket';
        }

        accountSettings = xmpp.XmppAccountSettings(
          jid.fullJid ?? fullJidStr,
          jid.local,
          jid.domain,
          pass,
          wsPort,
          host: wsHost,
          resource: configData?.customResource ?? 'gibber_web',
          wsPath: wsPath,
        );
        accountSettings.wsProtocols = ['xmpp'];
        debugPrint('XMPP: Web connection to $wsHost:$wsPort$wsPath');
      } else {
        // Native: connect via local TCP/TLS proxy
        _xmppProxies[id]?.stop();
        final proxy = XmppProxyService();
        _xmppProxies[id] = proxy;

        final proxyTargetHost = host ?? domain;
        final proxyTargetPort = port;

        final localPort = await proxy.start(
          proxyTargetHost,
          proxyTargetPort,
          domain,
        );

        accountSettings = xmpp.XmppAccountSettings(
          jid.fullJid ?? fullJidStr,
          jid.local,
          jid.domain,
          pass,
          localPort,
          host: '127.0.0.1',
          resource: configData?.customResource ?? 'gibber_mobile',
          wsPath: configData?.wsPath,
        );
      }

      // DOMAIN GUARD: Ensure SASL identity is explicitly the target domain
      debugPrint(
        'XMPP: Preparing connection for ${jid.fullJid} (Domain: ${jid.domain}, Pass Length: ${pass.length})',
      );

      // Stream Management: enabled by default (xmpp_stone SM bug is fixed in local fork)
      accountSettings.ackEnabled = true;
      accountSettings.smResumable = true;

      if (configData != null) {
        if (configData.reconnectionTimeout != null) {
          accountSettings.reconnectionTimeout = configData.reconnectionTimeout!;
        }
      }

      final conn = xmpp.Connection(accountSettings);
      final bareJid = fullJidStr.split('/').first.toLowerCase();
      _omemoService.registerConnection(id, conn, fullJidStr);
      await _omemoService.initialize(bareJid);

      _xmppConnections[id] = conn;
      _xmppJids[id] = jid.fullJid ?? fullJidStr; // Store JID
      ConnectionLifecycleService.instance.registerConnection(id, conn);

      _connectionStateSubs[id]?.cancel();
      _connectionStateSubs[id] = conn.connectionStateStream.listen((state) async {
        debugPrint('XMPP Account $id State: $state');
        notifyListeners();
        if (state == xmpp.XmppConnectionState.Ready) {
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.complete();
          }
          _xmppConnecting = false;
          _activeAccountId ??= id;
          _authenticatedAccountIds.add(id); // Track user intent

          // Enable keepalive pings (60s interval, 30s timeout, 3 max unanswered)
          xmpp.PingManager.getInstance(conn).setPingInterval(
            const Duration(seconds: 60),
            timeout: const Duration(seconds: 30),
          );

          // OMEMO: Publish keys now that we're connected & authenticated (XEP-0384)
          final bareJid = fullJidStr.split('/').first.toLowerCase();
          _omemoService.publishKeys(conn, bareJid);

          // Broadcast presence after connection (including XEP-0153 avatar hash)
          await updateMyStatus(_myStatus, message: _myStatusMessage);

          final signaling = JingleSignalingService(conn);
          _jingleServices[id] = signaling;
          debugPrint(
            'VOIP ($id): Jingle signaling service initialized and attached.',
          );

          final uploadService = HttpUploadService(conn);
          _uploadServices[id] = uploadService;

          // Trigger Service Discovery
          _discoverServiceFeatures(id, domain);

          // Auto-Join Persistence
          _autoJoinRooms(id);

          // Trigger Full Data Sync (MAM, Bookmarks, vCard)
          _syncAllXmppData(id, conn);

          // Flush offline message queue now that we're connected
          _flushPendingMessages(id);

          onAuthenticated?.call(bareJid);

          // Services are initialized on Ready state above.
          // Redundant listener removed to centralize state handling.

          // Pipe events to unified stream
          _jingleEventSubs[id]?.cancel();
          _jingleEventSubs[id] = signaling.events.listen((event) {
            _jingleEventController.add(
              JingleEvent(
                action: event.action,
                sessionId: event.sessionId,
                fromJid: event.fromJid,
                accountId: id, // Tag with local account ID
                sdp: event.sdp,
                reason: event.reason,
                candidate: event.candidate,
              ),
            );
          });

          // Setup Roster
          final rosterManager = xmpp.RosterManager.getInstance(conn);
          rosterManager.getRoster();
          _rosterSubs[id]?.cancel();
          _rosterSubs[id] = rosterManager.rosterStream.listen((items) {
            for (var item in items) {
              final jidObj = item.jid;
              final String? contactId = jidObj?.fullJid ?? jidObj?.domain;
              if (contactId != null &&
                  !_currentContacts.any((c) => c.id == contactId)) {
                _currentContacts.add(
                  Contact(
                    id: contactId,
                    name: item.name ?? jidObj?.local ?? 'User',
                    protocol: 'XMPP',
                  ),
                );
              }
            }
            _contactStreamController.add(List.from(_currentContacts));
            // Proactive vCard/Avatar discovery for the newly loaded roster
            _fetchAllVCards(id);
          });

          // Handle Presence
          final presenceManager = xmpp.PresenceManager.getInstance(conn);
          _presenceSubs[id]?.cancel();
          _presenceSubs[id] = presenceManager.presenceStream.listen((presence) {
            final pid = presence.jid?.fullJid ?? presence.jid?.domain;
            if (pid != null) {
              final barePid = pid.split('/').first.toLowerCase();
              final index = _currentContacts.indexWhere(
                (c) => c.id.toLowerCase().split('/').first == barePid,
              );
              if (index != -1) {
                _currentContacts[index].status = _mapPresenceToShow(
                  presence.showElement,
                );
                _currentContacts[index].presenceMessage = presence.status;
                _contactStreamController.add(List.from(_currentContacts));
              }
            }
          });

          // Handle Messages - Relegated entirely to inStanzasStream below
          // to prevent duplicate message emissions and avoid redundant OTR/OMEMO decryption overlaps.

          _xmppStanzaSubs[id]?.cancel();
          _xmppStanzaSubs[id] = conn.inStanzasStream.listen((stanza) async {
            if (stanza is xmpp.PresenceStanza) {
              final fromJid = stanza.fromJid;
              
              xmpp.XmppElement? mucUser;
              for (var child in stanza.children) {
                if (child.name == 'x' && child.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/muc#user') {
                  mucUser = child;
                  break;
                }
              }

              if (mucUser != null) {
                final roomJid = '${fromJid?.local}@${fromJid?.domain}';
                final nick = fromJid?.resource;
                if (nick != null) {
                  final isUnavailable = stanza.type.toString().contains(
                    'unavailable',
                  );

                  final item = mucUser.getChild('item');
                  final affiliation = item?.getAttribute('affiliation')?.value;
                  final role = item?.getAttribute('role')?.value;
                  final realJid = item?.getAttribute('jid')?.value;

                  final participant = RoomParticipant(
                    nickname: nick,
                    affiliation: affiliation,
                    role: role,
                    realJid: realJid,
                  );

                  if (isUnavailable) {
                    _roomService.removeParticipant(roomJid, nick);
                  } else {
                    _roomService.updateParticipant(roomJid, participant);
                  }
                }
              }
            }

            if (stanza is xmpp.PresenceStanza) {
              final typeStr = stanza.type.toString();
              final fromJid = stanza.fromJid?.fullJid;

              if (typeStr.contains('subscribe') &&
                  !typeStr.contains('unsubscribe')) {
                // Incoming friend request
                if (fromJid != null) {
                  final req = {
                    'jid': fromJid,
                    'accountId': id,
                    'type': 'subscribe',
                  };
                  if (!_pendingSubscriptionRequests.any((r) => r['jid'] == fromJid)) {
                    _pendingSubscriptionRequests.add(req);
                    _subscriptionRequestController.add(List.from(_pendingSubscriptionRequests));
                  }
                }
              } else if (typeStr.contains('unsubscribed')) {
                debugPrint('SOCIAL: User $fromJid unsubscribed from us.');
              }

              // XEP-0153: vCard-Based Avatars
              final updateNode = stanza.children.cast<xmpp.XmppElement?>().firstWhere(
                (child) => child != null && child.name == 'x' && child.getAttribute('xmlns')?.value == 'vcard-temp:x:update',
                orElse: () => null,
              );
              
              if (updateNode != null) {
                final photoNode = updateNode.getChild('photo');
                final hash = photoNode?.textValue;
                
                // Determine if it's a MUC participant
                final isMuc = stanza.children.any((c) => c.name == 'x' && c.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/muc#user');
                
                // MUC avatars use fullJid, regular contacts use bareJid
                final String? avatarTargetJid = isMuc 
                    ? stanza.fromJid?.fullJid?.toLowerCase()
                    : stanza.fromJid?.fullJid?.split('/').first.toLowerCase();
                
                if (avatarTargetJid != null) {
                  if (hash != null && hash.isNotEmpty) {
                    final currentHash = _contactAvatarHashes[avatarTargetJid];
                    if (currentHash != hash) {
                      debugPrint('XEP-0153: Detected new avatar hash for $avatarTargetJid, fetching vCard...');
                      _contactAvatarHashes[avatarTargetJid] = hash;
                      fetchVCard(id, avatarTargetJid);
                    }
                  } else if (hash == '') {
                    // Empty hash indicates the user removed their avatar
                    debugPrint('XEP-0153: Empty avatar hash received for $avatarTargetJid, clearing local cache.');
                    _contactAvatarHashes.remove(avatarTargetJid);
                  }
                }
              }
            }

            if (stanza is xmpp.IqStanza) {
              final fromJidStr = stanza.fromJid?.fullJid;

              if (stanza.id != null && (_pendingIqs.containsKey(stanza.id) || _roomService.pendingIqs.containsKey(stanza.id))) {
                if (_pendingIqs.containsKey(stanza.id)) {
                  _pendingIqs[stanza.id!]!.complete(stanza);
                  _pendingIqs.remove(stanza.id);
                } else {
                  _roomService.pendingIqs[stanza.id!]!.complete(stanza);
                  _roomService.pendingIqs.remove(stanza.id);
                }
              }

              if (stanza.type == xmpp.IqStanzaType.ERROR) {
                final error = stanza.getChild('error');
                if (error != null) {
                  final isNotImplemented =
                      error.getChild('feature-not-implemented') != null;
                  final isServiceUnavailable =
                      error.getChild('service-unavailable') != null;

                  if ((isNotImplemented || isServiceUnavailable) &&
                      fromJidStr != null) {
                    final cleanJid = fromJidStr.toLowerCase().split('/').first;
                    // If the IQ had a vCard element or starts with vcard_, blacklist it
                    if (stanza.getChild('vCard') != null ||
                        (stanza.id != null &&
                            stanza.id!.startsWith('vcard_'))) {
                      _vCardUnsupportedJids.add(cleanJid);
                      // debugPrint('VCard not supported by $cleanJid - blacklisting.');
                    }
                  }
                }

                if (stanza.id != null) {
                  if (_discoveryCompleters.containsKey(stanza.id)) {
                    _discoveryCompleters[stanza.id]!.complete([]);
                    _discoveryCompleters.remove(stanza.id);
                  }
                  if (_roomInfoCompleters.containsKey(stanza.id)) {
                    _roomInfoCompleters[stanza.id]!.complete({
                      'jid': stanza.fromJid?.fullJid ?? '',
                      'name': '',
                      'description': '',
                    });
                    _roomInfoCompleters.remove(stanza.id);
                  }
                  if (_roomService.discoveryCompleters.containsKey(stanza.id)) {
                    _roomService.discoveryCompleters[stanza.id]!.complete([]);
                    _roomService.discoveryCompleters.remove(stanza.id);
                  }
                  if (_roomService.roomInfoCompleters.containsKey(stanza.id)) {
                    _roomService.roomInfoCompleters[stanza.id]!.complete({
                      'jid': stanza.fromJid?.fullJid ?? '',
                      'name': '',
                      'description': '',
                    });
                    _roomService.roomInfoCompleters.remove(stanza.id);
                  }
                }
              }

              // Intercept Roster Pushes and Responses to parse custom <group> elements
              if (stanza.type == xmpp.IqStanzaType.RESULT || stanza.type == xmpp.IqStanzaType.SET) {
                final query = stanza.getChild('query');
                if (query != null && query.getAttribute('xmlns')?.value == 'jabber:iq:roster') {
                  bool rosterUpdated = false;
                  for (var item in query.children.where((e) => e.name == 'item')) {
                    final itemJid = item.getAttribute('jid')?.value;
                    if (itemJid != null) {
                      final bareJid = itemJid.toLowerCase().split('/').first;
                      final name = item.getAttribute('name')?.value;
                      
                      // Extract <group> tags
                      final groups = item.children
                          .where((e) => e.name == 'group')
                          .map((e) => e.textValue)
                          .whereType<String>()
                          .toList();

                      final index = _currentContacts.indexWhere((c) => c.id.toLowerCase().split('/').first == bareJid);
                      if (index != -1) {
                        _currentContacts[index].groups.clear();
                        _currentContacts[index].groups.addAll(groups);
                        if (name != null && name.isNotEmpty) {
                          _currentContacts[index].name = name;
                        }
                        rosterUpdated = true;
                      } else {
                        // If not found, add it optimistically; RosterManager will also process it but we have group data now.
                        _currentContacts.add(Contact(
                          id: itemJid,
                          name: name ?? bareJid,
                          protocol: 'XMPP',
                          groups: groups,
                        ));
                        rosterUpdated = true;
                      }
                    }
                  }
                  if (rosterUpdated) {
                    _contactStreamController.add(List.from(_currentContacts));
                  }
                }
              }

              // Respond to incoming Discovery requests (XEP-0030)
              if (stanza.type == xmpp.IqStanzaType.GET) {
                final query = stanza.getChild('query');
                if (query != null) {
                  final xmlns = query.getAttribute('xmlns')?.value;
                  if (xmlns == 'http://jabber.org/protocol/disco#info') {
                    final responseId =
                        stanza.id ??
                        'disco_resp_${DateTime.now().millisecondsSinceEpoch}';
                    final iq = xmpp.IqStanza(
                      responseId,
                      xmpp.IqStanzaType.RESULT,
                    );
                    iq.toJid = stanza.fromJid;

                    final resultQuery = xmpp.XmppElement();
                    resultQuery.name = 'query';
                    resultQuery.addAttribute(
                      xmpp.XmppAttribute(
                        'xmlns',
                        'http://jabber.org/protocol/disco#info',
                      ),
                    );

                    final identity = xmpp.XmppElement();
                    identity.name = 'identity';
                    identity.addAttribute(
                      xmpp.XmppAttribute('category', 'client'),
                    );
                    identity.addAttribute(xmpp.XmppAttribute('type', 'pc'));
                    identity.addAttribute(xmpp.XmppAttribute('name', 'Gibber'));
                    resultQuery.addChild(identity);

                    final f1 = xmpp.XmppElement();
                    f1.name = 'feature';
                    f1.addAttribute(
                      xmpp.XmppAttribute(
                        'var',
                        'http://jabber.org/protocol/disco#info',
                      ),
                    );
                    final f2 = xmpp.XmppElement();
                    f2.name = 'feature';
                    f2.addAttribute(
                      xmpp.XmppAttribute(
                        'var',
                        'http://jabber.org/protocol/disco#items',
                      ),
                    );
                    final f3 = xmpp.XmppElement();
                    f3.name = 'feature';
                    f3.addAttribute(
                      xmpp.XmppAttribute('var', 'urn:xmpp:http:upload:0'),
                    );
                    final f4 = xmpp.XmppElement();
                    f4.name = 'feature';
                    f4.addAttribute(
                      xmpp.XmppAttribute('var', 'urn:xmpp:jingle:1'),
                    );
                    final f5 = xmpp.XmppElement();
                    f5.name = 'feature';
                    f5.addAttribute(
                      xmpp.XmppAttribute('var', 'urn:xmpp:receipts'),
                    );

                    resultQuery.addChild(f1);
                    resultQuery.addChild(f2);
                    resultQuery.addChild(f3);
                    resultQuery.addChild(f4);
                    resultQuery.addChild(f5);
                    iq.addChild(resultQuery);
                    conn.writeStanza(iq);
                    return;
                  } else if (xmlns ==
                      'http://jabber.org/protocol/disco#items') {
                    final responseId =
                        stanza.id ??
                        'disco_items_resp_${DateTime.now().millisecondsSinceEpoch}';
                    final iq = xmpp.IqStanza(
                      responseId,
                      xmpp.IqStanzaType.RESULT,
                    );
                    iq.toJid = stanza.fromJid;

                    final resultQuery = xmpp.XmppElement();
                    resultQuery.name = 'query';
                    resultQuery.addAttribute(
                      xmpp.XmppAttribute(
                        'xmlns',
                        'http://jabber.org/protocol/disco#items',
                      ),
                    );

                    iq.addChild(resultQuery);
                    conn.writeStanza(iq);
                    return;
                  }
                }
              }

              final vcard = stanza.getChild('vCard');
              if (vcard != null &&
                  vcard.getAttribute('xmlns')?.value == 'vcard-temp') {
                final nick = vcard.getChild('NICKNAME')?.textValue;
                final fullName = vcard.getChild('FN')?.textValue;
                final desc = vcard.getChild('DESC')?.textValue;
                final email = vcard.getChild('EMAIL')?.getChild('USERID')?.textValue;
                final phone = vcard.getChild('TEL')?.getChild('NUMBER')?.textValue;
                final url = vcard.getChild('URL')?.textValue;
                final org = vcard.getChild('ORG')?.getChild('ORGNAME')?.textValue;
                final title = vcard.getChild('TITLE')?.textValue;
                final role = vcard.getChild('ROLE')?.textValue;
                final bday = vcard.getChild('BDAY')?.textValue;
                final photo = vcard
                    .getChild('PHOTO')
                    ?.getChild('BINVAL')
                    ?.textValue;

                if (nick != null ||
                    photo != null ||
                    fullName != null ||
                    desc != null ||
                    email != null ||
                    phone != null ||
                    url != null ||
                    org != null ||
                    title != null ||
                    role != null ||
                    bday != null) {
                  // XEP-0054: Server omits 'from' if it's our own vCard.
                  final responseJid =
                      stanza.fromJid?.fullJid ??
                      _xmppJids[id]?.split('/').first ??
                      '';

                  if (photo != null) {
                    try {
                      final bytes = base64Decode(
                        photo.replaceAll(RegExp(r'\s+'), ''),
                      );
                      AvatarCacheService().saveAvatar(responseJid, bytes);
                    } catch (e) {
                      debugPrint('VCard PHOTO DECODE ERROR: $e');
                    }
                  }

                  // Update local profile if it's our JID
                  final myJid = _xmppJids[id];
                  if (responseJid.isNotEmpty &&
                      myJid != null &&
                      responseJid.toLowerCase().startsWith(
                        myJid.split('/').first.toLowerCase(),
                      )) {
                    if (_currentProfile != null) {
                      _currentProfile!.displayName =
                          fullName ?? nick ?? _currentProfile!.displayName;
                      _currentProfile!.nickName = nick;
                      _currentProfile!.bio = desc;
                      _currentProfile!.email = email;
                      _currentProfile!.phone = phone;
                      _currentProfile!.url = url;
                      _currentProfile!.organization = org;
                      _currentProfile!.title = title;
                      _currentProfile!.role = role;
                      _currentProfile!.birthday = bday;
                      notifyListeners();
                      debugPrint(
                        'SYNC: Synced local profile avatar/vCard from server.',
                      );
                    }
                  }

                  // Update Contact object if it exists
                  final bareResponseJid = responseJid.split('/').first.toLowerCase();
                  final contactIndex = _currentContacts.indexWhere((c) => c.id.toLowerCase().split('/').first == bareResponseJid);
                  if (contactIndex != -1) {
                    _currentContacts[contactIndex].fullName = fullName;
                    _currentContacts[contactIndex].bio = desc;
                    _currentContacts[contactIndex].email = email;
                    _currentContacts[contactIndex].phone = phone;
                    _currentContacts[contactIndex].url = url;
                    _currentContacts[contactIndex].organization = org;
                    _currentContacts[contactIndex].title = title;
                    _currentContacts[contactIndex].role = role;
                    _currentContacts[contactIndex].birthday = bday;
                    if (nick != null && nick.isNotEmpty) {
                      _currentContacts[contactIndex].name = nick;
                    } else if (fullName != null && fullName.isNotEmpty) {
                      _currentContacts[contactIndex].name = fullName;
                    }
                    _contactStreamController.add(List.from(_currentContacts));
                  }

                  _messageStreamController.add(
                    ChatMessage(
                      id: 'vcard_$responseJid',
                      text: 'UPDATE_PROFILE',
                      timestamp: DateTime.now(),
                      isSent: false,
                      senderId: responseJid,
                      senderName: fullName ?? nick,
                      type: MessageType.system,
                    ),
                  );
                }
              }

              final items = stanza.getChild('query');
              if (items != null &&
                  items.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/disco#items') {
                final discoveredRooms = <Map<String, String>>[];
                for (var item in items.children) {
                  final jid = item.getAttribute('jid')?.value;
                  final name = item.getAttribute('name')?.value;
                  if (jid != null &&
                      (name?.toLowerCase().contains('upload') == true ||
                          name?.toLowerCase().contains('share') == true ||
                          jid.startsWith('upload.') ||
                          jid.contains('upload') ||
                          jid.contains('share'))) {
                    _uploadServiceJids[id] = jid;
                    _uploadServices[id]?.uploadServiceJid = jid;
                    debugPrint('DISCO: Found HTTP Upload service: $jid');
                  } else if (jid != null && name != null) {
                    discoveredRooms.add({'jid': jid, 'name': name});
                  }
                }

                if (stanza.id != null &&
                    _discoveryCompleters.containsKey(stanza.id)) {
                  _discoveryCompleters[stanza.id]!.complete(discoveredRooms);
                  _discoveryCompleters.remove(stanza.id);
                }
                if (stanza.id != null &&
                    _roomService.discoveryCompleters.containsKey(stanza.id)) {
                  _roomService.discoveryCompleters[stanza.id]!.complete(discoveredRooms);
                  _roomService.discoveryCompleters.remove(stanza.id);
                }
                return;
              }

              final info = stanza.getChild('query');
              if (info != null &&
                  info.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/disco#info') {
                // Only update server features if this was our server discovery query
                // and avoid processing if it was just a component discovery
                if (stanza.id != null &&
                    stanza.id!.startsWith('disco_info_server_')) {
                  _serverFeatures[id] = {};
                  for (var feature in info.children.where(
                    (c) => c.name == 'feature',
                  )) {
                    final varAttr = feature.getAttribute('var')?.value;
                    if (varAttr != null) {
                      _serverFeatures[id]!.add(varAttr);
                    }
                  }
                  _omemoService.registerServerFeatures(id, _serverFeatures[id]!);
                  debugPrint('DISCO: Server features: ${_serverFeatures[id]}');

                  // If Carbons supported, auto-enable
                  if (_serverFeatures[id]!.contains('urn:xmpp:carbons:2') &&
                      _carbonsEnabled[id] != true) {
                    _enableCarbons(id);
                  }

                  // Check if server directly supports HTTP File Upload
                  // NOTE: We only use the main domain as a fallback if no dedicated component was found in disco#items
                  if (_serverFeatures[id]!.contains('urn:xmpp:http:upload:0') &&
                      _uploadServiceJids[id] == null) {
                    final domain = _xmppJids[id]
                        ?.split('@')
                        .last
                        .split('/')
                        .first;
                    if (domain != null) {
                      _uploadServiceJids[id] = domain;
                      _uploadServices[id]?.uploadServiceJid = domain;
                      debugPrint(
                        'DISCO: Server advertises HTTP Upload on main domain (fallback)',
                      );
                    }
                  }
                }

                // Handle MUC Room Info queries
                if (stanza.id != null &&
                    (_roomInfoCompleters.containsKey(stanza.id) ||
                     _roomService.roomInfoCompleters.containsKey(stanza.id))) {
                  final Map<String, dynamic> roomInfo = {
                    'jid': stanza.fromJid?.fullJid ?? '',
                    'password_protected': false,
                  };

                  // Extract features (e.g. muc_passwordprotected)
                  for (var feature in info.children.where(
                    (c) => c.name == 'feature',
                  )) {
                    if (feature.getAttribute('var')?.value ==
                        'muc_passwordprotected') {
                      roomInfo['password_protected'] = true;
                    }
                  }

                  // Extract extended data forms
                  final xData = info.getChild('x');
                  if (xData != null &&
                      xData.getAttribute('xmlns')?.value == 'jabber:x:data') {
                    for (var field in xData.children.where(
                      (c) => c.name == 'field',
                    )) {
                      final varName = field.getAttribute('var')?.value;
                      final val = field.getChild('value')?.textValue;
                      if (varName != null && val != null) {
                        if (varName == 'muc#roominfo_occupants') {
                          roomInfo['users'] = val;
                        }
                        if (varName == 'muc#roominfo_description') {
                          roomInfo['description'] = val;
                        }
                        if (varName == 'muc#roominfo_subject') {
                          roomInfo['topic'] = val;
                        }
                      }
                    }
                  }

                  if (_roomInfoCompleters.containsKey(stanza.id)) {
                    _roomInfoCompleters[stanza.id]!.complete(roomInfo);
                    _roomInfoCompleters.remove(stanza.id);
                  }
                  if (_roomService.roomInfoCompleters.containsKey(stanza.id)) {
                    _roomService.roomInfoCompleters[stanza.id]!.complete(roomInfo);
                    _roomService.roomInfoCompleters.remove(stanza.id);
                  }
                }

                return;
              }

              final jingle = stanza.getChild('jingle');
              if ((jingle != null &&
                      jingle.getAttribute('xmlns')?.value ==
                          'urn:xmpp:jingle:1') ||
                  (stanza.id != null &&
                      (stanza.id!.startsWith('jingle') ||
                          stanza.id!.startsWith('cand_')))) {
                _jingleServices[id]?.handleIncomingIq(stanza);
                return;
              }

              final blocklist = stanza.getChild('blocklist');
              if (blocklist != null &&
                  blocklist.getAttribute('xmlns')?.value ==
                      'urn:xmpp:blocking') {
                _currentBlockedContacts.clear();
                for (var item in blocklist.children) {
                  if (item.name == 'item') {
                    final jid = item.getAttribute('jid')?.value;
                    if (jid != null) _currentBlockedContacts.add(jid);
                  }
                }
                _blockedContactsController.add(
                  List.from(_currentBlockedContacts),
                );
                debugPrint(
                  'SOCIAL: Updated blocklist for $id: $_currentBlockedContacts',
                );
                return;
              }

              // Parse PubSub Bookmarks (XEP-0048 / XEP-0402)
              final pubsub = stanza.getChild('pubsub');
              if (pubsub != null &&
                  pubsub.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/pubsub') {
                final items = pubsub.getChild('items');
                if (items != null) {
                  final node = items.getAttribute('node')?.value;
                  if (node == 'storage:bookmarks') {
                    for (var item in items.children) {
                      final storage = item.getChild('storage');
                      if (storage != null &&
                          storage.getAttribute('xmlns')?.value ==
                              'storage:bookmarks') {
                        for (var conf in storage.children) {
                          if (conf.name == 'conference') {
                            final jid = conf.getAttribute('jid')?.value;
                            final name = conf.getAttribute('name')?.value;
                            if (jid != null) {
                              final parts = jid.split('@');
                              if (parts.length == 2) {
                                // Join the room using the active account ID and the nickname from the JID (parts[0])
                                _roomService.setNickname(id, jid, parts[0]);
                                joinXmppRoom(jid, parts[0]);
                                debugPrint(
                                  'SYNC: Synced bookmark room $jid (Legacy)',
                                );
                              }
                            }
                          }
                        }
                      }
                    }
                  } else if (node == 'urn:xmpp:bookmarks:1') {
                    for (var item in items.children) {
                      final conf = item.getChild('conference');
                      if (conf != null &&
                          conf.getAttribute('xmlns')?.value ==
                              'urn:xmpp:bookmarks:1') {
                        final jid =
                            item.getAttribute('id')?.value ??
                            conf.getAttribute('jid')?.value;
                        final name = conf.getAttribute('name')?.value;
                        if (jid != null) {
                          final parts = jid.split('@');
                          if (parts.length == 2) {
                            _roomService.setNickname(id, jid, parts[0]);
                            joinXmppRoom(jid, parts[0]);
                            debugPrint(
                              'SYNC: Synced bookmark room $jid (Modern)',
                            );
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            if (stanza is xmpp.MessageStanza) {
              // Parse PubSub PEP Events (XEP-0163)
              final eventEl = stanza.getChild('event');
              if (eventEl != null &&
                  eventEl.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/pubsub#event') {
                final items = eventEl.getChild('items');
                if (items != null &&
                    items.getAttribute('node')?.value ==
                        'urn:xmpp:omemo:0:devices') {
                  final bareJid =
                      stanza.fromJid?.fullJid?.split('/').first.toLowerCase() ??
                      '';
                  if (bareJid.isNotEmpty) {
                    for (var item in items.children.where(
                      (c) => c.name == 'item',
                    )) {
                      final list = item.getChild('list');
                      if (list != null &&
                          list.getAttribute('xmlns')?.value ==
                              XmppOmemoService.nsOmemo) {
                        for (var device in list.children.where(
                          (c) => c.name == 'device',
                        )) {
                          final idStr = device.getAttribute('id')?.value;
                          if (idStr != null) {
                            final devId = int.tryParse(idStr);
                            if (devId != null) {
                              // Dynamically fetch bundle for new devices
                              _omemoService.buildSession(bareJid, devId).then((_) {
                                notifyListeners();
                              });
                            }
                          }
                        }
                        debugPrint(
                          'OMEMO: Received live device list update from $bareJid',
                        );
                      }
                    }
                  }
                }
              }

              // DISPATCH TO JINGLE (XEP-0353 Signaling)
              _jingleServices[id]?.handleIncomingMessage(stanza);

              // XEP-0184: Auto-respond to delivery requests
              final request = stanza.getChild('request');
              if (request != null &&
                  request.getAttribute('xmlns')?.value == 'urn:xmpp:receipts') {
                final receipt = xmpp.MessageStanza(
                  DateTime.now().millisecondsSinceEpoch.toString(),
                  stanza.type,
                );
                receipt.toJid = stanza.fromJid;
                final receivedEl = xmpp.XmppElement();
                receivedEl.name = 'received';
                receivedEl.addAttribute(
                  xmpp.XmppAttribute('xmlns', 'urn:xmpp:receipts'),
                );
                receivedEl.addAttribute(
                  xmpp.XmppAttribute('id', stanza.id ?? ''),
                );
                receipt.addChild(receivedEl);
                conn.writeStanza(receipt);
              }

              // Handle Chat States (Typing Notifications)
              final chatState = stanza.children.firstWhere(
                (c) =>
                    c.getAttribute('xmlns')?.value ==
                    'http://jabber.org/protocol/chatstates',
                orElse: () => xmpp.XmppElement(),
              );
              if (chatState.name != null) {
                _jingleEventController.add(
                  JingleEvent(
                    action: JingleAction.transportInfo, // reusing as signaling
                    sessionId: 'typing',
                    fromJid: stanza.fromJid?.fullJid ?? '',
                    reason: chatState.name,
                    accountId: id,
                  ),
                );
              }

              // Handle Delivery Receipts (XEP-0184)
              final received = stanza.getChild('received');
              if (received != null &&
                  received.getAttribute('xmlns')?.value ==
                      'urn:xmpp:receipts') {
                _jingleEventController.add(
                  JingleEvent(
                    action: JingleAction.transportInfo,
                    sessionId: 'receipt',
                    fromJid: stanza.fromJid?.fullJid ?? '',
                    reason: received.getAttribute('id')?.value,
                    accountId: id,
                  ),
                );
              }

              // Handle Chat Markers (XEP-0333)
              final displayed = stanza.getChild('displayed');
              if (displayed != null &&
                  displayed.getAttribute('xmlns')?.value ==
                      'urn:xmpp:chat-markers:0') {
                _jingleEventController.add(
                  JingleEvent(
                    action: JingleAction.transportInfo,
                    sessionId: 'marker',
                    fromJid: stanza.fromJid?.fullJid ?? '',
                    reason: displayed.getAttribute('id')?.value,
                    accountId: id,
                  ),
                );
              }

              // Handle Reactions (XEP-0444)
              final reactions = stanza.getChild('reactions');
              if (reactions != null &&
                  reactions.getAttribute('xmlns')?.value ==
                      'urn:xmpp:reactions:0') {
                final targetId = reactions.getAttribute('id')?.value;
                final emoji = reactions.getChild('reaction')?.textValue;
                if (targetId != null && emoji != null) {
                  _jingleEventController.add(
                    JingleEvent(
                      action: JingleAction.transportInfo,
                      sessionId: 'reaction',
                      fromJid: stanza.fromJid?.fullJid ?? '',
                      reason: targetId, // message ID
                      sdp: emoji, // emoji
                      accountId: id,
                    ),
                  );
                }
              }

              // GROUP INVITE DETECTION (Mediated and Direct)
              for (var child in stanza.children) {
                final ns = child.getAttribute('xmlns')?.value;

                // XEP-0249: Direct Invitations or Space Invites
                if (child.name == 'x' && ns == 'jabber:x:conference') {
                  final roomJid = child.getAttribute('jid')?.value;
                  if (roomJid != null) {
                    debugPrint('MUC: Received Direct Invite to $roomJid');
                    _roomService.emitGroupInvite({
                      'accountId': id,
                      'roomJid': roomJid,
                      'fromJid': stanza.fromJid?.fullJid ?? '',
                      'reason': child.getAttribute('reason')?.value,
                      'password': child.getAttribute('password')?.value,
                    });

                    // Generate system message so it appears in the chat UI
                    _messageStreamController.add(
                      ChatMessage(
                        id: 'invite_${DateTime.now().millisecondsSinceEpoch}',
                        text: 'INVITE: $roomJid',
                        timestamp: DateTime.now(),
                        isSent: false,
                        senderId: stanza.fromJid?.fullJid,
                        senderName: stanza.fromJid?.local,
                        type: MessageType.system,
                      ),
                    );
                  }
                }

                // XEP-0045: Mediated Invitations
                if (child.name == 'x' &&
                    ns == 'http://jabber.org/protocol/muc#user') {
                  final invite = child.getChild('invite');
                  if (invite != null) {
                    final fromJid =
                        invite.getAttribute('from')?.value ??
                        stanza.fromJid?.fullJid ??
                        '';
                    debugPrint('MUC: Received Mediated Invite from $fromJid');
                    _roomService.emitGroupInvite({
                      'accountId': id,
                      'roomJid': stanza.fromJid?.fullJid ?? '',
                      'fromJid': fromJid,
                      'reason': invite.getChild('reason')?.textValue,
                    });
                  }
                }
              }

              if (stanza.type == xmpp.MessageStanzaType.GROUPCHAT) {
                final body = stanza.getChild('body')?.textValue;
                final fromJid = stanza.fromJid?.fullJid ?? '';
                final roomJid = stanza.fromJid?.local != null
                    ? '${stanza.fromJid!.local}@${stanza.fromJid!.domain}'
                    : stanza.fromJid?.domain ?? '';
                final nick = stanza.fromJid?.resource ?? 'Unknown';

                // OMEMO Decryption Interceptor
                String? finalBody = body;
                final encrypted = stanza.getChild('encrypted');
                if (encrypted != null) {
                  final delay = stanza.getChild('delay');
                  final decrypted = await _omemoService.decryptMessage(
                    encrypted,
                    fromBareJid: roomJid.toLowerCase(),
                    isHistorical: delay != null,
                  );
                  if (decrypted != null) {
                    finalBody = decrypted;
                  } else {
                    finalBody =
                        '🔒 [Decryption Failed - Rebuilding Session...]';
                    // Auto-heal session
                    _omemoService.fetchDeviceList(roomJid.toLowerCase()).then((
                      devices,
                    ) {
                      for (var devId in devices) {
                        _omemoService.buildSession(roomJid.toLowerCase(), devId);
                      }
                    });
                  }
                }

                // Handle MUC Topic (Subject)
                final subject = stanza.getChild('subject')?.textValue;
                if (subject != null) {
                  _messageStreamController.add(
                    ChatMessage(
                      id: 'subject_${roomJid}_${DateTime.now().microsecondsSinceEpoch}',
                      text: 'Topic changed to: $subject',
                      timestamp: DateTime.now(),
                      isSent: false,
                      senderId: roomJid,
                      senderName: nick,
                      conversationId: roomJid.toLowerCase(),
                      accountId: id,
                      protocol: 'XMPP',
                      type: MessageType.system,
                      isGroup: true,
                    ),
                  );
                }

                // Identify if this message was sent by us (MUC Echo)
                bool isMe = false;
                final myNick = _roomService.getNickname(id, roomJid.toLowerCase());
                if (myNick != null) {
                  isMe = (nick == myNick);
                } else {
                  // Fallback to username/profile check if nickname not cached
                  final myBareJid =
                      _xmppJids[id]?.split('/').first.toLowerCase() ?? '';
                  final myUsername = myBareJid.split('@').first;
                  if (nick == myUsername ||
                      nick == _currentProfile?.displayName ||
                      nick == _currentProfile?.nickName) {
                    isMe = true;
                  }
                }

                // If it's a live echo of our own message, allow it to pass through.
                // ChatProvider will deduplicate it by ID and update the 'sending' status to 'sent'.
                final delay = stanza.getChild('delay');
                if (isMe && delay == null) {
                  // We used to return here, but that leaves the local message stuck in 'sending' state.
                }

                if (finalBody != null) {
                  _messageStreamController.add(
                    ChatMessage(
                      id:
                          stanza.id ??
                          'xmpp_${DateTime.now().microsecondsSinceEpoch}',
                      text: finalBody,
                      timestamp: DateTime.now(),
                      isSent: isMe,

                      senderId: fromJid,
                      senderName: nick,
                      accountId: id,
                      protocol: 'XMPP',
                      conversationId: roomJid.toLowerCase(),
                      type: MessageType.text,
                      isGroup: true,
                    ),
                  );
                }
              } else if (stanza.type == xmpp.MessageStanzaType.CHAT) {
                final body = stanza.body;
                final fromJid = stanza.fromJid?.fullJid ?? '';
                final bareJid = fromJid.split('/').first.toLowerCase();

                // OMEMO Decryption Interceptor
                String? finalBody = body;
                final encrypted = stanza.getChild('encrypted');
                if (encrypted != null) {
                  final delay = stanza.getChild('delay');
                  final decrypted = await _omemoService.decryptMessage(
                    encrypted,
                    fromBareJid: bareJid,
                    isHistorical: delay != null,
                  );
                  if (decrypted != null) {
                    finalBody = decrypted;
                  } else {
                    finalBody =
                        '🔒 [Decryption Failed - Rebuilding Session...]';
                    // Auto-heal session
                    refreshOmemoDevices(bareJid);
                  }
                }

                if (finalBody != null) {
                  final replacesId = stanza
                      .getChild('replace')
                      ?.getAttribute('id')
                      ?.value;
                  final isRetraction =
                      stanza.getChild('apply-to')?.getChild('retract') != null;

                  // OTR Decryption Interceptor
                  if (bareJid.isNotEmpty) {
                    finalBody = _otr.processIncomingMessage(bareJid, finalBody);
                  }

                  if (finalBody == null) {
                    return; // OTR interceptor consumed the message (e.g., key exchange)
                  }

                  _messageStreamController.add(
                    ChatMessage(
                      id:
                          stanza.id ??
                          'xmpp_${DateTime.now().microsecondsSinceEpoch}',
                      text: isRetraction ? '🚫 Message retracted' : finalBody,
                      timestamp: DateTime.now(),
                      isSent: false,
                      type: isRetraction
                          ? MessageType.system
                          : MessageType.text,
                      senderId: bareJid,
                      senderName: bareJid.split('@').first,
                      conversationId: bareJid,
                      accountId: id,
                      protocol: 'XMPP',
                      replacesId: replacesId,
                      encryptionType: encrypted != null ? 'omemo' : null,
                    ),
                  );
                }
              }

              // Handle MAM (XEP-0313) Results
              final mamResult = stanza.getChild('result');
              if (mamResult != null &&
                  (mamResult.name == 'result' ||
                      mamResult
                              .getAttribute('xmlns')
                              ?.value
                              ?.startsWith('urn:xmpp:mam:') ==
                          true)) {
                try {
                  final forwarded = mamResult.getChild('forwarded');
                  if (forwarded != null) {
                    final delay = forwarded.getChild('delay');
                    final innerMessage = forwarded.getChild('message');
                    if (innerMessage != null) {
                      String? body = innerMessage.getChild('body')?.textValue;
                      final fromJidStr = innerMessage
                          .getAttribute('from')
                          ?.value;

                      // OMEMO Decryption Interceptor for MAM
                      final encrypted = innerMessage.getChild('encrypted');
                      if (encrypted != null && fromJidStr != null) {
                        final bareJid = fromJidStr
                            .split('/')
                            .first
                            .toLowerCase();
                        final decrypted = await _omemoService.decryptMessage(
                          encrypted,
                          fromBareJid: bareJid,
                          isHistorical:
                              true, // MAM results are always historical
                        );
                        if (decrypted != null) {
                          body = decrypted;
                        } else {
                          body =
                              '🔒 [Decryption Failed - Rebuilding Session...]';
                          refreshOmemoDevices(bareJid);
                        }
                      }

                      if (body != null) {
                        final stamp = delay?.getAttribute('stamp')?.value;
                        final timestamp = stamp != null
                            ? DateTime.parse(stamp)
                            : DateTime.now();

                        // Identify if the archived message was sent by us
                        final myJid = _xmppJids[id];
                        final isSent =
                            fromJidStr != null &&
                            myJid != null &&
                            fromJidStr.toLowerCase().startsWith(
                              myJid.split('/').first.toLowerCase(),
                            );

                        // Critical for Mirroring: conversationId is ALWAYS the Buddy (the other party)
                        final String archiveSender =
                            stanza.fromJid?.fullJid ?? id;
                        final String buddyJid =
                            (isSent
                                    ? innerMessage.getAttribute('to')?.value ??
                                          archiveSender
                                    : fromJidStr ?? archiveSender)
                                .toString();

                        final reply = innerMessage.getChild('reply');
                        final replyToId =
                            reply?.getAttribute('xmlns')?.value ==
                                'urn:xmpp:reply:0'
                            ? reply?.getAttribute('id')?.value
                            : null;

                        _messageStreamController.add(
                          ChatMessage(
                            id:
                                innerMessage.getAttribute('id')?.value ??
                                mamResult.getAttribute('id')?.value ??
                                'xmpp_${DateTime.now().microsecondsSinceEpoch}',
                            text: body,
                            timestamp: timestamp,
                            isSent: isSent,
                            senderId: fromJidStr,
                            senderName: fromJidStr?.split('@').first,
                            accountId: id,
                            protocol: 'XMPP',
                            conversationId: buddyJid
                                .split('/')
                                .first
                                .toLowerCase(),
                            replyToId: replyToId,
                            isGroup:
                                buddyJid.contains('conference.') ||
                                buddyJid.startsWith('#'),
                          ),
                        );
                      }
                    }
                  }
                } catch (e) {
                  debugPrint('MAM PARSE ERROR: $e');
                }
              }

              // Handle Carbons (XEP-0280)
              final carbonSent = stanza.getChild('sent');
              final carbonReceived = stanza.getChild('received');
              final carbon = carbonSent ?? carbonReceived;
              if (carbon != null &&
                  carbon.getAttribute('xmlns')?.value == 'urn:xmpp:carbons:2') {
                try {
                  final forwarded = carbon.getChild('forwarded');
                  final innerMessage = forwarded?.getChild('message');
                  if (innerMessage != null) {
                    // XEP-0359: Check origin-id for deduplication
                    final originIdEl = innerMessage.getChild('origin-id');
                    final originId = originIdEl?.getAttribute('id')?.value;
                    if (originId != null && _sentOriginIds.containsKey(originId)) {
                      // This is a carbon echo of our own message — update status to sent
                      debugPrint('XMPP: Carbon echo for origin-id $originId, updating status');
                      _sentOriginIds.remove(originId);
                      // The message was already added to the stream when sent locally.
                      // ChatProvider will update its status via the stream.
                      return;
                    }

                    String? body = innerMessage.getChild('body')?.textValue;
                    final buddyJid = carbonSent != null
                        ? innerMessage.getAttribute('to')?.value
                        : innerMessage.getAttribute('from')?.value;

                    // OMEMO Decryption Interceptor for Carbons
                    final encrypted = innerMessage.getChild('encrypted');
                    if (encrypted != null && buddyJid != null) {
                      final bareJid = buddyJid.split('/').first.toLowerCase();
                      final delay = forwarded?.getChild('delay');
                      final decrypted = await _omemoService.decryptMessage(
                        encrypted,
                        fromBareJid: bareJid,
                        isHistorical: delay != null,
                      );
                      if (decrypted != null) {
                        body = decrypted;
                      } else {
                        body = '🔒 [Decryption Failed - Rebuilding Session...]';
                        refreshOmemoDevices(bareJid);
                      }
                    }

                    if (body != null) {
                      final delay = forwarded?.getChild('delay');
                      final stamp = delay?.getAttribute('stamp')?.value;
                      final timestamp = stamp != null
                          ? DateTime.parse(stamp)
                          : DateTime.now();

                      if (buddyJid != null) {
                        _messageStreamController.add(
                          ChatMessage(
                            id:
                                innerMessage.getAttribute('id')?.value ??
                                originId ??
                                'carbon_${timestamp.millisecondsSinceEpoch}',
                            text: body,
                            timestamp: timestamp,
                            isSent: carbonSent != null,
                            senderId:
                                innerMessage.getAttribute('from')?.value ??
                                innerMessage.getAttribute('to')?.value,
                            accountId: id,
                            protocol: 'XMPP',
                            conversationId: buddyJid
                                .split('/')
                                .first
                                .toLowerCase(),
                          ),
                        );
                      }
                    }
                  }
                } catch (e) {
                  debugPrint('CARBON PARSE ERROR: $e');
                }
                return; // Prevent duplicate processing
              }
            }
          });

          notifyListeners();
        } else if (state == xmpp.XmppConnectionState.AuthenticationFailure) {
          _xmppConnecting = false;
          _lastDiagnostic =
              'Authentication failed. Check your username and password.';
          ConnectionLifecycleService.instance.unregisterConnection(id);
          conn.dispose();
          _xmppProxies[id]?.stop();
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.completeError(Exception(_lastDiagnostic));
          }
        } else if (state ==
            xmpp.XmppConnectionState.AuthenticationNotSupported) {
          _xmppConnecting = false;
          _lastDiagnostic =
              'Server does not support any compatible authentication method.';
          ConnectionLifecycleService.instance.unregisterConnection(id);
          conn.dispose();
          _xmppProxies[id]?.stop();
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.completeError(Exception(_lastDiagnostic));
          }
        } else if (state == xmpp.XmppConnectionState.StartTlsFailed) {
          _xmppConnecting = false;
          _lastDiagnostic =
              'TLS handshake failed. The server may not support secure connections on this port.';
          ConnectionLifecycleService.instance.unregisterConnection(id);
          conn.dispose();
          _xmppProxies[id]?.stop();
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.completeError(Exception(_lastDiagnostic));
          }
        } else if (state == xmpp.XmppConnectionState.Closed ||
            state == xmpp.XmppConnectionState.ForcefullyClosed) {
          _xmppConnecting = false;
          xmpp.PingManager.removeInstance(conn);
          _presenceSubs[id]?.cancel();
          _presenceSubs.remove(id);
          _rosterSubs[id]?.cancel();
          _rosterSubs.remove(id);
          _xmppMessageSubs[id]?.cancel();
          _xmppMessageSubs.remove(id);
          _jingleEventSubs[id]?.cancel();
          _jingleEventSubs.remove(id);
          _xmppStanzaSubs[id]?.cancel();
          _xmppStanzaSubs.remove(id);
          if (!_authenticatedAccountIds.contains(id)) {
            _lastDiagnostic = state == xmpp.XmppConnectionState.ForcefullyClosed
                ? 'Connection was forcefully closed by the server.'
                : 'Connection closed before authentication completed.';
            ConnectionLifecycleService.instance.unregisterConnection(id);
            conn.dispose();
            _xmppProxies[id]?.stop();
            if (!connectionCompleter.isCompleted) {
              connectionCompleter.completeError(Exception(_lastDiagnostic));
            }
          }
        } else if (state == xmpp.XmppConnectionState.Resumed) {
          debugPrint('XMPP Account $id: Stream Management resumed — flushing pending messages');
          _flushPendingMessages(id);
        }
      }, onError: _handleXmppStreamError);

      conn.connect();
      await connectionCompleter.future;
    } catch (e) {
      debugPrint('XMPP Proxy Error: $e');
      rethrow;
    } finally {
      _xmppConnecting = false;
      notifyListeners();
    }
  }

  // Fetch Older History (XEP-0313 + XEP-0059)
  Future<void> fetchOlderHistory(
    String accountId,
    String buddyJid, {
    String? beforeId,
  }) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final mamManager = xmpp.MessageArchiveManager.getInstance(conn);
    // xmpp_stone's MessageArchiveManager usually handles RSM internally
    // when using queryById with beforeId/afterId.
    mamManager.queryById(
      jid: xmpp.Jid.fromFullJid(buddyJid),
      beforeId: beforeId,
    );
  }

  Future<void> sendXmppMessage(
    String targetJid,
    String text, {
    String? accountId,
    MessageType type = MessageType.text,
    String? filePath,
    String? fileName,
    String? replyToId,
    bool isGroup = false,
  }) =>
      _messageService.sendXmppMessage(
        targetJid, text,
        accountId: accountId, type: type, filePath: filePath,
        fileName: fileName, replyToId: replyToId, isGroup: isGroup,
      );

  Future<void> _flushPendingMessages(String accountId) =>
      _messageService.flushPendingMessages(accountId);

  Future<void> sendEditedMessage(
    String targetJid,
    String originalMsgId,
    String newText, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.sendEditedMessage(targetJid, originalMsgId, newText, accountId: accountId, isGroup: isGroup);

  // XEP-0333: Chat Markers
  void sendChatMarker(
    String targetJid,
    String msgId,
    String markerType, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.sendChatMarker(targetJid, msgId, markerType, accountId: accountId, isGroup: isGroup);

  Future<void> sendXmppReaction(
    String targetJid,
    String originalMsgId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.sendXmppReaction(targetJid, originalMsgId, emoji, accountId: accountId, isGroup: isGroup);

  void sendReaction(
    String chatId,
    String messageId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.sendReaction(chatId, messageId, emoji, accountId: accountId, isGroup: isGroup);

  // Unified Message Sender (Standalone)
  Future<void> sendMessage(
    String accountId,
    String toId,
    String text, {
    MessageType type = MessageType.text,
    String? fileName,
    String? filePath,
    String? replyToId,
    bool isGroup = false,
  }) =>
      _messageService.sendMessage(accountId, toId, text, type: type, fileName: fileName, filePath: filePath, replyToId: replyToId, isGroup: isGroup);

  // Retraction (XEP-0424)
  Future<void> retractXmppMessage(
    String targetJid,
    String messageId, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.retractXmppMessage(targetJid, messageId, accountId: accountId, isGroup: isGroup);

  Future<String?> _getMyAvatarHash(String accountId) async {
    final myJid = _xmppJids[accountId];
    if (myJid == null) return null;
    
    final bytes = await AvatarCacheService().getAvatar(myJid.split('/').first);
    if (bytes != null) {
      return sha1.convert(bytes).toString();
    }
    return null;
  }

  Future<void> updateMyStatus(ContactStatus status, {String? message}) async {
    _myStatus = status;
    _myStatusMessage = message;
    notifyListeners();

    // 1. Sync XMPP
    for (var entry in _xmppConnections.entries) {
      final accountId = entry.key;
      final conn = entry.value;
      if (conn.state == xmpp.XmppConnectionState.Ready ||
          conn.state == xmpp.XmppConnectionState.Resumed) {
        
        final hash = await _getMyAvatarHash(accountId);

        final presence = xmpp.PresenceStanza();
        presence.show = _mapShowToPresence(status);
        presence.status = message ?? '';
        
        // XEP-0153: vCard-Based Avatars
        final xUpdate = xmpp.XmppElement();
        xUpdate.name = 'x';
        xUpdate.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp:x:update'));
        final photo = xmpp.XmppElement();
        photo.name = 'photo';
        if (hash != null) {
          photo.textValue = hash;
        }
        xUpdate.addChild(photo);
        presence.addChild(xUpdate);

        conn.writeStanza(presence);
      }
    }
  }

  // Shared Account Persistence (Simplified for now)
  Future<void> saveAccount(SavedAccount account, String pass) async {
    final prefs = await SharedPreferences.getInstance();
    final index = _savedAccounts.indexWhere(
      (a) => a.fullJid == account.fullJid,
    );
    if (index != -1) {
      _savedAccounts[index] = account;
    } else {
      _savedAccounts.add(account);
    }

    final jsonList = _savedAccounts.map((a) => a.toJson()).toList();
    await prefs.setString('saved_accounts_json', json.encode(jsonList));
    await _secureStorage.write(key: 'pass_${account.fullJid}', value: pass);
    notifyListeners();
  }

  Future<void> updateSavedAccount(
    SavedAccount oldAcc,
    SavedAccount newAcc,
    String? newPass,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final index = _savedAccounts.indexWhere((a) => a.fullJid == oldAcc.fullJid);
    if (index != -1) {
      _savedAccounts[index] = newAcc;
    } else {
      _savedAccounts.add(newAcc);
    }

    // Manage passwords
    if (newPass != null && newPass.isNotEmpty) {
      await _secureStorage.write(key: 'pass_${newAcc.fullJid}', value: newPass);
    }
    // Clean up old pass if JID changed
    if (oldAcc.fullJid != newAcc.fullJid) {
      await _secureStorage.delete(key: 'pass_${oldAcc.fullJid}');
    }

    final jsonList = _savedAccounts.map((a) => a.toJson()).toList();
    await prefs.setString('saved_accounts_json', json.encode(jsonList));
    notifyListeners();
  }

  Future<void> deleteSavedAccount(SavedAccount acc) async {
    final prefs = await SharedPreferences.getInstance();
    _savedAccounts.removeWhere((a) => a.fullJid == acc.fullJid);
    await _secureStorage.delete(key: 'pass_${acc.fullJid}');

    final jsonList = _savedAccounts.map((a) => a.toJson()).toList();
    await prefs.setString('saved_accounts_json', json.encode(jsonList));

    // Disconnect if currently connected — clean up all subscriptions and resources
    if (acc.protocol == 'XMPP' && _xmppConnections.containsKey(acc.fullJid)) {
      final conn = _xmppConnections[acc.fullJid]!;
      xmpp.PingManager.removeInstance(conn);
      ConnectionLifecycleService.instance.unregisterConnection(acc.fullJid);
      _connectionStateSubs[acc.fullJid]?.cancel();
      _connectionStateSubs.remove(acc.fullJid);
      _presenceSubs[acc.fullJid]?.cancel();
      _presenceSubs.remove(acc.fullJid);
      _rosterSubs[acc.fullJid]?.cancel();
      _rosterSubs.remove(acc.fullJid);
      _xmppMessageSubs[acc.fullJid]?.cancel();
      _xmppMessageSubs.remove(acc.fullJid);
      _jingleEventSubs[acc.fullJid]?.cancel();
      _jingleEventSubs.remove(acc.fullJid);
      _xmppStanzaSubs[acc.fullJid]?.cancel();
      _xmppStanzaSubs.remove(acc.fullJid);
      _xmppProxies[acc.fullJid]?.stop();
      _xmppProxies.remove(acc.fullJid);
      conn.dispose();
      _xmppConnections.remove(acc.fullJid);
    }

    _authenticatedAccountIds.remove(acc.fullJid);
    notifyListeners();
  }

  Future<void> loadSavedAccounts() async {
    await _loadJoinedRooms();
    final prefs = await SharedPreferences.getInstance();

    // Load Profile
    final profileStr = prefs.getString('current_profile');
    if (profileStr != null) {
      _currentProfile = UserProfile.fromJson(json.decode(profileStr));
    }

    final jsonStr = prefs.getString('saved_accounts_json');
    if (jsonStr != null) {
      final List<dynamic> decoded = json.decode(jsonStr);
      _savedAccounts.clear();
      _savedAccounts.addAll(decoded.map((j) => SavedAccount.fromJson(j)));
      notifyListeners();
    }
  }

  Future<void> joinRoom(String accountId, String roomJid, String nickname) async =>
      _roomService.joinRoom(accountId, roomJid, nickname);

  Future<void> inviteToRoom(String accountId, String roomJid, String userJid, {String? reason}) async =>
      _roomService.inviteToRoom(accountId, roomJid, userJid, reason: reason);

  Future<void> inviteToRoomDirect(String accountId, String roomJid, String userJid, {String? reason, String? password}) async =>
      _roomService.inviteToRoomDirect(accountId, roomJid, userJid, reason: reason, password: password);

  Future<void> createRoom(String accountId, String roomJid, String nickname) async =>
      _roomService.createRoom(accountId, roomJid, nickname);

  Future<void> leaveRoom(String accountId, String roomJid) async =>
      _roomService.leaveRoom(accountId, roomJid);

  Future<String?> joinGenericRoom(String destination, {String? accountId}) async =>
      _roomService.joinGenericRoom(destination, accountId: accountId);

  void sendChatState(
    String targetJid,
    String state, {
    String? accountId,
    bool isGroup = false,
  }) =>
      _messageService.sendChatState(targetJid, state, accountId: accountId, isGroup: isGroup);

  Future<void> forwardMessage(
    ChatMessage original,
    List<String> targetChatIds, {
    String? accountId,
    String? targetProtocol,
  }) =>
      _messageService.forwardMessage(original, targetChatIds, accountId: accountId, targetProtocol: targetProtocol);

  Future<List<Map<String, String>>> discoverMucRooms(String accountId, String serviceJid) async =>
      _roomService.discoverMucRooms(accountId, serviceJid);

  Future<Map<String, dynamic>> getMucRoomInfo(String accountId, String roomJid) async =>
      _roomService.getMucRoomInfo(accountId, roomJid);

  Future<void> requestRoomConfig(String accountId, String roomJid) async =>
      _roomService.requestRoomConfig(accountId, roomJid);

  Future<void> submitRoomConfig(String accountId, String roomJid, Map<String, String> fields) async =>
      _roomService.submitRoomConfig(accountId, roomJid, fields);

  Future<Map<String, dynamic>?> fetchRoomConfig(String accountId, String roomJid) async =>
      _roomService.fetchRoomConfig(accountId, roomJid);

  Future<List<Map<String, String>>> fetchRoomAffiliations(String accountId, String roomJid, String affiliation) async =>
      _roomService.fetchRoomAffiliations(accountId, roomJid, affiliation);

  Future<void> setMucRole(String accountId, String roomJid, String nick, String role, {String? reason}) async =>
      _roomService.setMucRole(accountId, roomJid, nick, role, reason: reason);

  Future<void> setMucAffiliation(String accountId, String roomJid, String userJid, String affiliation, {String? reason}) async =>
      _roomService.setMucAffiliation(accountId, roomJid, userJid, affiliation, reason: reason);

  Future<void> sendXmppSubject(String roomJid, String subject, {String? accountId}) async =>
      _roomService.sendXmppSubject(roomJid, subject, accountId: accountId);

  Future<void> kickUser(String accountId, String roomJid, String nick, {String? reason}) async =>
      _roomService.kickUser(accountId, roomJid, nick, reason: reason);

  Future<void> banUser(String accountId, String roomJid, String userJid, {String? reason}) async =>
      _roomService.banUser(accountId, roomJid, userJid, reason: reason);

  List<Map<String, dynamic>> getAuthenticatedAccounts() {
    return _authenticatedAccountIds
        .map((id) => {'id': id, 'protocol': 'XMPP'})
        .toList();
  }

  String getContactName(String accountId, String jid) {
    final contact = _currentContacts.where((c) => c.id == jid).firstOrNull;
    if (contact != null) return contact.name;

    // Cheogram phone number normalization for display
    if (jid.contains('@cheogram.com')) {
      return jid.split('@').first;
    }

    return jid;
  }

  Future<void> _saveJoinedRooms() async => await _roomService.saveJoinedRooms();
  void _publishBookmarks() => _roomService.publishBookmarks();
  Future<void> _loadJoinedRooms() async {
    await _roomService.loadJoinedRooms();

    // Migrate old spaces from SharedPreferences to SQLite if needed
    final prefs = await SharedPreferences.getInstance();
    final spacesList = prefs.getStringList('joined_spaces');
    final db = DatabaseService();
    if (spacesList != null && spacesList.isNotEmpty) {
      for (final s in spacesList) {
        final parts = s.split('|');
        if (parts.length >= 3) {
          final space = SpaceNode(domain: parts[0], node: parts[1], name: parts[2]);
          await db.upsertSpace(space, isJoined: true);
        }
      }
      await prefs.remove('joined_spaces');
    }

    final loaded = await db.getJoinedSpaces();
    _cachedJoinedSpaces
      ..clear()
      ..addAll(loaded);
    _emitJoinedSpaces();
  }
  Future<void> _autoJoinRooms(String accountId) async => await _roomService.autoJoinRooms(accountId);

  Future<String?> createXmppRoom(String roomJid, String nick, {String? accountId}) async =>
      _roomService.createXmppRoom(roomJid, nick, accountId: accountId);

  Future<void> configureXmppRoom(
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
  }) async =>
      _roomService.configureXmppRoom(
        roomJid,
        accountId: accountId,
        name: name,
        description: description,
        isPublic: isPublic,
        isPersistent: isPersistent,
        isMembersOnly: isMembersOnly,
        allowMemberInvites: allowMemberInvites,
        changeSubject: changeSubject,
        historyLength: historyLength,
      );

  Future<String?> joinXmppRoom(String roomJid, String nick, {String? accountId, String? password}) async =>
      _roomService.joinXmppRoom(roomJid, nick, accountId: accountId, password: password);

  Future<void> logout() async {
    for (var entry in _xmppConnections.entries) {
      xmpp.PingManager.removeInstance(entry.value);
      ConnectionLifecycleService.instance.unregisterConnection(entry.key);
      _connectionStateSubs[entry.key]?.cancel();
      _connectionStateSubs.remove(entry.key);
      _presenceSubs[entry.key]?.cancel();
      _presenceSubs.remove(entry.key);
      _rosterSubs[entry.key]?.cancel();
      _rosterSubs.remove(entry.key);
      _xmppMessageSubs[entry.key]?.cancel();
      _xmppMessageSubs.remove(entry.key);
      _jingleEventSubs[entry.key]?.cancel();
      _jingleEventSubs.remove(entry.key);
      _xmppStanzaSubs[entry.key]?.cancel();
      _xmppStanzaSubs.remove(entry.key);
      entry.value.dispose();
    }
    _xmppConnections.clear();

    for (var proxy in _xmppProxies.values) {
      proxy.stop();
    }
    _xmppProxies.clear();

    _activeAccountId = null;
    _authenticatedAccountIds.clear();
    _currentContacts.clear();
    _contactStreamController.add([]);

    notifyListeners();
  }

  // Mappings
  xmpp.PresenceShowElement _mapShowToPresence(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return xmpp.PresenceShowElement.CHAT;
      case ContactStatus.away:
        return xmpp.PresenceShowElement.AWAY;
      case ContactStatus.dnd:
        return xmpp.PresenceShowElement.DND;
      default:
        return xmpp.PresenceShowElement.CHAT;
    }
  }

  ContactStatus _mapPresenceToShow(xmpp.PresenceShowElement? show) {
    if (show == null || show == xmpp.PresenceShowElement.CHAT) {
      return ContactStatus.online;
    } else if (show == xmpp.PresenceShowElement.AWAY) {
      return ContactStatus.away;
    } else if (show == xmpp.PresenceShowElement.XA) {
      return ContactStatus.xa; // Correctly distinguish Extended Away
    } else if (show == xmpp.PresenceShowElement.DND) {
      return ContactStatus.dnd;
    } else {
      return ContactStatus.offline;
    }
  }

  void _handleXmppStreamError(dynamic e) {
    debugPrint('XMPP Stream Error: $e');
    _xmppConnecting = false;
    _lastDiagnostic = 'XMPP stream error: $e';
    notifyListeners();
  }

  // Legacy compatibility for single-account UI parts
  Future<bool> autoLogin() => _contactService.autoLogin();

  Future<String> testSocketConnection(String host, int port) =>
      _contactService.testSocketConnection(host, port);

  void _enableCarbons(String accountId) {
    final conn = _xmppConnections[accountId];
    if (conn == null || _carbonsEnabled[accountId] == true) return;

    _carbonsEnabled[accountId] = true;
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

  Future<void> fetchXmppHistory(String jid, {String? accountId, DateTime? since}) =>
      _contactService.fetchXmppHistory(jid, accountId: accountId, since: since);

  void _syncAllXmppData(String accountId, xmpp.Connection conn) {
    debugPrint('SYNC: Triggering full account sync for $accountId');

    // 1. Sync User Avatar/vCard
    fetchMyVCard(accountId: accountId);

    // 2. Global MAM Catchup (Offline Messages) — limited to last 50
    try {
      final iqId = 'mam_sync_${DateTime.now().millisecondsSinceEpoch}';
      final iq = xmpp.IqStanza(
        iqId,
        xmpp.IqStanzaType.SET,
      );
      final query = xmpp.XmppElement();
      query.name = 'query';
      query.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      // RSM: Request only the last 50 messages for initial sync
      final setEl = xmpp.XmppElement();
      setEl.name = 'set';
      setEl.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'));
      final maxEl = xmpp.XmppElement();
      maxEl.name = 'max';
      maxEl.textValue = '50';
      setEl.addChild(maxEl);
      // Request from the end (most recent first)
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

    // 3. Sync Bookmarks (PubSub MUCs)
    try {
      // Legacy storage:bookmarks
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

      // Modern urn:xmpp:bookmarks:1
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

  void logCallEvent(String targetId, String text, bool isSent, {String? filePath, MessageType type = MessageType.call}) =>
      _contactService.logCallEvent(targetId, text, isSent, filePath: filePath, type: type);

  Future<List<Map<String, dynamic>>> fetchIceServers(String accountId) =>
      _contactService.fetchIceServers(accountId);

  // --- ROSTER & CONTACT MANAGEMENT (XEP-0164, XEP-0191) ---

  // XEP-0030: Service Discovery (XEP-0030)
  Future<void> _discoverServiceFeatures(String accountId, String domain) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    debugPrint('DISCO: Starting discovery for $domain');

    // 1. Discover Server Features (MAM, Carbons, etc.)
    final infoId = 'disco_info_server_${DateTime.now().millisecondsSinceEpoch}';
    final infoIq = xmpp.IqStanza(infoId, xmpp.IqStanzaType.GET);
    infoIq.toJid = xmpp.Jid.fromFullJid(domain);
    final infoQuery = xmpp.XmppElement();
    infoQuery.name = 'query';
    infoQuery.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'),
    );
    infoIq.addChild(infoQuery);

    // 2. Discover Server Items (Sub-services like HTTP Upload)
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

  // --- Space Management (Bookmarks / Persistence) ---

  List<SpaceNode> get joinedSpaces => _cachedJoinedSpaces;

  void _emitJoinedSpaces() {
    _joinedSpacesStreamController.add(joinedSpaces);
  }

  Future<void> joinPersistedSpace(
    String domain,
    String node,
    String name,
  ) async {
    final index = _cachedJoinedSpaces.indexWhere((s) => s.domain == domain && s.node == node);
    if (index == -1) {
      final space = SpaceNode(domain: domain, node: node, name: name, isSubscribed: true);
      _cachedJoinedSpaces.add(space);
      await DatabaseService().upsertSpace(space, isJoined: true);
      _emitJoinedSpaces();
      notifyListeners();
    }
  }

  Future<void> leavePersistedSpace(String domain, String node) async {
    _cachedJoinedSpaces.removeWhere((s) => s.domain == domain && s.node == node);
    await DatabaseService().deleteSpace(domain, node);
    _emitJoinedSpaces();
    notifyListeners();
  }

  Future<void> updatePersistedSpace(SpaceNode space) async {
    final index = _cachedJoinedSpaces.indexWhere((s) => s.domain == space.domain && s.node == space.node);
    if (index != -1) {
      _cachedJoinedSpaces[index] = space;
      await DatabaseService().upsertSpace(space, isJoined: true);
      _emitJoinedSpaces();
      notifyListeners();
    }
  }

  // --- Profile Management ---

  Future<void> createProfile(String name, {String? bio}) =>
      _contactService.createProfile(name, bio: bio);

  // --- Backup / Restore ---

  Future<Map<String, String>> exportAccountSecrets() => _contactService.exportAccountSecrets();
  Future<void> importAccountSecrets(Map<String, String> secrets) => _contactService.importAccountSecrets(secrets);
  Future<void> importSavedAccounts(List<SavedAccount> accounts) => _contactService.importSavedAccounts(accounts);
  List<Map<String, dynamic>> exportContacts() => _contactService.exportContacts();
  Future<void> importContacts(List<dynamic> contactsJson) => _contactService.importContacts(contactsJson);
  Future<Map<String, dynamic>> exportSettings() => _contactService.exportSettings();
  Future<void> importSettings(Map<String, dynamic> settings) => _contactService.importSettings(settings);

  Future<void> fetchContactVCard(String jid, {String? accountId}) =>
      _contactService.fetchContactVCard(jid, accountId: accountId);

  void _fetchAllVCards(String accountId) {
    // Collect unique JIDs from the current contacts for this account
    final jids = _currentContacts
        .where((c) => c.protocol == 'XMPP')
        .map((c) => c.id.split('/').first) // Fetch only for base JID
        .toSet();

    for (var jid in jids) {
      // Small randomized delay to avoid server-side rate-limiting during bulk fetch
      Future.delayed(
        Duration(milliseconds: 100 + (jids.toList().indexOf(jid) * 50)),
        () {
          fetchContactVCard(jid, accountId: accountId);
        },
      );
    }
  }

  // --- SOCIAL INTELLIGENCE: CONTACT MANAGEMENT ---

  final StreamController<List<String>> _blockedContactsController =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get blockedContacts => _blockedContactsController.stream;
  StreamController<List<String>> get blockedContactsController => _blockedContactsController;
  final List<String> _currentBlockedContacts = [];
  List<String> get currentBlockedContacts => _currentBlockedContacts;

  /// Fetches the list of blocked contacts (XEP-0191)
  Future<void> fetchBlockedContacts({String? accountId}) =>
      _contactService.fetchBlockedContacts(accountId: accountId);

  /// Updates our own presence status (XEP-0030/RFC 6121)
  Future<void> updatePresence(ContactStatus status, {String? message, String? accountId}) =>
      _contactService.updatePresence(status, message: message, accountId: accountId);

  /// Accepts an incoming friend request (XEP-0163)
  void acceptSubscription(String jid, {String? accountId}) =>
      _contactService.acceptSubscription(jid, accountId: accountId);

  /// Declines or cancels a friend request
  void declineSubscription(String jid, {String? accountId}) =>
      _contactService.declineSubscription(jid, accountId: accountId);

  /// Blocks a contact using XEP-0191 (Blocking Command)
  Future<void> blockContact(String jid, {String? accountId}) =>
      _contactService.blockContact(jid, accountId: accountId);

  /// Unblocks a contact using XEP-0191
  Future<void> unblockContact(String jid, {String? accountId}) =>
      _contactService.unblockContact(jid, accountId: accountId);

  /// Renames a contact in the roster (Roster Push)
  Future<void> renameContact(String jid, String newName, {String? accountId}) =>
      _contactService.renameContact(jid, newName, accountId: accountId);

  /// Completely removes a contact from the roster
  Future<void> removeContact(String jid, {String? accountId}) =>
      _contactService.removeContact(jid, accountId: accountId);

  /// Sends a friend request (XEP-0163)
  void addContact(String jid, {String? nickname, String? group, String? accountId}) =>
      _contactService.addContact(jid, nickname: nickname, group: group, accountId: accountId);

  Future<List<String>> getBlockList({String? accountId}) =>
      _contactService.getBlockList(accountId: accountId);

  Future<void> clearAllData() => _contactService.clearAllData();
}

class _AuthContactDeps implements AuthServiceContactDeps {
  final AuthService _auth;
  _AuthContactDeps(this._auth);

  Map<String, xmpp.Connection> get xmppConnections => _auth._xmppConnections;
  Map<String, String> get xmppJids => _auth._xmppJids;
  String? get activeAccountId => _auth.activeAccountId;
  List<Contact> get currentContacts => _auth._currentContacts;
  Map<String, StreamSubscription> get presenceSubs => _auth._presenceSubs;
  Map<String, StreamSubscription> get rosterSubs => _auth._rosterSubs;
  StreamController<List<Contact>> get contactStreamController => _auth._contactStreamController;
  Map<String, StreamSubscription> get xmppMessageSubs => _auth._xmppMessageSubs;
  Map<String, StreamSubscription> get jingleEventSubs => _auth._jingleEventSubs;
  Map<String, StreamSubscription> get xmppStanzaSubs => _auth._xmppStanzaSubs;
  List<SavedAccount> get savedAccounts => _auth._savedAccounts;
  XmppOmemoService get omemoService => _auth.omemoService;
  XmppRoomService get roomService => _auth.roomService;
  SecureStorageService get secureStorage => _auth.secureStorage;
  List<Map<String, String>> get pendingSubscriptionRequests => _auth._pendingSubscriptionRequests;
  StreamController<List<Map<String, String>>> get subscriptionRequestController => _auth._subscriptionRequestController;
  StreamController<ChatMessage> get messageStreamController => _auth._messageStreamController;
  StreamController<List<SpaceNode>> get joinedSpacesStreamController => _auth._joinedSpacesStreamController;
  List<SpaceNode> get cachedJoinedSpaces => _auth._cachedJoinedSpaces;
  Map<String, bool> get carbonsEnabled => _auth.carbonsEnabled;
  Map<String, List<Map<String, dynamic>>> get accountIceServers => _auth.accountIceServers;
  Set<String> get pendingVCardFetches => _auth.pendingVCardFetches;
  Map<String, DateTime> get vCardLastFetch => _auth.vCardLastFetch;
  Set<String> get vCardUnsupportedJids => _auth.vCardUnsupportedJids;
  Map<String, String> get contactAvatarHashes => _auth.contactAvatarHashes;
  StreamController<List<String>> get blockedContactsController => _auth._blockedContactsController;
  List<String> get currentBlockedContacts => _auth._currentBlockedContacts;
  bool get xmppConnecting => _auth.xmppConnecting;
  String? get lastDiagnostic => _auth.lastDiagnostic;
  ContactStatus get myStatus => _auth.myStatus;
  String? get myStatusMessage => _auth.myStatusMessage;
  UserProfile? get currentProfile => _auth.currentProfile;
  set myStatus(ContactStatus value) => _auth._myStatus = value;
  set myStatusMessage(String? value) => _auth._myStatusMessage = value;
  set xmppConnecting(bool value) => _auth._xmppConnecting = value;
  set lastDiagnostic(String? value) => _auth._lastDiagnostic = value;
  set currentProfile(UserProfile? value) => _auth._currentProfile = value;
  void notifyListeners() => _auth.notifyListeners();
  Future<void> loadSavedAccounts() => _auth.loadSavedAccounts();
  Future<void> setPresence(ContactStatus status, String? message) => _auth.setPresence(status, message);
  Future<void> fetchMyVCard({String? accountId}) => _auth.fetchMyVCard(accountId: accountId);
  Future<void> fetchContactVCard(String jid, {String? accountId}) => _auth.fetchContactVCard(jid, accountId: accountId);
  Future<void> sendMessage(String accountId, String toJid, String text, {String? fileName, String? filePath, bool isGroup = false, String? replyToId, MessageType type = MessageType.text}) =>
      _auth.sendMessage(accountId, toJid, text, fileName: fileName, filePath: filePath, isGroup: isGroup, replyToId: replyToId, type: type);
  Future<void> connectXmpp({required String user, required String domain, required String pass, required int port, String? host, String? accountId, SavedAccount? configData}) =>
      _auth.connectXmpp(user: user, domain: domain, pass: pass, port: port, host: host, accountId: accountId, configData: configData);
  Future<void> logout() => _auth.logout();
}

class _AuthMessageDeps implements AuthServiceMessageDeps {
  final AuthService _auth;
  _AuthMessageDeps(this._auth);

  Map<String, xmpp.Connection> get xmppConnections => _auth._xmppConnections;
  String? get activeAccountId => _auth.activeAccountId;
  Map<String, String> get xmppJids => _auth._xmppJids;
  XmppOmemoService get omemoService => _auth.omemoService;
  OtrService get otrService => _auth._otr;
  OfflineQueueService get offlineQueue => _auth._offlineQueue;
  StreamController<ChatMessage> get messageStreamController => _auth._messageStreamController;
  StreamController<JingleEvent> get jingleEventController => _auth._jingleEventController;
  Map<String, String> get sentOriginIds => _auth._sentOriginIds;
}
