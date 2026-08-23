import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/space_models.dart';
import '../services/auth_service.dart';
import '../services/spaces_service.dart';

class SpaceSettingsScreen extends StatefulWidget {
  final SpaceNode space;
  final SpacesService spacesService;

  const SpaceSettingsScreen({
    super.key,
    required this.space,
    required this.spacesService,
  });

  @override
  State<SpaceSettingsScreen> createState() => _SpaceSettingsScreenState();
}

class _SpaceSettingsScreenState extends State<SpaceSettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _memberSearchController;
  String _accessModel = 'open';
  String _publishModel = 'publishers';
  String _notificationPref = 'all'; // 'all', 'mentions', 'off'
  bool _isLoading = false;
  bool _hasChanges = false;
  List<SpaceMember>? _members;
  List<SpaceMember> _pendingMembers = [];
  bool _loadingPending = false;
  bool _uploadingAvatar = false;
  bool _uploadingCover = false;
  Uint8List? _avatarPreview;
  Uint8List? _coverPreview;

  List<SpaceMember> get _filteredMembers {
    if (_members == null) return [];
    final q = _memberSearchController.text.toLowerCase();
    if (q.isEmpty) return _members!;
    return _members!.where((m) => m.jid.toLowerCase().contains(q)).toList();
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.space.name.isNotEmpty ? widget.space.name : widget.space.node);
    _descController = TextEditingController(text: widget.space.description ?? '');
    _memberSearchController = TextEditingController();
    _accessModel = widget.space.accessModel ?? 'open';
    _publishModel = widget.space.publishModel ?? 'publishers';
    _nameController.addListener(_onFormChanged);
    _descController.addListener(_onFormChanged);
    _loadMembers();
    _loadNotificationPref();
  }

  void _onFormChanged() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  Future<void> _loadNotificationPref() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'notif_level_${widget.space.domain}|${widget.space.node}';
    final pref = prefs.getString(key);
    if (pref != null && mounted) {
      setState(() => _notificationPref = pref);
    }
  }

  Future<void> _saveNotificationPref(String val) async {
    setState(() => _notificationPref = val);
    final prefs = await SharedPreferences.getInstance();
    final key = 'notif_level_${widget.space.domain}|${widget.space.node}';
    await prefs.setString(key, val);
    await widget.spacesService.setSpaceNotificationLevel(
      widget.space.domain, widget.space.node, val,
    );
  }

  Future<void> _loadMembers() async {
    final members = await widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
    if (mounted) setState(() => _members = members);
    _loadPendingMembers();
  }

  Future<void> _loadPendingMembers() async {
    setState(() => _loadingPending = true);
    final pending = await widget.spacesService.fetchPendingSubscribers(widget.space.domain, widget.space.node);
    if (mounted) setState(() { _pendingMembers = pending; _loadingPending = false; });
  }

  Future<void> _approveJoinRequest(SpaceMember member) async {
    final ok = await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'member');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '${member.jid} approved' : 'Failed to approve ${member.jid}')),
      );
      if (ok) {
        _loadPendingMembers();
        _loadMembers();
      }
    }
  }

  Future<void> _denyJoinRequest(SpaceMember member) async {
    final ok = await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'none');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '${member.jid} denied' : 'Failed to deny ${member.jid}')),
      );
      if (ok) _loadPendingMembers();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _memberSearchController.dispose();
    super.dispose();
  }

  Widget _notifTile(IconData icon, String title, String subtitle, String value, ThemeData theme) {
    final isSelected = _notificationPref == value;
    return GestureDetector(
      onTap: () {
        setState(() => _notificationPref = value);
        _saveNotificationPref(value);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3) : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withValues(alpha: 0.3),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(icon, size: 22, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isSelected ? theme.colorScheme.primary : null)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ])),
          if (isSelected) Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 22),
        ]),
      ),
    );
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    final error = await widget.spacesService.updateSpaceConfig(
      widget.space.domain,
      widget.space.node,
      name: _nameController.text.trim(),
      description: _descController.text.trim(),
      accessModel: _accessModel,
      publishModel: _publishModel,
    );
    if (mounted) {
      setState(() => _isLoading = false);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved successfully!')));
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _changeAffiliation(SpaceMember member, String newAffiliation) async {
    final success = await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, newAffiliation);
    if (success) {
      _loadMembers();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Role updated')));
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update role')));
    }
  }

  void _showMemberOptions(SpaceMember member) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('Manage ${member.jid}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              const Divider(),
              _roleTile(member, 'owner', 'Owner', Icons.star),
              _roleTile(member, 'publisher', 'Publisher', Icons.edit),
              _roleTile(member, 'member', 'Member', Icons.person),
              _roleTile(member, 'none', 'Remove from Space', Icons.person_remove, color: Colors.red),
              _roleTile(member, 'outcast', 'Ban (Outcast)', Icons.block, color: Colors.red),
            ],
          ),
        );
      }
    );
  }

  Widget _roleTile(SpaceMember member, String role, String title, IconData icon, {Color? color}) {
    final isCurrent = member.affiliation == role;
    return ListTile(
      leading: Icon(icon, color: color ?? (isCurrent ? Colors.blue : null)),
      title: Text(title, style: TextStyle(color: color ?? (isCurrent ? Colors.blue : null), fontWeight: isCurrent ? FontWeight.bold : null)),
      trailing: isCurrent ? const Icon(Icons.check, color: Colors.blue) : null,
      onTap: () {
        Navigator.pop(context);
        if (!isCurrent) _changeAffiliation(member, role);
      },
    );
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;

    final bytes = await file.readAsBytes();
    final contentType = 'image/${file.path.split('.').last.toLowerCase()}';

    setState(() { _uploadingAvatar = true; _avatarPreview = bytes; });

    final auth = Provider.of<AuthService>(context, listen: false);
    final uploadService = auth.activeUploadService;
    if (uploadService == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('HTTP Upload not available on this server.')),
      );
      setState(() { _uploadingAvatar = false; _avatarPreview = null; });
      return;
    }

    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.${file.path.split('.').last}';
    final size = bytes.length;

    try {
      final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
      if (slot == null) throw Exception('Failed to request upload slot.');

      final uploaded = await uploadService.uploadFile(slot['put']!, bytes, contentType);
      if (!uploaded) throw Exception('Upload failed.');

      final imageUrl = slot['get']!;
      final ownerJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? '';
      final error = await widget.spacesService.setSpaceAvatar(
        widget.space.domain, widget.space.node, imageUrl, contentType, ownerJid,
      );

      if (mounted) {
        if (error != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
          setState(() { _uploadingAvatar = false; _avatarPreview = null; });
        } else {
          setState(() { _uploadingAvatar = false; });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Avatar updated!')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() { _uploadingAvatar = false; _avatarPreview = null; });
      }
    }
  }

  Future<void> _pickAndUploadCover() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;

    final bytes = await file.readAsBytes();
    final contentType = 'image/${file.path.split('.').last.toLowerCase()}';

    setState(() { _uploadingCover = true; _coverPreview = bytes; });

    final auth = Provider.of<AuthService>(context, listen: false);
    final uploadService = auth.activeUploadService;
    if (uploadService == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('HTTP Upload not available on this server.')),
      );
      setState(() { _uploadingCover = false; _coverPreview = null; });
      return;
    }

    final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}.${file.path.split('.').last}';
    final size = bytes.length;

    try {
      final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
      if (slot == null) throw Exception('Failed to request upload slot.');

      final uploaded = await uploadService.uploadFile(slot['put']!, bytes, contentType);
      if (!uploaded) throw Exception('Upload failed.');

      final imageUrl = slot['get']!;
      final ownerJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? '';
      final error = await widget.spacesService.setSpaceBanner(
        widget.space.domain, widget.space.node, imageUrl, contentType, ownerJid,
      );

      if (mounted) {
        if (error != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
          setState(() { _uploadingCover = false; _coverPreview = null; });
        } else {
          setState(() { _uploadingCover = false; });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cover updated!')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() { _uploadingCover = false; _coverPreview = null; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Space Settings'),
        actions: [
          if (_isLoading)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            TextButton(
              onPressed: _hasChanges ? _saveSettings : null,
              child: Text(_hasChanges ? 'Save' : 'Saved', style: TextStyle(color: _hasChanges ? null : Colors.grey)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('GENERAL', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Space Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descController,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          Text('AVATAR & COVER', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          // Avatar row
          Row(children: [
            GestureDetector(
              onTap: () => _pickAndUploadAvatar(),
              child: Stack(children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  backgroundImage: _avatarPreview != null ? MemoryImage(_avatarPreview!) : (widget.space.avatarUrl != null ? NetworkImage(widget.space.avatarUrl!) : null),
                  child: _avatarPreview == null && widget.space.avatarUrl == null
                      ? Icon(Icons.public_rounded, size: 32, color: theme.colorScheme.onPrimaryContainer)
                      : null,
                ),
                if (_uploadingAvatar)
                  Positioned.fill(child: CircleAvatar(backgroundColor: Colors.black38, child: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))),
                Positioned(
                  bottom: 0, right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt_rounded, size: 14, color: Colors.white),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Avatar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 4),
              Text('Tap to upload a new avatar image', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ])),
          ]),
          const SizedBox(height: 20),
          // Cover image
          Text('Cover Image', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _pickAndUploadCover(),
            child: Container(
              height: 120,
              width: double.infinity,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
                image: _coverPreview != null ? DecorationImage(image: MemoryImage(_coverPreview!), fit: BoxFit.cover) : (widget.space.coverUrl != null ? DecorationImage(image: NetworkImage(widget.space.coverUrl!), fit: BoxFit.cover) : null),
              ),
              child: _coverPreview == null && widget.space.coverUrl == null
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.add_photo_alternate_rounded, size: 32, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                      const SizedBox(height: 8),
                      Text('Tap to add a cover image', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6))),
                    ])
                  : (_uploadingCover
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(children: [
                          Positioned(top: 8, right: 8, child: Container(padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.white)))])),
            ),
          ),
          const SizedBox(height: 24),
          Text('PRIVACY', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _accessModel,
            decoration: const InputDecoration(labelText: 'Who Can View', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Public — Anyone can view')),
              DropdownMenuItem(value: 'authorize', child: Text('Private — Requires approval')),
              DropdownMenuItem(value: 'whitelist', child: Text('Whitelist — Owner invites only')),
            ],
            onChanged: (val) {
              if (val != null) { setState(() { _accessModel = val; _hasChanges = true; }); }
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _publishModel,
            decoration: const InputDecoration(labelText: 'Who Can Post', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Anyone — All members can post')),
              DropdownMenuItem(value: 'publishers', child: Text('Admins Only — Moderated posting')),
              DropdownMenuItem(value: 'subscribers', child: Text('Subscribers Only')),
            ],
            onChanged: (val) {
              if (val != null) { setState(() { _publishModel = val; _hasChanges = true; }); }
            },
          ),
          const SizedBox(height: 24),
          Text('INVITE', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          _buildInviteKeySection(theme),
          const SizedBox(height: 24),
          Text('NOTIFICATIONS', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          _notifTile(Icons.notifications_active_rounded, 'All Notifications', 'Get notified for every new post', 'all', theme),
          const SizedBox(height: 8),
          _notifTile(Icons.alternate_email_rounded, 'Mentions Only', 'Only when someone @mentions you', 'mentions', theme),
          const SizedBox(height: 8),
          _notifTile(Icons.notifications_off_rounded, 'Muted', 'No notifications from this space', 'off', theme),
          const SizedBox(height: 32),
          Row(
            children: [
              Text('MEMBERS', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: const Text('Invite'),
                onPressed: () => _showInviteByJidDialog(theme),
              ),
              if (_members == null) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _memberSearchController,
            decoration: InputDecoration(
              hintText: 'Search members...',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          if (_members != null && _members!.isEmpty)
             const Padding(padding: EdgeInsets.all(16), child: Text('No members found.'))
          else if (_members != null)
             ..._filteredMembers.map((m) => ListTile(
               leading: CircleAvatar(child: Text(m.jid[0].toUpperCase())),
               title: Text(m.jid),
               subtitle: Text('Role: ${m.affiliation}'),
               trailing: const Icon(Icons.more_vert),
               onTap: () => _showMemberOptions(m),
              )),
          if (_pendingMembers.isNotEmpty) ...[
            const SizedBox(height: 32),
            Row(
              children: [
                Text('JOIN REQUESTS', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, letterSpacing: 1.2, fontSize: 12)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(10)),
                  child: Text('${_pendingMembers.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                if (_loadingPending) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            ..._pendingMembers.map((m) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.orange.withValues(alpha: 0.2),
                    child: Text(m.jid[0].toUpperCase(), style: const TextStyle(color: Colors.orange)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.jid, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        Text('Requested to join', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check_circle, color: Colors.green),
                    tooltip: 'Approve',
                    onPressed: () => _approveJoinRequest(m),
                  ),
                  IconButton(
                    icon: const Icon(Icons.cancel, color: Colors.red),
                    tooltip: 'Deny',
                    onPressed: () => _denyJoinRequest(m),
                  ),
                ],
              ),
            )),
          ],
          const SizedBox(height: 32),
          Text('DANGER ZONE', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, side: const BorderSide(color: Colors.orange)),
            icon: const Icon(Icons.exit_to_app),
            label: const Text('Leave Space'),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Leave Space?'),
                  content: Text('You will stop receiving updates from "${widget.space.name}". You can rejoin later if it is public.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Leave'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                final auth = Provider.of<AuthService>(context, listen: false);
                await auth.leavePersistedSpace(widget.space.domain, widget.space.node);
                if (!context.mounted) return;
                Navigator.pop(context, 'left');
              }
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete Space'),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Delete Space?'),
                  content: const Text('This action cannot be undone. All posts and data will be permanently deleted.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(dialogContext, true), 
                      child: const Text('Delete')
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                final success = await widget.spacesService.deleteSpace(widget.space.domain, widget.space.node);
                if (!context.mounted) return;
                if (success) {
                  Navigator.pop(context, 'deleted');
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete space')));
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInviteKeySection(ThemeData theme) {
    final inviteUri = 'xmpp:${widget.space.domain}?;node=${widget.space.node}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.qr_code_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text('Invite Key', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: theme.colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
            ),
            child: Text(
              inviteUri,
              style: TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: QrImageView(
              data: inviteUri,
              version: QrVersions.auto,
              size: 160,
              backgroundColor: Colors.white,
              foregroundColor: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: inviteUri));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Invite key copied!'), duration: Duration(seconds: 2)),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Share.shareUri(Uri.parse(inviteUri));
                  },
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: const Text('Share'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showInviteByJidDialog(ThemeData theme) {
    final controller = TextEditingController();
    bool inviting = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Invite Member'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'JID or username',
              hintText: 'user@domain.org',
              prefixIcon: Icon(Icons.person_add_rounded),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: inviting ? null : () async {
                final jid = controller.text.trim();
                if (jid.isEmpty) return;
                setDialogState(() => inviting = true);
                Navigator.pop(ctx);
                await _inviteUserToSpace(jid);
              },
              child: inviting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Invite'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _inviteUserToSpace(String jid) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final ok = await widget.spacesService.inviteMember(widget.space.domain, widget.space.node, jid, 'member');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Invitation sent to $jid' : 'Failed to invite $jid')),
      );
      if (ok) _loadMembers();
    }
  }
}
