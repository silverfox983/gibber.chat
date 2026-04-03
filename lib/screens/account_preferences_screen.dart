import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';
import '../services/backup_service.dart';
import './login_screen.dart';
import './security_settings_screen.dart';

class AccountPreferencesScreen extends StatefulWidget {
  const AccountPreferencesScreen({super.key});

  @override
  State<AccountPreferencesScreen> createState() => _AccountPreferencesScreenState();
}

class _AccountPreferencesScreenState extends State<AccountPreferencesScreen> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Preferences', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const LoginScreen(isAddingAccount: true)),
          );
        },
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Consumer<AuthService>(
        builder: (context, authService, child) {
          final accounts = authService.savedAccounts;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ...accounts.map((acc) => Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  leading: CircleAvatar(
                    backgroundColor: acc.protocol == 'XMPP' ? Colors.deepPurple.shade100 : Colors.teal.shade100,
                    child: Icon(
                      acc.protocol == 'XMPP' ? Icons.chat_bubble_outline : Icons.tag,
                      color: acc.protocol == 'XMPP' ? Colors.deepPurple : Colors.teal,
                    ),
                  ),
                  title: Text(
                    acc.displayName ?? acc.user,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('${acc.protocol} • ${acc.fullJid}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openAccountEditor(context, authService, acc),
                ),
              )),
              const SizedBox(height: 24),
              Text('Backup & Security', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Theme.of(context).hintColor, letterSpacing: 1.2)),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.security_rounded, color: Theme.of(context).colorScheme.primary),
                      title: const Text('Security & Encryption', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Manage OMEMO fingerprints and device trust'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const SecuritySettingsScreen()),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.cloud_upload_outlined, color: Colors.blue),
                      title: const Text('Export Profile', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Create a portable JSON backup of all accounts and history'),
                      onTap: () => _handleExport(authService),
                      enabled: !_isProcessing,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.cloud_download_outlined, color: Colors.orange),
                      title: const Text('Import Profile', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Restore accounts and messages from a backup file'),
                      onTap: () => _handleImport(authService),
                      enabled: !_isProcessing,
                    ),
                  ],
                ),
              ),
              if (_isProcessing)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _showPasswordDialog({required bool isExport}) async {
    String password = '';
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(isExport ? 'Set Backup Password' : 'Enter Backup Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExport 
                ? 'Your profile backup will be encrypted with this password. If you lose it, the backup cannot be recovered.'
                : 'This backup is encrypted. Please enter the password to unlock your data.',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: isExport ? 'At least 8 characters recommended' : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (v) => password = v,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, password),
            child: Text(isExport ? 'Export' : 'Unlock'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleExport(AuthService authService) async {
    final password = await _showPasswordDialog(isExport: true);
    if (password == null || password.isEmpty) return;

    setState(() => _isProcessing = true);
    try {
      final backupService = BackupService(authService);
      final jsonStr = await backupService.generateBackup();
      final encryptedData = await backupService.encryptBackup(jsonStr, password);
      
      String? outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Gibber Backup',
        fileName: 'gibber_backup_${DateTime.now().millisecondsSinceEpoch}.gibber',
        type: FileType.any,
      );

      if (outputPath != null) {
        await backupService.saveBackupToFile(encryptedData, outputPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Secure backup exported successfully!'), backgroundColor: Colors.green)
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.redAccent)
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleImport(AuthService authService) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Backup?'),
        content: const Text('Importing a backup will WIPE all your current accounts and messages. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('Wipe & Import')
          ),
        ],
      )
    ) ?? false;

    if (!confirmed) return;

    setState(() => _isProcessing = true);
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        final backupService = BackupService(authService);
        final encodedData = await backupService.loadBackupFromFile(result.files.single.path!);
        
        String? password = '';
        if (!encodedData.trim().startsWith('{')) {
          password = await _showPasswordDialog(isExport: false);
          if (password == null) {
            setState(() => _isProcessing = false);
            return;
          }
        }

        final jsonStr = await backupService.decryptBackup(encodedData, password);
        await backupService.restoreBackup(jsonStr);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile restored! Please restart or reconnect.'), backgroundColor: Colors.green)
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: ${e.toString().replaceAll('Exception: ', '')}'), backgroundColor: Colors.redAccent)
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _openAccountEditor(BuildContext context, AuthService authService, SavedAccount account) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountEditorScreen(authService: authService, account: account),
      ),
    );
  }
}

