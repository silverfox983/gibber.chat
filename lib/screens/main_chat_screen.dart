import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:async';
import '../widgets/common/empty_state.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../providers/chat_provider.dart';
import '../widgets/group_invite_dialog.dart';
import '../providers/call_provider.dart';
import '../services/call_history_service.dart';
import '../services/pending_join_service.dart';
import '../providers/theme_provider.dart';
import './contacts_screen.dart';
import './feed_screen.dart';
import './profile_screen.dart';
import './spaces_screen.dart';
import '../widgets/navigation/gibber_nav_rail.dart';
import '../widgets/chat/chat_view.dart';
import '../widgets/navigation/gibber_sidebar_header.dart';
import '../widgets/navigation/gibber_conversation_list.dart';

class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isInitialized = false;

  String _searchQuery = '';
  VoidCallback? _signalingListener;
  Timer? _typingDebouncer;
  String? _lastSentChatState;
  DateTime? _lastComposingSent;
  bool _showScrollToBottom = false;
  bool _isTypingMsg = false;
  bool _isSidebarCollapsed = false;

  late AuthService _authService;
  late CallProvider _callProvider;
  int _lastMsgCount = 0;
  String? _lastChatId;

  @override
  void initState() {
    super.initState();
    _authService = Provider.of<AuthService>(context, listen: false);
    _callProvider = Provider.of<CallProvider>(context, listen: false);

    // Resume a pending join from the landing page (pre-auth room selection).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = PendingJoinService.instance.pending;
      if (pending != null && context.mounted) {
        PendingJoinService.instance.take();
        context.pushNamed('joinRoom', queryParameters: {'room': pending.encode()});
      }
    });

    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });

    // GROUP INVITE LISTENER & CHAT SWITCHING (Drafts)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chatProvider = Provider.of<ChatProvider>(context, listen: false);
      chatProvider.addListener(() {
        if (!mounted) return;
        final invites = chatProvider.pendingGroupInvites;
        if (invites.isNotEmpty) {
          _showGroupInviteDialog(invites.first);
        }

        // Handle Active Chat Switching for Drafts
        final currentChatId = chatProvider.activeConversation?.id;
        if (currentChatId != _lastChatId) {
          _lastChatId = currentChatId;
          if (currentChatId != null) {
            final draft = chatProvider.getDraft(currentChatId);
            if (_messageController.text != draft) {
              _messageController.text = draft;
            }
          }
        }
      });
    });

    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        final show = _scrollController.offset > 300;
        if (show != _showScrollToBottom) {
          setState(() => _showScrollToBottom = show);
        }

        // MAM Infinite Scroll: Trigger history load when reaching top
        if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200) {
          if (!mounted) return;
          final cp = Provider.of<ChatProvider>(context, listen: false);
          final activeChat = cp.activeConversation;
          if (activeChat != null && activeChat.protocol == 'XMPP') {
            final firstMsgId = activeChat.messages.isNotEmpty
                ? activeChat.messages.first.id
                : null;
            if (firstMsgId != null && !firstMsgId.startsWith('ping_')) {
              cp.loadHistory(activeChat.id, _authService, beforeId: firstMsgId);
            }
          }
        }
      }
    });

    // HARNESS: Android Audio Context Alignment (Silences AIDL conversion warnings)
    AudioPlayer.global.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.duckOthers},
        ),
      ),
    );

    // Listen for incoming calls
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Initialize renderers
      _callProvider.initRenderers();

      // Hook up Typing Indicators (XEP-0085) & Drafts
      _messageController.addListener(() {
        if (!mounted) return;

        final hasText = _messageController.text.isNotEmpty;
        if (_isTypingMsg != hasText) {
          setState(() => _isTypingMsg = hasText);
        }

        final cp = Provider.of<ChatProvider>(context, listen: false);
        final activeChat = cp.activeConversation;

        if (activeChat != null) {
          cp.setDraft(activeChat.id, _messageController.text);

          final newState = hasText ? 'composing' : 'active';

          final now = DateTime.now();
          if (newState == 'composing' && _lastSentChatState == 'composing') {
            if (_lastComposingSent == null || now.difference(_lastComposingSent!).inSeconds < 5) {
              return;
            }
          }

          if (newState != _lastSentChatState || newState == 'composing') {
            _authService.sendChatState(
              activeChat.id,
              newState,
              isGroup: activeChat.isGroup,
            );
            _lastSentChatState = newState;
            if (newState == 'composing') {
              _lastComposingSent = now;
            }
          }

          if (newState == 'composing') {
            _typingDebouncer?.cancel();
            _typingDebouncer = Timer(const Duration(seconds: 3), () {
              if (mounted && _lastSentChatState != 'paused') {
                _authService.sendChatState(
                  activeChat.id,
                  'paused',
                  isGroup: activeChat.isGroup,
                );
                _lastSentChatState = 'paused';
              }
            });
          }
        } else {
          _typingDebouncer?.cancel();
        }
      });

      _signalingListener = () {
        if (!mounted) return;
        final historyService = Provider.of<CallHistoryService>(
          context,
          listen: false,
        );
        _callProvider.initialize(_authService, historyService);
      };

      _signalingListener!();
      _authService.addListener(_signalingListener!);

      // Auto-create profile if missing
      if (_authService.currentProfile == null) {
        _authService.createProfile('Master User');
      }

      // Sync VCards for existing contacts
      final chatProvider = Provider.of<ChatProvider>(context, listen: false);
      for (var contact in chatProvider.contacts) {
        if (contact.protocol == 'XMPP') {
          _authService.fetchVCard(
            _authService.activeAccountId ?? '',
            contact.id,
          );
        }
      }
    });
  }

  void _showGroupInviteDialog(Map<String, dynamic> invite) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => GroupInviteDialog(invite: invite),
    );
  }

  @override
  void dispose() {
    debugPrint('LIFECYCLE: MainChatScreen DISPOSED');
    if (_signalingListener != null) {
      _authService.removeListener(_signalingListener!);
    }

    _messageController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _typingDebouncer?.cancel();
    super.dispose();
  }

  void _showSubscriptionRequests() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Consumer<ChatProvider>(
        builder: (context, provider, _) => ListView.builder(
          itemCount: provider.pendingSubscriptions.length,
          itemBuilder: (context, index) {
            final req = provider.pendingSubscriptions[index];
            return ListTile(
              title: Text(req['jid'] ?? 'Unknown'),
              subtitle: const Text('Sent you a friend request'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.check, color: Colors.green),
                    onPressed: () => provider.respondToSubscription(
                      req['jid']!,
                      true,
                      _authService,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red),
                    onPressed: () => provider.respondToSubscription(
                      req['jid']!,
                      false,
                      _authService,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _scrollToBottom() {
    if (!mounted) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    try {
      final chatProvider = Provider.of<ChatProvider>(context);
      _authService = Provider.of<AuthService>(context);
      final activeChat = chatProvider.activeConversation;

      // Smart Viewport Synchronization (Stick-to-Bottom Logic)
      if (activeChat != null) {
        if (_lastChatId != activeChat.id) {
          _lastChatId = activeChat.id;
          _lastSentChatState = null;
          _lastMsgCount = activeChat.messages.length;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
        } else if (_lastMsgCount < activeChat.messages.length) {
          _lastMsgCount = activeChat.messages.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              final pos = _scrollController.position;
              // If user is within 100px of bottom, stick to bottom
              if (pos.pixels > pos.maxScrollExtent - 100) {
                _scrollToBottom();
              }
            }
          });
        }
      }

      // Automated Sync Restoration (Safe-Throttled)
      if (!_isInitialized) {
        chatProvider.initialize(_authService);
        // Staggered global sync after roster load
        Future.delayed(
          const Duration(seconds: 1),
          () => chatProvider.syncAll(_authService),
        );
        _isInitialized = true;
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          final bool isMobile = constraints.maxWidth < 600;

          if (isMobile) {
            return _buildMobileLayout(chatProvider, _authService, activeChat);
          } else {
            return _buildDesktopLayout(chatProvider, _authService, activeChat);
          }
        },
      );
    } catch (e, stack) {
      debugPrint('NUCLEAR BUILD CRASH: $e\n$stack');
      return Container(color: Colors.red);
    }
  }

  Widget _buildMobileLayout(
    ChatProvider chatProvider,
    AuthService authService,
    Conversation? activeChat,
  ) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: activeChat != null
          ? null
          : AppBar(
              title: Row(
                children: [
                  Image.asset(
                    'assets/logo.png',
                    height: 28,
                    width: 28,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'GIBBER',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      color: Theme.of(context).appBarTheme.foregroundColor,
                    ),
                  ),
                ],
              ),
              backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
              elevation: 0,
              actions: [
                Consumer<ThemeProvider>(
                  builder: (context, tp, _) => IconButton(
                    icon: Icon(
                      tp.isDarkMode
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                      color: Theme.of(context).appBarTheme.foregroundColor,
                      size: 20,
                    ),
                    onPressed: () => tp.toggleTheme(),
                    tooltip: 'Toggle Theme',
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.travel_explore_rounded,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                    size: 20,
                  ),
                  onPressed: () => context.goNamed('search'),
                  tooltip: 'Nexus Global Search',
                ),
                IconButton(
                  icon: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: _getStatusColor(authService.myStatus),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  ),
                  onPressed: () => _showStatusPickerInline(authService),
                  tooltip: 'Set Status',
                ),
                PopupMenuButton<String>(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
                  ),
                  onSelected: (val) => _onAddActionSelected(val, authService),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'newMessage',
                      child: Row(
                        children: [
                          Icon(Icons.chat_bubble_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('New Message', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'buddy',
                      child: Row(
                        children: [
                          Icon(Icons.person_add_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Add Buddy', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'group',
                      child: Row(
                        children: [
                          Icon(Icons.group_add_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Create/Join Group', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'invite',
                      child: Row(
                        children: [
                          Icon(Icons.person_add_alt_1_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Invite Friends', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'connections',
                      child: Row(
                        children: [
                          Icon(Icons.hub_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Connections', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: Column(
        children: [
          if (chatProvider.pendingSubscriptions.isNotEmpty)
            InkWell(
              onTap: _showSubscriptionRequests,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Text(
                  '\${chatProvider.pendingSubscriptions.length} Pending Friend Requests',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          Expanded(
            child: activeChat != null
                ? ChatView(conversation: activeChat, chatProvider: chatProvider, authService: authService)
                : _buildSidebarContent(chatProvider, authService),
          ),
        ],
      ),
      floatingActionButton: null,
      bottomNavigationBar: activeChat != null
          ? null
          : BottomNavigationBar(
              currentIndex: chatProvider.selectedSidebarTab,
              onTap: (index) => chatProvider.setSidebarTab(index),
              selectedItemColor: Theme.of(context).colorScheme.primary,
              unselectedItemColor: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.chat_bubble_outline),
                  label: 'Chats',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.people_outline),
                  label: 'Contacts',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.dynamic_feed_rounded),
                  label: 'Feed',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.workspaces_outline),
                  label: 'Spaces',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  label: 'Profile',
                ),
              ],
            ),
    );
  }

  Widget _buildDesktopLayout(
    ChatProvider chatProvider,
    AuthService authService,
    Conversation? activeChat,
  ) {
    final selectedTab = chatProvider.selectedSidebarTab;
    final isFeedOrSpaces = selectedTab == 2 || selectedTab == 3;
    final showSidebar = !isFeedOrSpaces;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Row(
        children: [
          _buildNavRail(chatProvider, authService),
          if (showSidebar)
            _buildSidebarLayout(
              chatProvider,
              authService,
              false,
              onCollapseSidebar: () => setState(() => _isSidebarCollapsed = true),
            ),
          Expanded(
            child: _buildDesktopContent(
              chatProvider: chatProvider,
              authService: authService,
              activeChat: activeChat,
              selectedTab: selectedTab,
              isFeedOrSpaces: isFeedOrSpaces,
              showSidebar: showSidebar,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopContent({
    required ChatProvider chatProvider,
    required AuthService authService,
    required Conversation? activeChat,
    required int selectedTab,
    required bool isFeedOrSpaces,
    required bool showSidebar,
  }) {
    if (isFeedOrSpaces && activeChat == null) {
      return selectedTab == 2 ? const FeedScreen() : const SpacesScreen();
    }
    if (activeChat != null) {
      return ChatView(
        conversation: activeChat,
        chatProvider: chatProvider,
        authService: authService,
      );
    }
    if (showSidebar) {
      return _buildSidebarContent(chatProvider, authService);
    }
    return const SizedBox.shrink();
  }

  Widget _buildSidebarLayout(
    ChatProvider chatProvider,
    AuthService authService,
    bool isMobile, {
    VoidCallback? onCollapseSidebar,
  }) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outline,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          GibberSidebarHeader(
            chatProvider: chatProvider,
            authService: authService,
            onCollapseSidebar: onCollapseSidebar,
          ),
          Expanded(child: _buildSidebarContent(chatProvider, authService)),
        ],
      ),
    );

    if (isMobile) return content;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.centerLeft,
      child: _isSidebarCollapsed
          ? const SizedBox(width: 0)
          : SizedBox(
              width: 320,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: 1.0,
                child: ClipRect(child: content),
              ),
            ),
    );
  }

  Widget _buildNavRail(ChatProvider chatProvider, AuthService authService) {
    return GibberNavRail(
      selectedIndex: chatProvider.selectedSidebarTab,
      onDestinationSelected: (idx) {
        debugPrint('ISOLATE: Selected Tab $idx');
        chatProvider.setSidebarTab(idx);
      },
      onToggleSidebar: () => setState(() => _isSidebarCollapsed = !_isSidebarCollapsed),
      sidebarCollapsed: _isSidebarCollapsed,
    );
  }

  Widget _buildSidebarContent(
    ChatProvider chatProvider,
    AuthService authService,
  ) {
    return IndexedStack(
      index: chatProvider.selectedSidebarTab,
      children: [
        GibberConversationList(searchQuery: _searchQuery, authService: authService),
        const ContactsScreen(),
        const FeedScreen(),
        const SpacesScreen(),
        const ProfileScreen(isSidebar: true),
        _buildGlobalSearchList(chatProvider),
      ],
    );
  }

  Widget _buildGlobalSearchList(ChatProvider chatProvider) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: 'Search all messages...',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (val) {
              chatProvider.searchAllMessages(val);
            },
          ),
        ),
        Expanded(
          child: chatProvider.globalSearchResults.isEmpty
              ? EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No results',
                  subtitle: 'Try a different search term',
                )
              : ListView.builder(
                  itemCount: chatProvider.globalSearchResults.length,
                  itemBuilder: (context, index) {
                    final msg = chatProvider.globalSearchResults[index];
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.message_outlined),
                      ),
                      title: Text(
                        msg.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        'From: ${msg.senderName ?? msg.conversationId}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () async {
                        await chatProvider.setActiveConversation(
                          msg.conversationId,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showStatusPickerInline(AuthService authService) {
    final statusCtrl = TextEditingController(text: authService.myStatusMessage);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          top: 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set Presence Status',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Theme.of(ctx).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: statusCtrl,
              decoration: InputDecoration(
                hintText: "What's on your mind?",
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ...ContactStatus.values.map((status) {
              if (status == ContactStatus.offline) return const SizedBox.shrink();
              return ListTile(
                leading: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _getStatusColor(status),
                    shape: BoxShape.circle,
                  ),
                ),
                title: Text(
                  status.name.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                onTap: () {
                  authService.updatePresence(status, message: statusCtrl.text.trim());
                  Navigator.pop(ctx);
                },
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _onAddActionSelected(String val, AuthService authService) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    if (val == 'newMessage') {
      context.goNamed('newMessage');
      return;
    }
    if (val == 'buddy') chatProvider.setSidebarTab(1);
    if (val == 'group') _showJoinRoomDialog(authService);
    if (val == 'invite') {
      context.goNamed('invite');
    }
    if (val == 'connections') {
      context.goNamed('connections');
    }
  }

  Color _getStatusColor(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return Colors.greenAccent;
      case ContactStatus.away:
        return Colors.orangeAccent;
      case ContactStatus.dnd:
        return Colors.redAccent;
      case ContactStatus.offline:
        return Colors.grey;
      case ContactStatus.xa:
        return Colors.deepOrangeAccent;
    }
  }

  void _showJoinRoomDialog(AuthService authService) {
    final roomCtrl = TextEditingController();
    final nickCtrl = TextEditingController(
      text: authService.getResolvedNickname(authService.activeAccountId),
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          'Join Room / Channel',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: roomCtrl,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                labelText: 'Group Identifier',
                labelStyle: TextStyle(color: Theme.of(context).hintColor),
                hintText: '#channel or room@conference.domain.com',
                hintStyle: TextStyle(
                  color: Theme.of(context).hintColor.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nickCtrl,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                labelText: 'Your Nickname',
                labelStyle: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final String target = roomCtrl.text.trim();
              if (target.isNotEmpty) {
                final domain =
                    authService.activeAccountId?.split('@').last ??
                    'chat.example.com';
                final jid = target.contains('@')
                    ? target.toLowerCase()
                    : '${target.toLowerCase().replaceAll("#", "")}@conference.$domain';

                Navigator.pop(context);
                final error = await authService.joinXmppRoom(
                  jid,
                  nickCtrl.text.trim(),
                );

                if (error != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Join Result: $error'),
                      backgroundColor: error.startsWith('Unknown')
                          ? Colors.redAccent
                          : Colors.blueAccent,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              }
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

}
