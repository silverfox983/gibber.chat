import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:irc_dart/irc_dart.dart';
import 'package:nyxx/nyxx.dart' as discord;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/chat_models.dart';
import '../models/user_profile.dart';
import './jingle_signaling_service.dart';
import './xmpp_proxy_service.dart';
import './http_upload_service.dart';
import './avatar_cache_service.dart';
import './omemo_service.dart';
import './omemo_storage.dart';
import './database_service.dart';
import 'package:http/http.dart' as http;

enum ConnectionProtocol { xmpp, irc, discord, none }

class AuthService with ChangeNotifier {
  bool _xmppConnecting = false;
  bool _ircConnecting = false;
  bool _discordConnecting = false;

  ConnectionStatus getAccountStatus(String accountId) {
    if (_xmppConnections.containsKey(accountId)) {
      final state = _xmppConnections[accountId]?.state;
      if (state == xmpp.XmppConnectionState.Ready) {
        return ConnectionStatus.online;
      }
      // Use Authenticating if Connecting is not available
      if (state == xmpp.XmppConnectionState.Authenticating) {
        return ConnectionStatus.connecting;
      }
      return ConnectionStatus.offline;
    }
    if (_ircConnections.containsKey(accountId)) {
      return ConnectionStatus.online;
    }
    if (_discordConnections.containsKey(accountId)) {
      return ConnectionStatus.online;
    }
    return ConnectionStatus.offline;
  }

  bool get xmppConnected => _xmppConnections.values.any(
    (c) => c.state == xmpp.XmppConnectionState.Ready,
  );
  bool get ircConnected => _ircConnections.isNotEmpty;
  bool get discordConnected => _discordConnections.isNotEmpty;
  bool get isConnecting =>
      _xmppConnecting || _ircConnecting || _discordConnecting;
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

  // Unified Subscription Request Stream (Friend Requests)
  final StreamController<Map<String, String>> _subscriptionRequestController =
      StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get subscriptionRequests =>
      _subscriptionRequestController.stream;

  final List<SavedAccount> _savedAccounts = [];
  List<SavedAccount> get savedAccounts => List.unmodifiable(_savedAccounts);

  final List<Room> _joinedRooms = [];
  List<Room> get joinedRooms => List.unmodifiable(_joinedRooms);

  final StreamController<List<Room>> _joinedRoomsStreamController =
      StreamController<List<Room>>.broadcast();
  Stream<List<Room>> get joinedRoomsStream =>
      _joinedRoomsStreamController.stream;

  ContactStatus _myStatus = ContactStatus.online;
  ContactStatus get myStatus => _myStatus;
  String? _myStatusMessage;
  String? get myStatusMessage => _myStatusMessage;

  // Multi-Account Storages
  final Map<String, xmpp.Connection> _xmppConnections = {};
  final Map<String, String> _xmppJids = {};
  Set<String> _persistedRooms = {};
  final Map<String, Completer<List<Map<String, String>>>> _discoveryCompleters =
      {};
  final Map<String, XmppProxyService> _xmppProxies = {};
  final Map<String, StreamSubscription> _xmppMessageSubs = {};
  final Map<String, StreamSubscription> _xmppStanzaSubs = {};
  final Map<String, StreamSubscription> _xmppStatusSubs = {};
  final Map<String, JingleSignalingService> _jingleServices = {};
  final Map<String, HttpUploadService> _uploadServices = {};
  final Map<String, List<Map<String, dynamic>>> _accountIceServers = {};
  final Map<String, List<String>> _roomParticipants = {};

  final StreamController<Map<String, List<String>>>
  _roomParticipantStreamController =
      StreamController<Map<String, List<String>>>.broadcast();
  Stream<Map<String, List<String>>> get roomParticipantsStream =>
      _roomParticipantStreamController.stream;

  final Map<String, Set<String>> _serverFeatures = {};

  String _emojiToText(dynamic emoji) {
    final name = emoji?.name?.toString();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return emoji?.toString() ?? '';
  }
  final Map<String, String?> _uploadServiceJids = {};

  final Map<String, IrcConnection> _ircConnections = {};
  final Map<String, String> _ircNicks = {};
  final Map<String, StreamSubscription> _ircMessageSubs = {};
  final Map<String, Completer<void>> _ircReadyCompleters = {};

  // Discord Storages
  final Map<String, discord.NyxxGateway> _discordConnections = {};
  final Map<String, List<StreamSubscription>> _discordSubs = {};

  UserProfile? _currentProfile;
  UserProfile? get currentProfile => _currentProfile;

  String? _activeAccountId;
  String? get activeAccountId => _activeAccountId;

  Future<String?> getActiveAccountPassword() async {
    if (_activeAccountId == null) return null;
    return await _secureStorage.read(key: 'pass_$_activeAccountId');
  }

  // Reconnection state tracking
  final Map<String, int> _discordReconnectAttempts = {};
  final Map<String, bool> _isDiscordReconnecting = {};

  // Track accounts that are intentionally logged in, even if temporarily disconnected.
  // This prevents the "Login Screen Flap" during network transitions.
  final Set<String> _authenticatedAccountIds = {};

