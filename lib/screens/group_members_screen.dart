import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';

class GroupMembersScreen extends StatefulWidget {
  final Conversation conversation;

  const GroupMembersScreen({super.key, required this.conversation});

  @override
  State<GroupMembersScreen> createState() => _GroupMembersScreenState();
}

class _GroupMembersScreenState extends State<GroupMembersScreen> {
  List<RoomParticipant> _participants = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadParticipants();
  }

  Future<void> _loadParticipants() async {
    setState(() => _isLoading = true);
    final authService = Provider.of<AuthService>(context, listen: false);
    final participants = authService.getRoomParticipants(widget.conversation.id);
    if (mounted) {
      setState(() {
        _participants = participants;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.conversation.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_rounded),
            tooltip: 'Invite member',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite by JID from group settings')),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _participants.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_outline_rounded,
                          size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text('No members found',
                          style: TextStyle(color: theme.colorScheme.primary)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadParticipants,
                  child: ListView.builder(
                    itemCount: _participants.length,
                    itemBuilder: (context, index) {
                      final p = _participants[index];
                      final roleStr = (p.role != null && p.role != 'none')
                          ? p.role!
                          : (p.affiliation ?? '');

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primary.withValues(alpha: 0.1),
                          child: Text(
                            p.nickname.isNotEmpty
                                ? p.nickname[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          p.nickname,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: roleStr.isNotEmpty
                            ? Text(
                                roleStr,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _affiliationColor(roleStr),
                                ),
                              )
                            : null,
                        trailing: const Icon(Icons.more_vert_rounded, size: 18),
                        onTap: () => _showParticipantMenu(context, p),
                      );
                    },
                  ),
                ),
    );
  }

  Color _affiliationColor(String affiliation) {
    switch (affiliation.toLowerCase()) {
      case 'owner':
        return Colors.amber;
      case 'admin':
        return Colors.purple;
      case 'member':
        return Colors.green;
      case 'moderator':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  void _showParticipantMenu(BuildContext context, RoomParticipant participant) {
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = authService.activeAccountId ?? '';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              children: [
                Text(
                  'Manage ${participant.nickname}',
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Real JID: ${participant.realJid ?? "Hidden"}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('ROLES (Temporary Session)',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey)),
                ),
                ListTile(
                  leading: const Icon(Icons.record_voice_over_rounded),
                  title: const Text('Grant Voice'),
                  subtitle: const Text('Allow speaking in moderated rooms'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await authService.setMucRole(
                        accountId, widget.conversation.id, participant.nickname, 'participant');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.voice_over_off_rounded, color: Colors.orange),
                  title: const Text('Revoke Voice (Mute)'),
                  subtitle: const Text('Make user a visitor'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await authService.setMucRole(
                        accountId, widget.conversation.id, participant.nickname, 'visitor');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.security_rounded, color: Colors.blue),
                  title: const Text('Make Moderator'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await authService.setMucRole(
                        accountId, widget.conversation.id, participant.nickname, 'moderator');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: Colors.orange),
                  title: const Text('Kick User'),
                  subtitle: const Text('Remove from room temporarily'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await authService.kickUser(
                        accountId, widget.conversation.id, participant.nickname);
                  },
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8, top: 8),
                  child: Text('AFFILIATIONS (Permanent)',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey)),
                ),
                ListTile(
                  leading: const Icon(Icons.star_rounded, color: Colors.amber),
                  title: const Text('Make Owner'),
                  onTap: participant.realJid == null
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          await authService.setMucAffiliation(
                              accountId, widget.conversation.id, participant.realJid!, 'owner');
                        },
                  enabled: participant.realJid != null,
                ),
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings_rounded, color: Colors.purple),
                  title: const Text('Make Admin'),
                  onTap: participant.realJid == null
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          await authService.setMucAffiliation(
                              accountId, widget.conversation.id, participant.realJid!, 'admin');
                        },
                  enabled: participant.realJid != null,
                ),
                ListTile(
                  leading: const Icon(Icons.block_rounded, color: Colors.red),
                  title: const Text('Ban User'),
                  subtitle: const Text('Prevent from rejoining permanently'),
                  onTap: () async {
                    final jidToBan = participant.realJid ?? participant.nickname;
                    Navigator.pop(ctx);
                    await authService.banUser(
                        accountId, widget.conversation.id, jidToBan);
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
}
