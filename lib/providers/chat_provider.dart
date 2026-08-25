import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/avatar_cache_service.dart';
import '../services/chat_notification_service.dart';

class ChatProvider with ChangeNotifier {
  List<Conversation> _conversations = [];
  String? _activeConversationId;
  StreamSubscription? _authSub;
  StreamSubscription? _contactSub;
  StreamSubscription? _roomParticipantSub;
  StreamSubscription? _subscriptionSub;
  StreamSubscription? _joinedRoomsSub;
  StreamSubscription? _blockedSub;
  StreamSubscription? _groupInviteSub;
  AuthService? _authService;

  final List<Contact> _contacts = [];
  final List<String> _blockedJids = [];
  final List<Map<String, String>> _pendingSubscriptions = [];
  final List<Map<String, dynamic>> _pendingGroupInvites = [];
  String _messageSearchQuery = '';
  int _selectedSidebarTab =
      0; // 0 for Chats, 1 for Contacts, 2 for Groups, 3 for Dialer, 4 for Profile

  String _searchQuery = '';
  final Map<String, Timer> _typingTimers = {};

  Timer? _batchTimer;
  final List<void Function()> _batchQueue = [];
  final List<ChatMessage> _toPersist = [];
  final Set<String> _pendingIds = {};
  bool _isSyncing = false;
  bool _isLoadingOlderMessages = false;
  final Set<String> _pendingQuoteBackfills = {};
  final Map<String, DateTime> _quoteBackfillAttempts = {};
  List<ChatMessage> _globalSearchResults = [];
  String? _playingMessageId;
  DateTime? _lastSyncTime;
  final Map<String, ConnectionStatus> _lastAccountStatus = {};
  
  // Persistent drafts per conversation
  final Map<String, String> _drafts = {};

  // Story state per contact: {jid: {hasStory, hasUnviewed}}
  final Map<String, bool> _contactHasStory = {};
  final Map<String, bool> _contactHasUnviewedStory = {};

  void _showNotification({
    required String targetId,
    required String convName,
    required String? senderName,
    required String body,
    required String? accountId,
    required bool isGroup,
    required bool muteNotifications,
    required String? senderId,
    required bool mentioned,
  }) {
    if (muteNotifications && !mentioned) return;
    if (senderId != null && _blockedJids.contains(senderId.split('/').first.toLowerCase())) return;
    final preview = body.length > 100 ? '${body.substring(0, 100)}...' : body;
    ChatNotificationService.instance.showMessageNotification(
      conversationId: targetId,
      conversationName: convName,
      senderName: senderName ?? 'Someone',
      body: mentioned ? '[$senderName mentioned you] $preview' : preview,
      accountId: accountId,
      isGroup: isGroup,
    );
  }

  List<Contact> get contacts => _contacts;
  List<String> get blockedJids => _blockedJids;
  List<Map<String, String>> get pendingSubscriptions => _pendingSubscriptions;
  List<Map<String, dynamic>> get pendingGroupInvites => _pendingGroupInvites;
  String get messageSearchQuery => _messageSearchQuery;
  int get selectedSidebarTab => _selectedSidebarTab;
  bool get isSyncing => _isSyncing;
  bool get isLoadingOlderMessages => _isLoadingOlderMessages;
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

  void setDraft(String conversationId, String text) {
    if (text.trim().isEmpty) {
      _drafts.remove(conversationId);
    } else {
      _drafts[conversationId] = text;
    }
  }

  void setPinnedMessage(String conversationId, String? msgId, String? text) {
    try {
      final conv = _conversations.firstWhere((c) => c.id == conversationId);
      conv.pinnedMessageId = msgId;
      conv.pinnedMessageText = text;
      notifyListeners();
    } catch (_) {}
  }

  String getDraft(String conversationId) {
    return _drafts[conversationId] ?? '';
  }

  bool contactHasStory(String jid) => _contactHasStory[jid.toLowerCase()] ?? false;
  bool contactHasUnviewedStory(String jid) => _contactHasUnviewedStory[jid.toLowerCase()] ?? false;

