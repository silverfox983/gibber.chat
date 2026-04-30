import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class GroupInviteDialog extends StatelessWidget {
  final Map<String, dynamic> invite;

  const GroupInviteDialog({super.key, required this.invite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roomJid = invite['roomJid'] as String;
    final fromJid = invite['fromJid'] as String;
    final reason = invite['reason'] as String?;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: theme.colorScheme.surface,
      title: Row(
        children: [
          Icon(Icons.group_add_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Text('Group Invitation', style: TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You have been invited to join a group chat.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          _buildInfoItem(context, 'Group', roomJid, Icons.meeting_room_rounded),
          const SizedBox(height: 12),
          _buildInfoItem(context, 'Invited by', fromJid, Icons.person_rounded),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'MESSAGE:',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.1)),
              ),
              child: Text(
                reason,
                style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Provider.of<ChatProvider>(context, listen: false).declineGroupInvite(invite);
            Navigator.pop(context);
          },
          child: Text('IGNORE', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w900)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          onPressed: () {
            Provider.of<ChatProvider>(context, listen: false).acceptGroupInvite(invite);
            Navigator.pop(context);
          },
          child: const Text('JOIN GROUP', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }

  Widget _buildInfoItem(BuildContext context, String label, String value, IconData icon) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
              Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
