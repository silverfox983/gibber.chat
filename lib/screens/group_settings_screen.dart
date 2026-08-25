import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/xmpp_room_service.dart';
import '../providers/chat_provider.dart';
import '../models/chat_models.dart';

class GroupSettingsScreen extends StatefulWidget {
  final Conversation conversation;

  const GroupSettingsScreen({super.key, required this.conversation});

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _topicController;
  String _notificationAction = 'notify';
  bool _isLoadingNotifSettings = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.conversation.name);
    _topicController = TextEditingController();
    _loadNotificationSettings();
  }

  Future<void> _loadNotificationSettings() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.conversation.accountId ?? authService.activeAccountId;
    if (accountId == null) {
      if (mounted) setState(() => _isLoadingNotifSettings = false);
      return;
    }
    try {
      final settings = await authService.roomService.getChatNotificationSettings(accountId, widget.conversation.id);
      if (mounted && settings != null) {
        setState(() {
          _notificationAction = settings.effectiveAction;
          _isLoadingNotifSettings = false;
        });
      } else if (mounted) {
        setState(() => _isLoadingNotifSettings = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingNotifSettings = false);
    }
  }

  Future<void> _updateNotificationAction(String action) async {
    setState(() => _notificationAction = action);
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.conversation.accountId ?? authService.activeAccountId;
    if (accountId == null) return;

    final settings = ChatNotificationSettings(
      peerJid: widget.conversation.id,
      rules: [NotificationRule(action: action)],
    );
    await authService.roomService.setChatNotificationSettings(accountId, widget.conversation.id, settings);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final chatProvider = Provider.of<ChatProvider>(context);
    final theme = Theme.of(context);
    
    // Get the latest conversation state from provider
    final conversation = chatProvider.conversations.firstWhere(
      (c) => c.id == widget.conversation.id,
      orElse: () => widget.conversation,
    );

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Group Settings'),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: () {
                  authService.requestRoomConfig(
                    conversation.accountId ?? '',
                    conversation.id,
                  );
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader(context, 'ROOM INFO'),
                  const SizedBox(height: 16),
                  _buildCard(
                    context,
                    child: Column(
                      children: [
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Room Name / Topic',
                            border: InputBorder.none,
                            prefixIcon: Icon(Icons.title_rounded),
                          ),
                        ),
                        const Divider(height: 1),
                        TextField(
                          controller: _topicController,
                          decoration: const InputDecoration(
                            labelText: 'Description / Secondary Topic',
                            border: InputBorder.none,
                            prefixIcon: Icon(Icons.topic_outlined),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  _buildSectionHeader(context, 'PARTICIPANTS'),
                  const SizedBox(height: 16),
                  _buildParticipantList(context, authService, conversation),
                  const SizedBox(height: 32),
                  _buildSectionHeader(context, 'NOTIFICATIONS (XEP-0492)'),
                  const SizedBox(height: 16),
                  _buildNotificationSection(context, theme),
                  const SizedBox(height: 32),
                  _buildSectionHeader(context, 'DANGER ZONE'),
                  const SizedBox(height: 16),
                  _buildCard(
                    context,
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.2),
                    child: ListTile(
                      leading: Icon(Icons.exit_to_app_rounded, color: theme.colorScheme.error),
                      title: Text(
                        'Leave Group',
                        style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold),
                      ),
                      onTap: () {
                        authService.leaveRoom(
                          conversation.accountId ?? '',
                          conversation.id,
                        );
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () async {
          final fields = {
            'muc#roomconfig_roomname': _nameController.text,
            'muc#roomconfig_roomdesc': _topicController.text,
          };
          await authService.submitRoomConfig(
            conversation.accountId ?? '',
            conversation.id,
            fields,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Room configuration updated')),
            );
            Navigator.of(context).pop();
          }
        },
        label: const Text('Save Changes'),
        icon: const Icon(Icons.save_rounded),
      ),
    );
  }

  Widget _buildNotificationSection(BuildContext context, ThemeData theme) {
    final options = [
      ('notify', 'All Messages', Icons.notifications_rounded, 'Notify for every message'),
      ('mention', 'Mentions Only', Icons.alternate_email_rounded, 'Notify only when mentioned'),
      ('mute', 'Muted', Icons.notifications_off_rounded, 'No notifications'),
    ];

    return _buildCard(
      context,
      child: Column(
        children: [
          if (_isLoadingNotifSettings)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            ...options.map((opt) {
              final (action, label, icon, description) = opt;
              final isSelected = _notificationAction == action;
              return ListTile(
                leading: Icon(icon, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                title: Text(label, style: TextStyle(fontWeight: isSelected ? FontWeight.w900 : FontWeight.w500)),
                subtitle: Text(description, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                trailing: isSelected
                    ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
                    : null,
                onTap: () => _updateNotificationAction(action),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.5,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildCard(BuildContext context, {required Widget child, Color? color}) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: child,
    );
  }

  Widget _buildParticipantList(BuildContext context, AuthService authService, Conversation conversation) {
    final participants = conversation.participants;
    
    return _buildCard(
      context,
      child: Column(
        children: [
          if (participants.isEmpty)
            const ListTile(
              title: Text('No active participants found', style: TextStyle(color: Colors.black38, fontSize: 14)),
              leading: Icon(Icons.people_outline_rounded, color: Colors.black26),
            )
          else
            ...participants.map((p) => ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                child: Text(p.nickname.isNotEmpty ? p.nickname[0].toUpperCase() : '?', style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              title: Text(p.nickname, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(p.role != null && p.role != 'none' ? p.role! : (p.affiliation ?? 'Member'), style: const TextStyle(fontSize: 11)),
              trailing: p.nickname.toLowerCase() == (authService.currentProfile?.displayName ?? '').toLowerCase()
                ? const Icon(Icons.person_pin_rounded, color: Colors.blue, size: 16)
                : null,
            )),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('Invite Participant'),
            onTap: () {
               // Show invite dialog or logic
               _showInviteDialog(context, authService, conversation);
            },
          ),
        ],
      ),
    );
  }

  void _showInviteDialog(BuildContext context, AuthService authService, Conversation conversation) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite Participant'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter JID or Nickname'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final targetJid = controller.text.trim();
              if (targetJid.isNotEmpty) {
                // Send BOTH Mediated and Direct for maximum compatibility
                authService.inviteToRoom(
                  conversation.accountId ?? '',
                  conversation.id,
                  targetJid,
                );
                authService.inviteToRoomDirect(
                  conversation.accountId ?? '',
                  conversation.id,
                  targetJid,
                );
              }
              Navigator.pop(ctx);
            },
            child: const Text('Invite'),
          ),
        ],
      ),
    );
  }
}