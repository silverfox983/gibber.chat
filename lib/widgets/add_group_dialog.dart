import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class AddGroupDialog extends StatefulWidget {
  final bool isCreate;
  const AddGroupDialog({super.key, this.isCreate = true});

  @override
  State<AddGroupDialog> createState() => _AddGroupDialogState();
}

class _AddGroupDialogState extends State<AddGroupDialog> {
  final _idController = TextEditingController();
  final _nickController = TextEditingController(text: 'GibberUser');
  String? _selectedAccountId;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final authService = Provider.of<AuthService>(context, listen: false);
    final accounts = authService.getAuthenticatedAccounts();
    if (accounts.isNotEmpty) {
      _selectedAccountId = authService.activeAccountId ?? accounts.first['id'];
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final accounts = authService.getAuthenticatedAccounts();

    return AlertDialog(
      title: Text(widget.isCreate ? 'Create New Group' : 'Join Group / Channel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (accounts.isEmpty)
              const Text('No connected accounts found. Please log in first.', style: TextStyle(color: Colors.red)),
            if (accounts.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: _selectedAccountId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Account'),
                items: accounts.map<DropdownMenuItem<String>>((a) {
                  return DropdownMenuItem<String>(
                    value: a['id'],
                    child: Text(
                      '${a['id']} (${a['protocol']})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedAccountId = val;
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _idController,
                decoration: const InputDecoration(
                  labelText: 'Room Name / ID',
                  hintText: 'room@conference.example.com',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nickController,
                decoration: const InputDecoration(
                  labelText: 'Your Nickname',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        ElevatedButton(
          onPressed: _isLoading || accounts.isEmpty ? null : _handleSubmit,
          child: _isLoading 
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(widget.isCreate ? 'CREATE' : 'JOIN'),
        ),
      ],
    );
  }

  Future<void> _handleSubmit() async {
    final id = _idController.text.trim();
    final nick = _nickController.text.trim();
    if (id.isEmpty) return;

    setState(() => _isLoading = true);
    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      if (widget.isCreate) {
        String finalId = id;
        if (!id.contains('@')) {
          final domain = _selectedAccountId!.split('@').last;
          finalId = '${id.toLowerCase()}@conference.$domain';
        }
        final error = await authService.createRoom(_selectedAccountId!, finalId, nick);
        if (error != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
            );
          }
          return;
        }
      } else {
        final error = await authService.joinRoom(_selectedAccountId!, id, nick);
        if (error != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
            );
          }
          return;
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}