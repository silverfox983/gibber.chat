import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/room_participants_dialog.dart';

class RoomInfoScreen extends StatefulWidget {
  final Map<String, dynamic> room;
  final String accountId;

  const RoomInfoScreen({
    super.key,
    required this.room,
    required this.accountId,
  });

  @override
  State<RoomInfoScreen> createState() => _RoomInfoScreenState();
}

class _RoomInfoScreenState extends State<RoomInfoScreen> {
  Map<String, dynamic> _roomInfo = {};
  bool _isBookmarked = false;

  @override
  void initState() {
    super.initState();
    _roomInfo = Map<String, dynamic>.from(widget.room);
    _loadRoomInfo();
    _checkBookmark();
  }

  Future<void> _loadRoomInfo() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    try {
      final info = await authService.getMucRoomInfo(widget.accountId, widget.room['jid']!);
      if (mounted) {
        setState(() {
          _roomInfo = {..._roomInfo, ...info};
        });
      }
    } catch (e) {
      debugPrint('RoomInfo: load failed: $e');
    }
  }

  void _checkBookmark() {
    final authService = Provider.of<AuthService>(context, listen: false);
    final roomJid = widget.room['jid']?.toString().toLowerCase() ?? '';
    final isJoined = authService.joinedRooms.any((r) => r.id.toLowerCase() == roomJid);
    setState(() => _isBookmarked = isJoined);
  }

  Future<void> _toggleBookmark() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final roomJid = widget.room['jid']!;
    final nickname = authService.getResolvedNickname(widget.accountId);

    if (_isBookmarked) {
      await authService.leaveRoom(widget.accountId, roomJid);
      if (mounted) {
        setState(() => _isBookmarked = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Removed bookmark'), backgroundColor: Colors.orange),
        );
      }
    } else {
      final error = await authService.joinXmppRoom(roomJid, nickname, accountId: widget.accountId);
      if (mounted) {
        if (error == null) {
          setState(() => _isBookmarked = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bookmarked room'), backgroundColor: Colors.green),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $error'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _joinRoom() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final nickname = authService.currentProfile?.nickName ??
                     authService.currentProfile?.displayName ?? 'User';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Joining ${widget.room['name']}...'), duration: const Duration(seconds: 1)),
    );

    try {
      await authService.joinRoom(widget.accountId, widget.room['jid']!, nickname);
      if (mounted) {
        setState(() => _isBookmarked = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined ${widget.room['name']}'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to join: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final authService = Provider.of<AuthService>(context);

    final name = (_roomInfo['name'] ?? 'Untitled Room').toString().replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    final jid = _roomInfo['jid']?.toString() ?? 'Unknown JID';
    final topic = (_roomInfo['topic'] != null && _roomInfo['topic'].toString().isNotEmpty
        ? _roomInfo['topic'].toString() : 'No topic set')
        .replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    final description = _roomInfo['description']?.toString() ?? '';
    final userCount = _roomInfo['users']?.toString().trim() ?? '0';
    final isPasswordProtected = _roomInfo['password_protected'] == true || _roomInfo['passwordprotected'] == '1';
    final isPublic = _roomInfo['muc#roominfo_publicroom'] == '1' || _roomInfo['public'] == true;
    final isPersistent = _roomInfo['muc#roominfo_persistentroom'] == '1' || _roomInfo['persistent'] == true;
    final isMembersOnly = _roomInfo['muc#roominfo_membersonly'] == '1' || _roomInfo['membersonly'] == true;
    final isModerated = _roomInfo['muc#roominfo_moderatedroom'] == '1' || _roomInfo['moderated'] == true;
    final isAnonymous = _roomInfo['muc#roominfo_anonymity'] == 'semi-anonymous' || _roomInfo['anonymous'] == true;
    final features = _roomInfo['features'] as List<dynamic>?;

    final roomJid = _roomInfo['jid']?.toString() ?? '';
    final participants = authService.getRoomParticipants(roomJid.toLowerCase());

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Room Details'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(_isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_outline_rounded),
            tooltip: _isBookmarked ? 'Remove bookmark' : 'Bookmark room',
            onPressed: _toggleBookmark,
          ),
        ],
      ),
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3), width: 2),
                          boxShadow: [
                            BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.2), blurRadius: 20, spreadRadius: 2),
                          ],
                        ),
                        child: Icon(
                          isPasswordProtected ? Icons.lock_rounded : Icons.groups_rounded,
                          size: 40,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Text(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 6),

                    Center(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          _badge(theme, 'XMPP', theme.colorScheme.primary),
                          if (isPublic) _badge(theme, 'Public', Colors.green),
                          if (isMembersOnly) _badge(theme, 'Members Only', Colors.orange),
                          if (isPasswordProtected) _badge(theme, 'Protected', Colors.redAccent),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDetailRow(context, Icons.link_rounded, 'Address', jid),
                              const SizedBox(height: 16),
                              _buildDetailRow(context, Icons.people_rounded, 'Users', userCount),
                              if (description.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                _buildDetailRow(context, Icons.description_rounded, 'Description', description, isTopic: true),
                              ],
                              const SizedBox(height: 16),
                              _buildDetailRow(context, Icons.format_quote_rounded, 'Topic', topic, isTopic: true),

                              const Divider(height: 32),

                              Text('FEATURES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7))),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  if (isPersistent) _featureChip(theme, Icons.save_rounded, 'Persistent'),
                                  if (!isPersistent) _featureChip(theme, Icons.flash_on_rounded, 'Ephemeral'),
                                  if (isModerated) _featureChip(theme, Icons.gavel_rounded, 'Moderated'),
                                  if (isAnonymous) _featureChip(theme, Icons.visibility_off_rounded, 'Semi-Anonymous'),
                                  if (isPublic) _featureChip(theme, Icons.public_rounded, 'Discoverable'),
                                  if (isMembersOnly) _featureChip(theme, Icons.vpn_key_rounded, 'Invite Only'),
                                  if (features != null)
                                    for (var f in features)
                                      if (f is String && !['public_room', 'persistent_room', 'membersonly', 'passwordprotected', 'moderated'].any((k) => f.contains(k)))
                                        _featureChip(theme, Icons.check_circle_outline, f.split('#').last.replaceAll('_', ' ')),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (participants.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.people_outline_rounded, size: 18, color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    Text('OCCUPANTS (${participants.length})', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7))),
                                    const Spacer(),
                                    TextButton(
                                      onPressed: () => showDialog(
                                        context: context,
                                        builder: (ctx) => RoomParticipantsDialog(roomJid: roomJid, roomName: name),
                                      ),
                                      child: const Text('VIEW ALL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                ...participants.take(5).map((p) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: CircleAvatar(
                                    radius: 14,
                                    backgroundColor: theme.colorScheme.primaryContainer,
                                    child: Text(
                                      p.nickname.isNotEmpty ? p.nickname[0].toUpperCase() : '?',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer),
                                    ),
                                  ),
                                  title: Text(p.nickname, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  trailing: p.affiliation != null && p.affiliation != 'none'
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _affiliationColor(p.affiliation).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(p.affiliation!.toUpperCase(), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: _affiliationColor(p.affiliation))),
                                      )
                                    : null,
                                )),
                                if (participants.length > 5)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text('+ ${participants.length - 5} more', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    ElevatedButton(
                      onPressed: _joinRoom,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 8,
                        shadowColor: theme.colorScheme.primary.withValues(alpha: 0.5),
                      ),
                      child: const Text(
                        'CONNECT TO ROOM',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _affiliationColor(String? affiliation) {
    switch (affiliation) {
      case 'owner': return Colors.amber;
      case 'admin': return Colors.purple;
      case 'member': return Colors.green;
      default: return Colors.grey;
    }
  }

  Widget _badge(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: color)),
    );
  }

  Widget _featureChip(ThemeData theme, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(BuildContext context, IconData icon, String label, String value, {bool isTopic = false}) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: isTopic ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                  fontStyle: isTopic && value == 'No topic set' ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}