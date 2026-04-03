import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/avatar_cache_service.dart';

class ChatProvider with ChangeNotifier {
  List<Conversation> _conversations = [];
  String? _activeConversationId;
  StreamSubscription? _authSub;
  StreamSubscription? _contactSub;
  StreamSubscription? _roomParticipantSub;
  StreamSubscription? _subscriptionSub;
  StreamSubscription? _joinedRoomsSub;
  StreamSubscription? _blockedSub;

  final List<Contact> _contacts = [];
  final List<String> _blockedJids = [];
  final List<Map<String, String>> _pendingSubscriptions = [];
  String _messageSearchQuery = '';
  int _selectedSidebarTab =
      0; // 0 for Chats, 1 for Contacts, 2 for Groups, 3 for Dialer, 4 for Profile

  String _searchQuery = '';
  final Map<String, Timer> _typingTimers = {};

  Timer? _batchTimer;
  final List<void Function()> _batchQueue = [];
  final List<ChatMessage> _toPersist = [];
  bool _isSyncing = false;
  List<ChatMessage> _globalSearchResults = [];
  String? _playingMessageId;

  List<Contact> get contacts => _contacts;
  List<String> get blockedJids => _blockedJids;
  List<Map<String, String>> get pendingSubscriptions => _pendingSubscriptions;
  String get messageSearchQuery => _messageSearchQuery;
  int get selectedSidebarTab => _selectedSidebarTab;
  bool get isSyncing => _isSyncing;
  List<ChatMessage> get globalSearchResults => _globalSearchResults;
  String? get playingMessageId => _playingMessageId;

