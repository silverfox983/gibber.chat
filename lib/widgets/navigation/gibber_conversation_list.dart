import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_colors.dart';
import '../../models/chat_models.dart';
import '../../providers/chat_provider.dart';
import '../../services/auth_service.dart';
import '../story_ring.dart';

class GibberConversationList extends StatelessWidget {
  final String searchQuery;
  final AuthService authService;

  const GibberConversationList({
    super.key,
    required this.searchQuery,
    required this.authService,
  });

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: true);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final filtered = chatProvider.conversations
        .where((c) => c.name.toLowerCase().contains(searchQuery.toLowerCase()))
        .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView.builder(
        itemCount: filtered.length,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemBuilder: (context, index) {
          final conv = filtered[index];
          final isActive = chatProvider.activeConversation?.id == conv.id;
          final hasStory = chatProvider.contactHasStory(conv.id);
          final hasUnviewed = chatProvider.contactHasUnviewedStory(conv.id);
          return _ConversationTile(
            conv: conv,
            isActive: isActive,
            isDark: isDark,
            authService: authService,
            hasStory: hasStory,
            hasUnviewedStory: hasUnviewed,
            onTap: () => chatProvider.setActiveConversation(conv.id),
          );
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conv;
  final bool isActive;
  final bool isDark;
  final AuthService authService;
  final bool hasStory;
  final bool hasUnviewedStory;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conv,
    required this.isActive,
    required this.isDark,
    required this.authService,
    this.hasStory = false,
    this.hasUnviewedStory = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatarColor = _avatarColor(context);
    final protocolIcon = _protocolIcon();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isActive
            ? (isDark ? AppColors.primary.withValues(alpha: 0.15) : AppColors.primaryLight.withValues(alpha: 0.2))
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: isActive
            ? Border.all(color: AppColors.primary.withValues(alpha: 0.3))
            : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        onTap: onTap,
        leading: _buildAvatar(context, avatarColor, protocolIcon),
        title: _buildTitle(context),
        subtitle: _buildSubtitle(context),
        trailing: _buildTrailing(context),
      ),
    );
  }

  Color _avatarColor(BuildContext context) {
    if (isActive) {
      return isDark ? AppColors.primaryLight : AppColors.primaryDark;
    }
    switch (conv.protocol) {
      case 'Discord':
        return const Color(0xFF5865F2);
      case 'IRC':
        return Theme.of(context).colorScheme.secondary;
      default:
        return Colors.grey;
    }
  }

  IconData? _protocolIcon() {
    switch (conv.protocol) {
      case 'Discord':
        return Icons.discord;
      case 'IRC':
        return Icons.alternate_email;
      default:
        return null;
    }
  }

  Widget _buildAvatar(BuildContext context, Color avatarColor, IconData? protocolIcon) {
    final avatar = CircleAvatar(
      radius: 24,
      backgroundColor: avatarColor.withValues(alpha: 0.1),
      backgroundImage: conv.avatarBytes != null ? MemoryImage(conv.avatarBytes!) : null,
      child: _buildAvatarContent(avatarColor, protocolIcon),
    );

    if (hasStory) {
      return StoryRing(
        hasUnviewed: hasUnviewedStory,
        radius: 24,
        onTap: onTap,
        child: avatar,
      );
    }

    return avatar;
  }

  Widget _buildAvatarContent(Color avatarColor, IconData? protocolIcon) {
    if (conv.avatarBytes != null) return const SizedBox.shrink();
    if (protocolIcon != null) {
      return Icon(protocolIcon, color: avatarColor, size: 18);
    }
    return Text(
      conv.name.isNotEmpty ? conv.name[0].toUpperCase() : '?',
      style: TextStyle(
        color: avatarColor,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            conv.name,
            style: TextStyle(
              fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
              color: isActive
                  ? AppColors.primary
                  : (isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary),
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        if (!conv.isGroup && authService.isOmemoEnabled(conv.id))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(
              Icons.lock_rounded,
              size: 12,
              color: AppColors.primary.withValues(alpha: 0.7),
            ),
          ),
      ],
    );
  }

  Widget _buildSubtitle(BuildContext context) {
    if (conv.isTyping) {
      return Text(
        'Typing...',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.green[600],
        ),
      );
    }

    return Text(
      conv.lastMessage?.text ?? 'No messages',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: isActive
            ? AppColors.primary.withValues(alpha: 0.6)
            : (isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary),
      ),
    );
  }

  Widget? _buildTrailing(BuildContext context) {
    if (conv.lastMessage == null) return null;
    final ts = conv.lastMessage!.timestamp;

    final now = DateTime.now();
    final diff = now.difference(ts);
    String timeStr;
    if (diff.inDays > 0) {
      timeStr = diff.inDays == 1 ? 'Yesterday' : '${diff.inDays}d';
    } else if (diff.inHours > 0) {
      timeStr = '${diff.inHours}h';
    } else if (diff.inMinutes > 0) {
      timeStr = '${diff.inMinutes}m';
    } else {
      timeStr = 'Now';
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (conv.unreadCount > 0) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              conv.unreadCount > 99 ? '99+' : conv.unreadCount.toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          timeStr,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textDarkTertiary : AppColors.textLightTertiary,
          ),
        ),
      ],
    );
  }
}
