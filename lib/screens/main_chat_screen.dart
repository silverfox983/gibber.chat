import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:giphy_get/giphy_get.dart';
import './room_discovery_screen.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../providers/chat_provider.dart';
import '../providers/call_provider.dart';
import '../services/database_service.dart';
import './profile_screen.dart';
import './call_screen.dart';
import '../services/call_history_service.dart';
import '../models/call_log.dart';
import '../widgets/omemo_trust_dialog.dart';
import '../widgets/room_participants_dialog.dart';
import '../providers/theme_provider.dart';
import './contacts_screen.dart';
import './nexus_search_screen.dart';
import './security_settings_screen.dart';

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
        style: style ?? TextStyle(color: Theme.of(context).colorScheme.onSurface),
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
  bool _showScrollToBottom = false;

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

    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        final show = _scrollController.offset > 300;
        if (show != _showScrollToBottom) {
          setState(() => _showScrollToBottom = show);
        }

        // MAM Infinite Scroll: Trigger history load when reaching top
        if (_scrollController.position.pixels ==
            _scrollController.position.minScrollExtent) {
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

      // Hook up Typing Indicators (XEP-0085)
      _messageController.addListener(() {
        if (!mounted) return;
        final activeChat = Provider.of<ChatProvider>(
          context,
          listen: false,
        ).activeConversation;
        if (activeChat != null && !_authService.isOmemoEnabled(activeChat.id)) {
          if (_messageController.text.isNotEmpty) {
            _authService.sendChatState(
              activeChat.id,
              'composing',
              isGroup: activeChat.isGroup,
            );
            _typingDebouncer?.cancel();
            _typingDebouncer = Timer(const Duration(seconds: 3), () {
              _authService.sendChatState(
                activeChat.id,
                'paused',
                isGroup: activeChat.isGroup,
              );
            });
          } else {
            _authService.sendChatState(
              activeChat.id,
              'active',
              isGroup: activeChat.isGroup,
            );
            _typingDebouncer?.cancel();
          }
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

  bool _isDiscordVoiceChat(Conversation chat) {
    return chat.protocol == 'Discord' && chat.name.contains('🔊');
  }

  bool _canStartVoiceCall(Conversation chat) {
    return chat.protocol == 'XMPP' || _isDiscordVoiceChat(chat);
  }

  bool _canStartVideoCall(Conversation chat) {
    return chat.protocol == 'XMPP';
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
          _scrollController.position.maxScrollExtent,
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
    final gif = await GiphyGet.getGif(
      context: context,
      apiKey:
          '8865KxYxI5N5SgT7H1P5K3Q9E2G4I6K7', // Placeholder/Example - Should use config
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
                title: Text(file.path.split(Platform.pathSeparator).last),
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
        final directory = await getTemporaryDirectory();
        final path =
            '${directory.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
              title: Text(
                'GIBBER',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).appBarTheme.foregroundColor,
                ),
              ),
              backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
              elevation: 0,
            ),
      drawer: Drawer(
        child: _buildSidebarLayout(chatProvider, authService, true),
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
                  '${chatProvider.pendingSubscriptions.length} Pending Friend Requests',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          Expanded(
            child: activeChat != null
                ? _buildChatContent(activeChat)
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
              unselectedItemColor: Colors.black26,
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
                  icon: Icon(Icons.group_outlined),
                  label: 'Groups',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.dialpad_outlined),
                  label: 'Dialer',
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
          Expanded(child: _buildChatContent(activeChat)),
        ],
      ),
    );
  }

  Widget _buildChatContent(Conversation? activeChat) {
    if (activeChat == null) {
      return Center(
        child: Text(
          'Gibber: Welcome',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 22,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
            letterSpacing: -0.5,
          ),
        ),
      );
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
                                  activeChat.name[0],
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
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  activeChat.typingUser != null
                                      ? '${activeChat.typingUser} is typing'
                                      : 'Typing...',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                _TypingIndicator(),
                              ],
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
                                            ? 'Group Chat'
                                            : activeChat.protocol,
                                        style: TextStyle(
                                          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_authService.isOmemoEnabled(
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
                                              statusText = 'DISTRUSTED';
                                              break;
                                            case 0:
                                            default:
                                              statusColor = Colors.orange;
                                              statusIcon =
                                                  Icons.gpp_maybe_rounded;
                                              statusText = 'UNVERIFIED';
                                              break;
                                          }

                                          return Row(
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
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: 0.5,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
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
                  _isDiscordVoiceChat(activeChat)
                      ? Icons.keyboard_voice_rounded
                      : Icons.call_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                tooltip: _isDiscordVoiceChat(activeChat)
                    ? 'Join Voice'
                    : 'Start Audio Call',
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
                      : 'Enable OMEMO',
                  onPressed: () {
                    if (isEnabled) {
                      showDialog(
                        context: context,
                        builder: (context) => OmemoTrustDialog(
                          chatId: activeChat.id,
                          chatName: activeChat.name,
                        ),
                      );
                    } else {
                      _authService.toggleOmemo(activeChat.id);
                    }
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
                  cp.clearAll();
                } else if (val == 'block') {
                  cp.blockContact(activeChat.id, _authService);
                } else if (val == 'remove') {
                  cp.removeContact(activeChat.id, _authService);
                  cp.setActiveConversation(null);
                } else if (val == 'sync') {
                  cp.loadHistory(activeChat.id, _authService);
                } else if (val == 'info') {
                  _showRoomInfo(activeChat);
                } else if (val == 'participants') {
                  showDialog(
                    context: context,
                    builder: (context) => RoomParticipantsDialog(
                      roomJid: activeChat.id,
                      roomName: activeChat.name,
                    ),
                  );
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
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SecuritySettingsScreen(),
                    ),
                  );
                }
              },
              itemBuilder: (context) => [
                if (activeChat.isGroup) ...[
                  const PopupMenuItem(
                    value: 'info',
                    child: ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('Room Info'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'participants',
                    child: ListTile(
                      leading: Icon(Icons.people_outline),
                      title: Text('Participants'),
                    ),
                  ),
                  const PopupMenuDivider(),
                ],
                if (_canStartVoiceCall(activeChat))
                  PopupMenuItem(
                    value: 'call',
                    child: ListTile(
                      leading: Icon(
                        _isDiscordVoiceChat(activeChat)
                            ? Icons.keyboard_voice_rounded
                            : Icons.call_outlined,
                      ),
                      title: Text(
                        _isDiscordVoiceChat(activeChat)
                            ? 'Join Voice'
                            : 'Voice Call',
                      ),
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
                    leading: Icon(Icons.delete_outline, color: Colors.red),
                    title: Text(
                      'Clear Messages',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
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
        Expanded(child: _buildSafeList(activeChat)),
        _buildSafeInput(activeChat),
      ],
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Voice Note',
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (isPlaying)
                    SizedBox(
                      width: 80,
                      height: 2,
                      child: LinearProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          color.withValues(alpha: 0.5),
                        ),
                        backgroundColor: color.withValues(alpha: 0.1),
                      ),
                    )
                  else
                    Text(
                      'Tap to listen',
                      style: TextStyle(
                        color: color.withValues(alpha: 0.6),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
            ],
          );
        },
      );
    }
    // 2. Image Message Handler
    if (msg.type == MessageType.image) {
      final bool isNetwork = msg.text.startsWith('http');
      Widget imageWidget;

      if (msg.filePath != null && File(msg.filePath!).existsSync()) {
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
            Expanded(
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
          ? Colors.white
          : Theme.of(context).colorScheme.onSurfaceVariant;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_made_rounded, color: color, size: 16),
          const SizedBox(width: 8),
          Text(
            msg.text,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    // 4. Default Text Handler (Markdown)
    return MarkdownBody(
      data: msg.text,
      selectable: true,
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
          color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        strong: TextStyle(
          color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w900,
        ),
        code: TextStyle(
          backgroundColor: isMe ? Colors.white12 : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
          color: isMe ? Colors.white : Theme.of(context).colorScheme.primary,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: isMe ? Colors.white10 : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Future<void> _sendMessage(
    Conversation activeChat, {
    String? textOverride,
  }) async {
    final text = textOverride ?? _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      if (activeChat.protocol == 'IRC') {
        await _authService.sendIrcMessage(
          activeChat.id,
          text,
          accountId: activeChat.accountId,
          isGroup: activeChat.isGroup,
        );
      } else if (activeChat.protocol == 'Discord') {
        await _authService.sendDiscordMessage(
          activeChat.id,
          text,
          accountId: activeChat.accountId,
        );
      } else {
        await _authService.sendXmppMessage(
          activeChat.id,
          text,
          accountId: activeChat.accountId,
          replyToId: _replyToMessage?.id,
          isGroup: activeChat.isGroup,
        );
        _authService.sendChatState(
          activeChat.id,
          'active',
          accountId: activeChat.accountId,
          isGroup: activeChat.isGroup,
        ); // Clear typing state
      }

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

  Widget _buildSafeInput(Conversation activeChat) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildUploadProgressOverlay(_authService, activeChat),
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
              GestureDetector(
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
                    _isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                    color: Theme.of(context).colorScheme.onPrimary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
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
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
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
            child: msg.filePath != null && File(msg.filePath!).existsSync()
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
            if (msg.filePath != null && File(msg.filePath!).existsSync())
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
    final wallpaperImage = activeChat.wallpaperPath != null
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
              controller: _scrollController,
              itemCount: messages.length,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              itemBuilder: (context, index) {
                final msg = messages[index];
                final prevMsg = index > 0 ? messages[index - 1] : null;

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
                      _scrollController.position.maxScrollExtent,
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

    return Align(
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
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ),
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: isMe
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: msg.protocol == 'Discord'
                            ? [const Color(0xFF5865F2), const Color(0xFF4752C4)]
                            : msg.protocol == 'IRC'
                            ? [Colors.green.shade700, Colors.green.shade600]
                            : [
                                Theme.of(context).colorScheme.primary,
                                Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.9),
                              ],
                      )
                    : null,
                color: isMe
                    ? null
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isMe ? 20 : 0),
                  bottomRight: Radius.circular(isMe ? 0 : 20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: isMe
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3)
                        : Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
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
                                  ? Colors.white70
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
                                    ? Colors.white54
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
                          if (_authService.isOmemoEnabled(
                            msg.conversationId ?? '',
                          )) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.shield_rounded,
                              size: 10,
                              color: isMe
                                  ? Colors.white54
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
            if (msg.reactions.isNotEmpty) _buildReactionChips(msg),
            const SizedBox(height: 4),
          ],
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
                  Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'Sending...',
              style: TextStyle(
                fontSize: 8,
                color: Colors.white.withValues(alpha: 0.5),
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
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 12,
              color: Colors.white70,
            ),
          ),
        );

      case MessageStatus.delivered:
        return Tooltip(
          message: 'Delivered',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.done_all_rounded,
              size: 12,
              color: Colors.white70,
            ),
          ),
        );

      case MessageStatus.read:
        return Tooltip(
          message: 'Seen',
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.lightBlueAccent, Colors.cyanAccent],
              ),
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
    }
  }

  Widget _buildReplyQuote(ChatMessage msg) {
    return FutureBuilder<ChatMessage?>(
      future: DatabaseService().getMessageById(msg.replyToId ?? ''),
      builder: (context, snapshot) {
        final text = snapshot.data?.text ?? '...';
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
            style: const TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: Colors.black54,
            ),
          ),
        );
      },
    );
  }

  Widget _buildReactionChips(ChatMessage msg) {
    return Wrap(
      spacing: 4,
      children: msg.reactions.entries
          .map(
            (e) => Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
              child: Text(
                '${e.key} ${e.value.length}',
                style: const TextStyle(fontSize: 10),
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
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ['❤️', '👍', '😂', '😮', '😢', '🔥']
                  .map(
                    (emoji) => GestureDetector(
                      onTap: () {
                        _authService.sendReaction(
                          msg.conversationId ?? '',
                          msg.id,
                          emoji,
                          accountId: msg.accountId,
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
              leading: const Icon(Icons.copy_rounded, color: Colors.black54),
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
            if (msg.isSent &&
                msg.type == MessageType.text &&
                msg.protocol != 'Discord')
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
                leading: const Icon(Icons.block_rounded, color: Colors.orange),
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
                      SnackBar(content: Text('Blocked ${msg.conversationId}')),
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
                const Text(
                  'Select target conversations:',
                  style: TextStyle(fontSize: 12, color: Colors.black45),
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
                  _authService.forwardMessage(msg, selectedTargets);
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
    final content = DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Colors.black12, width: 1)),
      ),
      child: Column(
        children: [
          _buildSidebarHeader(chatProvider, authService),
          Expanded(child: _buildSidebarContent(chatProvider, authService)),
        ],
      ),
    );

    if (isMobile) return content;

    return SizedBox(width: 320, child: content);
  }

  Widget _buildNavRail(ChatProvider chatProvider, AuthService authService) {
    return NavigationRail(
      selectedIndex: chatProvider.selectedSidebarTab,
      onDestinationSelected: (idx) {
        debugPrint('ISOLATE: Selected Tab $idx');
        chatProvider.setSidebarTab(idx);
      },
      indicatorColor: Theme.of(
        context,
      ).colorScheme.secondary.withValues(alpha: 0.2),
      selectedIconTheme: IconThemeData(
        color: Theme.of(context).colorScheme.secondary,
      ),
      unselectedIconTheme: const IconThemeData(color: Colors.black38),
      selectedLabelTextStyle: TextStyle(
        color: Theme.of(context).colorScheme.secondary,
        fontWeight: FontWeight.bold,
        fontSize: 11,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: Colors.black38,
        fontWeight: FontWeight.bold,
        fontSize: 11,
      ),
      labelType: NavigationRailLabelType.all,
      leading: Column(
        children: [
          const SizedBox(height: 20),
          ...authService.savedAccounts.map((acc) {
            final status = authService.getAccountStatus(acc.fullJid);
            final bool isSelected = authService.activeAccountId == acc.fullJid;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Tooltip(
                message: '${acc.fullJid} (${status.name})',
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.black12,
                      child: Icon(
                        acc.protocol == 'Discord'
                            ? Icons.discord
                            : (acc.protocol == 'IRC'
                                  ? Icons.alternate_email
                                  : Icons.chat_bubble_outline),
                        color: isSelected ? Colors.white : Colors.black54,
                        size: 16,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: status == ConnectionStatus.online
                              ? Colors.green
                              : (status == ConnectionStatus.connecting
                                    ? Colors.orange
                                    : Colors.grey),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 20),
          const Divider(indent: 16, endIndent: 16),
        ],
      ),
      destinations: [
        NavigationRailDestination(
          icon: Icon(Icons.chat_outlined),
          selectedIcon: Icon(Icons.chat),
          label: Text('Chats'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: Text('Buddies'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.group_outlined),
          selectedIcon: Icon(Icons.group),
          label: Text('Groups'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.dialpad_outlined),
          selectedIcon: Icon(Icons.dialpad),
          label: Text('Dialer'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('Profile'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.manage_search_rounded),
          selectedIcon: Icon(Icons.search_rounded),
          label: Text('Search'),
        ),
        NavigationRailDestination(
          icon: const Icon(
            Icons.travel_explore_rounded,
            color: Colors.indigoAccent,
          ),
          selectedIcon: const Icon(
            Icons.travel_explore_rounded,
            color: Colors.indigo,
          ),
          label: const Text('Nexus'),
        ),
      ],
    );
  }

  Widget _buildSidebarHeader(
    ChatProvider chatProvider,
    AuthService authService,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Gibber',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              Consumer<ThemeProvider>(
                builder: (context, tp, _) => IconButton(
                  icon: Icon(
                    tp.isDarkMode
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () => tp.toggleTheme(),
                  tooltip: 'Toggle Theme',
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.travel_explore_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const NexusSearchScreen(),
                  ),
                ),
                tooltip: 'Nexus Global Search',
              ),
              _buildAddAction(chatProvider, authService),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _searchController,
            onChanged: (val) => chatProvider.setSearchQuery(val),
            decoration: InputDecoration(
              hintText: 'Search...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              filled: true,
              fillColor: const Color(0xFFF5F7FB),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _buildStatusRow(authService),
        ],
      ),
    );
  }

  Widget _buildAddAction(ChatProvider chatProvider, AuthService authService) {
    return PopupMenuButton<String>(
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
      ],
    );
  }

  void _onAddActionSelected(String val, AuthService authService) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    if (val == 'buddy') chatProvider.setSidebarTab(1);
    if (val == 'group') _showJoinRoomDialog(authService);
    if (val == 'discover') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const RoomDiscoveryScreen()),
      );
    }
  }

  Widget _buildStatusRow(AuthService authService) {
    return GestureDetector(
      onTap: () => _showStatusPicker(authService),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _getStatusColor(authService.myStatus),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                authService.myStatusMessage ??
                    authService.myStatus.name.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(
              Icons.mode_edit_outline_outlined,
              color: Colors.black26,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  void _showStatusPicker(AuthService authService) {
    final statusCtrl = TextEditingController(text: authService.myStatusMessage);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          top: 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set Presence Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: statusCtrl,
              decoration: InputDecoration(
                hintText: "What's on your mind?",
                filled: true,
                fillColor: Colors.black.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ...ContactStatus.values.map((status) {
              if (status == ContactStatus.offline)
                return const SizedBox.shrink(); // Use logout for offline
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
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                onTap: () {
                  authService.updatePresence(
                    status,
                    message: statusCtrl.text.trim(),
                  );
                  Navigator.pop(context);
                },
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarContent(
    ChatProvider chatProvider,
    AuthService authService,
  ) {
    switch (chatProvider.selectedSidebarTab) {
      case 0:
        return _buildConversationList(chatProvider);
      case 1:
        return const ContactsScreen();
      case 2:
        return _buildGroupList(authService);
      case 3:
        return _buildDialerSection(authService);
      case 4:
        return const ProfileScreen(isSidebar: true);
      case 5:
        return _buildGlobalSearchList(chatProvider);
      case 6:
        return const NexusSearchScreen();
      default:
        return _buildConversationList(chatProvider);
    }
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

  Widget _buildConversationList(ChatProvider chatProvider) {
    final filtered = chatProvider.conversations
        .where((c) => c.name.toLowerCase().contains(_searchQuery))
        .toList();
    return ListView.builder(
      itemCount: filtered.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (context, index) {
        final conv = filtered[index];
        final isActive = chatProvider.activeConversation?.id == conv.id;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: isActive
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: CircleAvatar(
              backgroundColor: isActive
                  ? Theme.of(context).colorScheme.primary
                  : (conv.protocol == 'Discord'
                        ? const Color(0xFF5865F2).withValues(alpha: 0.1)
                        : conv.protocol == 'IRC'
                        ? Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.15)
                        : Colors.grey[100]),
              backgroundImage: conv.avatarBytes != null
                  ? MemoryImage(conv.avatarBytes!)
                  : null,
              child: Stack(
                children: [
                  if (conv.avatarBytes == null)
                    Center(
                      child: conv.protocol == 'Discord'
                          ? Icon(
                              Icons.discord,
                              color: isActive
                                  ? Colors.white
                                  : const Color(0xFF5865F2),
                              size: 18,
                            )
                          : conv.protocol == 'IRC'
                          ? Icon(
                              Icons.alternate_email,
                              color: isActive
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.secondary,
                              size: 18,
                            )
                          : Text(
                              conv.name[0],
                              style: TextStyle(
                                color: isActive ? Colors.white : Colors.black54,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  if (!conv.isGroup)
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _getStatusColor(conv.status),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    conv.name,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                if (_authService.isOmemoEnabled(conv.id))
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.lock_rounded,
                      size: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
            subtitle: conv.isTyping
                ? Text(
                    'Typing...',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.green[600],
                    ),
                  )
                : Text(
                    conv.lastMessage?.text ?? 'No messages',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isActive
                          ? const Color(0xFFE91E63).withValues(alpha: 0.6)
                          : Colors.black38,
                    ),
                  ),
            selected: isActive,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  conv.lastMessage != null
                      ? DateFormat('HH:mm').format(conv.lastMessage!.timestamp)
                      : '',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (conv.unreadCount > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.secondary,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      conv.unreadCount > 99
                          ? '99+'
                          : conv.unreadCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            onTap: () {
              debugPrint('ISOLATE: Tapped Conversation ${conv.id}');
              chatProvider.setActiveConversation(conv.id);
            },
          ),
        );
      },
    );
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

  Widget _buildGroupList(AuthService authService) {
    final chatProvider = Provider.of<ChatProvider>(context);
    final groupConvs = chatProvider.conversations
        .where((c) => c.isGroup)
        .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView.builder(
        itemCount: groupConvs.length,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemBuilder: (context, index) {
          final conv = groupConvs[index];
          final isActive = chatProvider.activeConversation?.id == conv.id;
          final isIrc = conv.protocol == 'IRC';
          final isDiscord = conv.protocol == 'Discord';
          final themeColor = isDiscord
              ? const Color(0xFF5865F2)
              : (isIrc
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).colorScheme.primary);

          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: isActive
                  ? themeColor.withValues(alpha: 0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: isActive
                    ? themeColor
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: isDiscord
                    ? Icon(
                        Icons.discord,
                        color: isActive ? Colors.white : themeColor,
                        size: 20,
                      )
                    : Text(
                        isIrc ? '#' : conv.name[0].toUpperCase(),
                        style: TextStyle(
                          color: isActive
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
              title: Text(
                conv.name,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: isActive
                      ? themeColor
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                conv.lastMessage?.text ?? 'No messages',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    conv.protocol,
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: themeColor,
                    ),
                  ),
                  if (conv.participants.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: themeColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${conv.participants.length}',
                        style: TextStyle(
                          fontSize: 10,
                          color: themeColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              onTap: () {
                chatProvider.setActiveConversation(conv.id);
                chatProvider.setSidebarTab(0);
              },
            ),
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'discoverRooms',
            backgroundColor: Theme.of(context).colorScheme.secondary,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const RoomDiscoveryScreen(),
                ),
              );
            },
            child: const Icon(Icons.explore_rounded, color: Colors.white),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'joinGroup',
            backgroundColor: Theme.of(context).colorScheme.primary,
            onPressed: () => _showJoinRoomDialog(authService),
            child: const Icon(Icons.group_add, color: Colors.white),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'createGroup',
            backgroundColor: Theme.of(context).colorScheme.primary,
            onPressed: () => _showCreateGroupDialog(authService),
            child: const Icon(Icons.add, color: Colors.white),
          ),
        ],
      ),
    );
  }

  void _showCreateGroupDialog(AuthService authService) {
    final nameCtrl = TextEditingController();
    final nickCtrl = TextEditingController(text: 'Admin');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          'Create New Group',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                labelText: 'Room Name',
                labelStyle: TextStyle(color: Theme.of(context).hintColor),
                hintText: 'Project-Alley',
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
              final name = nameCtrl.text.trim();
              if (name.isNotEmpty) {
                final jid =
                    '${name.toLowerCase()}@conference.${authService.activeAccountId?.split("@").last ?? "chat.example.com"}';
                Navigator.pop(context);
                final error = await authService.createXmppRoom(
                  jid,
                  nickCtrl.text.trim(),
                );
                if (error != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to create: $error'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showJoinRoomDialog(AuthService authService) {
    final roomCtrl = TextEditingController();
    final nickCtrl = TextEditingController(text: 'GibberUser');
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
                Navigator.pop(context);
                final error = await authService.joinGenericRoom(target);

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

  Widget _buildDialerSection(AuthService authService) {
    final history = Provider.of<CallHistoryService>(context);

    return Column(
      children: [
        // 1. Call History List (Expanded)
        Expanded(
          child: history.logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 48,
                        color: Colors.black.withValues(alpha: 0.1),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No Recent Calls',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.2),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: history.logs.length,
                  itemBuilder: (context, index) {
                    final log = history.logs[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: log.status == CallStatus.missed
                            ? Colors.red.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.05),
                        child: Icon(
                          log.isVideo
                              ? Icons.videocam_rounded
                              : Icons.call_rounded,
                          size: 20,
                          color: log.status == CallStatus.missed
                              ? Colors.red
                              : Colors.black54,
                        ),
                      ),
                      title: Text(
                        log.jid,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: log.status == CallStatus.missed
                              ? Colors.red
                              : Colors.black87,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Icon(
                            log.direction == CallDirection.incoming
                                ? Icons.call_received_rounded
                                : Icons.call_made_rounded,
                            size: 12,
                            color: Colors.black38,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${log.timestamp.hour}:${log.timestamp.minute.toString().padLeft(2, '0')} • ${log.status.name.toUpperCase()}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black38,
                            ),
                          ),
                        ],
                      ),
                      trailing: log.duration != null
                          ? Text(
                              '${log.duration!.inMinutes}:${(log.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black26,
                              ),
                            )
                          : null,
                      onTap: () {
                        final cleanJid = log.jid.split('@').first;
                        setState(() => _dialedNumber = cleanJid);
                      },
                    );
                  },
                ),
        ),

        // Divider
        Container(height: 1, color: Colors.black.withValues(alpha: 0.05)),

        // 2. Dialpad Surface
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Dialed Number Display
              Text(
                _dialedNumber.isEmpty ? 'Enter Number' : _dialedNumber,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: _dialedNumber.isEmpty
                      ? Colors.black.withValues(alpha: 0.05)
                      : const Color(0xFFE91E63),
                  letterSpacing: 2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),

              // Numeric Grid
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 20,
                childAspectRatio: 1.4,
                children: [
                  _dialButton('1', ''),
                  _dialButton('2', 'ABC'),
                  _dialButton('3', 'DEF'),
                  _dialButton('4', 'GHI'),
                  _dialButton('5', 'JKL'),
                  _dialButton('6', 'MNO'),
                  _dialButton('7', 'PQRS'),
                  _dialButton('8', 'TUV'),
                  _dialButton('9', 'WXYZ'),
                  _dialButton('*', ''),
                  _dialButton('0', '+'),
                  _dialButton('#', ''),
                ],
              ),
              const SizedBox(height: 24),

              // Action Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.backspace_rounded,
                      color: Colors.black26,
                    ),
                    onPressed: () {
                      if (_dialedNumber.isNotEmpty) {
                        setState(
                          () => _dialedNumber = _dialedNumber.substring(
                            0,
                            _dialedNumber.length - 1,
                          ),
                        );
                      }
                    },
                  ),
                  FloatingActionButton.large(
                    heroTag:
                        null, // Critical: Disable hero to prevent multiple ticker violation in RawTooltipState
                    backgroundColor: Colors.green,
                    onPressed: () {
                      if (_dialedNumber.isNotEmpty) {
                        _callProvider.startCall(
                          _formatDialedNumber(_dialedNumber),
                          accountId: _authService.activeAccountId ?? '',
                          isVideo: false,
                        );
                      }
                    },
                    child: const Icon(
                      Icons.call,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.video_call,
                      color: Color(0xFF00BCD4),
                    ),
                    onPressed: () {
                      if (_dialedNumber.isNotEmpty) {
                        _callProvider.startCall(
                          _formatDialedNumber(_dialedNumber),
                          accountId: _authService.activeAccountId ?? '',
                          isVideo: true,
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
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
                    room.name[0],
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
                        style: const TextStyle(color: Colors.black38),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'PARTICIPANTS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black26,
              ),
            ),
            const SizedBox(height: 12),
            if (room.participants.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Waiting for participant presence...',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.black38,
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
                    final nick = room.participants[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        child: Text(
                          nick[0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        nick,
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
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () {
                  _authService.leaveRoom(room.accountId ?? '', room.id);
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

  Widget _buildUploadProgressOverlay(
    AuthService authService,
    Conversation activeChat,
  ) {
    return StreamBuilder<double>(
      stream:
          authService.getUploadProgress(activeChat.accountId) ??
          const Stream.empty(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data! <= 0.0 || snapshot.data! >= 1.0)
          return const SizedBox.shrink();

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
            final delay = index * 0.2;
            final value = ((_controller.value - delay) % 1.0);
            final opacity = value < 0.5 ? value * 2 : 2 - (value * 2);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: opacity.clamp(0.3, 1.0)),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
