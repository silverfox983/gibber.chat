import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class CreateRoomScreen extends StatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _jidController;
  late TextEditingController _descriptionController;
  String? _selectedAccountId;
  bool _isCreating = false;
  bool _isPublic = true;
  bool _isPersistent = true;
  bool _isMembersOnly = false;
  bool _allowMemberInvites = true;
  bool _changeSubject = true;
  int _historyLength = 50;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _jidController = TextEditingController();
    _descriptionController = TextEditingController();
    final authService = Provider.of<AuthService>(context, listen: false);
    final xmppAccounts = authService.savedAccounts.where((a) => a.protocol == 'XMPP').toList();
    if (xmppAccounts.isNotEmpty) {
      _selectedAccountId = xmppAccounts.first.fullJid;
    }

    _nameController.addListener(() {
      if (_selectedAccountId != null && _nameController.text.isNotEmpty) {
        final domain = _selectedAccountId!.split('@').last;
        final formattedName = _nameController.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '-');
        if (formattedName.isNotEmpty && !_jidController.text.contains('@')) {
           _jidController.text = '$formattedName@conference.$domain';
        }
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _jidController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (!_formKey.currentState!.validate() || _selectedAccountId == null) return;

    setState(() => _isCreating = true);

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final nick = authService.getResolvedNickname(_selectedAccountId);

      final error = await authService.createXmppRoom(
        _jidController.text.trim().toLowerCase(),
        nick,
        accountId: _selectedAccountId,
      );
      if (error != null) throw error;

      if (_descriptionController.text.isNotEmpty || !_isPublic || !_isPersistent || _isMembersOnly) {
        final configError = await authService.configureXmppRoom(
          _jidController.text.trim().toLowerCase(),
          accountId: _selectedAccountId,
          name: _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : null,
          description: _descriptionController.text.trim().isNotEmpty ? _descriptionController.text.trim() : null,
          isPublic: _isPublic,
          isPersistent: _isPersistent,
          isMembersOnly: _isMembersOnly,
          allowMemberInvites: _allowMemberInvites,
          changeSubject: _changeSubject,
          historyLength: _historyLength,
        );
        if (configError != null) throw configError;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Room Created Successfully!'), backgroundColor: Theme.of(context).colorScheme.secondary),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final xmppAccounts = authService.savedAccounts.where((a) => a.protocol == 'XMPP').toList();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Create Group Chat'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SELECT ACCOUNT', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colorScheme.outline),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedAccountId,
                    items: xmppAccounts.map((acc) {
                      return DropdownMenuItem(
                        value: acc.fullJid,
                        child: Text(acc.fullJid, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      );
                    }).toList(),
                    onChanged: (val) => setState(() => _selectedAccountId = val),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text('ROOM IDENTITY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Room Name',
                controller: _nameController,
                icon: Icons.badge_rounded,
                hint: 'The Chill Zone',
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Room JID',
                controller: _jidController,
                icon: Icons.alternate_email_rounded,
                hint: 'chill@conference.server.id',
                validator: (v) {
                  if (v == null || !v.contains('@')) return 'Enter a valid MUC JID';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Description (optional)',
                controller: _descriptionController,
                icon: Icons.description_rounded,
                hint: 'A place to hang out and chat',
                maxLines: 2,
              ),
              const SizedBox(height: 32),
              Text('ROOM SETTINGS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              _buildSwitchTile(
                icon: Icons.public_rounded,
                title: 'Public Room',
                subtitle: 'Anyone can discover and join this room',
                value: _isPublic,
                onChanged: (v) => setState(() => _isPublic = v),
              ),
              _buildSwitchTile(
                icon: Icons.save_rounded,
                title: 'Persistent Room',
                subtitle: 'Room survives even when all participants leave',
                value: _isPersistent,
                onChanged: (v) => setState(() => _isPersistent = v),
              ),
              _buildSwitchTile(
                icon: Icons.lock_rounded,
                title: 'Members Only',
                subtitle: 'Only invited members can join',
                value: _isMembersOnly,
                onChanged: (v) => setState(() => _isMembersOnly = v),
              ),
              if (_isMembersOnly)
                _buildSwitchTile(
                  icon: Icons.person_add_rounded,
                  title: 'Allow Member Invites',
                  subtitle: 'Members can invite others without admin approval',
                  value: _allowMemberInvites,
                  onChanged: (v) => setState(() => _allowMemberInvites = v),
                ),
              _buildSwitchTile(
                icon: Icons.edit_rounded,
                title: 'Anyone Can Change Subject',
                subtitle: 'Allow all participants to change the room topic',
                value: _changeSubject,
                onChanged: (v) => setState(() => _changeSubject = v),
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.secondary,
                    foregroundColor: colorScheme.onSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  onPressed: (_isCreating || xmppAccounts.isEmpty) ? null : _createRoom,
                  child: _isCreating
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: colorScheme.onSecondary, strokeWidth: 2))
                    : const Text('CREATE ROOM', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  _isPublic ? 'Public room — anyone can find and join' : 'Private room — invitation required',
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outline.withOpacity(0.3)),
      ),
      child: SwitchListTile(
        secondary: Icon(icon, color: colorScheme.secondary, size: 22),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colorScheme.onSurface)),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        value: value,
        onChanged: onChanged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    String? hint,
    String? Function(String?)? validator,
    int maxLines = 1,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline),
      ),
      child: TextFormField(
        controller: controller,
        validator: validator,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, color: colorScheme.secondary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
          labelStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}