  void updateStoryState(String jid, {required bool hasStory, required bool hasUnviewed}) {
    final key = jid.toLowerCase();
    bool changed = false;
    if ((_contactHasStory[key] ?? false) != hasStory) {
      _contactHasStory[key] = hasStory;
      changed = true;
    }
    if ((_contactHasUnviewedStory[key] ?? false) != hasUnviewed) {
      _contactHasUnviewedStory[key] = hasUnviewed;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void clearStoryState() {
    _contactHasStory.clear();
    _contactHasUnviewedStory.clear();
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
        AuthService.detectProtocol(_activeConversationId!);
        final contact = _contacts.firstWhere(
          (c) => c.id == _activeConversationId,
          orElse: () => Contact(
            id: _activeConversationId!,
            name: _activeConversationId!.split('@').first,
            protocol: 'XMPP',
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
      if (_conversations[index].unreadCount > 0 && _conversations[index].messages.isNotEmpty) {
        final lastMsg = _conversations[index].messages.last;
        if (!lastMsg.isSent && _authService != null) {
          _authService!.sendChatMarker(
            _activeConversationId!,
            lastMsg.id,
            'displayed',
            accountId: _conversations[index].accountId,
            isGroup: _conversations[index].isGroup,
          );
        }
      }

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
      final contact = _contacts.firstWhere(
        (c) => c.id == id,
        orElse: () => Contact(
          id: id,
          name: id.split('@').first,
          protocol: 'XMPP',
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
    }
    notifyListeners();
  }

  Future<void> loadOlderMessages(
    String conversationId,
    AuthService authService,
  ) async {
    if (_isLoadingOlderMessages) {
      return;
    }
    final conv = _conversations.firstWhere(
      (c) => c.id == conversationId,
      orElse: () => Conversation(
        id: conversationId,
        name: conversationId,
        messages: const [],
        protocol: 'XMPP',
      ),
    );
    if (conv.messages.isEmpty) {
      return;
    }

    final oldestId = conv.messages.first.id;
    final accountId = conv.accountId ?? authService.activeAccountId;
    if (accountId == null) return;

    _isLoadingOlderMessages = true;
    notifyListeners();

    if (conv.protocol == 'XMPP') {
      try {
        await authService.fetchOlderHistory(
          accountId,
          conversationId,
          beforeId: oldestId,
        );
      } finally {
        _isLoadingOlderMessages = false;
        notifyListeners();
      }
    } else {
      _isLoadingOlderMessages = false;
      notifyListeners();
    }
  }

  Future<void> initialize(AuthService authService) async {
    _authService = authService;
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
              muteNotifications: c.muteNotifications,
              messagePreview: c.messagePreview,
              notificationSound: c.notificationSound,
              omemoEnabled: c.omemoEnabled,
            ),
          );
          if (c.omemoEnabled) {
            authService.omemoService.setOmemoEnabled(c.id, true);
          }
        }
      }
      notifyListeners();
    } catch (e, stack) {
      debugPrint('DB LOAD ERROR: $e\n$stack');
    }

    // 2. Setup Subscription Listener (Friend Requests)
    _subscriptionSub?.cancel();
    _subscriptionSub = authService.subscriptionRequests.listen((requests) {
      _pendingSubscriptions.clear();
      _pendingSubscriptions.addAll(requests);
      notifyListeners();
    });

    authService.addListener(() {
      _handleAuthChange(authService);
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
      // Cancel typing timer when message received from this JID
      final rawSender = (message.conversationId ?? message.senderId ?? '')
          .split('/')
          .first
          .toLowerCase();
      _typingTimers[rawSender]?.cancel();

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
        chatName: message.isGroup ? targetId : (message.senderName ?? targetId),
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

    // Listen for Signaling Events (Typing, Receipts, Errors)
    authService.jingleEvents.listen((event) {
      if (event.sessionId == 'typing') {
        _handleTyping(event.fromJid, event.reason ?? 'active');
      } else if (event.sessionId == 'reaction') {
        _handleReaction(event.fromJid, event.reason!, event.sdp!);
      } else if (event.sessionId == 'receipt') {
        _handleReceipt(event.fromJid, event.reason!);
      } else if (event.sessionId == 'marker') {
        _handleMarker(event.fromJid, event.reason!);
      } else if (event.sessionId == 'error') {
        _handleMessageError(event.fromJid, event.reason!, event.sdp);
      }
    });

    // 4. Setup Joined Rooms Listener
    _joinedRoomsSub?.cancel();
    _joinedRoomsSub = authService.joinedRoomsStream.listen((rooms) {
      _updateJoinedRooms(rooms);
    });

    _groupInviteSub?.cancel();
    _groupInviteSub = authService.groupInviteStream.listen((invite) {
      _handleIncomingGroupInvite(invite);
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
    _handleAuthChange(authService);
  }

  void _handleIncomingGroupInvite(Map<String, dynamic> invite) {
    // Check if we already have this invite
    final exists = _pendingGroupInvites.any((i) => 
      i['roomJid'] == invite['roomJid'] && i['accountId'] == invite['accountId']);
    
    if (!exists) {
      _pendingGroupInvites.add(invite);
      notifyListeners();
    }
  }

  Future<void> acceptGroupInvite(Map<String, dynamic> invite) async {
    final auth = _authService;
    if (auth != null) {
      final roomJid = invite['roomJid'];
      final accountId = invite['accountId'];
      final nick = auth.getResolvedNickname(accountId);
      
      await auth.joinXmppRoom(roomJid, nick, accountId: accountId);
      _pendingGroupInvites.removeWhere((i) => 
        i['roomJid'] == roomJid && i['accountId'] == accountId);
      
      setActiveConversation(roomJid);
      notifyListeners();
    }
  }

  void declineGroupInvite(Map<String, dynamic> invite) {
    _pendingGroupInvites.removeWhere((i) => 
      i['roomJid'] == invite['roomJid'] && i['accountId'] == invite['accountId']);
    notifyListeners();
  }

  void _updateJoinedRooms(List<Room> rooms) {
    for (var room in rooms) {
      final id = room.id.toLowerCase();
      if (!_conversations.any((c) => c.id.toLowerCase() == id)) {
        final newConv = Conversation(
          id: id,
          name: room.name,
          messages: [],
          protocol: room.protocol,
          accountId: _authService?.activeAccountId,
          isGroup: true,
        );
        _conversations.add(newConv);
        DatabaseService().upsertConversation(newConv);
        notifyListeners();
      }
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
      var targetEmoji = emoji;
      var senderId = fromJid;
      var isRemoval = false;

      if (emoji.trimLeft().startsWith('{')) {
        try {
          final decoded = jsonDecode(emoji);
          if (decoded is Map<String, dynamic>) {
            targetEmoji = (decoded['emoji'] ?? emoji).toString();
            senderId = (decoded['userId'] ?? fromJid).toString();
            isRemoval = decoded['op']?.toString() == 'remove';
          }
        } catch (_) {
          // Non-JSON payload (XMPP) falls back to original values.
        }
      }

      final updated = _applyReactionMutation(
        msg,
        emoji: targetEmoji,
        senderId: senderId,
        isRemoval: isRemoval,
      );
      if (updated) {
        notifyListeners();
        DatabaseService().updateMessageReactions(msg.id, msg.reactions);
      }
    }
  }

  String _canonicalReactionSenderId(String rawSenderId) {
    final trimmed = rawSenderId.trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    return trimmed.split('/').first;
  }

  bool _applyReactionMutation(
    ChatMessage msg, {
    required String emoji,
    required String senderId,
    required bool isRemoval,
  }) {
    final normalizedEmoji = emoji.trim();
    final normalizedSender = _canonicalReactionSenderId(senderId);
    if (normalizedEmoji.isEmpty || normalizedSender.isEmpty) return false;

    final existing = List<String>.from(msg.reactions[normalizedEmoji] ?? const []);
    final deduped = <String>{};
    for (final sender in existing) {
      final canonical = _canonicalReactionSenderId(sender);
      if (canonical.isNotEmpty) {
        deduped.add(canonical);
      }
    }
    final hadDuplicates = deduped.length != existing.length;
    final changedByOp = isRemoval
        ? deduped.remove(normalizedSender)
        : deduped.add(normalizedSender);

    if (deduped.isEmpty) {
      final hadEntry = msg.reactions.containsKey(normalizedEmoji);
      if (hadEntry) {
        msg.reactions.remove(normalizedEmoji);
      }
      return hadDuplicates || hadEntry || changedByOp;
    }

    msg.reactions[normalizedEmoji] = deduped.toList();
    return hadDuplicates || changedByOp;
  }

  void _handleReceipt(String fromJid, String msgId) {
    final bareJid = fromJid.split('/').first.toLowerCase();
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    final msgIndex = _conversations[index].messages.indexWhere(
      (m) => m.id == msgId,
    );
    if (msgIndex != -1) {
      if (_conversations[index].messages[msgIndex].status != MessageStatus.read) {
        _conversations[index].messages[msgIndex].status = MessageStatus.delivered;
        DatabaseService().updateMessageStatus(msgId, MessageStatus.delivered);
        notifyListeners();
      }
    }
  }

  void _handleMarker(String fromJid, String msgId) {
    final bareJid = fromJid.split('/').first.toLowerCase();
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    final msgIndex = _conversations[index].messages.indexWhere(
      (m) => m.id == msgId,
    );
    if (msgIndex != -1) {
      _conversations[index].messages[msgIndex].status = MessageStatus.read;
      DatabaseService().updateMessageStatus(msgId, MessageStatus.read);
      notifyListeners();
    }
  }

  void _handleMessageError(String fromJid, String msgId, String? errorText) {
    final bareJid = fromJid.split('/').first.toLowerCase();
    final index = _conversations.indexWhere((c) => c.id == bareJid);
    if (index == -1) return;

    final msgIndex = _conversations[index].messages.indexWhere(
      (m) => m.id == msgId,
    );
    if (msgIndex != -1) {
      _conversations[index].messages[msgIndex].status = MessageStatus.failed;
      DatabaseService().updateMessageStatus(msgId, MessageStatus.failed);
      debugPrint('ChatProvider: Message $msgId marked as failed: $errorText');
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _contactSub?.cancel();
    _joinedRoomsSub?.cancel();
    _blockedSub?.cancel();
    _subscriptionSub?.cancel();
    _roomParticipantSub?.cancel();
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
        isGroup || message.isGroup || targetId.startsWith('#') || targetId.contains('conference.');

    // Deduplicate against messages already in the pending batch
    if (_pendingIds.contains(message.id)) {
      debugPrint('ChatProvider: Dropping duplicate message ${message.id} (in batch queue)');
      return;
    }
    _pendingIds.add(message.id);

    // Queue the message work
    _batchQueue.add(() {
      try {
        int index = _conversations.indexWhere((c) => c.id == targetId);

        if (index == -1) {
          final newConv = Conversation(
            id: targetId,
            name: chatName ?? targetId,
            messages: [message],
            protocol: protocol ?? message.protocol ?? 'XMPP', // Fallback to safe default
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
            final contactId = message.senderId?.split('/').first.toLowerCase();
            if (contactId != null) {
              final authContacts = _authService?.currentContacts ?? [];
              final authContact = authContacts.where((c) => c.id.toLowerCase() == contactId).toList();
              final cIdx = _contacts.indexWhere((c) => c.id.toLowerCase() == contactId);
              if (cIdx != -1) {
                if (authContact.isNotEmpty) {
                  _contacts[cIdx] = authContact.first;
                } else if (message.senderName != null) {
                  _contacts[cIdx].name = message.senderName!;
                }
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
            _showNotification(
              targetId: targetId,
              convName: _conversations[index].name,
              senderName: message.senderName,
              body: message.text,
              accountId: message.accountId,
              isGroup: _conversations[index].isGroup,
              muteNotifications: _conversations[index].muteNotifications,
              senderId: message.senderId,
              mentioned: message.mentioned,
            );
          } else if (targetId == _activeConversationId && !message.isSent && _authService != null) {
            _authService!.sendChatMarker(
              targetId,
              message.id,
              'displayed',
              accountId: message.accountId,
              isGroup: _conversations[index].isGroup,
            );
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
          _pendingIds.clear(); // Clear after DB write starts, not before
          DatabaseService().insertMessagesBatch(messages).catchError((e) {
            debugPrint('DB BATCH INSERT ERROR: $e');
          });
        } else {
          _pendingIds.clear();
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

    // 1. Update In-Memory Contacts — sync full vCard fields from AuthService
    final authContacts = _authService?.currentContacts ?? [];
    final authContact = authContacts.where((c) => c.id.toLowerCase() == bareJid).toList();
    final cIdx = _contacts.indexWhere((c) => c.id.toLowerCase() == bareJid);
    if (cIdx != -1) {
      if (authContact.isNotEmpty) {
        _contacts[cIdx] = authContact.first;
      } else {
        if (newName != null) _contacts[cIdx].name = newName;
        _contacts[cIdx].avatarBytes = await AvatarCacheService().getAvatar(bareJid);
      }
    }

    // 2. Update In-Memory Conversations
    final convIdx = _conversations.indexWhere((c) => c.id.toLowerCase() == bareJid);
    if (convIdx != -1) {
      if (newName != null) {
      }
      _conversations[convIdx].avatarBytes = await AvatarCacheService().getAvatar(bareJid);
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

  Future<void> leaveGroup(String jid, AuthService authService) async {
    final idx = _conversations.indexWhere((c) => c.id == jid);
    if (idx != -1) {
      final accountId = _conversations[idx].accountId ?? authService.activeAccountId;
      if (accountId != null) {
        await authService.leaveRoom(accountId, jid);
      }
      _conversations.removeAt(idx);
      await DatabaseService().deleteConversation(jid);
      if (_activeConversationId == jid) {
        _activeConversationId = null;
      }
      notifyListeners();
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
    
    // Find accountId safely
    String? accountId;
    try {
      accountId = _pendingSubscriptions.firstWhere((r) => r['jid'] == jid)['accountId'];
    } catch (e) {
      accountId = authService.activeAccountId;
    }
    
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

  void updateContactFromPepNickname(String bareJid, String nickname) {
    final jid = bareJid.toLowerCase().split('/').first;
    final cIdx = _contacts.indexWhere((c) => c.id.toLowerCase() == jid);
    if (cIdx != -1) {
      _contacts[cIdx].name = nickname;
      notifyListeners();
    }
  }

  void updateContactFromPepLastInteraction(String bareJid, DateTime lastInteraction) {
    final jid = bareJid.toLowerCase().split('/').first;
    final cIdx = _contacts.indexWhere((c) => c.id.toLowerCase() == jid);
    if (cIdx != -1) {
      _contacts[cIdx].lastInteraction = lastInteraction;
      notifyListeners();
    }
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
            ? ((convo.accountId ?? auth.activeAccountId ?? '').split('@').first)
            : (auth.activeAccountId ?? 'me');
        final updated = _applyReactionMutation(
          msg,
          emoji: emoji,
          senderId: myId.isNotEmpty ? myId : 'me',
          isRemoval: false,
        );
        if (updated) {
          notifyListeners();
          await DatabaseService().updateMessageReactions(msg.id, msg.reactions);
        }
      }
    } catch (e) {
      debugPrint('Error adding reaction: $e');
    }
  }

  Future<void> ensureQuotedMessageLoaded(
    ChatMessage message,
    AuthService auth,
  ) async {
    final replyToId = message.replyToId?.trim();
    final rawConversationId = message.conversationId?.trim();
    if (replyToId == null ||
        replyToId.isEmpty ||
        rawConversationId == null ||
        rawConversationId.isEmpty) {
      return;
    }

    final conversationId = rawConversationId.split('/').first.toLowerCase();
    final key = '$conversationId|$replyToId';
    final lastAttempt = _quoteBackfillAttempts[key];
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(seconds: 20)) {
      return;
    }
    if (_pendingQuoteBackfills.contains(key)) {
      return;
    }

    _quoteBackfillAttempts[key] = DateTime.now();
    _pendingQuoteBackfills.add(key);
    try {
      final existing = await DatabaseService().getMessageById(replyToId);
      if (existing != null) return;

      final convo = _conversations.cast<Conversation?>().firstWhere(
        (c) => c?.id == conversationId,
        orElse: () => null,
      );
      final protocol = (message.protocol ?? convo?.protocol ?? '').toUpperCase();
      final accountId =
          (message.accountId ?? convo?.accountId ?? auth.activeAccountId)
              ?.trim();
      if (accountId == null || accountId.isEmpty) return;

      if (protocol == 'XMPP') {
        final anchorId = message.id.trim().isNotEmpty ? message.id : null;
        await auth.fetchOlderHistory(
          accountId,
          conversationId,
          beforeId: anchorId,
        );
      }
    } catch (e) {
      debugPrint('Quote backfill failed for $key: $e');
    } finally {
      _pendingQuoteBackfills.remove(key);
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
        await auth.retractXmppMessage(
          convo.id,
          messageId,
          accountId: convo.accountId,
          isGroup: convo.isGroup,
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

  Future<void> removeConversation(String conversationId) async {
    _conversations.removeWhere((c) => c.id == conversationId);
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
    }
    // Delete from DB
    await DatabaseService().deleteConversation(conversationId);
    notifyListeners();
  }

  void _handleAuthChange(AuthService authService) {
    for (var accountId in authService.connectedAccountIds) {
      final currentStatus = authService.getAccountStatus(accountId);
      final lastStatus = _lastAccountStatus[accountId];

      if (currentStatus == ConnectionStatus.online &&
          lastStatus != ConnectionStatus.online) {
        debugPrint(
          'ChatProvider: Account $accountId reconnected. Triggering sync...',
        );
        syncAll(authService, accountId: accountId);
      }
      _lastAccountStatus[accountId] = currentStatus;
    }
  }

  Future<void> syncAll(AuthService authService, {String? accountId}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    notifyListeners();

    try {
      // Sync since last sync time, or last 24 hours if null
      final since = _lastSyncTime ??
          DateTime.now().subtract(const Duration(hours: 24));

      // Iterate through active conversations and request history
      for (var conv in _conversations) {
        if (accountId != null && conv.accountId != accountId) continue;

        // Only sync XMPP conversations
        if (conv.id.contains('@')) {
          authService.fetchXmppHistory(
            conv.id,
            accountId: conv.accountId,
            since: since,
          );
        }
      }
      _lastSyncTime = DateTime.now();
    } catch (e) {
      debugPrint('Sync error: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }
}
