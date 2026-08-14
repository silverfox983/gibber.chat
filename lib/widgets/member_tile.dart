import 'package:flutter/material.dart';


/// Displays a single space member with avatar, name, role badge, and optional join date.
class MemberTile extends StatelessWidget {
  final String? avatarUrl;
  final String? displayName;
  final String? role;
  final DateTime? joinDate;

  const MemberTile({
    this.avatarUrl,
    this.displayName,
    this.role,
    this.joinDate,
    super.key,
  });

  Color _roleColor(BuildContext context, String? role) {
    switch (role?.toLowerCase()) {
      case 'owner':
        return Colors.deepOrange;
      case 'publisher':
        return Colors.blueAccent;
      case 'admin':
        return Colors.purple;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = displayName ?? 'Unknown';
    final roleColor = _roleColor(context, role);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primaryContainer,
        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
        child: avatarUrl == null
            ? Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                  fontSize: 16,
                ),
              )
            : null,
      ),
      title: Text(
        name,
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: joinDate != null
          ? Text(
              'Joined ${_formatDate(joinDate!)}',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: role != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: roleColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: roleColor.withValues(alpha: 0.4)),
              ),
              child: Text(
                role!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: roleColor,
                  letterSpacing: 0.4,
                ),
              ),
            )
          : null,
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
