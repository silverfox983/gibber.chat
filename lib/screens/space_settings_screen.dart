import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  String _accessModel = 'open';
  String _publishModel = 'publishers';
  String _notificationPref = 'all'; // 'all', 'mentions', 'off'
  bool _isLoading = false;
  bool _hasChanges = false;
  List<SpaceMember>? _members;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.space.name.isNotEmpty ? widget.space.name : widget.space.node);
    _descController = TextEditingController(text: widget.space.description ?? '');
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
  }

  Future<void> _loadMembers() async {
    final members = await widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
    if (mounted) setState(() => _members = members);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
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
          Text('PRIVACY', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _accessModel,
            decoration: const InputDecoration(labelText: 'Who Can View', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Public — Anyone can view')),
              DropdownMenuItem(value: 'authorize', child: Text('Private — Requires approval')),
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
          Text('NOTIFICATIONS', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _notificationPref,
            decoration: const InputDecoration(
              labelText: 'Alerts',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.notifications_active_outlined),
            ),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All Messages')),
              DropdownMenuItem(value: 'mentions', child: Text('Mentions Only')),
              DropdownMenuItem(value: 'off', child: Text('Muted')),
            ],
            onChanged: (val) {
              if (val != null) _saveNotificationPref(val);
            },
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Text('MEMBERS', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
              const Spacer(),
              if (_members == null) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          if (_members != null && _members!.isEmpty)
             const Padding(padding: EdgeInsets.all(16), child: Text('No members found.'))
          else if (_members != null)
             ..._members!.map((m) => ListTile(
               leading: CircleAvatar(child: Text(m.jid[0].toUpperCase())),
               title: Text(m.jid),
               subtitle: Text('Role: ${m.affiliation}'),
               trailing: const Icon(Icons.more_vert),
               onTap: () => _showMemberOptions(m),
             )),
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
}
