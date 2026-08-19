import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../core/app_colors.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:giphy_get/giphy_get.dart';
import '../widgets/link_preview.dart';
import '../widgets/audio_waveform.dart';
import '../widgets/typing_indicator.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../providers/chat_provider.dart';
import '../widgets/group_invite_dialog.dart';
import '../providers/call_provider.dart';
import '../services/database_service.dart';
import './call_screen.dart';
import '../services/call_history_service.dart';
import '../models/call_log.dart';
import '../widgets/omemo_trust_dialog.dart';
import '../widgets/room_participants_dialog.dart';
import '../providers/theme_provider.dart';
import '../services/xep_0392_service.dart';
import '../services/backend_config.dart';
import './contacts_screen.dart';
import './feed_screen.dart';
import './nexus_search_screen.dart';
import './profile_screen.dart';
import './welcome_dashboard.dart';
import './spaces_screen.dart';
import '../widgets/navigation/gibber_nav_rail.dart';
import '../widgets/chat/chat_view.dart';
import '../widgets/navigation/gibber_sidebar_header.dart';
import '../widgets/navigation/gibber_conversation_list.dart';

class HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final TextStyle? highlightStyle;
  final int? maxLines;
  final TextOverflow? overflow;

  const HighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.highlightStyle,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final matches = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) {
        matches.add(TextSpan(text: text.substring(start)));
        break;
      }

      if (index > start) {
        matches.add(TextSpan(text: text.substring(start, index)));
      }

      matches.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style:
              highlightStyle ??
              TextStyle(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.5),
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
        ),
      );

      start = index + query.length;
    }

    return RichText(
      text: TextSpan(
        style:
            style ?? TextStyle(color: Theme.of(context).colorScheme.onSurface),
        children: matches,
      ),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}