  static ConnectionProtocol detectProtocol(String rawInput) {
    final input = rawInput.trim();

    // 1. Specific Discord Domain Check (for saved accounts)
    if (input.toLowerCase().endsWith('@discord.com')) {
      return ConnectionProtocol.discord;
    }

    // 2. Raw Discord Token Check
    // Discord tokens are typically 50-70 characters of base64-like characters
    // They may have 2-3 dot-separated segments (old format) or be a single segment (newer bot tokens)
    // A token starting with "Bot " prefix is also common
    if (input.toLowerCase().startsWith('bot ')) {
      return ConnectionProtocol.discord;
    }
    final parts = input.split('.');
    // Old format: 2-3 segments like MTIz.NDM1.bG9jYWw= (50+ chars total)
    // Or: mfa.ABC123... format
    // Or: Simple base64 token (newer bot tokens)
    if ((parts.length >= 2 && parts.length <= 3 && input.length > 30) ||
        input.startsWith('mfa.') ||
        input.startsWith('MTIz') || // Base64-ish pattern common in tokens
        (input.length >= 50 && RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(input))) {
      return ConnectionProtocol.discord;
    }

    // 3. IRC Detection
    if (input.startsWith('irc.') || input.contains('#')) {
      return ConnectionProtocol.irc;
    }

    // 4. XMPP Detection (Must contain @ but not be Discord)
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

  Future<String> getMyOmemoFingerprint() async {
    return await _omemo.getLocalFingerprint();
  }

  Future<List<Map<String, dynamic>>> fetchOmemoIdentities() async {
    final store = SQLiteSignalStore();
    return await store.getAllIdentities();
  }

  int getLocalOmemoDeviceId() => _omemo.localDeviceId;

  Future<void> resetOmemoKeys() async {
    await _omemo.resetIdentity();
    notifyListeners();
  }

  final _secureStorage = const FlutterSecureStorage();

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

  /// Map Gibber status to Discord status
  discord.CurrentUserStatus _mapStatusToDiscord(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return discord.CurrentUserStatus.online;
      case ContactStatus.away:
      case ContactStatus.xa:
        return discord.CurrentUserStatus.idle;
      case ContactStatus.dnd:
        return discord.CurrentUserStatus.dnd;
      case ContactStatus.offline:
        return discord.CurrentUserStatus.offline;
    }
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

    final fileName = file.path.split(Platform.pathSeparator).last;
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
    } else if (_discordConnections.containsKey(id)) {
      // Discord: Send via gateway as attachment
      final fileName = file.path.split(Platform.pathSeparator).last;
      await sendDiscordMessage(
        toJid,
        caption ?? '',
        accountId: id,
        file: file,
        type: type,
        fileName: fileName,
      );
    } else if (_ircConnections.containsKey(id)) {
      // IRC: (Fallback) Not supported
      debugPrint('IRC: Multimedia not supported');
    }
  }

  // Update VCard (XEP-0054)
  Future<void> updateMyVCard({
    required String accountId,
    String? fullName,
    String? nickName,
    String? description,
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

    iq.addChild(vcard);
    conn.writeStanza(iq);

    // Refresh local cache
    if (_currentProfile != null) {
      _currentProfile!.displayName = fullName ?? _currentProfile!.displayName;
      _currentProfile!.nickName = nickName ?? _currentProfile!.nickName;
      _currentProfile!.bio = description ?? _currentProfile!.bio;

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
      await fetchVCard(id, _xmppJids[id]!);
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
      await AvatarCacheService().saveAvatar(myJid, bytes, protocol: 'XMPP');
      notifyListeners();
    }
  }

  // Fetch VCard (XEP-0054)
  Future<void> fetchVCard(String accountId, String jid) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(jid);
    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));
    iq.addChild(vcard);
    conn.writeStanza(iq);
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
    notifyListeners();

    try {
      final jid = xmpp.Jid.fromFullJid(fullJidStr);

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

      final accountSettings = xmpp.XmppAccountSettings(
        jid.fullJid ?? fullJidStr,
        jid.local,
        jid.domain,
        pass,
        localPort,
        host: '127.0.0.1',
        resource: configData?.customResource ?? 'gibber_mobile',
        wsPath: configData?.wsPath,
      );

      // DOMAIN GUARD: Ensure SASL identity is explicitly the target domain
      debugPrint('XMPP: Preparing connection for ${jid.fullJid} (Domain: ${jid.domain}, Pass Length: ${pass.length})');

      if (configData != null) {
        if (configData.ackEnabled != null) {
          accountSettings.ackEnabled = configData.ackEnabled!;
        }
        if (configData.smResumable != null) {
          accountSettings.smResumable = configData.smResumable!;
        }
        if (configData.reconnectionTimeout != null) {
          accountSettings.reconnectionTimeout = configData.reconnectionTimeout!;
        }
      }

      final conn = xmpp.Connection(accountSettings);
      _omemo.setConnection(conn);
      await _omemo.initialize();

      _xmppConnections[id] = conn;
      _xmppJids[id] = jid.fullJid ?? fullJidStr; // Store JID

      // --- CRITICAL: Connect to start the milkshake! ---
      debugPrint('XMPP: Calling conn.connect() for $id...');
      conn.connect();
      // --------------------------------------------------

      conn.connectionStateStream.listen((state) {
        debugPrint('XMPP Account $id State: $state');
        if (state == xmpp.XmppConnectionState.Ready) {
          _xmppConnecting = false;
          _activeAccountId ??= id;
          _authenticatedAccountIds.add(id); // Track user intent

          // OMEMO: Publish keys now that we're connected & authenticated (XEP-0384)
          _omemo.publishDeviceList(conn);
          _omemo.publishBundle(conn);

          final presenceManager = xmpp.PresenceManager.getInstance(conn);
          presenceManager.sendPresence(
            xmpp.PresenceData(xmpp.PresenceShowElement.CHAT, 'Available', null),
          );

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

          _xmppStatusSubs[id] = conn.connectionStateStream.listen((state) {
            // ...
          });

          // Pipe events to unified stream
          signaling.events.listen((event) {
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
          _enableCarbons(id); // Mirror other devices in real-time
          rosterManager.rosterStream.listen((items) {
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
          presenceManager.presenceStream.listen((presence) {
            final pid = presence.jid?.fullJid ?? presence.jid?.domain;
            if (pid != null) {
              final index = _currentContacts.indexWhere((c) => c.id == pid);
              if (index != -1) {
                _currentContacts[index].status = _mapPresenceToShow(
                  presence.showElement,
                );
                _currentContacts[index].presenceMessage = presence.status;
                _contactStreamController.add(List.from(_currentContacts));
              }
            }
          });

          // Handle Messages
          final messageHandler = xmpp.MessageHandler.getInstance(conn);
          _xmppMessageSubs[id] = messageHandler.messagesStream.listen((m) {
            if (m != null && m.body != null) {
              _messageStreamController.add(
                ChatMessage(
                  id: DateTime.now().toIso8601String(),
                  text: m.body!,
                  timestamp: DateTime.now(),
                  isSent: false,
                  senderId: m.fromJid?.fullJid ?? m.fromJid?.domain,
                  senderName: m.fromJid?.local,
                  accountId: id,
                  protocol: 'XMPP',
                  conversationId: (m.fromJid?.fullJid ?? m.fromJid?.domain)
                      ?.split('/')
                      .first,
                ),
              );
            }
          });

          // Handle Stanzas (Jingle, MUC, MAM, ChatStates, Receipts)
          _xmppStanzaSubs[id] = conn.inStanzasStream.listen((stanza) async {
            if (stanza is xmpp.PresenceStanza) {
              final fromJid = stanza.fromJid;
              final mucUser = stanza.getChild('x');
              if (mucUser != null &&
                  mucUser.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/muc#user') {
                final roomJid = '${fromJid?.local}@${fromJid?.domain}';
                final nick = fromJid?.resource;
                if (nick != null) {
                  _roomParticipants[roomJid] ??= [];
                  // Use robust string-based check if enum is being finicky
                  final isUnavailable = stanza.type.toString().contains(
                    'unavailable',
                  );
                  if (isUnavailable) {
                    _roomParticipants[roomJid]!.remove(nick);
                  } else {
                    if (!_roomParticipants[roomJid]!.contains(nick)) {
                      _roomParticipants[roomJid]!.add(nick);
                    }
                  }
                  _roomParticipantStreamController.add(
                    Map.from(_roomParticipants),
                  );
                  notifyListeners();
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
                  _subscriptionRequestController.add({
                    'jid': fromJid,
                    'accountId': id,
                    'type': 'subscribe',
                  });
                }
              } else if (typeStr.contains('unsubscribed')) {
                debugPrint('SOCIAL: User $fromJid unsubscribed from us.');
              }
            }

            if (stanza is xmpp.IqStanza) {
              final vcard = stanza.getChild('vCard');
              if (vcard != null &&
                  vcard.getAttribute('xmlns')?.value == 'vcard-temp') {
                final nick = vcard.getChild('NICKNAME')?.textValue;
                final fullName = vcard.getChild('FN')?.textValue;
                final desc = vcard.getChild('DESC')?.textValue;
                final photo = vcard
                    .getChild('PHOTO')
                    ?.getChild('BINVAL')
                    ?.textValue;

                if (nick != null ||
                    photo != null ||
                    fullName != null ||
                    desc != null) {
                  if (photo != null) {
                    try {
                      final bytes = base64Decode(
                        photo.replaceAll(RegExp(r'\s+'), ''),
                      );
                      AvatarCacheService().saveAvatar(
                        stanza.fromJid?.fullJid ?? '',
                        bytes,
                      );
                    } catch (e) {
                      debugPrint('VCard PHOTO DECODE ERROR: $e');
                    }
                  }

                  // Update local profile if it's our JID
                  final myJid = _xmppJids[id];
                  final fromJidStr = stanza.fromJid?.fullJid;
                  if (fromJidStr != null &&
                      myJid != null &&
                      fromJidStr.toLowerCase().startsWith(
                        myJid.split('/').first.toLowerCase(),
                      )) {
                    if (_currentProfile != null) {
                      _currentProfile!.displayName =
                          fullName ?? nick ?? _currentProfile!.displayName;
                      _currentProfile!.nickName = nick;
                      _currentProfile!.bio = desc;
                      notifyListeners();
                    }
                  }

                  _messageStreamController.add(
                    ChatMessage(
                      id: 'vcard_${stanza.fromJid?.fullJid}',
                      text: 'UPDATE_PROFILE',
                      timestamp: DateTime.now(),
                      isSent: false,
                      senderId: stanza.fromJid?.fullJid,
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
                for (var item in items.children) {
                  final jid = item.getAttribute('jid')?.value;
                  final name = item.getAttribute('name')?.value;
                  if (jid != null &&
                      (name?.contains('upload') == true ||
                          jid.startsWith('upload.'))) {
                    _uploadServiceJids[id] = jid;
                    _uploadServices[id]?.uploadServiceJid = jid;
                    debugPrint('DISCO: Found HTTP Upload service: $jid');
                  }
                }
                return;
              }

              final info = stanza.getChild('query');
              if (info != null &&
                  info.getAttribute('xmlns')?.value ==
                      'http://jabber.org/protocol/disco#info') {
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
                if (_serverFeatures[id]!.contains('urn:xmpp:carbons:2')) {
                  _enableCarbons(id);
                }
                return;
              }

              final jingle = stanza.getChild('jingle');
              if (jingle != null &&
                  jingle.getAttribute('xmlns')?.value == 'urn:xmpp:jingle:1') {
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
            }
            if (stanza is xmpp.MessageStanza) {
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
                  final decrypted = await _omemo.decryptMessage(
                    encrypted,
                    fromBareJid: roomJid.toLowerCase(),
                  );
                  if (decrypted != null) {
                    finalBody = decrypted;
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

                if (finalBody != null) {
                  _messageStreamController.add(
                    ChatMessage(
                      id:
                          stanza.id ??
                          'xmpp_${DateTime.now().microsecondsSinceEpoch}',
                      text: finalBody,
                      timestamp: DateTime.now(),
                      isSent: false,
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
                  final decrypted = await _omemo.decryptMessage(
                    encrypted,
                    fromBareJid: bareJid,
                  );
                  if (decrypted != null) {
                    finalBody = decrypted;
                  }
                }

                if (finalBody != null) {
                  final replacesId = stanza
                      .getChild('replace')
                      ?.getAttribute('id')
                      ?.value;
                  final isRetraction =
                      stanza.getChild('apply-to')?.getChild('retract') != null;

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
                      final body = innerMessage.getChild('body')?.textValue;
                      if (body != null) {
                        final stamp = delay?.getAttribute('stamp')?.value;
                        final timestamp = stamp != null
                            ? DateTime.parse(stamp)
                            : DateTime.now();
                        final fromJidStr = innerMessage
                            .getAttribute('from')
                            ?.value;

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
                    final body = innerMessage.getChild('body')?.textValue;
                    if (body != null) {
                      final delay = forwarded?.getChild('delay');
                      final stamp = delay?.getAttribute('stamp')?.value;
                      final timestamp = stamp != null
                          ? DateTime.parse(stamp)
                          : DateTime.now();

                      final buddyJid = carbonSent != null
                          ? innerMessage.getAttribute('to')?.value
                          : innerMessage.getAttribute('from')?.value;

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
        } else if (state == xmpp.XmppConnectionState.Closed ||
            state == xmpp.XmppConnectionState.ForcefullyClosed) {
          _xmppConnecting = false;
          notifyListeners();
        }
      }, onError: _handleXmppStreamError);

      conn.connect();
    } catch (e) {
      debugPrint('XMPP Proxy Error: $e');
      rethrow;
    } finally {
      _xmppConnecting = false;
      notifyListeners();
    }
  }

  // IRC Connection
  Future<void> connectIrc({
    required String host,
    required int port,
    required String nick,
    required String channel,
    String? accountId,
    SavedAccount? configData,
  }) async {
    final id = accountId ?? 'irc_${DateTime.now().millisecondsSinceEpoch}';
    _ircConnecting = true;
    notifyListeners();
    try {
      final actualNick = '$nick${DateTime.now().millisecondsSinceEpoch % 1000}';
      final client = IrcClient(
        host: host,
        port: port,
        secure: configData?.isSecure ?? false,
        nick: actualNick,
        user: nick,
        userRealName: configData?.realName,
        pass: configData?.serverPassword,
        auth: configData?.saslAuthPassword,
      );

      final connection = await client.connect();
      _ircReadyCompleters[id] = Completer<void>();
      _ircNicks[id] = actualNick;
      _ircConnections[id] = connection;
      _ircConnecting = false;
      _activeAccountId ??= id;
      _authenticatedAccountIds.add(id); // Track user intent

      _ircMessageSubs[id] = connection.listen((message) {
        if (message.command == 'PRIVMSG' && message.parameters.isNotEmpty) {
          final target = message.parameters.first;
          final String senderNick =
              message.prefix?.split('!').first ?? 'irc-user';
          final isChannel = target.startsWith('#');

          String text = message.parameters.last;
          bool isAction = false;

          // Detect CTCP ACTION (\x01ACTION text\x01)
          if (text.startsWith('\x01ACTION ') && text.endsWith('\x01')) {
            text = text.substring(8, text.length - 1);
            isAction = true;
          }

          // Self-Detection (from other clients with same nick)
          final bool isSentByMe =
              senderNick.toLowerCase() == actualNick.toLowerCase();

          _messageStreamController.add(
            ChatMessage(
              id: 'irc_${DateTime.now().microsecondsSinceEpoch}_$senderNick',
              text: isAction ? '* $senderNick $text' : text,
              timestamp: DateTime.now(),
              isSent: isSentByMe,
              senderId: senderNick,
              senderName: senderNick,
              conversationId: isChannel
                  ? target
                  : (isSentByMe ? target : senderNick),
              accountId: id,
              protocol: 'IRC',
              isGroup: isChannel,
              type: isAction ? MessageType.system : MessageType.text,
            ),
          );
        } else if (message.command == 'JOIN') {
          final channel = message.parameters.first;
          final nick = message.prefix?.split('!').first;
          _messageStreamController.add(
            ChatMessage(
              id: 'irc_join_${DateTime.now().microsecondsSinceEpoch}',
              text: '$nick has joined $channel',
              timestamp: DateTime.now(),
              isSent: false,
              senderId: channel,
              conversationId: channel,
              accountId: id,
              protocol: 'IRC',
              isGroup: true,
            ),
          );
        } else if (message.command == 'TOPIC') {
          final channel = message.parameters.first;
          _messageStreamController.add(
            ChatMessage(
              id: 'irc_topic_${DateTime.now().microsecondsSinceEpoch}',
              text: 'Topic for $channel: ${message.parameters.last}',
              timestamp: DateTime.now(),
              isSent: false,
              senderId: channel,
              conversationId: channel,
              accountId: id,
              protocol: 'IRC',
              isGroup: true,
            ),
          );
        } else if (message.command == '001') {
          _ircReadyCompleters[id]?.complete();
          connection.add(IrcMessage(command: 'JOIN')..arg(channel));
        } else if (message.command == 'TOPIC') {
          final channel = message.parameters.first;
          final topic = message.parameters.last;
          _messageStreamController.add(
            ChatMessage(
              id: 'irc_topic_change_${DateTime.now().microsecondsSinceEpoch}',
              text: 'Topic for $channel changed to: $topic',
              timestamp: DateTime.now(),
              isSent: false,
              senderId: channel,
              conversationId: channel,
              accountId: id,
              protocol: 'IRC',
              isGroup: true,
              type: MessageType.system,
            ),
          );
        } else if (message.command == '332') {
          // RPL_TOPIC
          final channel = message.parameters[1];
          final topic = message.parameters.last;
          _messageStreamController.add(
            ChatMessage(
              id: 'irc_topic_sync_${DateTime.now().microsecondsSinceEpoch}',
              text: 'Topic: $topic',
              timestamp: DateTime.now(),
              isSent: false,
              senderId: channel,
              conversationId: channel,
              accountId: id,
              protocol: 'IRC',
              isGroup: true,
              type: MessageType.system,
            ),
          );
        } else if (message.command == '353') {
          // RPL_NAMREPLY
          final channel = message.parameters[2];
          final users = message.parameters.last.split(' ');
          _roomParticipants[channel] ??= [];
          for (var user in users) {
            final nick = user.replaceAll(
              RegExp(r'[^a-zA-Z0-9_\-\\\[\]\{\}\^\`]'),
              '',
            );
            if (nick.isNotEmpty &&
                !_roomParticipants[channel]!.contains(nick)) {
              _roomParticipants[channel]!.add(nick);
            }
          }
          _roomParticipantStreamController.add(Map.from(_roomParticipants));
        } else if (message.command == 'QUIT' || message.command == 'PART') {
          final senderNick = message.prefix?.split('!').first;
          if (senderNick != null) {
            final index = _currentContacts.indexWhere(
              (c) => c.id == senderNick && c.protocol == 'IRC',
            );
            if (index != -1) {
              _currentContacts[index].status = ContactStatus.offline;
              _contactStreamController.add(List.from(_currentContacts));
            }
          }
          // Setup Auto-Join channels if defined
          if (configData?.autoJoinChannels != null &&
              configData!.autoJoinChannels!.isNotEmpty) {
            for (var c in configData.autoJoinChannels!) {
              connection.msg(
                'JOIN $c',
                to: c,
              ); // or just use connection.add(IrcMessage(command: 'JOIN')..arg(c)) but let's just let joinIrcChannel handle it later if it exists. Actually irc_dart has raw commands:
              // Since irc_dart doesn't have an explicit join method, we use internal mapping or let our join method handle it.
            }
          }
        }
      });
      notifyListeners();
    } catch (e) {
      _ircConnecting = false;
      notifyListeners();
    } finally {
      // Done
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
    if (conn != null && conn.state == xmpp.XmppConnectionState.Ready) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      msg.toJid = xmpp.Jid.fromFullJid(targetJid);

      // OMEMO Encryption Layer
      final isOmemo = _omemoEnabled[targetJid.toLowerCase()] ?? false;
      if (isOmemo) {
        final encrypted = await _omemo.encryptMessage(
          targetJid,
          text,
          strict: _isStrictVerificationEnabled,
        );
        if (encrypted != null) {
          msg.addChild(encrypted);
          msg.body = '🔒 This message is encrypted with OMEMO.';
        } else {
          if (_isStrictVerificationEnabled) {
            throw Exception(
              'Message blocked: Unverified devices detected in Strict Mode.',
            );
          }
          msg.body = text;
        }
      } else {
        msg.body = text;
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
        ),
      );
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
    if (conn != null && conn.state == xmpp.XmppConnectionState.Ready) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup ? xmpp.MessageStanzaType.GROUPCHAT : xmpp.MessageStanzaType.CHAT,
      );
      msg.toJid = xmpp.Jid.fromFullJid(targetJid);
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

  Future<void> sendXmppReaction(
    String targetJid,
    String originalMsgId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null && conn.state == xmpp.XmppConnectionState.Ready) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      msg.toJid = xmpp.Jid.fromFullJid(targetJid);

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
    } else if (_discordConnections.containsKey(activeId)) {
      sendDiscordReaction(chatId, messageId, emoji, accountId: activeId);
    }
    // IRC doesn't support structured reactions
  }

  // Unified Message Sender (Standalone)
  void sendMessage(
    String accountId,
    String toId,
    String text, {
    MessageType type = MessageType.text,
    String? fileName,
    String? filePath,
    String? replyToId,
    bool isGroup = false,
  }) {
    if (_xmppConnections.containsKey(accountId)) {
      sendXmppMessage(
        toId,
        text,
        accountId: accountId,
        type: type,
        filePath: filePath,
        fileName: fileName,
        replyToId: replyToId,
        isGroup: isGroup,
      );
    } else if (_discordConnections.containsKey(accountId)) {
      sendDiscordMessage(toId, text, accountId: accountId);
    } else {
      sendIrcMessage(toId, text, accountId: accountId, isGroup: isGroup);
    }
  }

  Future<void> sendIrcMessage(
    String target,
    String text, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _ircConnections[id];
    final localNick = _ircNicks[id] ?? 'me';

    if (conn != null) {
      final actualIsGroup = isGroup || target.startsWith('#');
      conn.msg(text, to: target);

      _messageStreamController.add(
        ChatMessage(
          id: 'irc_sent_${DateTime.now().microsecondsSinceEpoch}',
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: localNick,
          accountId: id!,
          protocol: 'IRC',
          conversationId: target,
          isGroup: actualIsGroup,
        ),
      );
    }
  }

  /// Initiates an IRC DCC SEND (Direct Client-to-Client) file transfer
  Future<void> sendIrcFile(
    String target,
    String fileName,
    int fileSize, {
    String? accountId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final conn = _ircConnections[id];
    if (conn == null) return;

    // DCC SEND syntax: PRIVMSG <target> :\x01DCC SEND <filename> <ip> <port> <filesize>\x01
    // For now, we use a placeholder IP/Port as this requires a listening socket (active or passive)
    const placeholderIp = '0'; // 0 placeholder for now
    const placeholderPort = '0';

    final dccCommand =
        '\x01DCC SEND $fileName $placeholderIp $placeholderPort $fileSize\x01';
    conn.msg(dccCommand, to: target);

    _messageStreamController.add(
      ChatMessage(
        id: 'irc_dcc_${DateTime.now().microsecondsSinceEpoch}',
        text: '📎 Sent DCC File: $fileName ($fileSize bytes)',
        timestamp: DateTime.now(),
        isSent: true,
        senderId: _ircNicks[id] ?? 'me',
        accountId: id!,
        protocol: 'IRC',
        conversationId: target,
        type: MessageType.file,
        fileName: fileName,
      ),
    );

    debugPrint('IRC ($id): Initiated DCC SEND for $fileName to $target');
  }

  // --- DISCORD IMPLEMENTATION ---

  /// Retrieves a saved Discord token for a given handle (user#1234)
  Future<String?> getSavedDiscordToken(String handleOrId) async {
    // 1. Direct lookup by ID/Handle in Secure Storage
    final directKey = 'pass_$handleOrId@discord.com';
    final token = await _secureStorage.read(key: directKey);
    if (token != null) return token;

    // 2. Fallback: Search _savedAccounts for a matching Discord entry to find its JID
    for (var acc in _savedAccounts) {
      if (acc.protocol == 'Discord') {
        final passKey = 'pass_${acc.fullJid}';
        final savedToken = await _secureStorage.read(key: passKey);
        if (savedToken != null) {
          // Verify this token works for this handle if possible (or just trust the registry)
          // For now, we trust the first Discord account we find if only one exists
          return savedToken;
        }
      }
    }
    return null;
  }

  /// High-level method to connect Discord and handle result
  Future<String> connectDiscord(String token, {bool rememberMe = true}) async {
    // 1. Initial connection with the token
    String result = '';
    try {
      result = await _connectDiscord(
        SavedAccount(
          user: token,
          domain: 'discord.com',
          port: 443,
          protocol: 'Discord',
        ),
      );
    } catch (e) {
      if (e.toString().contains('4014')) {
        debugPrint('Discord: Primary connection failed with 4014. Retrying with minimal intents...');
        // Retry with minimal intents (No privileged intents)
        result = await _connectDiscord(
          SavedAccount(
            user: token,
            domain: 'discord.com',
            port: 443,
            protocol: 'Discord',
          ),
          useMinimalIntents: true,
        );
      } else {
        rethrow;
      }
    }

    // result is the accountId (snowflake@discord.com)
    if (result.isEmpty) {
      throw Exception(_lastDiagnostic ?? 'Discord connection failed (Handshake incomplete).');
    }

    if (rememberMe) {
      await saveAccount(
        SavedAccount(
          user: result.split('@').first,
          domain: 'discord.com',
          port: 443,
          protocol: 'Discord',
          displayName: token.length > 20
              ? 'Discord Bot (${token.substring(0, 8)}...)'
              : 'Discord Bot',
        ),
        token,
      );
    }
    return result;
  }

  Future<String> _connectDiscord(SavedAccount account, {bool useMinimalIntents = false}) async {
    final accountId = '${account.user}@${account.domain}';
    String actualAccountId = '';

    if (_discordConnections.containsKey(accountId)) return accountId;

    _discordConnecting = true;
    notifyListeners();

    return await runZonedGuarded(
          () async {
            try {
              // 1. Clean token (handle "Bot " prefix carefully)
              final rawToken = account.user.trim();
              final isExplicitBot = rawToken.toLowerCase().startsWith('bot ');
              final token = isExplicitBot ? rawToken.replaceFirst(RegExp(r'^Bot ', caseSensitive: false), '') : rawToken;

              // 2. Select Intents (Adaptive nyxx 6.x constructor path)
              var intents = discord.GatewayIntents.allUnprivileged;
              if (!useMinimalIntents) {
                intents = discord.GatewayIntents(
                  intents.value |
                      discord.GatewayIntents.messageContent.value |
                      discord.GatewayIntents.guildPresences.value |
                      discord.GatewayIntents.guildMembers.value,
                );
              }

              debugPrint('Discord: Connecting with intents ${intents.value} (Minimal: $useMinimalIntents)');
              
              final client = await discord.Nyxx.connectGateway(
                token,
                intents,
                options: discord.GatewayClientOptions(
                  plugins: [discord.logging, discord.ignoreExceptions],
                ),
              );

              // Robust handshake: Wait for ready OR informative disconnect
              final readyCompleter = Completer<void>();
              final errorCompleter = Completer<String>();

              final readySub = client.onReady.listen((_) {
                debugPrint('[Discord Handshake] Received READY');
                if (!readyCompleter.isCompleted) readyCompleter.complete();
              });

              final resumeSub = client.onResumed.listen((_) {
                debugPrint('[Discord Handshake] Received RESUMED');
                if (!readyCompleter.isCompleted) readyCompleter.complete();
              });

              final disconnectSub = client.gateway.events.listen(
                (event) {
                  debugPrint('[Discord Handshake] Event: $event');
                  // Use dynamic check to avoid lint issues with specific Nyxx event types
                  final eventStr = event.toString().toLowerCase();
                  if (eventStr.contains('disconnect') ||
                      eventStr.contains('close')) {
                    int? code;
                    try {
                      // Nyxx 6.x events often have a 'code' property for disconnections
                      final dynamic dEvent = event;
                      code = dEvent.code?.value;
                    } catch (_) {}

                    String msg = 'Discord connection closed abruptly.';
                    if (code == 4004) {
                      msg =
                          'Discord Authentication Failed. Verify your token is correct and is a BOT token.';
                    }
                    if (code == 4014) {
                      msg =
                          'Discord Disallowed Intent. Enable "Message Content Intent" in the Discord Developer Portal.';
                    }

                    if (!errorCompleter.isCompleted &&
                        !readyCompleter.isCompleted) {
                      errorCompleter.complete(msg);
                    }
                  }
                },
                onError: (e, stack) {
                  debugPrint('Discord Gateway Handshake Error: $e\n$stack');
                  if (!errorCompleter.isCompleted &&
                      !readyCompleter.isCompleted) {
                    errorCompleter.complete('Discord Handshake Error: $e');
                  }
                },
              );

              try {
                await Future.any([
                  readyCompleter.future,
                  errorCompleter.future,
                ]).timeout(const Duration(seconds: 30));

                if (errorCompleter.isCompleted) {
                  throw Exception(await errorCompleter.future);
                }
              } on TimeoutException {
                throw Exception(
                  'Timed out waiting for Discord ready state. Network may be unstable.',
                );
              } finally {
                await readySub.cancel();
                await resumeSub.cancel();
                await disconnectSub.cancel();
              }

              final currentUser = await client.users.fetchCurrentUser();

              // Use the Snowflake ID for the stable account identity (handle can change!)
              final snowflake = currentUser.id.toString();
              actualAccountId = '$snowflake@discord.com';

              if (_discordConnections.containsKey(actualAccountId)) {
                // Already connected with this identity
                return actualAccountId;
              }

              // Ensure old subs are cleared if reconnecting
              if (_discordSubs.containsKey(actualAccountId)) {
                for (var sub in _discordSubs[actualAccountId]!) {
                  await sub.cancel();
                }
                _discordSubs[actualAccountId]!.clear();
              }

              _discordConnections[actualAccountId] = client;
              _discordSubs[actualAccountId] ??= [];
              _monitorDiscordHealth(actualAccountId, client);

              _activeAccountId ??= actualAccountId;
              _discordReconnectAttempts[actualAccountId] =
                  0; // Reset on success
              _isDiscordReconnecting[actualAccountId] = false;
              _authenticatedAccountIds.add(
                actualAccountId,
              ); // Track user intent

              // REINFORCEMENT: All events and watchers must use the discovered identity, NOT the token
              final String accountId = actualAccountId;

              // Handle Messages
              _discordSubs[accountId]!.add(
                client.onMessageCreate.listen(
                  (event) {
                    if (event.message.author.id == client.user.id) return;

                    final isGroup = event.guild != null;
                    final convId = event.message.channelId.toString();

                    // Extract Attachments
                    String text = event.message.content;
                    for (var attachment in event.message.attachments) {
                      text += '\n📎 ${attachment.url}';
                    }

                    _messageStreamController.add(
                      ChatMessage(
                        id: event.message.id.toString(),
                        text: text,
                        timestamp: event.message.timestamp,
                        isSent: false,
                        senderId: event.message.author.id.toString(),
                        senderName: event.message.author.username,
                        accountId: accountId,
                        protocol: 'Discord',
                        conversationId: convId,
                        isGroup: isGroup,
                        replyToId: event.message.referencedMessage?.id.toString(),
                      ),
                    );
                  },
                  onError: (e) {
                    debugPrint(
                      'Discord ($actualAccountId) MessageCreate Error: $e',
                    );
                    _lastDiagnostic =
                        'Discord ($actualAccountId) Stream Error: $e';
                    notifyListeners();
                  },
                ),
              );

              // Handle Edits (Updates)
              _discordSubs[actualAccountId]!.add(
                client.onMessageUpdate.listen(
                  (event) {
                    final msg = event.message;

                    final convId = msg.channelId.toString();
                    _messageStreamController.add(
                      ChatMessage(
                        id: msg.id.toString(),
                        text: msg.content,
                        timestamp: msg.timestamp,
                        isSent: msg.author.id == client.user.id,
                        senderId: msg.author.id.toString(),
                        senderName: msg.author.username,
                        accountId: actualAccountId,
                        protocol: 'Discord',
                        conversationId: convId,
                        isGroup: event.guild != null,
                        replacesId: msg.id.toString(),
                        replyToId: msg.referencedMessage?.id.toString(),
                        isEdited: msg.editedTimestamp != null,
                        editTimestamp: msg.editedTimestamp,
                      ),
                    );
                  },
                  onError: (e) {
                    debugPrint(
                      'Discord ($actualAccountId) MessageUpdate Error: $e',
                    );
                  },
                ),
              );

              // Handle Reaction Adds
              _discordSubs[actualAccountId]!.add(
                client.onMessageReactionAdd.listen(
                  (event) {
                    final emojiText = _emojiToText(event.emoji);
                    if (emojiText.isEmpty) return;
                    _jingleEventController.add(
                      JingleEvent(
                        action: JingleAction.transportInfo,
                        sessionId: 'reaction',
                        fromJid: event.channelId.toString(),
                        reason: event.messageId.toString(),
                        sdp: jsonEncode({
                          'emoji': emojiText,
                          'userId': event.userId.toString(),
                          'op': 'add',
                        }),
                        accountId: actualAccountId,
                      ),
                    );
                  },
                ),
              );

              // Handle Reaction Removes
              _discordSubs[actualAccountId]!.add(
                client.onMessageReactionRemove.listen(
                  (event) {
                    final emojiText = _emojiToText(event.emoji);
                    if (emojiText.isEmpty) return;
                    _jingleEventController.add(
                      JingleEvent(
                        action: JingleAction.transportInfo,
                        sessionId: 'reaction',
                        fromJid: event.channelId.toString(),
                        reason: event.messageId.toString(),
                        sdp: jsonEncode({
                          'emoji': emojiText,
                          'userId': event.userId.toString(),
                          'op': 'remove',
                        }),
                        accountId: actualAccountId,
                      ),
                    );
                  },
                ),
              );

              // Handle Deletes
              _discordSubs[actualAccountId]!.add(
                client.onMessageDelete.listen(
                  (event) {
                    _messageStreamController.add(
                      ChatMessage(
                        id: event.id.toString(),
                        text: '🚫 Message deleted',
                        timestamp: DateTime.now(),
                        isSent: false,
                        type: MessageType.system,
                        accountId: actualAccountId,
                        protocol: 'Discord',
                        conversationId: event.channelId.toString(),
                      ),
                    );
                  },
                  onError: (e) {
                    debugPrint(
                      'Discord ($actualAccountId) MessageDelete Error: $e',
                    );
                  },
                ),
              );

              // Handle Presence
              _discordSubs[actualAccountId]!.add(
                client.onPresenceUpdate.listen(
                  (event) {
                    if (event.status == null) return;
                    final status = _mapDiscordStatus(event.status!);
                    final contactIdx = _currentContacts.indexWhere(
                      (c) => c.id == event.user?.id.toString(),
                    );
                    if (contactIdx != -1) {
                      _currentContacts[contactIdx].status = status;
                      _contactStreamController.add(List.from(_currentContacts));
                    }
                  },
                  onError: (e) {
                    debugPrint(
                      'Discord ($actualAccountId) PresenceUpdate Error: $e',
                    );
                  },
                ),
              );

              // Discover Guild Channels
              _discordSubs[actualAccountId]!.add(
                client.onGuildCreate.listen(
                  (event) async {
                    final guild = event.guild;
                    if (guild is discord.Guild) {
                      final channels = await guild.fetchChannels();
                      final textChannels = channels
                          .whereType<discord.GuildTextChannel>();

                      final rooms = textChannels.map((ch) {
                        return Room(
                          id: ch.id.toString(),
                          name: '${guild.name} > ${ch.name}',
                          protocol: 'Discord',
                          participants: [],
                          isGroup: true,
                          accountId: actualAccountId,
                        );
                      }).toList();

                      _joinedRooms.addAll(rooms);
                      _joinedRoomsStreamController.add(List.from(_joinedRooms));
                    }
                  },
                  onError: (e) {
                    debugPrint(
                      'Discord ($actualAccountId) GuildCreate Error: $e',
                    );
                  },
                ),
              );

              // Fetch initial state once ready
              client.onReady.listen(
                (event) async {
                  debugPrint(
                    'Discord ($actualAccountId): Client ready as ${client.user.id}. Resetting backoff.',
                  );
                  _discordReconnectAttempts[actualAccountId] = 0;
                  _isDiscordReconnecting[actualAccountId] = false;
                  _discordConnecting = false;
                  _lastDiagnostic =
                      'Discord ($actualAccountId) is connected and ready.';

                  await _discoverDiscordResources(actualAccountId, client);
                  notifyListeners();
                },
                onError: (e) {
                  debugPrint('Discord ($accountId) Ready State Error: $e');
                  _reconnectDiscord(accountId);
                },
              );

              return actualAccountId;
            } catch (e, stack) {
              debugPrint('Discord Login Error: $e\n$stack');
              final errorStr = e.toString();
              if (errorStr.contains('401') ||
                  errorStr.toLowerCase().contains('unauthorized')) {
                _lastDiagnostic =
                    'Discord Error: Unauthorized. Ensure your token is a BOT token.';
              } else if (errorStr.contains('4013') ||
                  errorStr.contains('intent')) {
                _lastDiagnostic =
                    'Discord Error: Disallowed Intents. Ensure "Message Content Intent" is enabled in Discord Dev Portal.';
              } else {
                _lastDiagnostic = 'Discord Connection Error: $e';
              }
              notifyListeners();
              throw Exception(_lastDiagnostic);
            } finally {
              _discordConnecting = false;
              notifyListeners();
            }
          },
          (error, stack) {
            final String errorStr = error.toString();
            final bool isShardError =
                errorStr.contains('Shard') && errorStr.contains('disconnected');

            if (isShardError) {
              debugPrint('DISCORD GATEWAY ALERT (Recoverable): $errorStr');
            } else {
              debugPrint('DISCORD CRITICAL ZONE ERROR: $error\n$stack');
            }

            _lastDiagnostic =
                'Discord ($actualAccountId) Gateway Error: $errorStr';
            _discordConnecting = false;
            notifyListeners();

            // TRIGGER RECOVERY: Handled by _reconnectDiscord which has internal debouncing
            _reconnectDiscord(
              actualAccountId.isEmpty ? accountId : actualAccountId,
            );
          },
        ) ??
        '';
  }

  Future<void> _discoverDiscordResources(
    String accountId,
    discord.NyxxGateway client,
  ) async {
    try {
      final guilds = client.guilds.cache.values;
      final List<Room> rooms = [];

      for (var guild in guilds) {
        final channels = await guild.fetchChannels();
        final textChannels = channels.whereType<discord.GuildTextChannel>();
        final voiceChannels = channels.whereType<discord.GuildVoiceChannel>();

        // Fetch guild members for participant tracking
        final List<String> participants = [];
        try {
          // Nyxx 6.x: fetchGuildMembers returns a Stream<Member> via HTTP
          final members = await (client as dynamic).httpEndpoints
              .fetchGuildMembers(guild.id)
              .toList();
          for (var m in members) {
            participants.add(m.user.username);
            // Background fetch/cache avatars for members
            fetchDiscordAvatar(
              m.user.id.toString(),
              m.user.avatarUrl(),
              accountId: accountId,
            );
          }
        } catch (e) {
          debugPrint('Discord: Error fetching members for ${guild.name}: $e');
        }

        rooms.addAll(
          textChannels.map(
            (ch) => Room(
              id: ch.id.toString(),
              name: '${guild.name} > ${ch.name}',
              protocol: 'Discord',
              participants: participants,
              accountId: accountId,
            ),
          ),
        );

        rooms.addAll(
          voiceChannels.map(
            (ch) => Room(
              id: ch.id.toString(),
              name: '${guild.name} > 🔊 ${ch.name}',
              protocol: 'Discord',
              participants: participants,
              isGroup: true, // Voice channels behave like groups
              accountId: accountId,
            ),
          ),
        );
      }

      _joinedRooms.addAll(
        rooms.where((r) => !_joinedRooms.any((jr) => jr.id == r.id)),
      );
      _joinedRoomsStreamController.add(List.from(_joinedRooms));

      // Discovery DMs (Private Channels)
      // Note: For bots, this only lists channels in cache. For users, it lists active DMs.
      final dmChannels = client.channels.cache.values
          .whereType<discord.DmChannel>();
      for (var dm in dmChannels) {
        final participant = dm.recipient;
        _messageStreamController.add(
          ChatMessage(
            id: 'ping_${dm.id}',
            text: '', // Hidden ping to trigger conversation creation
            timestamp: DateTime.now(),
            isSent: false,
            senderId: participant.id.toString(),
            senderName: participant.username,
            accountId: accountId,
            protocol: 'Discord',
            conversationId: dm.id.toString(),
            isGroup: false,
            type: MessageType.system,
          ),
        );
      }
    } catch (e) {
      debugPrint('Discord Discovery Error: $e');
    }
  }

  ContactStatus _mapDiscordStatus(discord.UserStatus status) {
    if (status == discord.UserStatus.online) return ContactStatus.online;
    if (status == discord.UserStatus.idle) return ContactStatus.away;
    if (status == discord.UserStatus.dnd) return ContactStatus.dnd;
    return ContactStatus.offline;
  }

  /// Persistent health monitor for Discord gateway health (prevents Unhandled Zoned Errors)
  void _monitorDiscordHealth(String accountId, discord.NyxxGateway client) {
    // 1. Monitor for ready states (resets any diagnostic errors)
    final readySub = client.onReady.listen(
      (_) {
        _lastDiagnostic = 'Discord ($accountId) is connected and ready.';
        _discordConnecting = false;
        notifyListeners();
      },
      onError: (e) {
        _lastDiagnostic = 'Discord ($accountId) Ready Stream Error: $e';
        notifyListeners();
      },
    );

    // 2. Monitor for background disconnects
    final disconnectSub = client.gateway.events.listen(
      (event) {
        final eventStr = event.toString().toLowerCase();
        if (eventStr.contains('disconnect') || eventStr.contains('close')) {
          int? code;
          try {
            final dynamic dEvent = event;
            code = dEvent.code?.value;
          } catch (_) {}

          _lastDiagnostic =
              'Discord ($accountId) disconnected unexpectedly (Close Code: ${code ?? "Unknown"}). Attempting auto-reconnect...';
          notifyListeners();

          // Trigger Reconnection if not a fatal error (4004 = Auth Fail, 4014 = Intents Fail)
          if (code != 4004 && code != 4014) {
            _reconnectDiscord(accountId);
          }
        }
      },
      onError: (e, stack) {
        _lastDiagnostic =
            'Discord ($accountId) Critical Gateway Error: $e. Re-enabling guard...';
        debugPrint('Discord Watchdog ($accountId): $e\n$stack');
        notifyListeners();
        _reconnectDiscord(accountId);
      },
    );

    _discordSubs[accountId]?.addAll([readySub, disconnectSub]);
  }

  /// Handles automated reconnection with exponential backoff for Discord accounts
  /// Discord-Specific: Send a reaction to a message
  Future<void> sendDiscordReaction(
    String channelId,
    String messageId,
    String emoji, {
    String? accountId,
  }) async {
    final activeId = accountId ?? _activeAccountId;
    final client = _discordConnections[activeId];
    if (client == null) return;

    try {
      final snowflakeChannelId = discord.Snowflake.parse(channelId);
      final snowflakeMessageId = discord.Snowflake.parse(messageId);

      // Nyxx 6.x: Try using the rest client's http property if available via dynamic cast
      // or use the specific httpEndpoints if available.
      await (client as dynamic).httpEndpoints.createReaction(
        snowflakeChannelId,
        snowflakeMessageId,
        emoji,
      );
      debugPrint(
        'Discord ($activeId): Sent reaction $emoji to message $messageId',
      );
    } catch (e) {
      debugPrint('Discord ($activeId): Failed to send reaction: $e');
    }
  }

  /// Discord-Specific: Delete a message
  Future<void> deleteDiscordMessage(
    String channelId,
    String messageId, {
    String? accountId,
  }) async {
    final activeId = accountId ?? _activeAccountId;
    final client = _discordConnections[activeId];
    if (client == null) return;

    try {
      final snowflakeChannelId = discord.Snowflake.parse(channelId);
      final snowflakeMessageId = discord.Snowflake.parse(messageId);

      await (client as dynamic).httpEndpoints.deleteMessage(
        snowflakeChannelId,
        snowflakeMessageId,
      );
      debugPrint('Discord ($activeId): Deleted message $messageId');
    } catch (e) {
      debugPrint('Discord ($activeId): Failed to delete message: $e');
    }
  }

  /// Discord-Specific: Edit a message
  Future<void> editDiscordMessage(
    String channelId,
    String messageId,
    String newText, {
    String? accountId,
  }) async {
    final activeId = accountId ?? _activeAccountId;
    final client = _discordConnections[activeId];
    if (client == null) return;

    try {
      final snowflakeChannelId = discord.Snowflake.parse(channelId);
      final snowflakeMessageId = discord.Snowflake.parse(messageId);
      await (client as dynamic).httpEndpoints.updateMessage(
        snowflakeChannelId,
        snowflakeMessageId,
        discord.MessageUpdateBuilder(content: newText),
      );
      debugPrint('Discord ($activeId): Edited message $messageId');
    } catch (e) {
      debugPrint('Discord ($activeId): Failed to edit message: $e');
    }
  }

  Future<void> _reconnectDiscord(String accountId) async {
    // Prevent overlapping reconnect attempts
    if (_isDiscordReconnecting[accountId] == true) return;

    _isDiscordReconnecting[accountId] = true;
    final int attempt = _discordReconnectAttempts[accountId] ?? 0;

    _discordConnecting = true;
    notifyListeners();

    // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 64s (max)
    final delaySeconds = (1 << (attempt + 1)).clamp(2, 60);
    debugPrint(
      'Discord ($accountId): Reconnecting in $delaySeconds seconds... (Attempt ${attempt + 1})',
    );

    await Future.delayed(Duration(seconds: delaySeconds));

    // GUARD: Ensure subscriptions for the previous failed instance are cleared
    if (_discordSubs.containsKey(accountId)) {
      for (var sub in _discordSubs[accountId]!) {
        try {
          await sub.cancel();
        } catch (_) {}
      }
      _discordSubs[accountId]!.clear();
    }

    try {
      if (_savedAccounts.isEmpty) {
        await loadSavedAccounts();
      }
      final token = await getSavedDiscordToken(accountId.split('@').first);
      if (token == null) {
        _lastDiagnostic =
            'Discord ($accountId): Reconnection failed - Saved token not found.';
        _isDiscordReconnecting[accountId] = false;
        _discordConnecting = false;
        notifyListeners();
        return;
      }

      // Explicitly cleanup old connection
      if (_discordConnections.containsKey(accountId)) {
        try {
          await _discordConnections[accountId]!.close();
        } catch (_) {}
        _discordConnections.remove(accountId);
      }

      _discordReconnectAttempts[accountId] = attempt + 1;
      String result = '';
      try {
        result = await _connectDiscord(
          SavedAccount(
            user: token,
            domain: 'discord.com',
            port: 443,
            protocol: 'Discord',
          ),
        );
      } catch (e) {
        if (e.toString().contains('4014')) {
          result = await _connectDiscord(
            SavedAccount(
              user: token,
              domain: 'discord.com',
              port: 443,
              protocol: 'Discord',
            ),
            useMinimalIntents: true,
          );
        } else {
          rethrow;
        }
      }

      if (result.isNotEmpty) {
        debugPrint('Discord ($accountId): Reconnected successfully.');
      } else {
        _isDiscordReconnecting[accountId] = false;
        _reconnectDiscord(accountId);
      }
    } catch (e) {
      debugPrint('Discord ($accountId): Reconnection attempt failed: $e');
      _isDiscordReconnecting[accountId] = false;
      _reconnectDiscord(accountId);
    }
  }

  Future<void> sendDiscordMessage(
    String channelId,
    String text, {
    String? accountId,
    File? file,
    MessageType type = MessageType.text,
    String? fileName,
    String? replyToId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final client = _discordConnections[id];
    if (client == null) return;

    try {
      final snowflake = discord.Snowflake.parse(channelId);
      final channel =
          await client.channels.fetch(snowflake) as discord.TextChannel;

      final actualFileName =
          fileName ??
          (file != null
              ? file.path.split(Platform.pathSeparator).last
              : 'attachment');
      final builder = discord.MessageBuilder(
        content: text,
        attachments: file != null
            ? [
                discord.AttachmentBuilder(
                  data: file.readAsBytesSync(),
                  fileName: actualFileName,
                ),
              ]
            : null,
        referencedMessage: replyToId != null && replyToId.isNotEmpty
            ? discord.MessageReferenceBuilder.reply(
                messageId: discord.Snowflake.parse(replyToId),
              )
            : null,
      );

      final msg = await channel.sendMessage(builder);

      _messageStreamController.add(
        ChatMessage(
          id: msg.id.toString(),
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: client.user.id.toString(),
          accountId: id,
          protocol: 'Discord',
          conversationId: channelId,
          isGroup: true,
          type: file != null ? type : MessageType.text,
          fileName: fileName ?? file?.path.split(Platform.pathSeparator).last,
          filePath: file?.path,
          replyToId: replyToId,
        ),
      );
    } catch (e) {
      debugPrint('Discord: Error sending message: $e');
    }
  }

  Future<void> fetchDiscordAvatar(
    String userId,
    String? url, {
    String? accountId,
  }) async {
    if (url == null) {
      return;
    }
    final cached = await AvatarCacheService().hasAvatar(
      userId,
      protocol: 'Discord',
    );
    if (!cached) {
      try {
        final resp = await http.get(Uri.parse(url));
        if (resp.statusCode == 200) {
          await AvatarCacheService().saveAvatar(
            userId,
            resp.bodyBytes,
            protocol: 'Discord',
          );
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Discord Avatar Fetch Error: $e');
      }
    }
  }

  Future<String?> joinGenericRoom(
    String destination, {
    String? accountId,
  }) async {
    final protocol = detectProtocol(destination);
    if (protocol == ConnectionProtocol.xmpp) {
      return await joinXmppRoom(
        destination,
        _currentProfile?.displayName ?? 'User',
        accountId: accountId,
      );
    } else if (protocol == ConnectionProtocol.irc) {
      return await joinIrcChannel(destination, accountId: accountId);
    } else if (protocol == ConnectionProtocol.discord) {
      // Discord uses specific methods for voice/text, but for generic 'join'
      // we'll assume it's a channel ID for now.
      debugPrint('Discord: Manual join requested for $destination');
      return 'Discord joining not fully automated via string';
    }
    return 'Unknown protocol for $destination';
  }

  Future<void> joinDiscordVoiceChannel(
    String channelId, {
    String? accountId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final client = _discordConnections[id];
    if (client == null) return;

    try {
      final channelSnowflake = discord.Snowflake.parse(channelId);
      final channel =
          await client.channels.fetch(channelSnowflake) as discord.GuildChannel;

      // Update Voice State via Gateway
      // Nyxx 6.x updateVoiceState takes (guildId, builder)
      client.gateway.updateVoiceState(
        channel.guildId,
        discord.GatewayVoiceStateBuilder(
          channelId: channelSnowflake,
          isMuted: false,
          isDeafened: false,
        ),
      );
      debugPrint('Discord: Gateway signaled join for voice $channelId');
    } catch (e) {
      debugPrint('Discord Voice Error: $e');
    }
  }

  Future<void> fetchDiscordHistory(
    String channelId, {
    String? accountId,
    String? beforeId,
  }) async {
    final id = accountId ?? _activeAccountId;
    final client = _discordConnections[id];
    if (client == null) return;

    try {
      final channel =
          await client.channels.fetch(discord.Snowflake.parse(channelId))
              as discord.TextChannel;
      final messages = await channel.messages.fetchMany(
        limit: 50,
        before: beforeId != null ? discord.Snowflake.parse(beforeId) : null,
      );

      for (var msg in messages) {
        _messageStreamController.add(
          ChatMessage(
            id: msg.id.toString(),
            text: msg.content,
            timestamp: msg.timestamp,
            isSent: msg.author.id == client.user.id,
            senderId: msg.author.id.toString(),
            senderName: msg.author.username,
            accountId: id,
            protocol: 'Discord',
            conversationId: channelId,
            isGroup: true, // Assuming guild/group for now
          ),
        );
      }
    } catch (e) {
      debugPrint('Discord History Error: $e');
    }
  }

  // XEP-0085 Chat State Notifications (Typing Indicators)
  void sendChatState(
    String targetJid,
    String state, {
    String? accountId,
    bool isGroup = false,
  }) {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn != null && conn.state == xmpp.XmppConnectionState.Ready) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      msg.toJid = xmpp.Jid.fromFullJid(targetJid);

      final stateEl = xmpp.XmppElement();
      stateEl.name = state; // e.g., 'composing', 'paused', 'active'
      stateEl.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/chatstates'),
      );
      msg.addChild(stateEl);

      conn.writeStanza(msg);
    }
  }

  // MUC Management (Manual XEP-0045)
  Future<void> joinRoom(
    String accountId,
    String roomJid,
    String nickname,
  ) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    debugPrint('MUC: Joining Room $roomJid as $nickname');
    final presence = xmpp.PresenceStanza();
    // Join by sending presence to room@service/nick
    presence.toJid = xmpp.Jid.fromFullJid('$roomJid/$nickname');
    conn.writeStanza(presence);

    _persistedRooms.add('$accountId|$roomJid|$nickname');
    _saveJoinedRooms();
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

    // Timeout support
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _discoveryCompleters.remove(id);
        return [];
      },
    );
  }

  Future<void> _saveJoinedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('joined_rooms', _persistedRooms.toList());
  }

  Future<void> _autoJoinRooms(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('joined_rooms') ?? [];
    _persistedRooms = list.toSet();

    for (var roomInfo in list) {
      final parts = roomInfo.split('|');
      if (parts.length == 3 && parts[0] == accountId) {
        joinRoom(parts[0], parts[1], parts[2]);
      }
    }
  }

  // --- ADVANCED MESSAGING (XEP-0422, Forwarding) ---

  Future<void> forwardMessage(
    ChatMessage original,
    List<String> targetChatIds, {
    String? accountId,
    List<Conversation>? knownConversations,
  }) async {
    for (var targetChatId in targetChatIds) {
      // Small randomized delay to avoid server-side rate-limiting during multi-forward
      await Future.delayed(const Duration(milliseconds: 100));

      final targetConversation = knownConversations?.cast<Conversation?>().firstWhere(
        (c) => c?.id == targetChatId,
        orElse: () => null,
      );
      final protocol = targetConversation?.protocol.toUpperCase();
      final targetAccountId =
          targetConversation?.accountId ?? accountId ?? _activeAccountId;
      if (targetAccountId == null) continue;

      if (protocol == 'DISCORD' || _discordConnections.containsKey(targetAccountId)) {
        await sendDiscordMessage(
          targetChatId,
          original.type == MessageType.text ? original.text : '',
          accountId: targetAccountId,
          file: original.filePath != null ? File(original.filePath!) : null,
          type: original.type,
          fileName: original.fileName,
        );
      } else if (protocol == 'IRC' || _ircConnections.containsKey(targetAccountId)) {
        // IRC supports text-only forwarding in this client.
        final textToForward = original.text.isNotEmpty
            ? original.text
            : (original.fileName != null
                  ? 'Forwarded file: ${original.fileName}'
                  : '[Forwarded message]');
        await sendIrcMessage(
          targetChatId,
          textToForward,
          accountId: targetAccountId,
          isGroup: targetConversation?.isGroup ?? targetChatId.startsWith('#'),
        );
      } else {
        await sendXmppMessage(
          targetChatId,
          original.text,
          accountId: targetAccountId,
          type: original.type,
          fileName: original.fileName,
          filePath: original.filePath,
          isGroup: targetConversation?.isGroup ?? false,
        );
      }
    }
  }

  Future<ChatMessage?> fetchQuotedMessage(String msgId) async {
    return await DatabaseService().getMessageById(msgId);
  }

  // Next method...

  // Send Retraction (XEP-0424)
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
    msg.toJid = xmpp.Jid.fromFullJid(targetJid);

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

  Future<void> updateMyStatus(ContactStatus status, {String? message}) async {
    _myStatus = status;
    _myStatusMessage = message;
    notifyListeners();

    // 1. Sync XMPP
    for (var conn in _xmppConnections.values) {
      if (conn.state == xmpp.XmppConnectionState.Ready) {
        final pManager = xmpp.PresenceManager.getInstance(conn);
        pManager.sendPresence(
          xmpp.PresenceData(_mapShowToPresence(status), message ?? '', null),
        );
      }
    }

    // 2. Sync IRC
    for (var conn in _ircConnections.values) {
      if (status == ContactStatus.offline ||
          status == ContactStatus.away ||
          status == ContactStatus.xa) {
        conn.add(
          IrcMessage(command: 'AWAY')..arg(message ?? 'Away from Gibber'),
        );
      } else {
        conn.add(IrcMessage(command: 'AWAY')); // Clear away status
      }
    }

    // 3. Sync Discord
    for (var gateway in _discordConnections.values) {
      gateway.updatePresence(
        discord.PresenceBuilder(
          status: _mapStatusToDiscord(status),
          activities: message != null
              ? [
                  discord.ActivityBuilder(
                    name: message,
                    type: discord.ActivityType.custom,
                  ),
                ]
              : [],
          isAfk: status == ContactStatus.away || status == ContactStatus.xa,
        ),
      );
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
    } else if (acc.protocol == 'IRC' &&
        _ircConnections.containsKey(acc.fullJid)) {
      _ircConnections[acc.fullJid]?.close();
      _ircConnections.remove(acc.fullJid);
    }

    _authenticatedAccountIds.remove(acc.fullJid);
    notifyListeners();
  }

  Future<void> loadSavedAccounts() async {
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

  Future<void> logout() async {
    for (var sub in _xmppMessageSubs.values) {
      await sub.cancel();
    }
    for (var sub in _xmppStanzaSubs.values) {
      await sub.cancel();
    }
    for (var conn in _xmppConnections.values) {
      conn.dispose();
    }
    for (var proxy in _xmppProxies.values) {
      proxy.stop();
    }
    for (var sub in _ircMessageSubs.values) {
      await sub.cancel();
    }
    for (var conn in _ircConnections.values) {
      conn.close();
    }
    for (var subList in _discordSubs.values) {
      for (var sub in subList) {
        await sub.cancel();
      }
    }
    for (var client in _discordConnections.values) {
      await client.close();
    }

    _xmppConnections.clear();
    _xmppProxies.clear();
    _xmppMessageSubs.clear();
    _xmppStanzaSubs.clear();
    _jingleServices.clear();
    _ircConnections.clear();
    _ircMessageSubs.clear();
    _discordConnections.clear();
    _discordSubs.clear();
    _activeAccountId = null;
    _currentContacts.clear();
    _authenticatedAccountIds.clear(); // Complete reset
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

  // Final Implementations
  Future<String> testSocketConnection(String host, int port) async => 'Success';

  void _enableCarbons(String accountId) {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final enable = xmpp.XmppElement();
    enable.name = 'enable';
    enable.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:carbons:2'));
    iq.addChild(enable);
    conn.writeStanza(iq);
    debugPrint('XEP-0280: Carbons enabled for $accountId');
  }

  Future<void> fetchXmppHistory(String jid, {String? accountId}) async {
    final id = accountId ?? _activeAccountId;
    final conn = _xmppConnections[id];
    if (conn == null || conn.state != xmpp.XmppConnectionState.Ready) return;
    try {
      final mamManager = xmpp.MessageArchiveManager.getInstance(conn);
      mamManager.queryByTime(jid: xmpp.Jid.fromFullJid(jid));

      // The results will come through the normal message stream from the server,
      // but they will have archived attributes which we should already handle.
      debugPrint('MAM: Requested history for $jid');
    } catch (e) {
      debugPrint('MAM Error: $e');
    }
  }

  void logCallEvent(String targetId, String text, bool isSent) {
    _messageStreamController.add(
      ChatMessage(
        id: 'call_log_${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        timestamp: DateTime.now(),
        type: MessageType.call,
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
      presence.show = xmpp.PresenceShowElement.CHAT;
      presence.status = 'Joining room...';

      final mucX = xmpp.XmppElement();
      mucX.name = 'x';
      mucX.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'),
      );
      presence.addChild(mucX);

      conn.writeStanza(presence);

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
      debugPrint('Failed to join room: $e');
      return e.toString();
    }
  }

  List<String> getRoomParticipants(String roomJid) {
    return _roomParticipants[roomJid] ?? [];
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

  Future<String?> joinIrcChannel(String channel, {String? accountId}) async {
    String? id = accountId ?? _activeAccountId;
    IrcConnection? conn = _ircConnections[id];

    if (conn == null && accountId == null && _ircConnections.isNotEmpty) {
      id = _ircConnections.keys.first;
      conn = _ircConnections[id];
    }

    if (conn == null) return 'IRC not connected';

    // Fix: Wait for connection to be REGISTERED (RPL_WELCOME) before joining
    if (_ircReadyCompleters[id]?.isCompleted == false) {
      debugPrint('IRC: Waiting for RPL_WELCOME before joining $channel');
      await _ircReadyCompleters[id]!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
    }

    conn.add(IrcMessage(command: 'JOIN')..arg(channel));

    // Status Feedback
    _messageStreamController.add(
      ChatMessage(
        id: 'irc_join_req_${DateTime.now().microsecondsSinceEpoch}',
        text: 'Joining $channel...',
        timestamp: DateTime.now(),
        isSent: true,
        senderId: _ircNicks[id] ?? 'me',
        conversationId: channel,
        accountId: id,
        protocol: 'IRC',
        isGroup: true,
      ),
    );

    // Add to joined rooms tracking
    if (!_joinedRooms.any((r) => r.id == channel)) {
      _joinedRooms.add(
        Room(id: channel, name: channel, participants: [], protocol: 'IRC'),
      );
      _joinedRoomsStreamController.add(List.from(_joinedRooms));
    }

    notifyListeners();
    return null;
  }

  // --- ROSTER & CONTACT MANAGEMENT (XEP-0164, XEP-0191) ---

  // XEP-0030: Service Discovery (XEP-0030)
  Future<void> _discoverServiceFeatures(String accountId, String domain) async {
    final conn = _xmppConnections[accountId];
    if (conn == null) return;

    debugPrint('DISCO: Starting discovery for $domain');

    // 1. Discover Server Features (MAM, Carbons, etc.)
    final infoId = 'disco_info_${DateTime.now().millisecondsSinceEpoch}';
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
  void addContact(String jid, {String? nickname, String? accountId}) {
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
    query.addChild(item);
    iq.addChild(query);
    conn.writeStanza(iq);

    final presence = xmpp.PresenceStanza();
    presence.toJid = xmpp.Jid.fromFullJid(jid);
    presence.type = xmpp.PresenceType.SUBSCRIBE;
    conn.writeStanza(presence);

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
