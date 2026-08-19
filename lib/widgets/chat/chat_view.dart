import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../../core/app_colors.dart';
import '../../models/chat_models.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/auth_service.dart';

class ChatView extends StatefulWidget {
  final Conversation conversation;
  final ChatProvider chatProvider;
  final AuthService authService;

  const ChatView({
    super.key,
    required this.conversation,
    required this.chatProvider,
    required this.authService,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  late TextEditingController _messageController;
  late TextEditingController _searchController;
  late ScrollController _scrollController;
  final TextEditingController _msgSearchController = TextEditingController();
  bool _showScrollToBottom = false;
  bool _isSearchingMessages = false;
  AudioRecorder? _audioRecorder;
  Timer? _typingDebouncer;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    _searchController = TextEditingController();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _audioRecorder = AudioRecorder();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _searchController.dispose();
    _msgSearchController.dispose();
    _scrollController.dispose();
    _audioRecorder?.dispose();
    _typingDebouncer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      final shouldShow = pos.pixels < pos.maxScrollExtent - 100;
      if (_showScrollToBottom != shouldShow) {
        setState(() => _showScrollToBottom = shouldShow);
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(context),
        Expanded(child: _buildMessageList(context)),
        _buildMessageInput(context),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final conv = widget.conversation;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => widget.chatProvider.setActiveConversation(null),
              tooltip: 'Back',
            ),
            const SizedBox(width: 4),
            _buildAvatar(conv),
            const SizedBox(width: 12),
            Expanded(child: _buildTitleRow(conv, isDark)),
            _buildHeaderActions(context, conv),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(Conversation conv) {
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppColors.primary.withValues(alpha: 0.1),
      backgroundImage: conv.avatarBytes != null ? MemoryImage(conv.avatarBytes!) : null,
      child: conv.avatarBytes == null
          ? Icon(
              conv.protocol == 'Discord' ? Icons.discord : Icons.person_rounded,
              color: AppColors.primary,
              size: 18,
            )
          : null,
    );
  }

  Widget _buildTitleRow(Conversation conv, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          conv.name,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        if (conv.isTyping)
          Text(
            'Typing...',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.green[600],
            ),
          )
        else
          Text(
            conv.presenceMessage ?? conv.status.name.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
      ],
    );
  }

  Widget _buildHeaderActions(BuildContext context, Conversation conv) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!conv.isGroup) ...[
          IconButton(
            icon: const Icon(Icons.call_rounded),
            tooltip: 'Voice call',
            onPressed: () => _startCall(context, conv, false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_rounded),
            tooltip: 'Video call',
            onPressed: () => _startCall(context, conv, true),
          ),
        ],
        if (!conv.isGroup && widget.authService.isOmemoEnabled(conv.id))
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.lock_rounded, color: AppColors.primary, size: 16),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (val) => _handleMenuAction(val, conv),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'search', child: Text('Search messages')),
            if (conv.isGroup) ...[
              const PopupMenuItem(value: 'members', child: Text('View members')),
              const PopupMenuItem(value: 'info', child: Text('Group info')),
            ],
            const PopupMenuItem(value: 'settings', child: Text('Chat settings')),
          ],
        ),
      ],
    );
  }

  Future<void> _startCall(BuildContext context, Conversation conv, bool isVideo) async {
    final messenger = ScaffoldMessenger.of(context);
    final callProvider = Provider.of<CallProvider>(context, listen: false);
    final statuses = await [
      Permission.microphone,
      if (isVideo) Permission.camera,
    ].request();

    if (statuses[Permission.microphone] != PermissionStatus.granted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(isVideo
              ? 'Camera and microphone permissions are required for video calls.'
              : 'Microphone permission is required for voice calls.'),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => openAppSettings(),
          ),
        ),
      );
      return;
    }

    if (isVideo && statuses[Permission.camera] != PermissionStatus.granted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Camera permission is required for video calls.')),
      );
      return;
    }

    callProvider.startCall(
      conv.id,
      accountId: conv.accountId,
      isVideo: isVideo,
      protocol: conv.protocol,
    );
  }

  void _handleMenuAction(String action, Conversation conv) {
    switch (action) {
      case 'search':
        setState(() => _isSearchingMessages = !_isSearchingMessages);
        break;
      case 'members':
        break;
      case 'info':
        break;
      case 'settings':
        break;
    }
  }

  Widget _buildMessageList(BuildContext context) {
    final conv = widget.conversation;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = conv.wallpaperColor != null
        ? Color(conv.wallpaperColor!)
        : (isDark ? AppColors.darkBackground : AppColors.lightBackground);

    final filtered = _isSearchingMessages && _msgSearchController.text.isNotEmpty
        ? conv.messages.where((m) => m.text.toLowerCase().contains(_msgSearchController.text.toLowerCase())).toList()
        : conv.messages;

    return Container(
      color: bgColor,
      child: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            reverse: false,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final msg = filtered[index];
              final showDateHeader = index == 0 ||
                  !_sameDay(
                    filtered[index - 1].timestamp,
                    msg.timestamp,
                  );
              return Column(
                children: [
                  if (showDateHeader) _buildDateHeader(msg.timestamp),
                  _buildMessageBubble(msg, isDark),
                ],
              );
            },
          ),
          if (_showScrollToBottom)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.small(
                onPressed: _scrollToBottom,
                child: const Icon(Icons.arrow_downward_rounded),
              ),
            ),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Widget _buildDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    String label;
    if (msgDate == today) {
      label = 'TODAY';
    } else if (msgDate == yesterday) {
      label = 'YESTERAY';
    } else {
      label = DateFormat('MMMM d, y').format(date).toUpperCase();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.5),
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isDark) {
    final isMe = msg.isSent;
    final alignment = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final bgColor = isMe
        ? AppColors.primary
        : (isDark ? AppColors.darkSurfaceRaised : AppColors.lightSurfaceRaised);
    final textColor = isMe
        ? Colors.white
        : (isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: isMe ? const Radius.circular(4) : null,
              bottomLeft: !isMe ? const Radius.circular(4) : null,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (msg.text.isNotEmpty)
                Text(
                  msg.text,
                  style: TextStyle(color: textColor, fontSize: 15),
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormat('HH:mm').format(msg.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: textColor.withValues(alpha: 0.5),
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      msg.status == MessageStatus.read
                          ? Icons.done_all_rounded
                          : msg.status == MessageStatus.delivered
                              ? Icons.done_all_rounded
                              : msg.status == MessageStatus.sent
                                  ? Icons.done_rounded
                                  : Icons.error_outline_rounded,
                      size: 14,
                      color: textColor.withValues(alpha: 0.5),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageInput(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        border: Border(
          top: BorderSide(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add_rounded),
              onPressed: () {},
              tooltip: 'Attachments',
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: 'Message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: isDark
                      ? AppColors.darkSurfaceRaised
                      : AppColors.lightSurfaceRaised,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onChanged: (val) => _onMessageChanged(val),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send_rounded),
              onPressed: _sendMessage,
              color: AppColors.primary,
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }

  void _onMessageChanged(String text) {
    _typingDebouncer?.cancel();
    _typingDebouncer = Timer(const Duration(seconds: 2), () {
      // Send typing stopped
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    await widget.authService.sendMessage(
      widget.authService.activeAccountId ?? '',
      widget.conversation.id,
      text,
    );
    _messageController.clear();
    _scrollToBottom();
  }
}