  List<Conversation> get conversations {
    final filtered = _searchQuery.isEmpty
        ? _conversations
        : _conversations
              .where(
                (c) =>
                    c.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();

    // Return conversations sorted by the most recent message timestamp
    final sorted = List<Conversation>.from(filtered);
    sorted.sort((a, b) {
      final aTime = a.messages.isNotEmpty
          ? a.messages.last.timestamp
          : DateTime(1970);
      final bTime = b.messages.isNotEmpty
          ? b.messages.last.timestamp
          : DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return sorted;
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  bool isTyping(String conversationId) {
    return _conversations.any((c) => c.id == conversationId && c.isTyping);
  }

  Conversation? get activeConversation {
    if (_activeConversationId == null) return null;
    try {
      return _conversations.firstWhere((c) => c.id == _activeConversationId);
    } catch (_) {
      return null;
    }
  }

  Future<void> setActiveConversation(String? id) async {
    _activeConversationId = id?.split('/').first.toLowerCase();
    _messageSearchQuery = ''; // Reset search when switching chats

    if (_activeConversationId != null) {
      // 1. Ensure Conversation exists in memory list
      int index = _conversations.indexWhere(
        (c) => c.id == _activeConversationId,
      );
      if (index == -1) {
        final protocol = AuthService.detectProtocol(_activeConversationId!);
        final contact = _contacts.firstWhere(
          (c) => c.id == _activeConversationId,
          orElse: () => Contact(
            id: _activeConversationId!,
            name: protocol == ConnectionProtocol.discord
                ? 'Discord Channel'
                : _activeConversationId!.split('@').first,
            protocol: protocol == ConnectionProtocol.discord
                ? 'Discord'
                : 'XMPP',
          ),
        );
        _conversations.add(
          Conversation(
            id: _activeConversationId!,
            name: contact.name,
            messages: [],
            protocol: contact.protocol,
          ),
        );
        index = _conversations.length - 1;
      }

      // 2. Perform UI Reset & History Pulse
      _conversations[index].unreadCount = 0;
      DatabaseService().resetUnreadCount(_activeConversationId!);

      try {
        final messages = await DatabaseService().getMessages(
          _activeConversationId!,
        );
        // Merge DB messages with any pending in-memory messages from stream
        final existingIds = messages.map((m) => m.id).toSet();
        final pendingMessages = _conversations[index].messages
            .where((m) => !existingIds.contains(m.id))
            .toList();

        _conversations[index].messages.clear();
        _conversations[index].messages.addAll(messages);
        _conversations[index].messages.addAll(pendingMessages);
        _conversations[index].messages.sort(
          (a, b) => a.timestamp.compareTo(b.timestamp),
        );

        // 3. Robust History Sync (MAM)
        // Trigger a catch-up sync if we have few messages or it's been a while.
        // Small delay prevents UI freeze during rapid switching.
        if (_conversations[index].protocol == 'XMPP' &&
            !_conversations[index].historyLoaded) {
          _conversations[index].historyLoaded = true;
          // Using local variable to avoid race conditions if _activeConversationId changes
          final targetId = _activeConversationId!;
          final providerAccountId = _conversations[index].accountId ?? '';

          Future.delayed(const Duration(milliseconds: 300), () {
            // Ensure we are still looking at the same conversation
            if (_activeConversationId == targetId) {
              AuthService().fetchOlderHistory(providerAccountId, targetId);
            }
          });
        }
      } catch (e) {
        debugPrint('HISTORY PULSE ERROR: $e');
      }
    }
    notifyListeners();
  }

  void setSidebarTab(int index) {
    _selectedSidebarTab = index;
    notifyListeners();
  }

  Future<void> loadHistory(
    String rawId,
    AuthService authService, {
    String? beforeId,
  }) async {
    final id = rawId.split('/').first.toLowerCase();
    int index = _conversations.indexWhere((c) => c.id == id);
    if (index == -1) {
      final protocol = AuthService.detectProtocol(id);
      final contact = _contacts.firstWhere(
        (c) => c.id == id,
        orElse: () => Contact(
          id: id,
          name: protocol == ConnectionProtocol.discord
              ? 'Discord Channel'
              : id.split('@').first,
          protocol: protocol == ConnectionProtocol.discord ? 'Discord' : 'XMPP',
        ),
      );
      _conversations.add(
        Conversation(
          id: id,
          name: contact.name,
          messages: [],
          protocol: contact.protocol,
          accountId: authService.activeAccountId,
        ),
      );
      index = _conversations.length - 1;
    }

    try {
      final messages = await DatabaseService().getMessages(id);
      if (messages.isNotEmpty) {
        final existingIds = _conversations[index].messages
            .map((m) => m.id)
            .toSet();
        final pending = _conversations[index].messages
            .where((m) => !existingIds.contains(m.id))
            .toList();

        _conversations[index].messages.clear();
        _conversations[index].messages.addAll(messages);
        _conversations[index].messages.addAll(pending);
        _conversations[index].messages.sort(
          (a, b) => a.timestamp.compareTo(b.timestamp),
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('LOAD HISTORY ERROR: $e');
    }

    if (_conversations[index].historyLoaded) return;
    _conversations[index].historyLoaded = true;

    if (authService.xmppConnected && _conversations[index].protocol == 'XMPP') {
      authService.fetchOlderHistory(
        _conversations[index].accountId ?? authService.activeAccountId ?? '',
        id,
        beforeId: beforeId,
      );
    } else if (authService.discordConnected &&
        _conversations[index].protocol == 'Discord') {
      authService.fetchDiscordHistory(id);
    }
    notifyListeners();
  }

  Future<void> loadOlderMessages(
    String conversationId,
    AuthService authService,
  ) async {
    final conv = _conversations.firstWhere((c) => c.id == conversationId);
    if (conv.messages.isEmpty) return;

    final oldestId = conv.messages.first.id;
    final accountId = conv.accountId ?? authService.activeAccountId;
    if (accountId == null) return;

    if (conv.protocol == 'XMPP') {
      await authService.fetchOlderHistory(
        accountId,
        conversationId,
        beforeId: oldestId,
      );
    } else if (conv.protocol == 'Discord') {
      await authService.fetchDiscordHistory(
        conversationId,
        accountId: accountId,
        beforeId: oldestId,
      );
    }
  }

  Future<void> initialize(AuthService authService) async {
    // 1. Load from Disk (Robust Persistence)
    try {
      final cachedConvs = await DatabaseService().getConversations();
      for (var c in cachedConvs) {
        final messages = await DatabaseService().getMessages(c.id);

        // Normalize stale account IDs (transition from xmpp_ timestamp to stable bare JID)
        String currentAccountId = c.accountId ?? '';
        if (currentAccountId.startsWith('xmpp_') &&
            authService.activeAccountId != null) {
          debugPrint(
            'ChatProvider: Normalizing stale accountId ${c.accountId} to ${authService.activeAccountId}',
          );
          currentAccountId = authService.activeAccountId!;
        }

        // Check if already in list (e.g. from previous initialization)
        if (!_conversations.any((existing) => existing.id == c.id)) {
          _conversations.add(
            Conversation(
              id: c.id,
              name: c.name,
              messages: messages,
              protocol: c.protocol,
              accountId: currentAccountId,
              isGroup: c.isGroup,
              unreadCount: c.unreadCount,
            ),
          );
        }
      }
      notifyListeners();
    } catch (e, stack) {
      debugPrint('DB LOAD ERROR: $e\n$stack');
    }

    // 2. Setup Subscription Listener (Friend Requests)
    _subscriptionSub?.cancel();
    _subscriptionSub = authService.subscriptionRequests.listen((request) {
      if (!_pendingSubscriptions.any((r) => r['jid'] == request['jid'])) {
        _pendingSubscriptions.add(request);
        notifyListeners();
      }
    });

    _authSub?.cancel();

    // 2. Setup Participant Stream (XEP-0045)
    _roomParticipantSub?.cancel();
    _roomParticipantSub = authService.roomParticipantsStream.listen((
      participantsMap,
    ) {
      for (var entry in participantsMap.entries) {
        final convId = entry.key.toLowerCase();
        final index = _conversations.indexWhere(
          (c) => c.id.toLowerCase() == convId,
        );
        if (index != -1) {
          _conversations[index].participants = entry.value;
        }
      }
      notifyListeners();
    });

    _authSub = authService.messages.listen((message) {
      final rawTarget = (message.conversationId ?? message.senderId ?? '')
          .toLowerCase();
      if (rawTarget.isEmpty) return;

      // Normalize: Strip resource part (e.g., /balcony) to ensure messages stay in one thread.
      final targetId = rawTarget.split('/').first;

      if (message.type == MessageType.system &&
          message.text == 'UPDATE_PROFILE') {
        _handleProfileUpdate(targetId, message.senderName);
        return;
      }

      // Handle Topic Sync
      if (message.type == MessageType.system &&
          (message.text.startsWith('Topic changed to: ') ||
              message.text.startsWith('Topic: '))) {
        final topicText = message.text
            .replaceFirst('Topic changed to: ', '')
            .replaceFirst('Topic: ', '');
        final idx = _conversations.indexWhere(
          (c) => c.id.toLowerCase() == targetId.toLowerCase(),
        );
        if (idx != -1) {
          _conversations[idx].topic = topicText;
        }
      }

      addMessage(
        targetId,
        message,
        protocol: message.protocol,
        chatName: message.senderName ?? targetId,
      );
    });

    _contactSub?.cancel();
    _contactSub = authService.contacts.listen((newContacts) {
      _contacts.clear();
      _contacts.addAll(newContacts);

      // Update presence for in-memory conversations
      for (var contact in newContacts) {
        final idx = _conversations.indexWhere(
          (c) => c.id.toLowerCase() == contact.id.toLowerCase(),
        );
        if (idx != -1) {
          _conversations[idx].status = contact.status;
          _conversations[idx].presenceMessage = contact.presenceMessage;
        }
      }
      notifyListeners();
    });

    // Listen for Signaling Events (Typing, Receipts)
    authService.jingleEvents.listen((event) {
      if (event.sessionId == 'typing') {
        _handleTyping(event.fromJid, event.reason ?? 'active');
      } else if (event.sessionId == 'reaction') {
        _handleReaction(event.fromJid, event.reason!, event.sdp!);
      } else if (event.sessionId == 'receipt') {
        _handleReceipt(event.fromJid, event.reason!);
      }
    });

    // 4. Setup Joined Rooms Listener
    _joinedRoomsSub?.cancel();
    _joinedRoomsSub = authService.joinedRoomsStream.listen((rooms) {
      for (var room in rooms) {
        final id = room.id.toLowerCase();
        if (!_conversations.any((c) => c.id.toLowerCase() == id)) {
          final newConv = Conversation(
            id: id,
            name: room.name,
            messages: [],
            protocol: room.protocol,
            accountId: authService.activeAccountId,
            isGroup: true,
          );
          _conversations.add(newConv);
          DatabaseService().upsertConversation(newConv);
          notifyListeners();
        }
      }
    });

    // 5. Setup Blocked List Listener
    _blockedSub?.cancel();
    _blockedSub = authService.blockedContacts.listen((blocked) {
      _blockedJids.clear();
      _blockedJids.addAll(blocked);
      notifyListeners();
    });

    if (authService.xmppConnected) {
      authService.fetchBlockedContacts();
    }
  }

  Future<void> syncAll(AuthService authService) async {
    if (_isSyncing ||
        !(authService.xmppConnected || authService.discordConnected))
      return;

    debugPrint('MAM: Starting Global Sync for ${_contacts.length} contacts...');
    _isSyncing = true;
    notifyListeners();

    try {
      for (final contact in _contacts) {
        // Skip if already loaded in this session to save bandwidth
        final index = _conversations.indexWhere((c) => c.id == contact.id);
        if (index != -1 && _conversations[index].historyLoaded) continue;

        debugPrint('MAM: Syncing ${contact.id}...');
        loadHistory(contact.id, authService);

        // Windows GPU Thrash Protection: 500ms stagger
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      _isSyncing = false;
      debugPrint('MAM: Global Sync Complete.');
      notifyListeners();
    }
  }

  void _handleTyping(String fromJid, String state) {
    final bareJid = fromJid.split('/').first;
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    if (state == 'composing') {
      _conversations[index].isTyping = true;
      _conversations[index].typingUser = fromJid.contains('/')
          ? fromJid.split('/').last
          : fromJid.split('@').first;

      _typingTimers[bareJid]?.cancel();
      _typingTimers[bareJid] = Timer(const Duration(seconds: 5), () {
        _conversations[index].isTyping = false;
        notifyListeners();
      });
    } else {
      _conversations[index].isTyping = false;
      _typingTimers[bareJid]?.cancel();
    }
    notifyListeners();
  }

  void _handleReaction(String fromJid, String msgId, String emoji) {
    final bareJid = fromJid.split('/').first.toLowerCase();
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    final msgIndex = _conversations[index].messages.indexWhere(
      (m) => m.id == msgId,
    );
    if (msgIndex != -1) {
      final msg = _conversations[index].messages[msgIndex];
      msg.reactions[emoji] = [...(msg.reactions[emoji] ?? []), fromJid];
      notifyListeners();
    }
  }

  void _handleReceipt(String fromJid, String msgId) {
    final bareJid = fromJid.split('/').first.toLowerCase();
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    final msgIndex = _conversations[index].messages.indexWhere(
      (m) => m.id == msgId,
    );
    if (msgIndex != -1) {
      _conversations[index].messages[msgIndex].status = MessageStatus.delivered;
      DatabaseService().updateMessageStatus(msgId, MessageStatus.delivered);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _contactSub?.cancel();
    _joinedRoomsSub?.cancel();
    _blockedSub?.cancel();
    _batchTimer?.cancel();
    super.dispose();
  }

  void addMessage(
    String? conversationId,
    ChatMessage message, {
    String? protocol,
    String? chatName,
    bool isGroup = false,
  }) {
    final String rawTarget = conversationId ?? message.conversationId ?? '';
    if (rawTarget.isEmpty) {
      debugPrint(
        'ChatProvider: Dropping message with no conversationId: ${message.text}',
      );
      return;
    }

    // Global Identity Normalization: Strip resource part and lowercase.
    final targetId = rawTarget.split('/').first.toLowerCase();

    // Auto-Group Detection for IRC channels and XMPP MUCs
    bool detectedGroup =
        isGroup || targetId.startsWith('#') || targetId.contains('conference.');

    // Queue the message work
    _batchQueue.add(() {
      try {
        int index = _conversations.indexWhere((c) => c.id == targetId);

        if (index == -1 &&
            (protocol != null ||
                message.protocol != null ||
                message.type == MessageType.system)) {
          final newConv = Conversation(
            id: targetId,
            name: chatName ?? targetId,
            messages: [message],
            protocol:
                protocol ??
                message.protocol ??
                'XMPP', // Fallback to safe default
            accountId: message.accountId,
            isGroup: detectedGroup,
            unreadCount:
                (conversationId != _activeConversationId && !message.isSent)
                ? 1
                : 0,
          );

          _conversations.add(newConv);
          _toPersist.add(message); // Ensure new conversations are persisted

          // Background Load Avatar
          _loadAvatarForConversation(newConv);
        } else if (index != -1) {
          if (message.text == 'UPDATE_PROFILE' &&
              message.type == MessageType.system) {
            final contactId = message.senderId?.split('/').first;
            if (contactId != null) {
              final cIdx = _contacts.indexWhere((c) => c.id == contactId);
              if (cIdx != -1 && message.senderName != null) {
                _contacts[cIdx].name = message.senderName!;
                _loadAvatarForContact(_contacts[cIdx]);
              }
            }
            return;
          }

          // --- 1. Handle Corrections (XEP-0308 / Discord Edit) ---
          final targetIdToReplace = message.replacesId ?? message.id;
          final existingMsgIdx = _conversations[index].messages.indexWhere(
            (m) => m.id == targetIdToReplace,
          );

          if (existingMsgIdx != -1) {
            // UPDATE: Reuse the existing message if it's the same ID (e.g. MAM result vs Live result)
            // OR replace if it's a correction
            _conversations[index].messages[existingMsgIdx] = message;
            _toPersist.add(message);
            return;
          }

          // --- 2. Standard Add logic ---
          // Force-sync group status for IRC channels/MUCs if not already set
          if (detectedGroup && !_conversations[index].isGroup) {
            debugPrint('ChatProvider: Force-promoting $targetId to Group Chat');
            _conversations[index].isGroup = true;
            DatabaseService().updateConversationGroupStatus(targetId, true);
          }

          _conversations[index].messages.add(message);
          // Strictly sort by timestamp to maintain mirroring parity
          _conversations[index].messages.sort(
            (a, b) => a.timestamp.compareTo(b.timestamp),
          );

          if (targetId != _activeConversationId && !message.isSent) {
            _conversations[index].unreadCount++;
            DatabaseService().incrementUnreadCount(targetId);
          }

          // 2. Queue for Disk Persistence (Phase 15 Batching)
          _toPersist.add(message);
        }
      } catch (e, stack) {
        debugPrint('DATA CRASH in addMessage (Queue): $e\n$stack');
      }
    });

    // Mirroring Performance Protection: 250ms batch window
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(const Duration(milliseconds: 250), () {
        if (_batchQueue.isEmpty) {
          _batchTimer = null;
          return;
        }

        for (var task in _batchQueue) {
          task();
        }

        _batchQueue.clear();
        _batchTimer = null; // Reset for next batch
        notifyListeners();

        // I/O Consolidation: Persist all queued messages in a single transaction
        if (_toPersist.isNotEmpty) {
          final messages = List<ChatMessage>.from(_toPersist);
          _toPersist.clear();
          DatabaseService().insertMessagesBatch(messages).catchError((e) {
            debugPrint('DB BATCH INSERT ERROR: $e');
          });
        }
      });
    }
  }

  Future<void> clearHistory(String conversationId) async {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index != -1) {
      _conversations[index].messages.clear();
      notifyListeners();
      await DatabaseService().clearConversationMessages(conversationId);
    }
  }

  Future<void> _handleProfileUpdate(String jid, String? newName) async {
    final bareJid = jid.split('/').first.toLowerCase();

    // 1. Update In-Memory Contacts
    final cIdx = _contacts.indexWhere((c) => c.id == bareJid);
    if (cIdx != -1) {
      if (newName != null) _contacts[cIdx].name = newName;
      _contacts[cIdx].avatarBytes = await AvatarCacheService().getAvatar(
        bareJid,
      );
    }

    // 2. Update In-Memory Conversations
    final convIdx = _conversations.indexWhere((c) => c.id == bareJid);
    if (convIdx != -1) {
      if (newName != null) {
        // We don't want to replace with null if fetched name is missing
        // but we should probably keep existing name if newName is null
      }
      _conversations[convIdx].avatarBytes = await AvatarCacheService()
          .getAvatar(bareJid);
    }
  }

  void setMessageSearchQuery(String query) {
    _messageSearchQuery = query.toLowerCase();
    notifyListeners();
  }

  Future<void> searchAllMessages(String query) async {
    if (query.isEmpty) {
      _globalSearchResults = [];
      notifyListeners();
      return;
    }
    _globalSearchResults = await DatabaseService().searchAllMessages(query);
    notifyListeners();
  }

  void setPlayingMessageId(String? id) {
    _playingMessageId = id;
    notifyListeners();
  }

  void clearAll() {
    _conversations = [];
    _activeConversationId = null;
    notifyListeners();
  }

  Future<void> _loadAvatarForConversation(Conversation conv) async {
    final bytes = await AvatarCacheService().getAvatar(
      conv.id,
      protocol: conv.protocol,
    );
    if (bytes != null) {
      conv.avatarBytes = bytes;
      notifyListeners();
    }
  }

  Future<void> _loadAvatarForContact(Contact contact) async {
    final bytes = await AvatarCacheService().getAvatar(
      contact.id,
      protocol: contact.protocol,
    );
    if (bytes != null) {
      contact.avatarBytes = bytes;
      notifyListeners();
    }
  }

  Future<void> searchGlobalMessages(String query) async {
    if (query.isEmpty) {
      _globalSearchResults = [];
      notifyListeners();
      return;
    }

    _isSyncing = true;
    notifyListeners();

    try {
      final results = await DatabaseService().searchAllMessages(query);
      _globalSearchResults = results;
    } catch (e) {
      debugPrint('GLOBAL SEARCH ERROR: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  // --- SOCIAL MANAGEMENT ---

  Future<void> addContact(
    String jid,
    String name,
    AuthService authService, {
    String protocol = 'XMPP',
  }) async {
    final bareJid = jid.toLowerCase().split('/').first;
    if (protocol == 'XMPP') {
      authService.addContact(bareJid, nickname: name);
    } else {
      // Basic IRC "Contact" Persistence (Local only for this version)
      if (!_contacts.any((c) => c.id == bareJid)) {
        _contacts.add(Contact(id: bareJid, name: name, protocol: 'IRC'));
        notifyListeners();
      }
    }
  }

  Future<void> removeContact(String jid, AuthService authService) async {
    final bareJid = jid.toLowerCase().split('/').first;
    final contact = _contacts.firstWhere(
      (c) => c.id == bareJid,
      orElse: () => Contact(id: bareJid, name: bareJid, protocol: 'XMPP'),
    );
    if (contact.protocol == 'XMPP') {
      await authService.removeContact(bareJid);
    } else {
      _contacts.removeWhere((c) => c.id == bareJid);
      notifyListeners();
    }
  }

  Future<void> respondToSubscription(
    String jid,
    bool accept,
    AuthService authService,
  ) async {
    final bareJid = jid.toLowerCase().split('/').first;
    final accountId =
        _pendingSubscriptions.firstWhere((r) => r['jid'] == jid)['accountId'] ??
        authService.activeAccountId;
    if (accountId == null) return;

    if (accept) {
      authService.acceptSubscription(bareJid);
    } else {
      authService.declineSubscription(bareJid);
    }

    _pendingSubscriptions.removeWhere((r) => r['jid'] == jid);
    notifyListeners();
  }

  Future<void> blockContact(String jid, AuthService authService) async {
    final bareJid = jid.toLowerCase().split('/').first;
    await authService.blockContact(bareJid);
    notifyListeners();
  }

  Future<void> unblockContact(String jid, AuthService authService) async {
    final bareJid = jid.toLowerCase().split('/').first;
    await authService.unblockContact(bareJid);
    notifyListeners();
  }

  Future<void> renameContact(
    String jid,
    String newName,
    AuthService authService,
  ) async {
    final bareJid = jid.toLowerCase().split('/').first;
    await authService.renameContact(bareJid, newName);
    notifyListeners();
  }

  Future<void> addReaction(
    String conversationId,
    String messageId,
    String emoji,
    AuthService auth,
  ) async {
    try {
      final convo = _conversations.firstWhere((c) => c.id == conversationId);
      auth.sendReaction(
        convo.id,
        messageId,
        emoji,
        accountId: convo.accountId,
        isGroup: convo.isGroup,
      );

      // Update local state immediately for better UX
      final msgIdx = convo.messages.indexWhere((m) => m.id == messageId);
      if (msgIdx != -1) {
        final msg = convo.messages[msgIdx];
        final myId = convo.protocol == 'Discord'
            ? 'me'
            : auth.activeAccountId ?? 'me';
        msg.reactions[emoji] = [...(msg.reactions[emoji] ?? []), myId];
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error adding reaction: $e');
    }
  }

  Future<void> deleteMessage(
    String conversationId,
    String messageId,
    AuthService auth,
  ) async {
    try {
      final convo = _conversations.firstWhere((c) => c.id == conversationId);

      if (convo.protocol == 'XMPP') {
        // XMPP: LMC or similar might be needed, but for now simple local remove
        // XEP-0424: Message Retraction could be implemented here
      } else if (convo.protocol == 'Discord') {
        await auth.deleteDiscordMessage(
          convo.id,
          messageId,
          accountId: convo.accountId,
        );
      }

      // Local remove
      convo.messages.removeWhere((m) => m.id == messageId);
      DatabaseService().deleteMessage(messageId);
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting message: $e');
    }
  }

  Future<void> updateMessage(
    String conversationId,
    String messageId,
    String newText,
  ) async {
    try {
      final convo = _conversations.firstWhere((c) => c.id == conversationId);
      final msgIndex = convo.messages.indexWhere((m) => m.id == messageId);

      if (msgIndex != -1) {
        convo.messages[msgIndex].text = newText;
        convo.messages[msgIndex].isEdited = true;
        convo.messages[msgIndex].editTimestamp = DateTime.now();

        // Update in database
        DatabaseService().updateMessage(messageId, newText, isEdited: true);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error updating message: $e');
    }
  }
}
