import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';

class RoomSettingsScreen extends StatefulWidget {
  final Conversation room;
  
  const RoomSettingsScreen({Key? key, required this.room}) : super(key: key);

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isPersistent = true;
  bool _isPublic = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.room.name;
    // We don't have the current description/password easily accessible without full dataform parsing.
    // We'll allow the owner to blindly update these.
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);

    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.room.accountId ?? authService.activeAccountId;
    
    if (accountId == null) {
      setState(() => _isLoading = false);
      return;
    }

    // XEP-0045 Standard variables
    final Map<String, String> fields = {
      'FORM_TYPE': 'http://jabber.org/protocol/muc#roomconfig',
      'muc#roomconfig_roomname': _nameController.text.trim(),
      'muc#roomconfig_roomdesc': _descController.text.trim(),
      'muc#roomconfig_persistentroom': _isPersistent ? '1' : '0',
      'muc#roomconfig_publicroom': _isPublic ? '1' : '0',
    };

    if (_passwordController.text.isNotEmpty) {
      fields['muc#roomconfig_passwordprotectedroom'] = '1';
      fields['muc#roomconfig_roomsecret'] = _passwordController.text;
    } else {
      fields['muc#roomconfig_passwordprotectedroom'] = '0';
      fields['muc#roomconfig_roomsecret'] = '';
    }

    await authService.submitRoomConfig(accountId, widget.room.id, fields);

    // Also update the room subject via message stanza to update the topic immediately
    final subject = _descController.text.trim();
    if (subject.isNotEmpty) {
       authService.sendXmppSubject(widget.room.id, subject, accountId: accountId);
    }

    if (mounted) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Room settings updated.')));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Room Settings'),
        actions: [
          if (_isLoading)
            const Center(child: Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))))
          else
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _saveSettings,
            )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Configuration is only applied if you are a Room Owner.', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Room Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descController,
            decoration: const InputDecoration(
              labelText: 'Topic / Description',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(
              labelText: 'Room Password (Optional)',
              border: OutlineInputBorder(),
              helperText: 'Leave empty to disable password.',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            title: const Text('Persistent Room'),
            subtitle: const Text('Room remains active when empty'),
            value: _isPersistent,
            onChanged: (val) => setState(() => _isPersistent = val),
          ),
          SwitchListTile(
            title: const Text('Publicly Discoverable'),
            subtitle: const Text('Room appears in server directories'),
            value: _isPublic,
            onChanged: (val) => setState(() => _isPublic = val),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
            ),
            onPressed: _isLoading ? null : _saveSettings,
            child: const Text('SAVE SETTINGS', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
