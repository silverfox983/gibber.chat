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
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _jidController = TextEditingController();
    final authService = Provider.of<AuthService>(context, listen: false);
    final xmppAccounts = authService.savedAccounts.where((a) => a.protocol == 'XMPP').toList();
    if (xmppAccounts.isNotEmpty) {
      _selectedAccountId = xmppAccounts.first.fullJid;
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
      final nick = authService.getResolvedNickname(_selectedAccountId);
      
      final error = await authService.createXmppRoom(
        _jidController.text.trim().toLowerCase(), 
        nick,
        accountId: _selectedAccountId,
      );
      if (error != null) throw error;

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

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Create Group Chat', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SELECT ACCOUNT', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.outline),
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
              Text('ROOM IDENTITY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
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
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    foregroundColor: Theme.of(context).colorScheme.onSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  onPressed: (_isCreating || xmppAccounts.isEmpty) ? null : _createRoom,
                  child: _isCreating 
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Theme.of(context).colorScheme.onSecondary, strokeWidth: 2))
                    : const Text('CREATE INSTANT ROOM', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Created rooms are initialized with default settings.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
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
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
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
          labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
