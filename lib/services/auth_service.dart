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
import './omemo_service_stub.dart' if (dart.library.io) './omemo_service.dart';
import './secure_storage_service.dart';
import './omemo_storage_stub.dart' if (dart.library.io) './omemo_storage.dart';
import './otr_service.dart';
import './spaces_service.dart';
import '../models/space_models.dart';
import './database_service.dart';

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

  final List<Room> _joinedRooms = [];
  List<Room> get joinedRooms => List.unmodifiable(_joinedRooms);

  final StreamController<List<Room>> _joinedRoomsStreamController =
      StreamController<List<Room>>.broadcast();
  Stream<List<Room>> get joinedRoomsStream =>
      _joinedRoomsStreamController.stream;

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
  Set<String> _persistedRooms = {};
  final Map<String, String> _roomNicknames = {}; // accountId|roomJid -> nick
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

  // XEP-0153: Track avatar hashes to avoid redundant fetches and trigger updates
  final Map<String, String> _contactAvatarHashes = {};

  final Map<String, StreamSubscription> _xmppStatusSubs = {};
  final Map<String, JingleSignalingService> _jingleServices = {};
  final Map<String, HttpUploadService> _uploadServices = {};
  final Map<String, bool> _carbonsEnabled = {};
  final Map<String, SpacesService> _spacesServices = {};
  final Map<String, List<Map<String, dynamic>>> _accountIceServers = {};
  // Track participants in MUCs
  final Map<String, Set<RoomParticipant>> _roomParticipants = {};
  final _roomParticipantStreamController =
      StreamController<Map<String, List<RoomParticipant>>>.broadcast();
  Stream<Map<String, List<RoomParticipant>>> get roomParticipantsStream =>
      _roomParticipantStreamController.stream;

  final StreamController<Map<String, dynamic>> _groupInviteStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get groupInviteStream =>
      _groupInviteStreamController.stream;

  final Map<String, Set<String>> _serverFeatures = {};

  String _emojiToText(dynamic emoji) {
    final name = emoji?.name?.toString();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return emoji?.toString() ?? '';
  }

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
    _otr.injectMessage = (bareJid, text) {
      sendMessage(_activeAccountId ?? '', bareJid, text, isGroup: false);
    };
  }

  String? _activeAccountId;
  String? get activeAccountId => _activeAccountId;

  Future<String?> getActiveAccountPassword() async {
    if (_activeAccountId == null) return null;
    return await _secureStorage.read(key: 'pass_$_activeAccountId');
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

  final OmemoService _omemo = OmemoService();
  final Map<String, bool> _omemoEnabled = {};
  bool _isStrictVerificationEnabled = false;

  bool isOmemoEnabled(String chatId) {
    return _omemoEnabled[chatId.toLowerCase()] ?? false;
  }

  bool get isStrictVerificationEnabled => _isStrictVerificationEnabled;

  Future<void> setStrictVerification(bool enabled) async {
    _isStrictVerificationEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('omemo_strict_verification', enabled);
    notifyListeners();
  }

  Future<bool> hasUnverifiedDevices(String jid) async {
    if (kIsWeb) return false;
    final store = SQLiteSignalStore();
    final identities = await store.getIdentitiesForJid(
      jid.split('/').first.toLowerCase(),
    );
    return identities.any((iden) => (iden['trust_level'] as int? ?? 0) == 0);
  }

  Future<int> getChatSecurityStatus(String chatId) async {
    if (!isOmemoEnabled(chatId)) return -1; // Not encrypted

    final fingerprints = await _omemo.getFingerprintsDetailed(chatId);
    if (fingerprints.isEmpty) return -1;

    bool hasDistrusted = false;
    bool hasUnverified = false;

    for (var device in fingerprints.values) {
      final level = device['trustLevel'] as int;
      if (level == 2) hasDistrusted = true;
      if (level == 0) hasUnverified = true;
    }

    if (hasDistrusted) return 2; // Red (Distrusted)
    if (hasUnverified) return 0; // Yellow (Unverified)
    return 1; // Green (Trusted)
  }

  Future<void> updateOmemoTrust(
    String jid,
    int deviceId,
    int trustLevel,
  ) async {
    await _omemo.setDeviceTrust(jid, deviceId, trustLevel);
    notifyListeners();
  }

  void toggleOmemo(String chatId) {
    final id = chatId.toLowerCase();
    _omemoEnabled[id] = !(_omemoEnabled[id] ?? false);
    notifyListeners();
  }

  bool isOmemoSupportedByServer(String accountId) {
    return _serverFeatures[accountId]?.contains(OmemoService.nsOmemo) ?? false;
  }

  Future<Map<int, Map<String, dynamic>>> getOmemoFingerprintsDetailed(
    String chatId,
  ) {
    return _omemo.getFingerprintsDetailed(chatId);
  }

  Future<void> refreshOmemoDevices(String chatId, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    if (id != null && _xmppConnections.containsKey(id)) {
      _omemo.setConnection(_xmppConnections[id]!);
    }

    final devices = await _omemo.fetchDeviceList(chatId);
    for (var devId in devices) {
      await _omemo.buildSession(chatId, devId);
    }
  }

  Future<String> getMyOmemoFingerprint() async {
    return await _omemo.getLocalFingerprint();
  }

  Future<List<Map<String, dynamic>>> fetchOmemoIdentities() async {
    if (kIsWeb) return [];
    final store = SQLiteSignalStore();
    final List<Map<String, dynamic>> identities = List.from(
      await store.getAllIdentities(),
    );

    try {
      final myIdentity = await store.getIdentityKeyPair();
      final myJid = _activeAccountId != null
          ? _xmppJids[_activeAccountId]?.split('/').first.toLowerCase()
          : 'My Account';
      identities.insert(0, {
        'address_name': myJid ?? 'My Account',
        'device_id': _omemo.localDeviceId,
        'identity_key_data': myIdentity.getPublicKey().serialize(),
        'trust_level': 1,
      });
    } catch (e) {
      debugPrint('Error loading own identity: $e');
    }

    return identities;
  }

  int getLocalOmemoDeviceId() => _omemo.localDeviceId;

  Future<void> resetOmemoKeys(String accountId) async {
    final bareJid = _xmppJids[accountId]?.split('/').first.toLowerCase();
    if (bareJid != null) {
      await _omemo.resetIdentity(bareJid);
    }
    notifyListeners();
  }

  final _secureStorage = SecureStorageService.instance;

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
        // Web: connect directly via WebSocket, no proxy
        final wsHost = host ?? domain;
        final wsPort = port;
        final wsPath = configData?.wsPath ?? '/xmpp-websocket';
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
      } else {
        // Native: connect via local TCP/TLS proxy
        _xmppProxies[id]?.stop();
        final proxy = XmppProxyService();
        _xmppProxies[id] = proxy;

        final proxyTargetHost = host ?? domain;
        final proxyTargetPort =
            (domain == 'jabb3r.org' || domain == 'jabb3r.info') ? 5222 : port;

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

      // FORCE disable Stream Management to prevent xmpp_stone <r/> loop bug
      accountSettings.ackEnabled = false;
      accountSettings.smResumable = false;

      if (configData != null) {
        if (configData.reconnectionTimeout != null) {
          accountSettings.reconnectionTimeout = configData.reconnectionTimeout!;
        }
      }

      final conn = xmpp.Connection(accountSettings);
      final bareJid = fullJidStr.split('/').first.toLowerCase();
      _omemo.setConnection(conn);
      await _omemo.initialize(bareJid);

      _xmppConnections[id] = conn;
      _xmppJids[id] = jid.fullJid ?? fullJidStr; // Store JID

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

          // OMEMO: Publish keys now that we're connected & authenticated (XEP-0384)
          final bareJid = fullJidStr.split('/').first.toLowerCase();
          _omemo.ensureNodeAccessModels(conn);
          _omemo.publishDeviceList(conn, bareJid);
          _omemo.publishBundle(conn);
          _omemo.checkAndReplenishPreKeys();

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
                  _roomParticipants[roomJid] ??= {};
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
                    _roomParticipants[roomJid]!.remove(participant);
                  } else {
                    _roomParticipants[roomJid]!.remove(participant);
                    _roomParticipants[roomJid]!.add(participant);
                  }

                  final cloned = <String, List<RoomParticipant>>{};
                  for (final e in _roomParticipants.entries) {
                    cloned[e.key] = e.value.toList();
                  }

                  _roomParticipantStreamController.add(cloned);
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

              if (stanza.id != null && _pendingIqs.containsKey(stanza.id)) {
                _pendingIqs[stanza.id!]!.complete(stanza);
                _pendingIqs.remove(stanza.id);
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
                    _roomInfoCompleters.containsKey(stanza.id)) {
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

                  _roomInfoCompleters[stanza.id]!.complete(roomInfo);
                  _roomInfoCompleters.remove(stanza.id);
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
                                _roomNicknames['$id|${jid.toLowerCase()}'] =
                                    parts[0];
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
                            _roomNicknames['$id|${jid.toLowerCase()}'] =
                                parts[0];
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
                              OmemoService.nsOmemo) {
                        for (var device in list.children.where(
                          (c) => c.name == 'device',
                        )) {
                          final idStr = device.getAttribute('id')?.value;
                          if (idStr != null) {
                            final devId = int.tryParse(idStr);
                            if (devId != null) {
                              // Dynamically fetch bundle for new devices
                              _omemo.buildSession(bareJid, devId).then((_) {
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
                    _groupInviteStreamController.add({
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
                    _groupInviteStreamController.add({
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
                  final decrypted = await _omemo.decryptMessage(
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
                    _omemo.fetchDeviceList(roomJid.toLowerCase()).then((
                      devices,
                    ) {
                      for (var devId in devices) {
                        _omemo.buildSession(roomJid.toLowerCase(), devId);
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
                final myNick = _roomNicknames['$id|${roomJid.toLowerCase()}'];
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
                  final decrypted = await _omemo.decryptMessage(
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
                        final decrypted = await _omemo.decryptMessage(
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
                    String? body = innerMessage.getChild('body')?.textValue;
                    final buddyJid = carbonSent != null
                        ? innerMessage.getAttribute('to')?.value
                        : innerMessage.getAttribute('from')?.value;

                    // OMEMO Decryption Interceptor for Carbons
                    final encrypted = innerMessage.getChild('encrypted');
                    if (encrypted != null && buddyJid != null) {
                      final bareJid = buddyJid.split('/').first.toLowerCase();
                      final delay = forwarded?.getChild('delay');
                      final decrypted = await _omemo.decryptMessage(
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
          conn.dispose();
          _xmppProxies[id]?.stop();
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.completeError(Exception(_lastDiagnostic));
          }
        } else if (state == xmpp.XmppConnectionState.StartTlsFailed) {
          _xmppConnecting = false;
          _lastDiagnostic =
              'TLS handshake failed. The server may not support secure connections on this port.';
          conn.dispose();
          _xmppProxies[id]?.stop();
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.completeError(Exception(_lastDiagnostic));
          }
        } else if (state == xmpp.XmppConnectionState.Closed ||
            state == xmpp.XmppConnectionState.ForcefullyClosed) {
          _xmppConnecting = false;
          if (!_authenticatedAccountIds.contains(id)) {
            _lastDiagnostic = state == xmpp.XmppConnectionState.ForcefullyClosed
                ? 'Connection was forcefully closed by the server.'
                : 'Connection closed before authentication completed.';
            conn.dispose();
            _xmppProxies[id]?.stop();
            if (!connectionCompleter.isCompleted) {
              connectionCompleter.completeError(Exception(_lastDiagnostic));
            }
          }
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
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      final bareTarget = targetJid.split('/').first;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      // OMEMO Encryption Layer
      final isOmemo = _omemoEnabled[targetJid.toLowerCase()] ?? false;
      if (isOmemo) {
        final encryptedList = await _omemo.encryptMessage(
          targetJid,
          text,
          strict: _isStrictVerificationEnabled,
        );
        if (encryptedList != null && encryptedList.isNotEmpty) {
          for (var enc in encryptedList) {
            msg.addChild(enc);
          }
          msg.body = '🔒 This message is encrypted with OMEMO.';
        } else {
          // If we are here, OMEMO is enabled but we found 0 devices.
          // This usually means the contact's client doesn't support OMEMO or hasn't published keys.
          throw Exception(
            'OMEMO Encryption Failed: The recipient ($targetJid) does not have any OMEMO-capable devices. '
            'Please disable OMEMO for this contact in the chat settings to send unencrypted messages.',
          );
        }
      } else {
        msg.body = isGroup
            ? text
            : _otr.processOutgoingMessage(bareTarget, text);
      }

      if (replyToId != null) {
        final reply = xmpp.XmppElement();
        reply.name = 'reply';
        reply.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
        reply.addAttribute(xmpp.XmppAttribute('to', targetJid));
        reply.addAttribute(xmpp.XmppAttribute('id', replyToId));
        msg.addChild(reply);
      }

      // XEP-0184: Request Delivery Receipt
      if (!isGroup) {
        final requestEl = xmpp.XmppElement();
        requestEl.name = 'request';
        requestEl.addAttribute(
          xmpp.XmppAttribute('xmlns', 'urn:xmpp:receipts'),
        );
        msg.addChild(requestEl);
      }

      conn.writeStanza(msg);

      _messageStreamController.add(
        ChatMessage(
          id: msg.id ?? 'xmpp_${DateTime.now().microsecondsSinceEpoch}',
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: _xmppJids[id] ?? 'me',
          accountId: id,
          protocol: 'XMPP',
          conversationId: targetJid.split('/').first.toLowerCase(),
          type: type,
          filePath: filePath,
          fileName: fileName,
          isGroup: isGroup,
          status: MessageStatus.sending,
          encryptionType: isOmemo ? 'omemo' : null,
        ),
      );
    } else {
      throw Exception('XMPP connection is not ready. State: ${conn?.state.name ?? "Disconnected"}');
    }
  }

  Future<void> sendEditedMessage(
    String targetJid,
    String originalMsgId,
    String newText, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);
      msg.body = newText;

      // XEP-0308: Message Correction
      final replace = xmpp.XmppElement();
      replace.name = 'replace';
      replace.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'),
      );
      replace.addAttribute(xmpp.XmppAttribute('id', originalMsgId));
      msg.addChild(replace);

      conn.writeStanza(msg);
      debugPrint('AuthService: Sent edited message for $originalMsgId');
    }
  }

  // XEP-0333: Chat Markers
  void sendChatMarker(
    String targetJid,
    String msgId,
    String markerType, { // 'displayed', 'received', or 'acknowledged'
    String? accountId,
    bool isGroup = false,
  }) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      final marker = xmpp.XmppElement();
      marker.name = markerType;
      marker.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'),
      );
      marker.addAttribute(xmpp.XmppAttribute('id', msgId));
      msg.addChild(marker);

      conn.writeStanza(msg);
    }
  }

  Future<void> sendXmppReaction(
    String targetJid,
    String originalMsgId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      final reactions = xmpp.XmppElement();
      reactions.name = 'reactions';
      reactions.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:reactions:0'),
      );
      reactions.addAttribute(xmpp.XmppAttribute('id', originalMsgId));

      final reaction = xmpp.XmppElement();
      reaction.name = 'reaction';
      reaction.textValue = emoji;
      reactions.addChild(reaction);

      msg.addChild(reactions);
      conn.writeStanza(msg);

      // Update local state (Optimistic)
      _jingleEventController.add(
        JingleEvent(
          action: JingleAction.transportInfo,
          sessionId: 'reaction',
          fromJid: _xmppJids[id] ?? 'me',
          reason: originalMsgId,
          sdp: emoji,
          accountId: id,
        ),
      );
    }
  }

  void sendReaction(
    String chatId,
    String messageId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) {
    final activeId = accountId ?? _activeAccountId;
    if (_xmppConnections.containsKey(activeId)) {
      sendXmppReaction(
        chatId,
        messageId,
        emoji,
        accountId: activeId,
        isGroup: isGroup,
      );
    }
  }

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
  }) async {
    if (_xmppConnections.containsKey(accountId)) {
      await sendXmppMessage(
        toId,
        text,
        accountId: accountId,
        type: type,
        filePath: filePath,
        fileName: fileName,
        replyToId: replyToId,
        isGroup: isGroup,
      );
    } else {
      throw Exception('Account $accountId is not connected.');
    }
  }

  // Retraction (XEP-0424)
  Future<void> retractXmppMessage(
    String targetJid,
    String messageId, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      'retract_${DateTime.now().millisecondsSinceEpoch}',
      isGroup ? xmpp.MessageStanzaType.GROUPCHAT : xmpp.MessageStanzaType.CHAT,
    );
    final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
    msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

    final applyTo = xmpp.XmppElement();
    applyTo.name = 'apply-to';
    applyTo.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:fasten:0'));
    applyTo.addAttribute(xmpp.XmppAttribute('id', messageId));

    final retract = xmpp.XmppElement();
    retract.name = 'retract';
    retract.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:retract:0'));
    applyTo.addChild(retract);
    msg.addChild(applyTo);

    conn.writeStanza(msg);
    debugPrint('XMPP: Retracted message $messageId for $targetJid');
  }

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

    // Disconnect if currently connected
    if (acc.protocol == 'XMPP' && _xmppConnections.containsKey(acc.fullJid)) {
      _xmppConnections[acc.fullJid]?.close();
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

  Future<void> joinRoom(
    String accountId,
    String roomJid,
    String nickname,
  ) async {
    await joinXmppRoom(roomJid, nickname, accountId: accountId);
  }

  Future<void> inviteToRoom(
    String accountId,
    String roomJid,
    String userJid, {
    String? reason,
  }) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.NORMAL,
    );
    msg.toJid = xmpp.Jid.fromFullJid(roomJid);

    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'),
    );

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
    final conn = _xmppConnections[accountId];
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

  Future<void> createRoom(
    String accountId,
    String roomJid,
    String nickname,
  ) async {
    await joinRoom(accountId, roomJid, nickname);
  }

  Future<void> leaveRoom(String accountId, String roomJid) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    debugPrint('MUC: Leaving Room $roomJid');
    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(roomJid);
    presence.type = xmpp.PresenceType.UNAVAILABLE;
    conn.writeStanza(presence);

    _persistedRooms.removeWhere((r) => r.startsWith('$accountId|$roomJid'));
    _saveJoinedRooms();
  }

  Future<String?> joinGenericRoom(
    String destination, {
    String? accountId,
  }) async {
    return await joinXmppRoom(
      destination,
      getResolvedNickname(accountId),
      accountId: accountId,
    );
  }

  void sendChatState(
    String targetJid,
    String state, {
    String? accountId,
    bool isGroup = false,
  }) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);
      final stateEl = xmpp.XmppElement();
      stateEl.name = state;
      stateEl.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/chatstates'),
      );
      msg.addChild(stateEl);

      // Add no-store hint to avoid archiving typing notifications
      final hint = xmpp.XmppElement();
      hint.name = 'no-store';
      hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
      msg.addChild(hint);

      conn.writeStanza(msg);
    }
  }

  Future<void> forwardMessage(
    ChatMessage original,
    List<String> targetChatIds, {
    String? accountId,
    String? targetProtocol,
  }) async {
    final curAccountId = accountId ?? _activeAccountId;
    if (curAccountId == null) return;
    for (var targetId in targetChatIds) {
      await Future.delayed(const Duration(milliseconds: 100));
      await sendXmppMessage(
        targetId,
        original.text,
        accountId: curAccountId,
        type: original.type,
        fileName: original.fileName,
        filePath: original.filePath,
      );
    }
  }

  Future<List<Map<String, String>>> discoverMucRooms(
    String accountId,
    String serviceJid,
  ) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return [];
    final id = 'disco_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'),
    );
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
    final conn = _xmppConnections[accountId];
    if (conn == null) {
      return {'jid': roomJid, 'name': roomJid, 'description': ''};
    }
    final id = 'roominfo_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'),
    );
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

  Future<void> requestRoomConfig(String accountId, String roomJid) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final id = 'config_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);
    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'),
    );
    iq.addChild(query);
    conn.writeStanza(iq);
  }

  Future<void> submitRoomConfig(
    String accountId,
    String roomJid,
    Map<String, String> fields,
  ) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final id = 'submit_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'),
    );

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

  // --- MUC Administration (XEP-0045) ---

  Future<Map<String, dynamic>?> fetchRoomConfig(String accountId, String roomJid) async {
    final conn = _xmppConnections[accountId];
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
    final conn = _xmppConnections[accountId];
    if (conn == null) return [];

    final id = 'affil_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'));
    
    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('affiliation', affiliation)); // owner, admin, member, outcast
    
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

  Future<void> setMucRole(
    String accountId,
    String roomJid,
    String nick,
    String role, {
    String? reason,
  }) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final id = 'role_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'),
    );

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
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final id = 'affil_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(roomJid);

    final query = xmpp.XmppElement();
    query.name = 'query';
    query.addAttribute(
      xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#admin'),
    );

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

  Future<void> sendXmppSubject(
    String roomJid,
    String subject, {
    String? accountId,
  }) async {
    final conn = _xmppConnections[accountId ?? _activeAccountId];
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

  Future<void> kickUser(
    String accountId,
    String roomJid,
    String nick, {
    String? reason,
  }) async {
    await setMucRole(accountId, roomJid, nick, 'none', reason: reason);
  }

  Future<void> banUser(
    String accountId,
    String roomJid,
    String userJid, {
    String? reason,
  }) async {
    await setMucAffiliation(
      accountId,
      roomJid,
      userJid,
      'outcast',
      reason: reason,
    );
  }

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

  Future<void> _saveJoinedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('joined_rooms', _persistedRooms.toList());
    _publishBookmarks();
  }

  void _publishBookmarks() {
    // Publish to storage:bookmarks
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
      final conn = _xmppConnections[acc];
      if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
        continue;
      }

      try {
        final id = 'pub_bm_${DateTime.now().millisecondsSinceEpoch}';
        final iq = xmpp.IqStanza(id, xmpp.IqStanzaType.SET);

        final pubsub = xmpp.XmppElement();
        pubsub.name = 'pubsub';
        pubsub.addAttribute(
          xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
        );

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
        accessModel.addAttribute(
          xmpp.XmppAttribute('var', 'pubsub#access_model'),
        );
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

  Future<void> _loadJoinedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('joined_rooms') ?? [];
    _persistedRooms = list.toSet();

    // Migrate old spaces from SharedPreferences to SQLite if needed
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

    _cachedJoinedSpaces = await db.getJoinedSpaces();
    _emitJoinedSpaces();
  }

  Future<void> _autoJoinRooms(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('joined_rooms') ?? [];
    _persistedRooms = list.toSet();

    for (var roomInfo in list) {
      final parts = roomInfo.split('|');
      if (parts.length == 3 && parts[0] == accountId) {
        _roomNicknames['${parts[0]}|${parts[1].toLowerCase()}'] = parts[2];
        joinRoom(parts[0], parts[1], parts[2]);
      }
    }
  }

  Future<void> logout() async {
    for (var conn in _xmppConnections.values) {
      conn.close();
    }
    _xmppConnections.clear();

    for (var sub in _xmppMessageSubs.values) {
      sub.cancel();
    }
    _xmppMessageSubs.clear();

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
  Future<bool> autoLogin() async {
    await loadSavedAccounts();
    if (_savedAccounts.isEmpty) return false;

    // For now, auto-login the first account found
    final acc = _savedAccounts.first;
    final pass = await _secureStorage.read(key: 'pass_${acc.fullJid}');

    // Restore Presence
    final prefs = await SharedPreferences.getInstance();
    final savedStatusIdx = prefs.getInt('my_presence_status');
    if (savedStatusIdx != null) {
      _myStatus = ContactStatus.values[savedStatusIdx];
    }
    _myStatusMessage = prefs.getString('my_presence_message');

    if (pass != null) {
      try {
        await connectXmpp(
          user: acc.user,
          domain: acc.domain,
          pass: pass,
          port: acc.port,
          host: acc.host,
          accountId: acc.fullJid,
          configData: acc,
        );

        // Broadcast presence after connection
        setPresence(_myStatus, _myStatusMessage);

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
      _lastDiagnostic =
          'Socket probe to $host:$port succeeded. Server is reachable.';
      notifyListeners();
      return 'Success: $host:$port is reachable';
    } on SocketException catch (e) {
      _lastDiagnostic = 'Socket probe failed: $host:$port — ${e.message}';
      notifyListeners();
      return 'Failed: ${e.message}';
    } catch (e) {
      _lastDiagnostic = 'Socket probe error: $e';
      notifyListeners();
      return 'Error: $e';
    }
  }

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

  Future<void> fetchXmppHistory(
    String jid, {
    String? accountId,
    DateTime? since,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return;
    try {
      final mamManager = xmpp.MessageArchiveManager.getInstance(conn);
      mamManager.queryByTime(jid: xmpp.Jid.fromFullJid(jid), start: since);

      // The results will come through the normal message stream from the server,
      // but they will have archived attributes which we should already handle.
      debugPrint(
        'MAM: Requested history for $jid ${since != null ? "since $since" : ""}',
      );
    } catch (e) {
      debugPrint('MAM Error: $e');
    }
  }

  void _syncAllXmppData(String accountId, xmpp.Connection conn) {
    debugPrint('SYNC: Triggering full account sync for $accountId');

    // 1. Sync User Avatar/vCard
    fetchMyVCard(accountId: accountId);

    // 2. Global MAM Catchup (Offline Messages)
    try {
      final iq = xmpp.IqStanza(
        'mam_sync_${DateTime.now().millisecondsSinceEpoch}',
        xmpp.IqStanzaType.SET,
      );
      final query = xmpp.XmppElement();
      query.name = 'query';
      query.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      iq.addChild(query);
      conn.writeStanza(iq);
      debugPrint('SYNC: Dispatched global MAM request.');
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

  void logCallEvent(
    String targetId,
    String text,
    bool isSent, {
    String? filePath,
    MessageType type = MessageType.call,
  }) {
    _messageStreamController.add(
      ChatMessage(
        id: 'call_log_${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        timestamp: DateTime.now(),
        type: type,
        filePath: filePath,
        isSent: isSent,
        senderId: isSent ? 'me' : targetId,
        accountId: _activeAccountId,
        protocol: 'XMPP',
      ),
    );
  }

  Future<String?> createXmppRoom(
    String roomJid,
    String nick, {
    String? accountId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) {
      return 'XMPP not connected';
    }

    try {
      // 1. Initial MUC joining presence (XEP-0045 7.2.1)
      final roomJidObj = xmpp.Jid.fromFullJid('$roomJid/$nick');
      final presence = xmpp.PresenceStanza();
      presence.toJid = roomJidObj;
      presence.addAttribute(xmpp.XmppAttribute('to', '$roomJid/$nick'));
      presence.show = xmpp.PresenceShowElement.CHAT;
      presence.status = 'Creating room...';

      // Add <x xmlns='http://jabber.org/protocol/muc'/> to signal MUC intent
      final mucX = xmpp.XmppElement();
      mucX.name = 'x';
      mucX.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'),
      );
      presence.addChild(mucX);

      conn.writeStanza(presence);

      // 2. Immediate "Instant Room" configuration (XEP-0045 10.1.2)
      final iqId = 'mucConfirm_${DateTime.now().millisecondsSinceEpoch}';
      final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
      iq.toJid = xmpp.Jid.fromFullJid(roomJid);

      final query = xmpp.XmppElement();
      query.name = 'query';
      query.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#owner'),
      );

      final xForm = xmpp.XmppElement();
      xForm.name = 'x';
      xForm.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
      xForm.addAttribute(
        xmpp.XmppAttribute('type', 'submit'),
      ); // Submit empty form = Instant Room

      query.addChild(xForm);
      iq.addChild(query);

      conn.writeStanza(iq);

      _joinedRooms.add(
        Room(
          id: roomJid,
          name: roomJid.split('@').first,
          participants: [],
          protocol: 'XMPP',
        ),
      );
      _joinedRoomsStreamController.add(List.from(_joinedRooms));
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('XMPP Room Creation Error: $e');
      return e.toString();
    }
  }

  Future<String?> joinXmppRoom(
    String roomJid,
    String nick, {
    String? accountId,
    String? password,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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
      mucX.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'),
      );

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
        _joinedRooms.add(
          Room(
            id: roomJid,
            name: roomJid.split('@').first,
            participants: [],
            protocol: 'XMPP',
          ),
        );
        _joinedRoomsStreamController.add(List.from(_joinedRooms));
        notifyListeners();
      }

      final persistStr = '$id|$roomJid|$nick';
      if (!_persistedRooms.contains(persistStr)) {
        _persistedRooms.add(persistStr);
        _saveJoinedRooms(); // This also publishes bookmarks
      }

      return null;
    } catch (e) {
      debugPrint('Failed to join room: $e');
      return e.toString();
    }
  }

  List<RoomParticipant> getRoomParticipants(String roomJid) {
    return _roomParticipants[roomJid]?.toList() ?? [];
  }

  Future<List<Map<String, dynamic>>> fetchIceServers(String accountId) async {
    if (_accountIceServers.containsKey(accountId) &&
        _accountIceServers[accountId]!.isNotEmpty) {
      return _accountIceServers[accountId]!;
    }

    final conn = _xmppConnections[accountId];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return [];

    final iqId = 'extdisco_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(conn.account.domain); // Query the server

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
        _accountIceServers[accountId] = discovered;
        completer.complete(discovered);
      }
    });

    conn.writeStanza(iq);

    // Timeout after 5 seconds
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub.cancel();
        return _accountIceServers[accountId] ?? [];
      },
    );
  }

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

  Future<void> createProfile(String name, {String? bio}) async {
    final profile = UserProfile(
      id: 'profile_${DateTime.now().millisecondsSinceEpoch}',
      displayName: name,
      bio: bio,
      accountIds: [],
    );
    _currentProfile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_profile', json.encode(profile.toJson()));
    notifyListeners();
  }

  // --- Backup / Restore ---

  Future<Map<String, String>> exportAccountSecrets() async {
    final all = await _secureStorage.readAll();
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
      await _secureStorage.write(key: entry.key, value: entry.value);
    }
  }

  Future<void> importSavedAccounts(List<SavedAccount> accounts) async {
    _savedAccounts.clear();
    _savedAccounts.addAll(accounts);

    final prefs = await SharedPreferences.getInstance();
    final jsonList = _savedAccounts.map((a) => a.toJson()).toList();
    await prefs.setString('saved_accounts_json', json.encode(jsonList));
    notifyListeners();
  }

  List<Map<String, dynamic>> exportContacts() {
    return _currentContacts.map((c) => c.toJson()).toList();
  }

  Future<void> importContacts(List<dynamic> contactsJson) async {
    final Map<String, Contact> newContacts = {};
    for (var c in _currentContacts) {
      newContacts[c.id] = c;
    }

    for (var j in contactsJson) {
      try {
        final contact = Contact.fromJson(j as Map<String, dynamic>);
        if (newContacts.containsKey(contact.id)) {
           // Merge rich fields if they are missing locally
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
    
    _currentContacts.clear();
    _currentContacts.addAll(newContacts.values);
    _contactStreamController.add(List.from(_currentContacts));
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
    // Reload local state
    await loadSavedAccounts();
  }

  Future<void> fetchContactVCard(String jid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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
  final List<String> _currentBlockedContacts = [];

  /// Fetches the list of blocked contacts (XEP-0191)
  Future<void> fetchBlockedContacts({String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) return;

    final iqId = 'get_blocklist_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.GET);
    final blocklist = xmpp.XmppElement();
    blocklist.name = 'blocklist';
    blocklist.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:blocking'));
    iq.addChild(blocklist);

    conn.writeStanza(iq);
    debugPrint('SOCIAL: Requested blocklist for $id');

    // The response is handled in the stanza stream listener
  }

  /// Updates our own presence status (XEP-0030/RFC 6121)
  Future<void> updatePresence(
    ContactStatus status, {
    String? message,
    String? accountId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    // Convert our internal status to XMPP Show values
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
        // We handle offline via disconnect, but for 'invisible' we'd use XEP-0186
        break;
    }

    if (message != null) {
      presence.status = message;
    }

    conn.writeStanza(presence);

    _myStatus = status;
    _myStatusMessage = message;
    notifyListeners();
    debugPrint('SOCIAL: Updated my presence to $status ($message) for $id');
  }

  /// Accepts an incoming friend request (XEP-0163)
  void acceptSubscription(String jid, {String? accountId}) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.SUBSCRIBED;
    conn.writeStanza(presence);

    // Also send a 'subscribe' back to ensure mutual friendship
    final subRequest = xmpp.PresenceStanza();
    subRequest.toJid = xmpp.Jid.fromFullJid(jid);
    subRequest.type = xmpp.PresenceType.SUBSCRIBE;
    conn.writeStanza(subRequest);

    debugPrint('SOCIAL: Accepted subscription and requested mutual from $jid');
    _pendingSubscriptionRequests.removeWhere((req) => req['jid'] == jid || req['jid'] == xmpp.Jid.fromFullJid(jid).userAtDomain);
    _subscriptionRequestController.add(List.from(_pendingSubscriptionRequests));
  }

  /// Declines or cancels a friend request
  void declineSubscription(String jid, {String? accountId}) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null) return;

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.UNSUBSCRIBED;
    conn.writeStanza(presence);

    debugPrint('SOCIAL: Declined subscription from $jid');
    _pendingSubscriptionRequests.removeWhere((req) => req['jid'] == jid || req['jid'] == xmpp.Jid.fromFullJid(jid).userAtDomain);
    _subscriptionRequestController.add(List.from(_pendingSubscriptionRequests));
  }

  /// Blocks a contact using XEP-0191 (Blocking Command)
  Future<void> blockContact(String jid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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

    if (!_currentBlockedContacts.contains(jid)) {
      _currentBlockedContacts.add(jid);
      _blockedContactsController.add(List.from(_currentBlockedContacts));
    }
  }

  /// Unblocks a contact using XEP-0191
  Future<void> unblockContact(String jid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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

    _currentBlockedContacts.remove(jid);
    _blockedContactsController.add(List.from(_currentBlockedContacts));
  }

  /// Renames a contact in the roster (Roster Push)
  Future<void> renameContact(
    String jid,
    String newName, {
    String? accountId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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

    final index = _currentContacts.indexWhere((c) => c.id == jid);
    if (index != -1) {
      _currentContacts[index].name = newName;
      _contactStreamController.add(List.from(_currentContacts));
    }
  }

  /// Completely removes a contact from the roster
  Future<void> removeContact(String jid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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

    _currentContacts.removeWhere((c) => c.id == jid);
    _contactStreamController.add(List.from(_currentContacts));
  }

  /// Sends a friend request (XEP-0163)
  void addContact(String jid, {String? nickname, String? group, String? accountId}) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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

    // Optimistic UI Update: Add the contact locally immediately
    if (!_currentContacts.any((c) => c.id == jid)) {
      _currentContacts.add(
        Contact(
          id: jid,
          name: nickname ?? xmpp.Jid.fromFullJid(jid).local,
          protocol: 'XMPP',
          groups: group != null && group.isNotEmpty ? [group] : [],
        ),
      );
      _contactStreamController.add(List.from(_currentContacts));
      debugPrint('SOCIAL: Optimistically added $jid to _currentContacts.');
    }

    debugPrint('SOCIAL: Added $jid to roster and sent subscribe request.');
  }

  Future<List<String>> getBlockList({String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
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
    await logout();
    await _omemo.clearDatabase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await _secureStorage.deleteAll();
    _savedAccounts.clear();
    _currentProfile = null;
    notifyListeners();
  }
}
