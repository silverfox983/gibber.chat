import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';

class RoomParticipantsDialog extends StatelessWidget {
  final String roomJid;
  final String roomName;

  const RoomParticipantsDialog({
    super.key,
    required this.roomJid,
    required this.roomName,
  });

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return StreamBuilder<Map<String, List<RoomParticipant>>>(
      stream: authService.roomParticipantsStream,
      builder: (context, snapshot) {
        final participants = authService.joinedRooms.firstWhere(
          (r) => r.id == roomJid, 
          orElse: () => Room(id: roomJid, name: roomName, participants: [], protocol: 'XMPP')
        ).participants;
        
        final liveParticipants = snapshot.data?[roomJid.toLowerCase()] ?? participants;

        return AlertDialog(
          title: Text('Participants ($roomName)'),
          content: SizedBox(
            width: double.maxFinite,
            child: liveParticipants.isEmpty
                ? const Center(child: Text('No participants found.'))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: liveParticipants.length,
                    itemBuilder: (context, index) {
                      final participant = liveParticipants[index];
                      final roleStr = participant.role != null && participant.role != 'none' 
                          ? participant.role! 
                          : participant.affiliation ?? '';
                          
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF00BCD4).withValues(alpha: 0.1),
                          child: Text(
                            participant.nickname.isNotEmpty ? participant.nickname[0].toUpperCase() : '?', 
                            style: const TextStyle(color: Color(0xFF00BCD4), fontSize: 12, fontWeight: FontWeight.bold)
                          ),
                        ),
                        title: Text(participant.nickname, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: roleStr.isNotEmpty ? Text(roleStr, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)) : null,
                        trailing: const Icon(Icons.more_vert_rounded, color: Colors.grey, size: 18),
                        onTap: () => _showParticipantMenu(context, authService, participant),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CLOSE'),
            ),
          ],
        );
      },
    );
  }

  void _showParticipantMenu(BuildContext context, AuthService authService, RoomParticipant participant) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            final accountId = authService.activeAccountId ?? '';
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              children: [
                Text('Manage ${participant.nickname}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Real JID: ${participant.realJid ?? "Hidden"}', style: const TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
                const SizedBox(height: 24),
                const Padding(padding: EdgeInsets.only(left: 16, bottom: 8), child: Text('ROLES (Temporary Session)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey))),
                ListTile(
                  leading: const Icon(Icons.record_voice_over_rounded),
                  title: const Text('Grant Voice'),
                  subtitle: const Text('Allow speaking in moderated rooms'),
                  onTap: () async {
                    Navigator.pop(context);
                    await authService.setMucRole(accountId, roomJid, participant.nickname, 'participant');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.voice_over_off_rounded, color: Colors.orange),
                  title: const Text('Revoke Voice (Mute)'),
                  subtitle: const Text('Make user a visitor'),
                  onTap: () async {
                    Navigator.pop(context);
                    await authService.setMucRole(accountId, roomJid, participant.nickname, 'visitor');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.security_rounded, color: Colors.blue),
                  title: const Text('Make Moderator'),
                  onTap: () async {
                    Navigator.pop(context);
                    await authService.setMucRole(accountId, roomJid, participant.nickname, 'moderator');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: Colors.orange),
                  title: const Text('Kick User'),
                  subtitle: const Text('Remove from room temporarily'),
                  onTap: () async {
                    Navigator.pop(context);
                    await authService.kickUser(accountId, roomJid, participant.nickname);
                  },
                ),
                const Divider(),
                const Padding(padding: EdgeInsets.only(left: 16, bottom: 8, top: 8), child: Text('AFFILIATIONS (Permanent)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey))),
                ListTile(
                  leading: const Icon(Icons.star_rounded, color: Colors.amber),
                  title: const Text('Make Owner'),
                  onTap: () async {
                    if (participant.realJid == null) return;
                    Navigator.pop(context);
                    await authService.setMucAffiliation(accountId, roomJid, participant.realJid!, 'owner');
                  },
                  enabled: participant.realJid != null,
                ),
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings_rounded, color: Colors.purple),
                  title: const Text('Make Admin'),
                  onTap: () async {
                    if (participant.realJid == null) return;
                    Navigator.pop(context);
                    await authService.setMucAffiliation(accountId, roomJid, participant.realJid!, 'admin');
                  },
                  enabled: participant.realJid != null,
                ),
                ListTile(
                  leading: const Icon(Icons.person_add_rounded, color: Colors.green),
                  title: const Text('Make Member'),
                  subtitle: const Text('Pre-approve for invite-only'),
                  onTap: () async {
                    if (participant.realJid == null) return;
                    Navigator.pop(context);
                    await authService.setMucAffiliation(accountId, roomJid, participant.realJid!, 'member');
                  },
                  enabled: participant.realJid != null,
                ),
                ListTile(
                  leading: const Icon(Icons.block_rounded, color: Colors.red),
                  title: const Text('Ban User'),
                  subtitle: const Text('Prevent from rejoining permanently'),
                  onTap: () async {
                    // Try realJid first, fallback to nickname mapping if server supports it
                    final jidToBan = participant.realJid ?? participant.nickname;
                    Navigator.pop(context);
                    await authService.banUser(accountId, roomJid, jidToBan);
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.clear_all_rounded),
                  title: const Text('Revoke Roles & Affiliations'),
                  onTap: () async {
                    Navigator.pop(context);
                    if (participant.realJid != null) {
                      await authService.setMucAffiliation(accountId, roomJid, participant.realJid!, 'none');
                    }
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
