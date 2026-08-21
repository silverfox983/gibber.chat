import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../providers/chat_provider.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/avatar_cache_service.dart';
import '../models/chat_models.dart';

class WelcomeDashboard extends StatefulWidget {
  const WelcomeDashboard({super.key});

  @override
  State<WelcomeDashboard> createState() => _WelcomeDashboardState();
}

class _WelcomeDashboardState extends State<WelcomeDashboard> {
  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final chatProvider = Provider.of<ChatProvider>(context);
    final entitlement = Provider.of<EntitlementService>(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 16 : 48,
            vertical: isMobile ? 24 : 48,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildGreeting(authService, isMobile),
              SizedBox(height: isMobile ? 24 : 32),
              _buildStatCards(chatProvider, authService, isMobile),
              SizedBox(height: isMobile ? 20 : 28),
              _buildTierMiningPanel(entitlement, isMobile),
              SizedBox(height: isMobile ? 20 : 28),
              _buildQuickActions(isMobile),
              SizedBox(height: isMobile ? 20 : 28),
              _buildRecentChats(chatProvider, isMobile),
              SizedBox(height: isMobile ? 16 : 20),
              _buildOnboardingTips(chatProvider, authService, isMobile),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGreeting(AuthService authService, bool isMobile) {
    final displayName = authService.getResolvedNickname(null);
    final now = DateTime.now();
    final hour = now.hour;
    String greeting;
    if (hour < 12) {
      greeting = 'Good morning';
    } else if (hour < 17) {
      greeting = 'Good afternoon';
    } else {
      greeting = 'Good evening';
    }

    final profile = authService.currentProfile;
    final statusColor = _statusColor(authService.myStatus);

    return Row(
      children: [
        Container(
          width: isMobile ? 48 : 56,
          height: isMobile ? 48 : 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primaryContainer,
            border: Border.all(color: statusColor, width: 3),
          ),
          child: Builder(builder: (context) {
            final jid = authService.activeAccountId ?? '';
            return FutureBuilder(
              future: AvatarCacheService().getAvatar(jid),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes != null) {
                  return ClipOval(child: Image.memory(bytes, fit: BoxFit.cover));
                }
                return Center(
                  child: Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : 'G',
                    style: TextStyle(
                      fontSize: isMobile ? 20 : 24,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                );
              },
            );
          }),
        ),
        SizedBox(width: isMobile ? 12 : 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$greeting, $displayName',
                style: TextStyle(
                  fontSize: isMobile ? 22 : 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    authService.myStatus.name.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (authService.myStatusMessage != null &&
                      authService.myStatusMessage!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '— ${authService.myStatusMessage}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _statusColor(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return Colors.green;
      case ContactStatus.away:
        return Colors.orange;
      case ContactStatus.dnd:
        return Colors.red;
      case ContactStatus.xa:
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }

  Widget _buildStatCards(ChatProvider chatProvider, AuthService authService, bool isMobile) {
    final totalUnread = chatProvider.conversations.fold<int>(0, (sum, c) => sum + c.unreadCount);
    final contactCount = chatProvider.contacts.length;
    final pendingRequests = chatProvider.pendingSubscriptions.length;
    final connectedAccounts = authService.connectedAccountIds.length;

    final stats = [
      _StatData(Icons.mark_chat_unread_rounded, '$totalUnread', 'Unread', totalUnread > 0 ? GibberTheme.arcticBlue : Colors.grey),
      _StatData(Icons.people_outline_rounded, '$contactCount', 'Contacts', const Color(0xFF10B981)),
      _StatData(Icons.person_add_rounded, '$pendingRequests', 'Requests', pendingRequests > 0 ? Colors.orange : Colors.grey),
      _StatData(Icons.cloud_done_rounded, '$connectedAccounts', 'Accounts', const Color(0xFF06B6D4)),
    ];

    if (isMobile) {
      return Column(
        children: [
          Row(children: [_statCard(stats[0], true), const SizedBox(width: 8), _statCard(stats[1], true)]),
          const SizedBox(height: 8),
          Row(children: [_statCard(stats[2], true), const SizedBox(width: 8), _statCard(stats[3], true)]),
        ],
      );
    }

    return Row(
      children: stats.map((s) => Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: _statCard(s, false),
      ))).toList(),
    );
  }

  Widget _statCard(_StatData stat, bool isMobile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? GibberTheme.eclipseSurface : Colors.white;

    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: stat.color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isMobile ? 8 : 10),
            decoration: BoxDecoration(
              color: stat.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(stat.icon, color: stat.color, size: isMobile ? 18 : 22),
          ),
          SizedBox(width: isMobile ? 10 : 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stat.value,
                style: TextStyle(
                  fontSize: isMobile ? 20 : 26,
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                stat.label,
                style: TextStyle(
                  fontSize: isMobile ? 11 : 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTierMiningPanel(EntitlementService entitlement, bool isMobile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? GibberTheme.eclipsePurple : GibberTheme.arcticBlue;
    final surface = isDark ? GibberTheme.eclipseSurface : Colors.white;

    final tier = entitlement.currentTier;
    final tierColor = tier == UserTier.ultimate
        ? const Color(0xFF8B5CF6)
        : tier == UserTier.pro
            ? primary
            : Colors.grey;

    final transUsed = entitlement.transcriptionSecondsUsed;
    final transLimit = entitlement.transcriptionSecondsLimit;
    final transPercent = transLimit > 0 ? (transUsed / transLimit).clamp(0.0, 1.0) : 0.0;

    final aiUsed = entitlement.aiQueriesUsed;
    final aiLimit = entitlement.aiQueriesLimit;
    final aiPercent = aiLimit > 0 ? (aiUsed / aiLimit).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tierColor.withValues(alpha: 0.25)),
        boxShadow: [BoxShadow(color: tierColor.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: tierColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tier == UserTier.ultimate
                          ? Icons.verified_rounded
                          : tier == UserTier.pro
                              ? Icons.workspaces_rounded
                              : Icons.chat_bubble_outline_rounded,
                      size: 14,
                      color: tierColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Subscription: ${tier.label}',
                      style: TextStyle(
                        color: tierColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
            ],
          ),
          SizedBox(height: isMobile ? 16 : 20),
          Text(
            'Transcription Quota',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          _quotaBar(
            transPercent,
            transLimit == -1
                ? '${(transUsed / 60).toStringAsFixed(1)} min used — Unlimited'
                : '${(transUsed / 60).toStringAsFixed(1)} / ${(transLimit / 60).toStringAsFixed(0)} min',
            primary,
          ),
          SizedBox(height: isMobile ? 12 : 16),
          Text(
            'AI Query Quota',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          _quotaBar(
            aiPercent,
            aiLimit == -1
                ? '$aiUsed used — Unlimited'
                : '$aiUsed / $aiLimit queries',
            primary,
          ),
          SizedBox(height: isMobile ? 12 : 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (isDark ? GibberTheme.eclipseDeep : const Color(0xFFF9FAFB)).withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.memory_rounded, size: 18, color: primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Subscription',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        tier == UserTier.free
                            ? 'Free plan'
                            : tier == UserTier.pro
                                ? 'Pro: \$9.99/mo'
                                : 'Ultimate: \$19.99/mo',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => context.goNamed('tier'),
                  icon: Icon(Icons.chevron_right_rounded, color: primary),
                  tooltip: 'Manage Subscription',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quotaBar(double percent, String label, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: percent.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildQuickActions(bool isMobile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? GibberTheme.eclipsePurple : GibberTheme.arcticBlue;

    final actions = [
      _QuickAction(Icons.chat_bubble_outline_rounded, 'New Chat', () {
        Provider.of<ChatProvider>(context, listen: false).setSidebarTab(0);
      }),
      _QuickAction(Icons.person_add_rounded, 'Add Buddy', () => context.goNamed('addContact')),
      _QuickAction(Icons.explore_rounded, 'Discover Rooms', () {
        Provider.of<ChatProvider>(context, listen: false).setSidebarTab(3);
      }),
      _QuickAction(Icons.dynamic_feed_rounded, 'Feed', () {
        Provider.of<ChatProvider>(context, listen: false).setSidebarTab(2);
      }),
      _QuickAction(Icons.workspaces_outline, 'Spaces', () {
        Provider.of<ChatProvider>(context, listen: false).setSidebarTab(3);
      }),
      _QuickAction(Icons.person_add_alt_1_rounded, 'Invite', () => context.goNamed('invite')),
    ];

    if (isMobile) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: actions.map((a) => _quickActionChip(a, primary, isMobile)).toList(),
      );
    }

    return Row(
      children: actions.map((a) => Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: _quickActionChip(a, primary, isMobile),
      ))).toList(),
    );
  }

  Widget _quickActionChip(_QuickAction action, Color primary, bool isMobile) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 14 : 16,
            vertical: isMobile ? 10 : 14,
          ),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: primary.withValues(alpha: 0.12)),
          ),
          child: Row(
            mainAxisAlignment: isMobile ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              Icon(action.icon, size: 18, color: primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentChats(ChatProvider chatProvider, bool isMobile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? GibberTheme.eclipseSurface : Colors.white;
    final recent = chatProvider.conversations.take(5).toList();

    if (recent.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 32, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'No conversations yet',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Start a chat or add a buddy to begin',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Recent',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              letterSpacing: -0.3,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        ...recent.map((conv) => _recentChatTile(conv, surface, isMobile)),
      ],
    );
  }

  Widget _recentChatTile(Conversation conv, Color surface, bool isMobile) {
    final lastMsg = conv.messages.isNotEmpty ? conv.messages.last : null;
    final timeStr = lastMsg != null ? DateFormat.Hm().format(lastMsg.timestamp) : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Provider.of<ChatProvider>(context, listen: false).setActiveConversation(conv.id);
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: surface.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      backgroundImage: conv.avatarBytes != null ? MemoryImage(conv.avatarBytes!) : null,
                      child: conv.avatarBytes == null
                          ? Text(
                              conv.name.isNotEmpty ? conv.name[0].toUpperCase() : '?',
                              style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary),
                            )
                          : null,
                    ),
                    if (conv.unreadCount > 0)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${conv.unreadCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              conv.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          if (timeStr.isNotEmpty)
                            Text(
                              timeStr,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastMsg?.text ?? 'No messages yet',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOnboardingTips(ChatProvider chatProvider, AuthService authService, bool isMobile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? GibberTheme.eclipsePurple : GibberTheme.arcticBlue;
    final surface = isDark ? GibberTheme.eclipseSurface : Colors.white;

    final hasContacts = chatProvider.contacts.isNotEmpty;
    final hasChats = chatProvider.conversations.isNotEmpty;

    final tips = <_OnboardingTip>[];
    if (!hasContacts) {
      tips.add(_OnboardingTip(Icons.person_add_rounded, 'Add your first buddy', 'Send a friend request to start chatting securely.', () => context.goNamed('addContact')));
    }
    if (!hasChats) {
      tips.add(_OnboardingTip(Icons.explore_rounded, 'Join a room', 'Discover public group chats and communities.', () {
        Provider.of<ChatProvider>(context, listen: false).setSidebarTab(3);
      }));
    }
    tips.add(_OnboardingTip(Icons.workspace_premium_rounded, 'Unlock more features', 'Protocol bridging and larger group calls are available with Pro and Ultimate plans.', () => context.goNamed('tier')));
    tips.add(_OnboardingTip(Icons.edit_rounded, 'Set your status', 'Let contacts know your availability.', null));

    if (tips.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Getting Started',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              letterSpacing: -0.3,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        ...tips.map((tip) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: tip.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: surface.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: primary.withValues(alpha: 0.08)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(tip.icon, color: primary, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tip.title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
                          Text(tip.desc, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (tip.onTap != null)
                      Icon(Icons.chevron_right_rounded, color: primary, size: 18),
                  ],
                ),
              ),
            ),
          ),
        )),
      ],
    );
  }
}

class _StatData {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const _StatData(this.icon, this.value, this.label, this.color);
}

class _QuickAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickAction(this.icon, this.label, this.onTap);
}

class _OnboardingTip {
  final IconData icon;
  final String title;
  final String desc;
  final VoidCallback? onTap;
  const _OnboardingTip(this.icon, this.title, this.desc, this.onTap);
}