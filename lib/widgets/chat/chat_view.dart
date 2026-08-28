import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../utils/call_permissions.dart';
import 'package:record/record.dart';
import '../../core/app_colors.dart';
import '../../models/chat_models.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/auth_service.dart';
import '../../services/translation/translation_service.dart';

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
  bool _isSpoilerMode = false;
  final TextEditingController _spoilerHintController = TextEditingController();
  final Set<String> _revealedSpoilers = {};
  AudioRecorder? _audioRecorder;


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
    _spoilerHintController.dispose();
    _scrollController.dispose();
    _audioRecorder?.dispose();
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline,
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
            Expanded(child: _buildTitleRow(context, conv)),
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

  Widget _buildTitleRow(BuildContext context, Conversation conv) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          conv.name,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
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
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        if (!conv.isGroup && conv.protocol == 'XMPP') ...[
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
    final callProvider = Provider.of<CallProvider>(context, listen: false);
    if (!await requestCallPermissions(context, isVideo: isVideo)) return;

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
        if (conv.isGroup) {
          context.pushNamed('groupMembers', extra: {'conversation': conv});
        }
        break;
      case 'info':
        context.pushNamed('chatInfo', extra: {'conversation': conv});
        break;
      case 'settings':
        context.pushNamed('chatSettings', extra: {'conversation': conv});
        break;
    }
  }

  Widget _buildMessageList(BuildContext context) {
    final conv = widget.conversation;
    final bgColor = conv.wallpaperColor != null
        ? Color(conv.wallpaperColor!)
        : Theme.of(context).colorScheme.surfaceContainerLow;

    final wallpaperImage = conv.wallpaperPath != null && !kIsWeb
        ? FileImage(File(conv.wallpaperPath!))
        : null;

    final filtered = _isSearchingMessages && _msgSearchController.text.isNotEmpty
        ? conv.messages.where((m) => m.text.toLowerCase().contains(_msgSearchController.text.toLowerCase())).toList()
        : conv.messages;

    return Container(
      color: bgColor,
      decoration: wallpaperImage != null
          ? BoxDecoration(
              image: DecorationImage(
                image: wallpaperImage,
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.1),
                  BlendMode.darken,
                ),
              ),
            )
          : null,
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
                  _buildMessageBubble(context, msg),
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

  Widget _buildMessageBubble(BuildContext context, ChatMessage msg) {
    final isMe = msg.isSent;
    final alignment = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final bgColor = isMe
        ? AppColors.primary
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final textColor = isMe
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;

    final isSpoilerRevealed = _revealedSpoilers.contains(msg.id);

    Widget contentWidget;
    if (msg.isSpoiler && !isSpoilerRevealed) {
      final hint = (msg.spoilerHint != null && msg.spoilerHint!.isNotEmpty) ? msg.spoilerHint! : 'Spoiler';
      contentWidget = GestureDetector(
        onTap: () {
          setState(() {
            _revealedSpoilers.add(msg.id!);
          });
        },
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off_rounded, size: 16, color: textColor.withValues(alpha: 0.7)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      hint,
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.7),
                        fontSize: 15,
                        fontStyle: FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Tap to reveal',
                style: TextStyle(
                  fontSize: 10,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      contentWidget = Container(
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
            if (msg.isSpoiler && isSpoilerRevealed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_rounded, size: 12, color: textColor.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        (msg.spoilerHint != null && msg.spoilerHint!.isNotEmpty) ? msg.spoilerHint! : 'Spoiler',
                        style: TextStyle(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.5),
                          fontStyle: FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
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
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: GestureDetector(
          onLongPress: () => _showMessageActions(context, msg, textColor),
          child: contentWidget,
        ),
      ),
    );
  }

  void _showMessageActions(BuildContext ctx, ChatMessage msg, Color textColor) {
    showModalBottomSheet(
      context: ctx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
        if (msg.text.isNotEmpty) ...[
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('Translate'),
            onTap: () async {
              Navigator.pop(ctx);
              final translated = await TranslationService.translate(msg.text, toLang: 'en');
              if (translated != null && translated != msg.text) {
                _showTranslatedMessage(ctx, msg.text, translated, textColor);
              } else {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('Translation unavailable')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Copy'),
            onTap: () {
              Navigator.pop(ctx);
              // Copy handled elsewhere
            },
          ),
        ],
        const SizedBox(height: 8),
      ]),
    );
  }

  void _showTranslatedMessage(BuildContext ctx, String original, String translated, Color textColor) {
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.translate_rounded, size: 20), SizedBox(width: 8), Text('Translation')]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Original:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor.withValues(alpha: 0.7))),
              const SizedBox(height: 4),
              Text(original, style: TextStyle(color: textColor)),
              const Divider(height: 24),
              Text('English:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(height: 4),
              Text(translated),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _buildMessageInput(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isSpoilerMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  controller: _spoilerHintController,
                  decoration: InputDecoration(
                    hintText: 'Spoiler hint (optional)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: _isSpoilerMode ? 'Spoiler message...' : 'Message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                    Icons.visibility_off_rounded,
                    color: _isSpoilerMode ? AppColors.primary : Colors.grey,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSpoilerMode = !_isSpoilerMode;
                      if (!_isSpoilerMode) {
                        _spoilerHintController.clear();
                      }
                    });
                  },
                  tooltip: 'Toggle spoiler',
                ),
                IconButton(
                  icon: const Icon(Icons.mood_rounded),
                  onPressed: () => _showMoodPicker(context),
                  color: Colors.grey,
                  tooltip: 'Set mood',
                ),
                IconButton(
                  icon: const Icon(Icons.send_rounded),
                  onPressed: _sendMessage,
                  color: AppColors.primary,
                  tooltip: 'Send',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showMoodPicker(BuildContext ctx) {
    final moods = {
      'happy': '😊 Happy',
      'sad': '😢 Sad',
      'angry': '😠 Angry',
      'surprised': '😮 Surprised',
      'confused': '😕 Confused',
      'love': '😍 In love',
      'sleeping': '😴 Sleeping',
      'laughing': '😂 Laughing',
      'gaming': '🎮 Gaming',
      'working': '💼 Working',
      'eating': '🍽️ Eating',
      'coffee': '☕ Drinking coffee',
      'music': '🎵 Listening to music',
      'exercise': '🏃 Exercising',
      'thinking': '🤔 Thinking',
      'excited': '🤩 Excited',
    };

    showModalBottomSheet(
      context: ctx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
            Text('How are you feeling?', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: moods.entries.map((e) {
                return ActionChip(
                  avatar: Text(e.key == e.value.split(' ')[0] ? e.value.split(' ')[0] : '😊'),
                  label: Text(e.value),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final auth = Provider.of<AuthService>(ctx, listen: false);
                    final svc = auth.spacesService;
                    if (svc != null) {
                      await svc.publishMood(e.key);
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Mood set: ${e.value}')));
                      }
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Clear mood'),
              onTap: () async {
                Navigator.pop(ctx);
                final auth = Provider.of<AuthService>(ctx, listen: false);
                final svc = auth.spacesService;
                if (svc != null) {
                  await svc.retractMood();
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Mood cleared')));
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final isSpoiler = _isSpoilerMode;
    final spoilerHint = _spoilerHintController.text.trim();

    await widget.authService.sendMessage(
      widget.authService.activeAccountId ?? '',
      widget.conversation.id,
      text,
      isSpoiler: isSpoiler,
      spoilerHint: spoilerHint.isNotEmpty ? spoilerHint : null,
      isGroup: widget.conversation.isGroup,
    );
    _messageController.clear();
    _spoilerHintController.clear();
    setState(() {
      _isSpoilerMode = false;
    });
    _scrollToBottom();
  }

}
