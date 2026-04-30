import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import './identity_trust_screen.dart';
import 'package:flutter/services.dart';

class SecuritySettingsScreen extends StatelessWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Security & Encryption', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onPrimary),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildSectionHeader(context, 'MY IDENTITY'),
          const SizedBox(height: 16),
          _buildMyFingerprintCard(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'OMEMO DEVICE KEY MANAGEMENT'),
          const SizedBox(height: 16),
          _buildDeviceKeyManagementCard(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'PRIVACY SETTINGS'),
          const SizedBox(height: 16),
          _buildPrivacyOptions(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'BLOCK LIST MANAGEMENT (XEP-0191)'),
          const SizedBox(height: 16),
          _buildBlockListCard(context, authService),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 12, 
        fontWeight: FontWeight.w800, 
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7), 
        letterSpacing: 1.2
      ),
    );
  }

  Widget _buildMyFingerprintCard(BuildContext context, AuthService authService) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fingerprint_rounded, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              const Text('Your OMEMO Identity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Device ID: ', style: TextStyle(fontSize: 13, color: Colors.grey)),
              Text('${authService.getLocalOmemoDeviceId()}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: authService.getMyOmemoFingerprint(),
            builder: (context, snapshot) {
              final fingerprint = snapshot.data ?? 'Loading fingerprint...';
              return GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: fingerprint));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fingerprint copied to clipboard')));
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    fingerprint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace', 
                      fontSize: 13, 
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          const Text(
            'This unique fingerprint and device ID allow others to verify that your conversations are secure and encrypted.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceKeyManagementCard(BuildContext context, AuthService authService) {
     return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.devices_other_rounded, color: Colors.orangeAccent),
            title: const Text('Identity Trust List', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Manage trusted keys for your contacts'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
               Navigator.push(context, MaterialPageRoute(builder: (context) => const IdentityTrustScreen()));
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phonelink_erase_rounded, color: Colors.redAccent),
            title: const Text('Reset OMEMO Identity', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
            subtitle: const Text('Generate new keys (Recommended if device is compromised)'),
            onTap: () {
               _showResetWarning(context, authService);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyOptions(BuildContext context, AuthService authService) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Always Re-Verify Devices', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Trigger trust dialogs for every new device session'),
            value: authService.isStrictVerificationEnabled,
            onChanged: (val) => authService.setStrictVerification(val),
            activeThumbColor: Theme.of(context).colorScheme.primary,
          ),
          const Divider(height: 1),
          ListTile(
             leading: const Icon(Icons.article_outlined, color: Colors.blueAccent),
             title: const Text('View Legal & Privacy Policy', style: TextStyle(fontWeight: FontWeight.bold)),
             trailing: const Icon(Icons.open_in_new_rounded, size: 18),
             onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildBlockListCard(BuildContext context, AuthService authService) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: FutureBuilder<List<String>>(
        future: authService.getBlockList(),
        builder: (context, snapshot) {
          final blocks = snapshot.data ?? [];
          if (blocks.isEmpty) {
            return const ListTile(
              title: Text('No contacts blocked', style: TextStyle(color: Colors.grey)),
            );
          }
          return Column(
            children: blocks.map((jid) => ListTile(
              title: Text(jid, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              trailing: TextButton(
                onPressed: () async {
                  await authService.unblockContact(jid);
                  // Refresh UI
                  if (context.mounted) {
                    (context as Element).markNeedsBuild();
                  }
                },
                child: const Text('UNBLOCK', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w900)),
              ),
            )).toList(),
          );
        },
      ),
    );
  }

  void _showResetWarning(BuildContext context, AuthService authService) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Identity?'),
        content: const Text('This will delete your current OMEMO keys and generate new ones. Your contacts will see a "New Device" warning. This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          TextButton(
            onPressed: () async {
              if (authService.activeAccountId != null) {
                await authService.resetOmemoKeys(authService.activeAccountId!);
              }
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Identity keys reset successfully.')));
              }
            },
            child: const Text('RESET', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