class AccountEditorScreen extends StatefulWidget {
  final AuthService authService;
  final SavedAccount account;

  const AccountEditorScreen({super.key, required this.authService, required this.account});

  @override
  State<AccountEditorScreen> createState() => _AccountEditorScreenState();
}

class _AccountEditorScreenState extends State<AccountEditorScreen> {
  late TextEditingController _userCtrl;
  late TextEditingController _domainCtrl;
  late TextEditingController _hostCtrl;
  late TextEditingController _portCtrl;
  late TextEditingController _displayCtrl;
  late TextEditingController _passCtrl;
  
  // Common Advanced
  late TextEditingController _autoJoinCtrl;
  late TextEditingController _resourceCtrl;
  bool _useTor = false;
  
  // IRC Advanced
  bool _isSecure = false;
  late TextEditingController _realNameCtrl;
  late TextEditingController _serverPassCtrl;
  late TextEditingController _saslPassCtrl;

  // XMPP Advanced
  late TextEditingController _wsPathCtrl;
  late TextEditingController _reconnectTimeoutCtrl;
  bool _ackEnabled = true;
  bool _smResumable = true;

  @override
  void initState() {
    super.initState();
    final acc = widget.account;
    _userCtrl = TextEditingController(text: acc.user);
    _domainCtrl = TextEditingController(text: acc.domain);
    _hostCtrl = TextEditingController(text: acc.host ?? '');
    _portCtrl = TextEditingController(text: acc.port.toString());
    _displayCtrl = TextEditingController(text: acc.displayName ?? '');
    _passCtrl = TextEditingController(); // Leaving empty as we don't fetch from SecureStorage for security
    
    _autoJoinCtrl = TextEditingController(text: (acc.autoJoinChannels ?? []).join(', '));
    _resourceCtrl = TextEditingController(text: acc.customResource ?? '');
    _useTor = acc.useTor ?? false;

    // IRC Init
    _isSecure = acc.isSecure ?? false;
    _realNameCtrl = TextEditingController(text: acc.realName ?? '');
    _serverPassCtrl = TextEditingController(text: acc.serverPassword ?? '');
    _saslPassCtrl = TextEditingController(text: acc.saslAuthPassword ?? '');

    // XMPP Init
    _wsPathCtrl = TextEditingController(text: acc.wsPath ?? '');
    _reconnectTimeoutCtrl = TextEditingController(text: (acc.reconnectionTimeout ?? 1000).toString());
    _ackEnabled = acc.ackEnabled ?? true;
    _smResumable = acc.smResumable ?? true;
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _displayCtrl.dispose();
    _passCtrl.dispose();
    _autoJoinCtrl.dispose();
    _resourceCtrl.dispose();
    _realNameCtrl.dispose();
    _serverPassCtrl.dispose();
    _saslPassCtrl.dispose();
    _wsPathCtrl.dispose();
    _reconnectTimeoutCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    final newAcc = SavedAccount(
      user: _userCtrl.text.trim(),
      domain: _domainCtrl.text.trim(),
      host: _hostCtrl.text.trim().isEmpty ? null : _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text.trim()) ?? widget.account.port,
      protocol: widget.account.protocol,
      displayName: _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim(),
      autoJoinChannels: _autoJoinCtrl.text.trim().isEmpty 
          ? null 
          : _autoJoinCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      customResource: _resourceCtrl.text.trim().isEmpty ? null : _resourceCtrl.text.trim(),
      useTor: _useTor,
      isSecure: _isSecure,
      realName: _realNameCtrl.text.trim().isEmpty ? null : _realNameCtrl.text.trim(),
      serverPassword: _serverPassCtrl.text.trim().isEmpty ? null : _serverPassCtrl.text.trim(),
      saslAuthPassword: _saslPassCtrl.text.trim().isEmpty ? null : _saslPassCtrl.text.trim(),
      wsPath: _wsPathCtrl.text.trim().isEmpty ? null : _wsPathCtrl.text.trim(),
      reconnectionTimeout: int.tryParse(_reconnectTimeoutCtrl.text.trim()),
      ackEnabled: _ackEnabled,
      smResumable: _smResumable,
    );
    
