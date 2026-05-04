import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  
  // Custom groupings
  final List<String> _commonDomains = ['@jabber.org', '@movim.eu', '@xmpp.jp', '@blabber.im', '@conversations.im'];
  
  // Pre-defined or standard groups
  final List<String> _standardGroups = ['General', 'Friends', 'Work', 'Family'];
  String _selectedGroup = 'General';
  bool _isCustomGroup = false;
  final TextEditingController _customGroupController = TextEditingController();

  bool get _isValidJid => _jidController.text.trim().contains('@') && _jidController.text.trim().contains('.');

  @override
  void dispose() {
    _jidController.dispose();
    _nicknameController.dispose();
    _customGroupController.dispose();
    super.dispose();
  }

  void _addDomain(String domain) {
    final text = _jidController.text;
    if (text.contains('@')) {
      _jidController.text = text.substring(0, text.indexOf('@')) + domain;
    } else {
      _jidController.text = text + domain;
    }
    _jidController.selection = TextSelection.fromPosition(TextPosition(offset: _jidController.text.length));
    setState(() {});
  }

  void _submit() {
    if (!_isValidJid) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid XMPP JID (user@domain.com)')));
      return;
    }

    final authService = Provider.of<AuthService>(context, listen: false);
    final jid = _jidController.text.trim().toLowerCase();
    final nick = _nicknameController.text.trim().isEmpty ? null : _nicknameController.text.trim();
    final group = _isCustomGroup 
        ? (_customGroupController.text.trim().isNotEmpty ? _customGroupController.text.trim() : null)
        : (_selectedGroup == 'General' ? null : _selectedGroup);

    authService.addContact(jid, nickname: nick, group: group);
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Friend request sent to $jid'), backgroundColor: Colors.green));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Add Connection', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.primary,
            padding: const EdgeInsets.only(bottom: 32, top: 16),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.person_add_alt_1_rounded, size: 64, color: Theme.of(context).colorScheme.onPrimary),
                ),
                const SizedBox(height: 16),
                Text('New Contact', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
                Text('Send a subscription request to their XMPP address', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.8))),
              ],
            ),
          ),
          
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('XMPP ADDRESS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _isValidJid ? Colors.green.withValues(alpha: 0.5) : Theme.of(context).colorScheme.outline,
                        width: _isValidJid ? 2 : 1,
                      ),
                    ),
                    child: TextField(
                      controller: _jidController,
                      onChanged: (v) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'e.g. alice@example.com',
                        prefixIcon: const Icon(Icons.alternate_email_rounded),
                        suffixIcon: _isValidJid ? const Icon(Icons.check_circle_rounded, color: Colors.green) : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                  
                  if (!_jidController.text.contains('@') && _jidController.text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _commonDomains.length,
                        separatorBuilder: (c, i) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          return ActionChip(
                            label: Text(_commonDomains[index]),
                            onPressed: () => _addDomain(_commonDomains[index]),
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            labelStyle: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 12, fontWeight: FontWeight.bold),
                            side: BorderSide.none,
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),
                  Text('NICKNAME (OPTIONAL)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: TextField(
                      controller: _nicknameController,
                      decoration: const InputDecoration(
                        hintText: 'How you want to see them',
                        prefixIcon: Icon(Icons.badge_rounded),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(16),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                  Text('ROSTER GROUP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _standardGroups.map((g) => ChoiceChip(
                      label: Text(g),
                      selected: !_isCustomGroup && _selectedGroup == g,
                      onSelected: (val) {
                        if (val) setState(() { _selectedGroup = g; _isCustomGroup = false; });
                      },
                      selectedColor: Theme.of(context).colorScheme.secondary,
                      labelStyle: TextStyle(
                        color: (!_isCustomGroup && _selectedGroup == g) ? Theme.of(context).colorScheme.onSecondary : null,
                        fontWeight: FontWeight.bold,
                      ),
                    )).toList()..add(ChoiceChip(
                      label: const Text('Custom...'),
                      selected: _isCustomGroup,
                      onSelected: (val) {
                        if (val) setState(() { _isCustomGroup = true; });
                      },
                      selectedColor: Theme.of(context).colorScheme.secondary,
                    )),
                  ),
                  if (_isCustomGroup) ...[
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Theme.of(context).colorScheme.outline),
                      ),
                      child: TextField(
                        controller: _customGroupController,
                        decoration: const InputDecoration(
                          hintText: 'Enter custom group name',
                          prefixIcon: Icon(Icons.group_rounded),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 48),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isValidJid ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceContainerHighest,
                        foregroundColor: _isValidJid ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                        elevation: _isValidJid ? 4 : 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('SEND FRIEND REQUEST', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                      onPressed: _isValidJid ? _submit : null,
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
