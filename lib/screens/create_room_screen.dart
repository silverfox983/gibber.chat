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
  String? _selectedAccountId;
  String _selectedProtocol = 'XMPP';
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _jidController = TextEditingController();
    final authService = Provider.of<AuthService>(context, listen: false);
    if (authService.savedAccounts.isNotEmpty) {
      _selectedAccountId = authService.savedAccounts.first.fullJid;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _jidController.dispose();
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (!_formKey.currentState!.validate() || _selectedAccountId == null) return;

    setState(() => _isCreating = true);

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final nick = authService.currentProfile?.nickName ?? authService.currentProfile?.displayName ?? 'Admin';
      
      if (_selectedProtocol == 'XMPP') {
        final error = await authService.createXmppRoom(
          _jidController.text.trim().toLowerCase(), 
          nick,
          accountId: _selectedAccountId,
        );
        if (error != null) throw error;
      } else {
        // IRC Channel Join/Creation
        final error = await authService.joinIrcChannel(
          _jidController.text.trim(),
          accountId: _selectedAccountId,
        );
        if (error != null) throw error;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_selectedProtocol == 'XMPP' ? 'Room Created' : 'Joined Channel'} Successfully!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group Chat', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        foregroundColor: Theme.of(context).appBarTheme.foregroundColor,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PROTOCOL & ACCOUNT', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black45, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              Row(
                children: [
                   Expanded(
                     child: _buildProtocolTab('XMPP', Icons.security_rounded),
                   ),
                   const SizedBox(width: 12),
                   Expanded(
                     child: _buildProtocolTab('IRC', Icons.language_rounded),
                   ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedAccountId,
                    items: authService.savedAccounts.where((a) => a.protocol == _selectedProtocol).map((acc) {
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
              const Text('ROOM IDENTITY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black45, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Room Name', 
                controller: _nameController, 
                icon: Icons.badge_rounded,
                hint: 'The Chill Zone',
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: _selectedProtocol == 'XMPP' ? 'Room JID' : 'Channel Name', 
                controller: _jidController, 
                icon: Icons.alternate_email_rounded,
                hint: _selectedProtocol == 'XMPP' ? 'chill@conference.server.id' : '#channel',
                validator: (v) {
                  if (_selectedProtocol == 'XMPP') {
                    if (v == null || !v.contains('@')) return 'Enter a valid MUC JID';
                  } else {
                    if (v == null || !v.startsWith('#')) return 'IRC channels must start with #';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  onPressed: _isCreating ? null : _createRoom,
                  child: _isCreating 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(_selectedProtocol == 'XMPP' ? 'CREATE INSTANT ROOM' : 'JOIN CHANNEL', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'Created rooms are initialized with default settings.',
                  style: TextStyle(color: Colors.black38, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label, 
    required TextEditingController controller, 
    required IconData icon, 
    String? hint,
    String? Function(String?)? validator
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12),
      ),
      child: TextFormField(
        controller: controller,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, color: Theme.of(context).colorScheme.secondary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
          labelStyle: const TextStyle(color: Colors.black45, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildProtocolTab(String protocol, IconData icon) {
    final isSelected = _selectedProtocol == protocol;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedProtocol = protocol;
          final accounts = Provider.of<AuthService>(context, listen: false)
              .savedAccounts
              .where((a) => a.protocol == protocol)
              .toList();
          _selectedAccountId = accounts.isNotEmpty ? accounts.first.fullJid : null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? Colors.transparent : Colors.black12),
          boxShadow: isSelected ? [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))] : null,
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? Colors.white : Colors.black45, size: 20),
            const SizedBox(height: 4),
            Text(protocol, style: TextStyle(color: isSelected ? Colors.white : Colors.black45, fontWeight: FontWeight.w800, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
