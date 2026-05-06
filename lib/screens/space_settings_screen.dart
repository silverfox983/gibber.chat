import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/space_models.dart';
import '../services/spaces_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String _notificationPref = 'all'; // 'all', 'mentions', 'off'
  bool _isLoading = false;
  List<SpaceMember>? _members;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.space.name.isNotEmpty ? widget.space.name : widget.space.node);
    _descController = TextEditingController(text: widget.space.description ?? '');
    _accessModel = widget.space.accessModel ?? 'open';
    _loadMembers();
    _loadNotificationPref();
  }

  Future<void> _loadNotificationPref() async {
    final prefs = await SharedPreferences.getInstance();
    final pref = prefs.getString('space_notify_${widget.space.node}');
    if (pref != null && mounted) {
      setState(() => _notificationPref = pref);
    }
  }

  Future<void> _saveNotificationPref(String val) async {
    setState(() => _notificationPref = val);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('space_notify_${widget.space.node}', val);
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
    );
    if (mounted) {
      setState(() => _isLoading = false);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved successfully!')));
        Navigator.pop(context, true); // true indicates changes were made
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
              onPressed: _saveSettings,
              child: const Text('Save'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('GENERAL', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
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
          Text('PRIVACY', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _accessModel,
            decoration: const InputDecoration(labelText: 'Access Model', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Public (Open)')),
              DropdownMenuItem(value: 'authorize', child: Text('Private (Authorize)')),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _accessModel = val);
            },
          ),
          const SizedBox(height: 24),
          Text('NOTIFICATIONS', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _notificationPref,
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
              Text('MEMBERS', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.2, fontSize: 12)),
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
          Text('DANGER ZONE', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.red, letterSpacing: 1.2, fontSize: 12)),
          const SizedBox(height: 16),
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
