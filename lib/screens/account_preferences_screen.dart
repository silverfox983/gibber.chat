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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Account Preferences', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onPrimary),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const LoginScreen(isAddingAccount: true)),
          );
        },
        backgroundColor: Theme.of(context).colorScheme.secondary,
        icon: Icon(Icons.add, color: Theme.of(context).colorScheme.onSecondary),
        label: Text('Add Account', style: TextStyle(color: Theme.of(context).colorScheme.onSecondary, fontWeight: FontWeight.bold)),
      ),
      body: Consumer<AuthService>(
        builder: (context, authService, child) {
          final accounts = authService.savedAccounts.where((a) => a.protocol == 'XMPP').toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('CONNECTED ACCOUNTS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              if (accounts.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                  ),
                  child: Center(
                    child: Text('No accounts connected.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                ),
              ...accounts.map((acc) => Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(Icons.alternate_email_rounded, color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  title: Text(
                    acc.displayName ?? acc.user,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  subtitle: Text('XMPP • ${acc.fullJid}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                  trailing: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.settings_rounded, color: Theme.of(context).colorScheme.primary, size: 20),
                  ),
                  onTap: () => _openAccountEditor(context, authService, acc),
                ),
              )),
              
              const SizedBox(height: 32),
              Text('BACKUP & SECURITY', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.outline),
                ),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      leading: Icon(Icons.security_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
                      title: const Text('Security & Encryption', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Manage OTR fingerprints and trust'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const SecuritySettingsScreen()),
                        );
                      },
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      leading: const Icon(Icons.cloud_upload_rounded, color: Colors.blue, size: 28),
                      title: const Text('Export Profile', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Create an encrypted backup of your data'),
                      onTap: () => _handleExport(authService),
                      enabled: !_isProcessing,
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outline),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      leading: const Icon(Icons.cloud_download_rounded, color: Colors.orange, size: 28),
                      title: const Text('Import Profile', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Restore accounts from a backup file'),
                      onTap: () => _handleImport(authService),
                      enabled: !_isProcessing,
                    ),
                  ],
                ),
              ),
              if (_isProcessing)
                const Padding(
                  padding: EdgeInsets.all(32),
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
        title: Text(isExport ? 'Set Backup Password' : 'Enter Backup Password', style: const TextStyle(fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExport 
                ? 'Your profile backup will be encrypted with this password. If you lose it, the backup cannot be recovered.'
                : 'This backup is encrypted. Please enter the password to unlock your data.',
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            onPressed: () => Navigator.pop(context, password),
            child: Text(isExport ? 'EXPORT' : 'UNLOCK'),
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
        fileName: 'gibber_backup_\${DateTime.now().millisecondsSinceEpoch}.gibber',
        type: FileType.any,
      );

      if (outputPath != null) {
        await backupService.saveBackupToFile(encryptedData, outputPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: const Text('Secure backup exported successfully!'), backgroundColor: Theme.of(context).colorScheme.secondary)
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: \$e'), backgroundColor: Theme.of(context).colorScheme.error)
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
        title: const Text('Import Backup?', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('Importing a backup will WIPE all your current accounts and messages. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('WIPE & IMPORT')
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
            SnackBar(content: const Text('Profile restored! Please restart or reconnect.'), backgroundColor: Theme.of(context).colorScheme.secondary)
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: \${e.toString().replaceAll("Exception: ", "")}'), backgroundColor: Theme.of(context).colorScheme.error)
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
  
  // Advanced XMPP
  late TextEditingController _resourceCtrl;
  late TextEditingController _wsPathCtrl;
  late TextEditingController _reconnectTimeoutCtrl;
  bool _useTor = false;
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
    _passCtrl = TextEditingController(); 
    
    _resourceCtrl = TextEditingController(text: acc.customResource ?? '');
    _useTor = acc.useTor ?? false;

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
    _resourceCtrl.dispose();
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
      protocol: 'XMPP',
      displayName: _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim(),
      customResource: _resourceCtrl.text.trim().isEmpty ? null : _resourceCtrl.text.trim(),
      useTor: _useTor,
      wsPath: _wsPathCtrl.text.trim().isEmpty ? null : _wsPathCtrl.text.trim(),
      reconnectionTimeout: int.tryParse(_reconnectTimeoutCtrl.text.trim()),
      ackEnabled: _ackEnabled,
      smResumable: _smResumable,
    );
    
    final newPass = _passCtrl.text.isNotEmpty ? _passCtrl.text : null;
    await widget.authService.updateSavedAccount(widget.account, newAcc, newPass);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Account updated successfully.'), backgroundColor: Theme.of(context).colorScheme.secondary));
      Navigator.pop(context);
    }
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('Are you sure you want to remove this account? Your local message history will be preserved, but connection will be dropped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('DELETE', style: TextStyle(color: Theme.of(context).colorScheme.onError)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.authService.deleteSavedAccount(widget.account);
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Account', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
            onPressed: _saveChanges,
            tooltip: 'Save Settings',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('CORE SETTINGS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 16),
          _buildTextField('Username', _userCtrl),
          const SizedBox(height: 12),
          _buildTextField('Domain', _domainCtrl),
          const SizedBox(height: 12),
          _buildTextField('Password (leave blank to keep current)', _passCtrl, obscureText: true),
          const SizedBox(height: 12),
          _buildTextField('Display Name (Optional)', _displayCtrl),
          
          const SizedBox(height: 32),
          Text('CONNECTION OVERRIDES', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(flex: 3, child: _buildTextField('Host (Optional)', _hostCtrl)),
              const SizedBox(width: 12),
              Expanded(flex: 1, child: _buildTextField('Port', _portCtrl)),
            ],
          ),
          
          const SizedBox(height: 32),
          Text('ADVANCED NETWORKING', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 16),
          _buildTextField('Custom Resource Code (Optional)', _resourceCtrl, hint: 'GibberMobile'),
          const SizedBox(height: 12),
          _buildTextField('WebSocket URI (Optional)', _wsPathCtrl, hint: 'wss://example.com/ws'),
          const SizedBox(height: 12),
          _buildTextField('Reconnection Timeout (ms)', _reconnectTimeoutCtrl, hint: '1000'),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Acknowledge Streams', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Ensure zero message loss (XEP-0198)'),
                  value: _ackEnabled, 
                  onChanged: (v) => setState(() => _ackEnabled = v),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
                Divider(height: 1, color: Theme.of(context).colorScheme.outline),
                SwitchListTile(
                  title: const Text('Session Resumption', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Resume streams without full reconnect'),
                  value: _smResumable, 
                  onChanged: (v) => setState(() => _smResumable = v),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
                Divider(height: 1, color: Theme.of(context).colorScheme.outline),
                SwitchListTile(
                  title: const Text('Use Tor (Proxy)', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Route traffic through Tor (Future)'),
                  value: _useTor, 
                  onChanged: (v) => setState(() => _useTor = v),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),

          const SizedBox(height: 64),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(color: Theme.of(context).colorScheme.error),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            icon: const Icon(Icons.delete_forever_rounded),
            label: const Text('REMOVE ACCOUNT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
            onPressed: _confirmDelete,
          )
        ],
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, {bool obscureText = false, String? hint}) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