    final newPass = _passCtrl.text.isNotEmpty ? _passCtrl.text : null;
    await widget.authService.updateSavedAccount(widget.account, newAcc, newPass);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account updated successfully.')));
      Navigator.pop(context);
    }
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text('Are you sure you want to remove this account? Your local message history will be preserved, but connection will be dropped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.onError)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.authService.deleteSavedAccount(widget.account);
      if (mounted) {
        Navigator.pop(context); // Pop editor
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIrc = widget.account.protocol == 'IRC';
    final isXmpp = widget.account.protocol == 'XMPP';

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.account.protocol} Account'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saveChanges,
            tooltip: 'Save Settings',
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Core Settings', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
          const SizedBox(height: 16),
          TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: 'Username')),
          const SizedBox(height: 12),
          TextField(controller: _domainCtrl, decoration: const InputDecoration(labelText: 'Domain/Network')),
          const SizedBox(height: 12),
          TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: 'Password (leave blank to keep current)', helperText: 'Passwords are symmetrically encrypted on disk.'), obscureText: true),
          const SizedBox(height: 12),
          TextField(controller: _displayCtrl, decoration: const InputDecoration(labelText: 'Display Name (Optional)')),
          
          const SizedBox(height: 32),
          Text('Connection Overrides', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(flex: 3, child: TextField(controller: _hostCtrl, decoration: const InputDecoration(labelText: 'Host (Optional)'))),
              const SizedBox(width: 12),
              Expanded(flex: 1, child: TextField(controller: _portCtrl, decoration: const InputDecoration(labelText: 'Port'))),
            ],
          ),
          
          if (isIrc) ...[
            const SizedBox(height: 32),
            Text('Security & Authentication', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
            const SizedBox(height: 16),
            SwitchListTile(
               title: const Text('Use SSL/TLS'),
               subtitle: const Text('Connect using a secure socket (Port 6697 default)'),
               value: _isSecure, 
               onChanged: (v) => setState(() => _isSecure = v),
               contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 12),
            TextField(controller: _serverPassCtrl, decoration: const InputDecoration(labelText: 'Server Password (Proxy/Bouncer Password)'), obscureText: true),
            const SizedBox(height: 12),
            TextField(controller: _saslPassCtrl, decoration: const InputDecoration(labelText: 'SASL Authentication Password (NickServ)'), obscureText: true),
            
            const SizedBox(height: 32),
            Text('IRC Identity & Channels', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
            const SizedBox(height: 16),
            TextField(controller: _realNameCtrl, decoration: const InputDecoration(labelText: 'IRC RealName Override (Optional)')),
            const SizedBox(height: 12),
            TextField(controller: _autoJoinCtrl, decoration: const InputDecoration(labelText: 'Auto-join Channels (comma separated)', hintText: '#lobby, #help')),
          ],
          
          if (isXmpp) ...[
            const SizedBox(height: 32),
            Text('Advanced Networking', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.secondary)),
            const SizedBox(height: 16),
            TextField(controller: _resourceCtrl, decoration: const InputDecoration(labelText: 'Custom Resource Code (Optional)', hintText: 'GibberMobile')),
            const SizedBox(height: 12),
            TextField(controller: _wsPathCtrl, decoration: const InputDecoration(labelText: 'WebSocket URI (Optional)', hintText: 'wss://ejabberd.local:5443/ws')),
            const SizedBox(height: 12),
            TextField(controller: _reconnectTimeoutCtrl, decoration: const InputDecoration(labelText: 'Reconnection Timeout (ms)', hintText: '1000')),
            const SizedBox(height: 16),
            Text('Stream Management (XEP-0198)', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
            SwitchListTile(
               title: const Text('Acknowledge Streams'),
               subtitle: const Text('Ensure zero message loss on unstable networks'),
               value: _ackEnabled, 
               onChanged: (v) => setState(() => _ackEnabled = v),
               contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
               title: const Text('Session Resumption'),
               subtitle: const Text('Resume XML streams instantly without full reconnect'),
               value: _smResumable, 
               onChanged: (v) => setState(() => _smResumable = v),
               contentPadding: EdgeInsets.zero,
            ),
          ],
          
          const SizedBox(height: 32),
          SwitchListTile(
               title: const Text('Use Tor (Proxy)'),
               subtitle: const Text('Route traffic through local Tor daemon (Future)'),
               value: _useTor, 
               onChanged: (v) => setState(() => _useTor = v),
               contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 64),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.all(16)
            ),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete Account'),
            onPressed: _confirmDelete,
          )
        ],
      ),
    );
  }
}