class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer(); // RESTORED
  // int _buildCount = 0; // Unused in Safe-List Phase
  bool _isRecording = false;
  bool _isInitialized = false;
  bool _isSearchingMessages = false;
  final TextEditingController _msgSearchController = TextEditingController();

  String _searchQuery = '';
  VoidCallback? _signalingListener;
  String _dialedNumber = '';
  ChatMessage? _replyToMessage;
  Timer? _typingDebouncer;
  String? _lastSentChatState;
  bool _showScrollToBottom = false;
  bool _isTypingMsg = false;
  final Set<String> _requestedQuoteBackfills = {};

  late AuthService _authService;
  late CallProvider _callProvider;
  int _lastMsgCount = 0;
  String? _lastChatId;

  @override
  void initState() {
    super.initState();
    _authService = Provider.of<AuthService>(context, listen: false);
    _callProvider = Provider.of<CallProvider>(context, listen: false);

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

          if (newState != _lastSentChatState) {
            _authService.sendChatState(
              activeChat.id,
              newState,
              isGroup: activeChat.isGroup,
            );
            _lastSentChatState = newState;
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

      // Automated Call Navigation: Show call screen when state changes
      _callProvider.addListener(_onCallStateChanged);

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

  bool _canStartVoiceCall(Conversation chat) {
    return chat.protocol == 'XMPP' && !chat.isGroup;
  }

  bool _canStartVideoCall(Conversation chat) {
    return chat.protocol == 'XMPP' && !chat.isGroup;
  }

  /*
  void _onCallErrorChanged() {
    ...
  }
  */

  @override
  void dispose() {
    debugPrint('LIFECYCLE: MainChatScreen DISPOSED');
    _callProvider.removeListener(_onCallStateChanged);
    if (_signalingListener != null) {
      _authService.removeListener(_signalingListener!);
    }

    _messageController.dispose();
    _msgSearchController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _typingDebouncer?.cancel();
    _requestedQuoteBackfills.clear();
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

  void _onCallStateChanged() {
    if (!mounted) return;
    if (_callProvider.state != CallState.idle) {
      // Prevent multiple navigations if already on the screen
      final currentRoute = ModalRoute.of(context)?.settings.name;
      if (currentRoute != '/call_screen') {
        Navigator.of(context).push(
          MaterialPageRoute(
            settings: const RouteSettings(name: '/call_screen'),
            builder: (context) => const CallScreen(),
          ),
        );
      }
    }
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

  Future<void> _pickImage(Conversation activeChat) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      _showUploadPreview(activeChat, File(pickedFile.path), isImage: true);
    }
  }

  Future<void> _pickFile(Conversation activeChat) async {
    if (activeChat.protocol == 'IRC') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File sharing is not supported over basic IRC.'),
        ),
      );
      return;
    }
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
    if (result != null && result.files.single.path != null) {
      _showUploadPreview(
        activeChat,
        File(result.files.single.path!),
        isImage: false,
      );
    }
  }

  Future<void> _pickGif(Conversation activeChat) async {
    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    final apiKey = backendConfig.giphyApiKey ?? 'dc6zaTOxFJmzC'; // Demo key fallback
    final gif = await GiphyGet.getGif(
      context: context,
      apiKey: apiKey,
      tabColor: Theme.of(context).colorScheme.primary,
    );
    if (gif != null && gif.images?.original?.url != null) {
      final url = gif.images!.original!.url;
      _sendMessage(activeChat, textOverride: url);
    }
  }

  void _showUploadPreview(
    Conversation activeChat,
    File file, {
    required bool isImage,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          isImage ? 'Send Image?' : 'Send File?',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(file, height: 200, fit: BoxFit.cover),
              )
            else
              ListTile(
                leading: Icon(
                  Icons.insert_drive_file,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(file.path.split(RegExp(r'[/\\]')).last),
                subtitle: Text(
                  '${(file.lengthSync() / 1024).toStringAsFixed(1)} KB',
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            onPressed: () {
              Navigator.pop(context);
              _uploadAndSend(
                activeChat,
                file,
                isImage ? MessageType.image : MessageType.file,
              );
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadAndSend(
    Conversation activeChat,
    File file,
    MessageType type,
  ) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text('Uploading ${type.name}...'),
            ],
          ),
          duration: const Duration(seconds: 2),
        ),
      );

      await _authService.sendMediaMessage(
        activeChat.id,
        file,
        type,
        accountId: activeChat.accountId,
        isGroup: activeChat.isGroup,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _playVoice(ChatMessage msg) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    if (chatProvider.playingMessageId == msg.id) {
      await _audioPlayer.stop();
      chatProvider.setPlayingMessageId(null);
      return;
    }

    try {
      chatProvider.setPlayingMessageId(msg.id);
      Source source;
      if (msg.text.startsWith('http')) {
        source = UrlSource(msg.text);
      } else {
        source = DeviceFileSource(msg.text);
      }

      await _audioPlayer.play(source);
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (chatProvider.playingMessageId == msg.id) {
          chatProvider.setPlayingMessageId(null);
        }
      });
    } catch (e) {
      debugPrint('PLAY VOICE ERROR: $e');
      chatProvider.setPlayingMessageId(null);
    }
  }

  Future<void> _toggleVoiceRecording(Conversation activeChat) async {
    if (activeChat.protocol == 'IRC') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice messages are not supported over basic IRC.'),
        ),
      );
      return;
    }

    if (_isRecording) {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        _uploadAndSend(activeChat, File(path), MessageType.voice);
      }
    } else {
      if (await _audioRecorder.hasPermission()) {
        if (kIsWeb) return;
        final docsDir = await getApplicationDocumentsDirectory();
        final exportDir = Directory('${docsDir.path}/GibberExport/VoiceNotes');
        if (!await exportDir.exists()) {
          await exportDir.create(recursive: true);
        }

        final path =
            '${exportDir.path}/VoiceNote_${activeChat.id.split("@").first}_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() => _isRecording = true);

        // Haptic Feedback for recording start
        HapticFeedback.mediumImpact();
      }
    }
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
                      value: 'discover',
                      child: Row(
                        children: [
                          Icon(Icons.explore_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Discover Rooms', style: TextStyle(fontSize: 13)),
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
                      value: 'gateways',
                      child: Row(
                        children: [
                          Icon(Icons.dns_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Manage Server Gateways', style: TextStyle(fontSize: 13)),
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
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Row(
        children: [
          _buildNavRail(chatProvider, authService),
          _buildSidebarLayout(chatProvider, authService, false),
            Expanded(child: activeChat != null
                ? ChatView(conversation: activeChat, chatProvider: chatProvider, authService: authService)
                : _buildSidebarContent(chatProvider, authService)),
        ],
      ),
    );
  }

  Widget _buildChatContent(Conversation? activeChat) {
    if (activeChat == null) {
      return const WelcomeDashboard();
    }
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    return Column(
      children: [
        AppBar(
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          elevation: 0,
          leading: _isSearchingMessages
              ? IconButton(
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    setState(() => _isSearchingMessages = false);
                    _msgSearchController.clear();
                    chatProvider.setMessageSearchQuery('');
                  },
                )
              : IconButton(
                  icon: Icon(
                    MediaQuery.of(context).size.width < 600
                        ? Icons.arrow_back_ios_new_rounded
                        : Icons.close_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 20,
                  ),
                  onPressed: () => Provider.of<ChatProvider>(
                    context,
                    listen: false,
                  ).setActiveConversation(null),
                ),
          title: _isSearchingMessages
              ? TextField(
                  controller: _msgSearchController,
                  autofocus: true,
                  style: const TextStyle(fontSize: 16),
                  onChanged: (val) => chatProvider.setMessageSearchQuery(val),
                  decoration: const InputDecoration(
                    hintText: 'Search messages...',
                    border: InputBorder.none,
                  ),
                )
              : Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          backgroundImage: activeChat.avatarBytes != null
                              ? MemoryImage(activeChat.avatarBytes!)
                              : null,
                          child: activeChat.avatarBytes == null
                              ? Text(
                                  activeChat.name.isNotEmpty
                                      ? activeChat.name[0]
                                      : '?',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                        if (!activeChat.isGroup)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _getStatusColor(activeChat.status),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  activeChat.name,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              FutureBuilder<int>(
                                future: _authService.getChatSecurityStatus(
                                  activeChat.id,
                                ),
                                builder: (context, snapshot) {
                                  final status = snapshot.data ?? -1;
                                  if (status == 1) {
                                    // Trusted
                                    return const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Icon(
                                        Icons.verified_user_rounded,
                                        color: Colors.green,
                                        size: 14,
                                      ),
                                    );
                                  } else if (status == 2) {
                                    // Distrusted
                                    return const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Icon(
                                        Icons.gpp_bad_rounded,
                                        color: Colors.red,
                                        size: 14,
                                      ),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                            ],
                          ),
                          if (activeChat.isTyping)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TypingIndicator(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      activeChat.typingUser != null
                                          ? '${activeChat.typingUser} is typing'
                                          : 'Typing...',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.8),
                                        fontSize: 12,
                                        fontStyle: FontStyle.italic,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        activeChat.isGroup
                                            ? '${activeChat.protocol} Group'
                                            : activeChat.protocol,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                              .withValues(alpha: 0.5),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_authService.otrService
                                        .isOtrSessionActive(
                                          activeChat.id.split('/').first,
                                        )) ...[
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.lock_rounded,
                                              size: 10,
                                              color: Colors.greenAccent,
                                            ),
                                            const SizedBox(width: 2),
                                            Flexible(
                                              child: Text(
                                                'OTR ENCRYPTED',
                                                style: TextStyle(
                                                  color: Colors.greenAccent,
                                                  fontSize: 8,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 0.5,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ] else if (_authService.isOmemoEnabled(
                                      activeChat.id,
                                    )) ...[
                                      const SizedBox(width: 4),
                                      FutureBuilder<int>(
                                        future: _authService
                                            .getChatSecurityStatus(
                                              activeChat.id,
                                            ),
                                        builder: (context, snapshot) {
                                          final status = snapshot.data ?? 0;
                                          Color statusColor;
                                          IconData statusIcon;
                                          String statusText;

                                          switch (status) {
                                            case 1:
                                              statusColor = Theme.of(
                                                context,
                                              ).colorScheme.primary;
                                              statusIcon =
                                                  Icons.security_rounded;
                                              statusText = 'ENCRYPTED';
                                              break;
                                            case 2:
                                              statusColor = Colors.red;
                                              statusIcon =
                                                  Icons.gpp_bad_rounded;
                                              statusText = 'UNVERIFIED';
                                              break;
                                            case 0:
                                            default:
                                              statusColor = Colors.orange;
                                              statusIcon =
                                                  Icons.gpp_maybe_rounded;
                                              statusText = 'UNVERIFIED';
                                              break;
                                          }

                                          return Flexible(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  statusIcon,
                                                  size: 10,
                                                  color: statusColor,
                                                ),
                                                const SizedBox(width: 2),
                                                Flexible(
                                                  child: Text(
                                                    statusText,
                                                    style: TextStyle(
                                                      color: statusColor,
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      letterSpacing: 0.5,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                                if (activeChat.topic != null &&
                                    activeChat.topic!.isNotEmpty)
                                  Text(
                                    activeChat.topic!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.secondary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
          actions: [
            if (_canStartVoiceCall(activeChat))
              IconButton(
                icon: Icon(
                  Icons.call_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                tooltip: 'Start Audio Call',
                onPressed: () {
                  final cp = Provider.of<CallProvider>(context, listen: false);
                  cp.startCall(
                    activeChat.id,
                    accountId: activeChat.accountId,
                    isVideo: false,
                    protocol: activeChat.protocol,
                  );
                },
              ),
              if (!activeChat.isGroup)
                FutureBuilder<int>(
                  future: _authService.getChatSecurityStatus(activeChat.id),
                  builder: (context, snapshot) {
                    final status = snapshot.data ?? 0;
                    final isEnabled = _authService.isOmemoEnabled(activeChat.id);

                    IconData icon;
                    Color color;

                    if (!isEnabled) {
                      icon = Icons.lock_open_rounded;
                      color = Theme.of(context).disabledColor;
                    } else {
                      switch (status) {
                        case 1:
                          icon = Icons.verified_user_rounded;
                          color = Colors.green;
                          break;
                        case 2:
                          icon = Icons.gpp_bad_rounded;
                          color = Colors.red;
                          break;
                        case 0:
                        default:
                          icon = Icons.gpp_maybe_rounded;
                          color = Colors.orange;
                          break;
                      }
                    }

                    return IconButton(
                      icon: Icon(icon, color: color),
                      tooltip: isEnabled
                          ? 'Identity Trust & Encryption'
                          : 'Enable Encryption',
                      onPressed: () {
                        if (isEnabled) {
                          showDialog(
                            context: context,
                            builder: (context) => OmemoTrustDialog(
                              chatId: activeChat.id,
                              chatName: activeChat.name,
                              accountId: activeChat.accountId,
                            ),
                          );
                        } else {
                          _authService.toggleOmemo(activeChat.id);
                        }
                      },
                    );
                  },
                ),
              if (activeChat.isGroup)
                FutureBuilder<int>(
                  future: _authService.getGroupParticipantKeyStatus(activeChat.id),
                  builder: (context, snapshot) {
                    final participantCount = snapshot.data ?? 0;
                    final isEnabled = _authService.isOmemoEnabled(activeChat.id);
                    
                    IconData icon;
                    Color color;
                    String tooltip;

                    if (!isEnabled) {
                      icon = Icons.group_add_outlined;
                      color = Theme.of(context).disabledColor;
                      tooltip = 'Group encryption disabled';
                    } else if (participantCount == 0) {
                      icon = Icons.group_outlined;
                      color = Theme.of(context).disabledColor;
                      tooltip = 'No participant keys loaded';
                    } else {
                      icon = Icons.group_rounded;
                      color = Colors.green;
                      tooltip = '$participantCount participant(s) with encryption keys';
                    }

                    return IconButton(
                      icon: Icon(icon, color: color),
                      tooltip: tooltip,
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => OmemoTrustDialog(
                            chatId: activeChat.id,
                            chatName: activeChat.name,
                            accountId: activeChat.accountId,
                            isGroupChat: true,
                          ),
                        );
                      },
                    );
                  },
                ),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert_rounded,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              onSelected: (val) {
                final cp = Provider.of<ChatProvider>(context, listen: false);
                if (val == 'clear') {
                  cp.clearHistory(activeChat.id);
                } else if (val == 'delete') {
                  cp.removeConversation(activeChat.id);
                } else if (val == 'block') {
                  cp.blockContact(activeChat.id, _authService);
                } else if (val == 'remove') {
                  cp.removeContact(activeChat.id, _authService);
                  cp.setActiveConversation(null);
                } else if (val == 'leave') {
                  cp.leaveGroup(activeChat.id, _authService);
                } else if (val == 'sync') {
                  cp.loadHistory(activeChat.id, _authService);
                } else if (val == 'info') {
                  _showRoomInfo(activeChat);
                } else if (val == 'invite') {
                  _showInviteDialog(activeChat);
                } else if (val == 'participants') {
                  showDialog(
                    context: context,
                    builder: (context) => RoomParticipantsDialog(
                      roomJid: activeChat.id,
                      roomName: activeChat.name,
                    ),
                  );
                } else if (val == 'settings') {
                  context.goNamed('roomSettings', extra: {'room': activeChat});
                } else if (val == 'call') {
                  Provider.of<CallProvider>(context, listen: false).startCall(
                    activeChat.id,
                    accountId: activeChat.accountId,
                    isVideo: false,
                    protocol: activeChat.protocol,
                  );
                } else if (val == 'video') {
                  Provider.of<CallProvider>(context, listen: false).startCall(
                    activeChat.id,
                    accountId: activeChat.accountId,
                    isVideo: true,
                    protocol: activeChat.protocol,
                  );
                } else if (val == 'security') {
                  context.goNamed('security');
                } else if (val == 'otr') {
                  final bareJid = activeChat.id.split('/').first;
                  if (_authService.otrService.isOtrSessionActive(bareJid)) {
                    _authService.otrService.endSession(bareJid);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('OTR Session Ended')),
                    );
                  } else {
                    _authService.otrService.startSession(bareJid);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Starting OTR Negotiation...'),
                      ),
                    );
                    // Also send a query message to peer
                    if (activeChat.accountId != null) {
                      _authService.sendMessage(
                        activeChat.accountId!,
                        activeChat.id,
                        '?OTR?',
                      );
                    }
                  }
                  setState(() {});
                } else if (val == 'add_contact') {
                  _authService.addContact(
                    activeChat.id,
                    accountId: activeChat.accountId,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Contact request sent!')),
                  );
                }
              },
              itemBuilder: (context) {
                final isContact = _authService.currentContacts.any(
                  (c) =>
                      c.id.split('/').first == activeChat.id.split('/').first,
                );
                return [
                  if (!activeChat.isGroup && !isContact)
                    const PopupMenuItem(
                      value: 'add_contact',
                      child: ListTile(
                        leading: Icon(Icons.person_add_rounded),
                        title: Text('Add to Contacts'),
                      ),
                    ),
                  if (activeChat.isGroup) ...[
                    const PopupMenuItem(
                      value: 'info',
                      child: ListTile(
                        leading: Icon(Icons.info_outline),
                        title: Text('Room Info'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'invite',
                      child: ListTile(
                        leading: Icon(Icons.person_add_alt_1_rounded),
                        title: Text('Invite Participant'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'participants',
                      child: ListTile(
                        leading: Icon(Icons.people_outline),
                        title: Text('Participants'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'settings',
                      child: ListTile(
                        leading: Icon(Icons.settings_rounded),
                        title: Text('Room Settings'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'leave',
                      child: ListTile(
                        leading: Icon(
                          Icons.exit_to_app_rounded,
                          color: Colors.redAccent,
                        ),
                        title: Text(
                          'Leave Group',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ),
                    const PopupMenuDivider(),
                  ],
                  if (_canStartVoiceCall(activeChat))
                    PopupMenuItem(
                      value: 'call',
                      child: ListTile(
                        leading: const Icon(Icons.call_outlined),
                        title: const Text('Voice Call'),
                      ),
                    ),
                  if (_canStartVideoCall(activeChat))
                    const PopupMenuItem(
                      value: 'video',
                      child: ListTile(
                        leading: Icon(Icons.videocam_outlined),
                        title: Text('Video Call'),
                      ),
                    ),
                  if (!activeChat.isGroup)
                    PopupMenuItem(
                      value: 'otr',
                      child: ListTile(
                        leading: Icon(
                          _authService.otrService.isOtrSessionActive(
                                activeChat.id.split('/').first,
                              )
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          color: Colors.greenAccent,
                        ),
                        title: Text(
                          _authService.otrService.isOtrSessionActive(
                                activeChat.id.split('/').first,
                              )
                              ? 'End OTR Session'
                              : 'Encrypt with OTR',
                        ),
                      ),
                    ),

                  const PopupMenuItem(
                    value: 'security',
                    child: ListTile(
                      leading: Icon(
                        Icons.security_rounded,
                        color: Colors.blueAccent,
                      ),
                      title: Text('Security Details'),
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'sync',
                    child: ListTile(
                      leading: Icon(Icons.sync),
                      title: Text('Sync History'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear',
                    child: ListTile(
                      leading: Icon(
                        Icons.cleaning_services_outlined,
                        color: Colors.orange,
                      ),
                      title: Text(
                        'Clear Messages',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline, color: Colors.red),
                      title: Text(
                        'Delete Conversation',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                  if (!activeChat.isGroup) ...[
                    const PopupMenuItem(
                      value: 'block',
                      child: ListTile(
                        leading: Icon(Icons.block, color: Colors.orange),
                        title: Text(
                          'Block Contact',
                          style: TextStyle(color: Colors.orange),
                        ),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: ListTile(
                        leading: Icon(
                          Icons.person_remove_outlined,
                          color: Colors.redAccent,
                        ),
                        title: Text(
                          'Remove Contact',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ],
                ];
              },
            ),
            IconButton(
              icon: Icon(
                _isSearchingMessages
                    ? Icons.close_rounded
                    : Icons.search_rounded,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              onPressed: () {
                setState(() {
                  _isSearchingMessages = !_isSearchingMessages;
                  if (!_isSearchingMessages) {
                    _msgSearchController.clear();
                    Provider.of<ChatProvider>(
                      context,
                      listen: false,
                    ).setMessageSearchQuery('');
                  }
                });
              },
            ),
          ],
          bottom: _isSearchingMessages
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(60),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: TextField(
                      controller: _msgSearchController,
                      autofocus: true,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search messages...',
                        hintStyle: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        filled: true,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(30),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                      ),
                      onChanged: (val) {
                        Provider.of<ChatProvider>(
                          context,
                          listen: false,
                        ).setMessageSearchQuery(val.toLowerCase());
                      },
                    ),
                  ),
                )
              : null,
        ),
        _buildConnectionBanner(activeChat),
        _buildPinnedMessageBanner(activeChat),
        Expanded(child: _buildSafeList(activeChat)),
        _buildSafeInput(activeChat),
      ],
    );
  }

  Widget _buildConnectionBanner(Conversation activeChat) {
    if (activeChat.accountId == null) return const SizedBox.shrink();

    // We use a Consumer or context.watch equivalent if AuthService notifies listeners on connection change
    // For now we just get the state directly, but assuming the parent build triggered on notifyListeners
    final status = _authService.getAccountStatus(activeChat.accountId!);
    if (status == ConnectionStatus.online) return const SizedBox.shrink();

    final isConnecting = status == ConnectionStatus.connecting;

    return Container(
      width: double.infinity,
      color: isConnecting
          ? Colors.orange.withValues(alpha: 0.9)
          : Colors.red.withValues(alpha: 0.9),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isConnecting)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            const Icon(Icons.cloud_off_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            isConnecting ? 'Connecting...' : 'Waiting for Network',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedMessageBanner(Conversation activeChat) {
    if (activeChat.pinnedMessageText == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.push_pin_rounded,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pinned Message',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  activeChat.pinnedMessageText!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              Provider.of<ChatProvider>(
                context,
                listen: false,
              ).setPinnedMessage(activeChat.id, null, null);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(ChatMessage msg) {
    final isMe = msg.isSent;
    // 1. Voice Message Handler
    if (msg.type == MessageType.voice) {
      return Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          final isPlaying = chatProvider.playingMessageId == msg.id;
          final color = isMe
              ? Colors.white
              : Theme.of(context).colorScheme.onSurface;

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => _playVoice(msg),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.25)
                        : Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying
                        ? Icons.stop_circle_rounded
                        : Icons.play_circle_filled_rounded,
                    color: color,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AudioWaveform(isPlaying: isPlaying, color: color),
                    const SizedBox(height: 6),
                    Text(
                      isPlaying ? 'Playing...' : 'Voice Note',
                      style: TextStyle(
                        color: color.withValues(alpha: 0.8),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }
    // 2. Image Message Handler
    if (msg.type == MessageType.image) {
      final bool isNetwork = msg.text.startsWith('http');
      Widget imageWidget;

      if (msg.filePath != null && !kIsWeb && File(msg.filePath!).existsSync()) {
        imageWidget = Image.file(
          File(msg.filePath!),
          width: 220,
          height: 160,
          fit: BoxFit.cover,
        );
      } else if (isNetwork) {
        imageWidget = Image.network(
          msg.text,
          width: 220,
          height: 160,
          fit: BoxFit.cover,
          cacheWidth: 800,
          errorBuilder: (context, error, stackTrace) => Container(
            width: 220,
            height: 160,
            color: Colors.black12,
            child: const Icon(Icons.broken_image_rounded, color: Colors.white),
          ),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return Container(
              width: 220,
              height: 160,
              color: Colors.black12,
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
            );
          },
        );
      } else {
        return Container(
          width: 220,
          height: 160,
          decoration: BoxDecoration(
            color: Colors.black12,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.image_not_supported_rounded,
            color: Colors.white,
            size: 40,
          ),
        );
      }

      return GestureDetector(
        onTap: () => _showImagePreview(msg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Hero(tag: 'img_${msg.id}', child: imageWidget),
          ),
        ),
      );
    }

    // 2b. File Message Handler
    if (msg.type == MessageType.file) {
      final color = isMe
          ? Colors.white
          : Theme.of(context).colorScheme.onSurface;
      return GestureDetector(
        onTap: () => _showFileOptions(msg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_rounded, color: color, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                msg.fileName ??
                    (msg.text.startsWith('http')
                        ? msg.text.split('/').last
                        : 'Document'),
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // 3. Call Info Handler
    if (msg.type == MessageType.call) {
      final color = isMe
          ? Theme.of(context).colorScheme.onPrimary
          : Theme.of(context).colorScheme.onSurfaceVariant;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_made_rounded, color: color, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              msg.text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // 4. Default Text Handler (Markdown & /me actions)
    final colorScheme = Theme.of(context).colorScheme;
    final defaultTextColor = isMe
        ? colorScheme.onPrimary
        : colorScheme.onSurface;
    final secondaryTextColor = isMe
        ? colorScheme.onPrimary.withValues(alpha: 0.85)
        : colorScheme.onSurfaceVariant;

    if (msg.text.startsWith('/me ')) {
      final action = msg.text.substring(4);
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.directions_run_rounded,
              size: 14,
              color: defaultTextColor.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${msg.senderName ?? (isMe ? "You" : "User")} $action',
                style: TextStyle(
                  color: defaultTextColor,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final urlRegex = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    final urlMatch = urlRegex.firstMatch(msg.text);
    final urlStr = urlMatch?.group(0);

    final markdownWidget = MarkdownBody(
      data: msg.text.replaceAllMapped(RegExp(r'(?<!  )\n'), (match) => '  \n'),
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [MentionSyntax()],
      builders: {'mention': MentionBuilder(context)},
      onTapLink: (text, href, title) async {
        if (href != null) {
          final uri = Uri.parse(href);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        }
      },
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: defaultTextColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        strong: TextStyle(color: defaultTextColor, fontWeight: FontWeight.w900),
        em: TextStyle(color: defaultTextColor, fontStyle: FontStyle.italic),
        a: TextStyle(
          color: isMe ? colorScheme.onPrimary : colorScheme.primary,
          decoration: TextDecoration.underline,
          fontWeight: FontWeight.w700,
        ),
        h1: TextStyle(
          color: defaultTextColor,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        h2: TextStyle(
          color: defaultTextColor,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
        h3: TextStyle(
          color: defaultTextColor,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
        listBullet: TextStyle(color: defaultTextColor),
        blockquote: TextStyle(color: secondaryTextColor, fontSize: 12),
        blockquoteDecoration: BoxDecoration(
          color: isMe
              ? colorScheme.onPrimary.withValues(alpha: 0.1)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: isMe
                  ? colorScheme.onPrimary.withValues(alpha: 0.7)
                  : colorScheme.primary,
              width: 3,
            ),
          ),
        ),
        code: TextStyle(
          backgroundColor: isMe
              ? colorScheme.onPrimary.withValues(alpha: 0.12)
              : colorScheme.onSurface.withValues(alpha: 0.08),
          color: isMe ? colorScheme.onPrimary : colorScheme.primary,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: isMe
              ? colorScheme.onPrimary.withValues(alpha: 0.1)
              : colorScheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );

    if (urlStr != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          markdownWidget,
          LinkPreview(url: urlStr),
        ],
      );
    }
    return markdownWidget;
  }

  Future<void> _sendMessage(
    Conversation activeChat, {
    String? textOverride,
  }) async {
    final text = textOverride ?? _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      await _authService.sendMessage(
        activeChat.accountId ?? _authService.activeAccountId!,
        activeChat.id,
        text,
        replyToId: _replyToMessage?.id,
        isGroup: activeChat.isGroup,
      );
      _authService.sendChatState(
        activeChat.id,
        'active',
        accountId: activeChat.accountId,
        isGroup: activeChat.isGroup,
      ); // Clear typing state

      _messageController.clear();
      setState(() => _replyToMessage = null); // Reset reply
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to send: ${e.toString().replaceAll('Exception: ', '')}',
            ),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    }
  }

  void _insertMarkdown(String token) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    if (selection.isValid && !selection.isCollapsed) {
      // Wrap selected text
      final selectedText = text.substring(selection.start, selection.end);
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        '$token$selectedText$token',
      );
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + token.length * 2 + selectedText.length,
        ),
      );
    } else {
      // Insert token at cursor
      final cursorPosition = selection.isValid ? selection.start : text.length;
      final newText = text.replaceRange(
        cursorPosition,
        cursorPosition,
        '$token$token',
      );
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: cursorPosition + token.length,
        ),
      );
    }
  }

  Widget _buildMarkdownToolbar() {
    if (!_isTypingMsg) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _markdownChip(Icons.format_bold_rounded, '**'),
          const SizedBox(width: 8),
          _markdownChip(Icons.format_italic_rounded, '*'),
          const SizedBox(width: 8),
          _markdownChip(Icons.strikethrough_s_rounded, '~~'),
          const SizedBox(width: 8),
          _markdownChip(Icons.code_rounded, '`'),
        ],
      ),
    );
  }

  Widget _markdownChip(IconData icon, String token) {
    return InkWell(
      onTap: () => _insertMarkdown(token),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Icon(
          icon,
          size: 18,
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _buildSafeInput(Conversation activeChat) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildUploadProgressOverlay(_authService, activeChat),
        _buildMarkdownToolbar(),
        if (_replyToMessage != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(
                  Icons.reply_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Replying to: ${_replyToMessage!.text}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => setState(() => _replyToMessage = null),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).appBarTheme.backgroundColor,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.add_circle_outline_rounded,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                onSelected: (val) {
                  if (val == 'image') _pickImage(activeChat);
                  if (val == 'file') _pickFile(activeChat);
                  if (val == 'gif') _pickGif(activeChat);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'image',
                    child: Row(
                      children: [
                        Icon(Icons.image_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('Image'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'file',
                    child: Row(
                      children: [
                        Icon(Icons.insert_drive_file_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('File'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'gif',
                    child: Row(
                      children: [
                        Icon(
                          Icons.gif_box_rounded,
                          size: 18,
                          color: Colors.deepPurple,
                        ),
                        SizedBox(width: 8),
                        Text('GIF'),
                      ],
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: Icon(
                  Icons.attach_file_rounded,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                onPressed: () => _pickFile(activeChat),
              ),
              IconButton(
                icon: Icon(
                  Icons.emoji_emotions_outlined,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                onPressed: () => _showEmojiPicker(),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: TextField(
                    controller: _messageController,
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: TextStyle(color: Theme.of(context).hintColor),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(activeChat),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return ScaleTransition(scale: animation, child: child);
                },
                child: _isTypingMsg
                    ? GestureDetector(
                        key: const ValueKey('sendButton'),
                        onTap: () => _sendMessage(activeChat),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.send_rounded,
                            color: Theme.of(context).colorScheme.onPrimary,
                            size: 20,
                          ),
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('micButton'),
                        onLongPress: () => _toggleVoiceRecording(activeChat),
                        onLongPressUp: () => _toggleVoiceRecording(activeChat),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: EdgeInsets.all(_isRecording ? 16 : 12),
                          decoration: BoxDecoration(
                            color: _isRecording
                                ? Colors.redAccent.withValues(alpha: 0.8)
                                : Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            boxShadow: _isRecording
                                ? [
                                    BoxShadow(
                                      color: Colors.red.withValues(alpha: 0.4),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Icon(
                            _isRecording
                                ? Icons.stop_rounded
                                : Icons.mic_none_rounded,
                            color: Theme.of(context).colorScheme.onPrimary,
                            size: 20,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showEmojiPicker() {
    final emojis = [
      '😀',
      '😂',
      '😍',
      '🥰',
      '😘',
      '😊',
      '🤣',
      '😭',
      '😎',
      '🤔',
      '😤',
      '🥺',
      '😳',
      '🤯',
      '😴',
      '🤝',
      '👍',
      '👎',
      '👏',
      '🙌',
      '🙏',
      '💪',
      '🤙',
      '✌️',
      '❤️',
      '💔',
      '💯',
      '🔥',
      '✨',
      '⭐',
      '🎉',
      '🎊',
      '💬',
      '💭',
      '📷',
      '🎤',
      '🎧',
      '📱',
      '💻',
      '🔗',
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.emoji_emotions_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Quick Emojis',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: emojis
                    .map(
                      (emoji) => InkWell(
                        onTap: () {
                          _messageController.text += emoji;
                          Navigator.pop(context);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showImagePreview(ChatMessage msg) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close Preview',
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_rounded, color: Colors.white),
              onPressed: () {
                if (msg.filePath != null) {
                  Share.shareXFiles([XFile(msg.filePath!)]);
                } else {
                  Share.share(msg.text);
                }
              },
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: msg.filePath != null && !kIsWeb && File(msg.filePath!).existsSync()
                ? Image.file(File(msg.filePath!))
                : Image.network(
                    msg.text,
                    errorBuilder: (c, e, s) => const Icon(
                      Icons.broken_image_rounded,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFileOptions(ChatMessage msg) async {
    final bool isNetwork = msg.text.startsWith('http');
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.insert_drive_file_rounded,
              size: 48,
              color: Colors.blueGrey,
            ),
            const SizedBox(width: 12),
            Text(
              msg.fileName ?? 'File Attachment',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(height: 32),
            if (msg.filePath != null && !kIsWeb && File(msg.filePath!).existsSync())
              ListTile(
                leading: const Icon(
                  Icons.open_in_new_rounded,
                  color: Colors.green,
                ),
                title: const Text('Open with System App'),
                onTap: () async {
                  Navigator.pop(context);
                  await OpenFilex.open(msg.filePath!);
                },
              ),
            if (isNetwork)
              ListTile(
                leading: const Icon(Icons.download_rounded, color: Colors.blue),
                title: const Text('Download & Save'),
                onTap: () async {
                  Navigator.pop(context);
                  _downloadAndOpenFile(msg);
                },
              ),
            if (isNetwork)
              ListTile(
                leading: const Icon(Icons.public_rounded, color: Colors.orange),
                title: const Text('Open in Browser'),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri.parse(msg.text);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ListTile(
              leading: Icon(
                Icons.share_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text('Share File'),
              onTap: () {
                Navigator.pop(context);
                if (msg.filePath != null) {
                  Share.shareXFiles([XFile(msg.filePath!)]);
                } else {
                  Share.share(msg.text);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndOpenFile(ChatMessage msg) async {
    if (kIsWeb) return;
    try {
      final response = await http.get(Uri.parse(msg.text));
      if (response.statusCode == 200) {
        final directory = await getApplicationDocumentsDirectory();
        final fileName = msg.fileName ?? msg.text.split('/').last;
        final file = File('${directory.path}/$fileName');
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Downloaded: $fileName')));
          await OpenFilex.open(file.path);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildSafeList(Conversation activeChat) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final query = chatProvider.messageSearchQuery;
    final messages = activeChat.messages.where((m) {
      if (query.isEmpty) return true;
      return m.text.toLowerCase().contains(query);
    }).toList();

    final wallpaperColor = activeChat.wallpaperColor != null
        ? Color(activeChat.wallpaperColor!)
        : null;
    final wallpaperImage = activeChat.wallpaperPath != null && !kIsWeb
        ? FileImage(File(activeChat.wallpaperPath!))
        : null;

    return Container(
      decoration: BoxDecoration(
        color: wallpaperColor ?? Colors.transparent,
        image: wallpaperImage != null
            ? DecorationImage(
                image: wallpaperImage,
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.1),
                  BlendMode.darken,
                ),
              )
            : null,
      ),
      child: RepaintBoundary(
        child: Stack(
          children: [
            ListView.builder(
              reverse: true,
              controller: _scrollController,
              itemCount: messages.length,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              itemBuilder: (context, index) {
                final msgIndex = messages.length - 1 - index;
                final msg = messages[msgIndex];
                final prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;

                // Check if we need a date header
                bool showDateHeader = false;
                if (prevMsg == null) {
                  showDateHeader = true;
                } else {
                  final prevDate = prevMsg.timestamp;
                  final currDate = msg.timestamp;
                  if (prevDate.day != currDate.day ||
                      prevDate.month != currDate.month ||
                      prevDate.year != currDate.year) {
                    showDateHeader = true;
                  }
                }

                return Column(
                  children: [
                    if (showDateHeader) _buildDateHeader(msg.timestamp),
                    const SizedBox(height: 12),
                    _buildMessageBubble(msg, activeChat.isGroup),
                  ],
                );
              },
            ),
            if (_showScrollToBottom)
              Positioned(
                right: 16,
                bottom: 16,
                child: FloatingActionButton.small(
                  heroTag: 'scrollBottom',
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.8),
                  onPressed: () {
                    _scrollController.animateTo(
                      0.0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  },
                  child: const Icon(
                    Icons.keyboard_double_arrow_down_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateHeader(DateTime date) {
    String label;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    if (msgDate == today) {
      label = 'TODAY';
    } else if (msgDate == yesterday) {
      label = 'YESTERDAY';
    } else {
      label = DateFormat('MMMM d, y').format(date).toUpperCase();
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isGroup) {
    final isMe = msg.isSent;
    // Only show sender label in Group Chats (MUC) where identity is ambiguous.
    final bool showSender = !isMe && isGroup;

    return Dismissible(
      key: ValueKey('msg_swipe_${msg.id}'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        setState(() => _replyToMessage = msg);
        HapticFeedback.lightImpact();
        return false; // Bounce back
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        child: Icon(
          Icons.reply_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(
          Icons.reply_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: () => _showMessageOptions(msg),
          child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (showSender && msg.senderName != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    msg.senderName!,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: Xep0392Service.generateColor(
                        msg.senderId ?? msg.senderName!,
                        isDarkTheme:
                            Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  if (showSender)
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0, bottom: 4.0),
                      child: FutureBuilder<Uint8List?>(
                        future: AvatarCacheService().getAvatar(msg.senderId ?? msg.senderName ?? ''),
                        builder: (context, snapshot) {
                          return CircleAvatar(
                            radius: 14,
                            backgroundColor: Xep0392Service.generateColor(
                              msg.senderId ?? msg.senderName ?? '?',
                              isDarkTheme: Theme.of(context).brightness == Brightness.dark,
                            ),
                            backgroundImage: snapshot.data != null ? MemoryImage(snapshot.data!) : null,
                            child: snapshot.data == null
                                ? Text(
                                    (msg.senderName ?? '?')[0].toUpperCase(),
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                  Flexible(
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * (showSender ? 0.65 : 0.7),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 5,
                            offset: const Offset(0, 2),
                          ),
                        ],
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(20),
                          topRight: const Radius.circular(20),
                          bottomLeft: Radius.circular(isMe ? 20 : 0),
                          bottomRight: Radius.circular(isMe ? 0 : 20),
                        ),
                      ),
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (msg.replyToId != null) _buildReplyQuote(msg),
                        _buildMessageContent(msg),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              DateFormat('HH:mm').format(msg.timestamp),
                              style: TextStyle(
                                fontSize: 9,
                                color: isMe
                                    ? Theme.of(context).colorScheme.onPrimary
                                          .withValues(alpha: 0.7)
                                    : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant
                                          .withValues(alpha: 0.7),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (msg.isEdited) ...[
                              const SizedBox(width: 4),
                              Text(
                                '(edited)',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontStyle: FontStyle.italic,
                                  color: isMe
                                      ? Theme.of(context).colorScheme.onPrimary
                                            .withValues(alpha: 0.54)
                                      : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant
                                            .withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                            if (isMe) ...[
                              const SizedBox(width: 4),
                              _buildStatusIcon(msg.status, isMe),
                            ],
                            if (msg.encryptionType == 'omemo') ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.shield_rounded,
                                size: 10,
                                color: isMe
                                    ? Theme.of(context).colorScheme.onPrimary
                                          .withValues(alpha: 0.54)
                                    : Theme.of(context).colorScheme.primary
                                          .withValues(alpha: 0.5),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (msg.reactions.isNotEmpty) _buildReactionChips(msg),
        const SizedBox(height: 4),
      ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(MessageStatus status, bool isMe) {
    if (!isMe) {
      return const SizedBox.shrink();
    }

    switch (status) {
      case MessageStatus.sending:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(
                    context,
                  ).colorScheme.onPrimary.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'Sending...',
              style: TextStyle(
                fontSize: 8,
                color: Theme.of(
                  context,
                ).colorScheme.onPrimary.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        );

      case MessageStatus.sent:
        return Tooltip(
          message: 'Sent',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onPrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.check_rounded,
              size: 12,
              color: Theme.of(
                context,
              ).colorScheme.onPrimary.withValues(alpha: 0.7),
            ),
          ),
        );

      case MessageStatus.delivered:
        return Tooltip(
          message: 'Delivered',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onPrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.done_all_rounded,
              size: 12,
              color: Theme.of(
                context,
              ).colorScheme.onPrimary.withValues(alpha: 0.7),
            ),
          ),
        );

      case MessageStatus.read:
        return Tooltip(
          message: 'Seen',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.lightBlueAccent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.lightBlueAccent.withValues(alpha: 0.4),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ],
            ),
            child: const Icon(
              Icons.done_all_rounded,
              size: 12,
              color: Colors.white,
            ),
          ),
        );

      case MessageStatus.failed:
        return Tooltip(
          message: 'Failed',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.error_outline_rounded,
              size: 12,
              color: Colors.redAccent,
            ),
          ),
        );
    }
  }

  Widget _buildReplyQuote(ChatMessage msg) {
    final fallbackText = msg.replyPreview?.trim();
    return FutureBuilder<ChatMessage?>(
      future: DatabaseService().getMessageById(msg.replyToId ?? ''),
      builder: (context, snapshot) {
        final cp = Provider.of<ChatProvider>(context, listen: false);
        final replyToId = msg.replyToId?.trim();
        final convoId = msg.conversationId?.split('/').first.toLowerCase();
        final backfillKey =
            (replyToId != null &&
                replyToId.isNotEmpty &&
                convoId != null &&
                convoId.isNotEmpty)
            ? '$convoId|$replyToId'
            : null;
        final quoteText =
            snapshot.data?.text ??
            (fallbackText?.isNotEmpty == true ? fallbackText! : null);

        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data == null &&
            backfillKey != null &&
            !_requestedQuoteBackfills.contains(backfillKey)) {
          _requestedQuoteBackfills.add(backfillKey);
          scheduleMicrotask(() async {
            await cp.ensureQuotedMessageLoaded(msg, _authService);
            if (!mounted) return;
            setState(() {
              _requestedQuoteBackfills.remove(backfillKey);
            });
          });
        }

        final text = quoteText ?? 'Loading quoted message...';
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border(
              left: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 4,
              ),
            ),
          ),
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }

  Widget _buildReactionChips(ChatMessage msg) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      children: msg.reactions.entries
          .map(
            (e) => Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                '${e.key} ${e.value.length}',
                style: TextStyle(fontSize: 10, color: colorScheme.onSurface),
              ),
            ),
          )
          .toList(),
    );
  }

  void _showMessageOptions(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Quick React',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                spacing: 8,
                runSpacing: 8,
                children: ['❤️', '👍', '😂', '😮', '😢', '🔥']
                    .map(
                      (emoji) => GestureDetector(
                        onTap: () {
                          final cp = Provider.of<ChatProvider>(
                            context,
                            listen: false,
                          );
                          cp.addReaction(
                            msg.conversationId ?? '',
                            msg.id,
                            emoji,
                            _authService,
                          );
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 18),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('Reaction added'),
                                ],
                              ),
                              duration: const Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.outline.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const Divider(height: 32),
              ListTile(
                leading: Icon(
                  Icons.reply_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: const Text(
                  'Reply',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () {
                  setState(() => _replyToMessage = msg);
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.copy_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: const Text('Copy Text'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.forward_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(context);
                  _showForwardDialog(msg);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.push_pin_rounded,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                title: const Text('Pin to Top'),
                onTap: () {
                  final cp = Provider.of<ChatProvider>(context, listen: false);
                  if (cp.activeConversation != null) {
                    cp.setPinnedMessage(
                      cp.activeConversation!.id,
                      msg.id,
                      msg.text,
                    );
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Message Pinned'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                  Navigator.pop(context);
                },
              ),
              if (msg.isSent && msg.type == MessageType.text)
                ListTile(
                  leading: Icon(
                    Icons.edit_rounded,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  title: const Text('Edit Message'),
                  onTap: () {
                    Navigator.pop(context);
                    _showEditMessageDialog(msg);
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.forward_rounded,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                title: const Text('Forward Message'),
                onTap: () {
                  Navigator.pop(context);
                  _showForwardMessageDialog(msg);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_rounded, color: Colors.red),
                title: const Text(
                  'Delete Message',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  final cp = Provider.of<ChatProvider>(context, listen: false);
                  cp.deleteMessage(
                    msg.conversationId ?? '',
                    msg.id,
                    _authService,
                  );

                  // Show localized feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Message deleted'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              if (!msg.isSent && msg.protocol == 'XMPP') ...[
                const Divider(),
                ListTile(
                  leading: const Icon(
                    Icons.block_rounded,
                    color: Colors.orange,
                  ),
                  title: const Text(
                    'Block User',
                    style: TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text('Prevent this user from messaging you'),
                  onTap: () async {
                    await _authService.blockContact(
                      msg.conversationId!,
                      accountId: msg.accountId,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Blocked ${msg.conversationId}'),
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.account_circle_outlined,
                    color: Colors.blue,
                  ),
                  title: const Text('View User Profile'),
                  onTap: () {
                    Navigator.pop(context);
                    // Navigate to profile or fetch VCard
                    if (msg.conversationId != null && msg.accountId != null) {
                      _authService.fetchVCard(
                        msg.accountId!,
                        msg.conversationId!,
                      );
                      // We could show a dialog here with the vcard info
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showForwardDialog(ChatMessage msg) {
    showDialog(
      context: context,
      builder: (context) {
        return Consumer<ChatProvider>(
          builder: (context, cp, _) {
            final activeConvs = cp.conversations
                .where((c) => c.messages.isNotEmpty)
                .toList();
            return AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surface,
              title: Text(
                'Forward to...',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: activeConvs.length,
                  itemBuilder: (context, index) {
                    final conv = activeConvs[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: conv.avatarBytes != null
                            ? MemoryImage(conv.avatarBytes!)
                            : null,
                        child: conv.avatarBytes == null
                            ? Text(
                                conv.name.isNotEmpty
                                    ? conv.name[0].toUpperCase()
                                    : '?',
                              )
                            : null,
                      ),
                      title: Text(conv.name),
                      onTap: () {
                        Navigator.pop(context);
                        _forwardMessage(msg, conv);
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _forwardMessage(ChatMessage msg, Conversation targetConv) {
    _authService.sendMessage(
      targetConv.accountId ?? _authService.activeAccountId!,
      targetConv.id,
      msg.text, // This works for media too, since the URL is stored in text
      isGroup: targetConv.isGroup,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Forwarded to ${targetConv.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showEditMessageDialog(ChatMessage msg) {
    final editController = TextEditingController(text: msg.text);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Message'),
        content: TextField(
          controller: editController,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Edit your message...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != msg.text) {
                msg.text = newText;
                msg.isEdited = true;
                msg.editTimestamp = DateTime.now();

                // Update in provider
                final cp = Provider.of<ChatProvider>(context, listen: false);
                cp.updateMessage(msg.conversationId ?? '', msg.id, newText);

                // Send XMPP message correction (XEP-0308)
                _authService.sendEditedMessage(
                  msg.conversationId ?? '',
                  msg.id,
                  newText,
                  accountId: msg.accountId,
                  isGroup: msg.isGroup,
                );

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Message edited'),
                    duration: Duration(seconds: 1),
                  ),
                );
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showForwardMessageDialog(ChatMessage msg) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final List<String> selectedTargets = [];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Forward Message'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select target conversations:',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.builder(
                    itemCount: chatProvider.conversations.length,
                    itemBuilder: (context, index) {
                      final conv = chatProvider.conversations[index];
                      final isSelected = selectedTargets.contains(conv.id);
                      return CheckboxListTile(
                        value: isSelected,
                        title: Text(
                          conv.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${conv.protocol} - ${conv.id}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        onChanged: (val) {
                          setDialogState(() {
                            if (val == true) {
                              selectedTargets.add(conv.id);
                            } else {
                              selectedTargets.remove(conv.id);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (selectedTargets.isNotEmpty) {
                  for (final targetId in selectedTargets) {
                    final conv = chatProvider.conversations.firstWhere(
                      (c) => c.id == targetId,
                      orElse: () => chatProvider.conversations.first,
                    );
                    _authService.forwardMessage(msg, [
                      targetId,
                    ], targetProtocol: conv.protocol);
                  }
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Forwarding to ${selectedTargets.length} recipients...',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Forward'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarLayout(
    ChatProvider chatProvider,
    AuthService authService,
    bool isMobile,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: isDark
                ? AppColors.borderDark
                : AppColors.borderLight,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          GibberSidebarHeader(chatProvider: chatProvider, authService: authService),
          Expanded(child: _buildSidebarContent(chatProvider, authService)),
        ],
      ),
    );

    if (isMobile) return content;

    return SizedBox(width: 320, child: content);
  }

  Widget _buildNavRail(ChatProvider chatProvider, AuthService authService) {
    return GibberNavRail(
      selectedIndex: chatProvider.selectedSidebarTab,
      onDestinationSelected: (idx) {
        debugPrint('ISOLATE: Selected Tab $idx');
        chatProvider.setSidebarTab(idx);
      },
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
        const NexusSearchScreen(),
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
              ? Center(
                  child: Text(
                    'No results',
                    style: TextStyle(color: Theme.of(context).disabledColor),
                  ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: statusCtrl,
              decoration: InputDecoration(
                hintText: "What's on your mind?",
                filled: true,
                fillColor: isDark ? AppColors.darkSurfaceRaised : AppColors.lightSurfaceRaised,
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
    if (val == 'discover') {
      context.goNamed('roomDiscovery');
    }
    if (val == 'invite') {
      context.goNamed('invite');
    }
    if (val == 'gateways') {
      context.goNamed('gateways');
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

  void _showCreateGroupDialog(AuthService authService) {
    context.goNamed('createRoom');
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

  String _formatDialedNumber(String number) {
    if (number.contains('@')) return number;
    // Basic phone number detection (+ or digital)
    final isPhone = number.startsWith('+') || RegExp(r'^\d+$').hasMatch(number);
    if (isPhone) {
      return '$number@cheogram.com'; // Default calling gateway
    }
    return number;
  }

  Widget _dialButton(String val, String sub) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFF5F7FB),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        padding: EdgeInsets.zero,
      ),
      onPressed: () => setState(() => _dialedNumber += val),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            val,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Colors.black87,
            ),
          ),
          if (sub.isNotEmpty)
            Text(
              sub,
              style: const TextStyle(
                fontSize: 9,
                color: Colors.black26,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  void _showRoomInfo(Conversation room) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  child: Text(
                    room.name.isNotEmpty ? room.name[0] : '?',
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        room.id,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'PARTICIPANTS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (room.participants.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Waiting for participant presence...',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.3,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: room.participants.length,
                  itemBuilder: (context, index) {
                    final participant = room.participants[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        child: Text(
                          participant.nickname.isNotEmpty
                              ? participant.nickname[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        participant.nickname,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(color: Theme.of(context).colorScheme.error),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () {
                  _authService.leaveRoom(room.accountId ?? '', room.id);
                  Provider.of<ChatProvider>(
                    context,
                    listen: false,
                  ).removeConversation(room.id);
                  Navigator.pop(context);
                },
                child: const Text(
                  'LEAVE ROOM',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showInviteDialog(Conversation room) {
    final TextEditingController jidController = TextEditingController();
    final TextEditingController reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Invite to Room'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: jidController,
                decoration: const InputDecoration(
                  labelText: 'Participant JID',
                  hintText: 'user@example.com',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: reasonController,
                decoration: const InputDecoration(
                  labelText: 'Reason (Optional)',
                  hintText: 'Please join this room!',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () {
                final jid = jidController.text.trim();
                if (jid.isNotEmpty) {
                  _authService.inviteToRoom(room.accountId ?? '', room.id, jid);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Invited $jid to room')),
                  );
                }
              },
              child: const Text('INVITE'),
            ),
          ],
        );
      },
    );
  }


  Widget _buildUploadProgressOverlay(
    AuthService authService,
    Conversation activeChat,
  ) {
    return StreamBuilder<double>(
      stream:
          authService.getUploadProgress(activeChat.accountId) ??
          const Stream.empty(),
      builder: (context, snapshot) {
        if (!snapshot.hasData ||
            snapshot.data! <= 0.0 ||
            snapshot.data! >= 1.0) {
          return const SizedBox.shrink();
        }

        final progress = snapshot.data!;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.9),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.cloud_upload_rounded,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(progress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            // Bouncing sine wave
            final delay = index * 0.2;
            final value = ((_controller.value - delay) % 1.0);
            // 0.0 -> 0.5 is half-sine wave (up and down)
            final double bounce = value < 0.5
                ? math.sin(value * 2 * math.pi)
                : 0.0;

            return Transform.translate(
              offset: Offset(0, -bounce * 4), // Bounce up 4 pixels
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.8),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class MentionSyntax extends md.InlineSyntax {
  MentionSyntax() : super(r'@[\w\-\.]+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final mention = match.group(0)!;
    final element = md.Element.text('mention', mention);
    parser.addNode(element);
    return true;
  }
}

class MentionBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  MentionBuilder(this.context);

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        element.textContent,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: preferredStyle?.fontSize,
        ),
      ),
    );
  }
}
