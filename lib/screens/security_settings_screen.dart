import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/auth_service.dart';
import 'package:flutter/services.dart';

class SecuritySettingsScreen extends StatelessWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Security & Encryption'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildSectionHeader(context, 'MY IDENTITY'),
          const SizedBox(height: 16),
          _buildMyFingerprintCard(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'DEVICE KEY MANAGEMENT'),
          const SizedBox(height: 16),
          _buildDeviceKeyManagementCard(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'PRIVACY SETTINGS'),
          const SizedBox(height: 16),
          _buildPrivacyOptions(context, authService),
          
          const SizedBox(height: 32),
          _buildSectionHeader(context, 'BLOCK LIST MANAGEMENT'),
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
              const Text('Your Encryption Identity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
              return Column(
                children: [
                  GestureDetector(
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
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _showFingerprintQR(context, fingerprint),
                      icon: const Icon(Icons.qr_code_rounded, size: 18),
                      label: const Text('Show QR Code'),
                    ),
                  ),
                ],
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
                context.goNamed('identity');
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phonelink_erase_rounded, color: Colors.redAccent),
             title: const Text('Reset Encryption Identity', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
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
          ListenableBuilder(
            listenable: authService,
            builder: (context, _) => Column(
              children: [
                SwitchListTile(
                  title: const Text('Send Read Receipts', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Let others know when you\'ve read their messages'),
                  value: authService.sendReadReceipts,
                  onChanged: (val) => authService.setSendReadReceipts(val),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Send Typing Indicators', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Let others see when you\'re typing'),
                  value: authService.sendTypingIndicators,
                  onChanged: (val) => authService.setSendTypingIndicators(val),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Always Re-Verify Devices', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Trigger trust dialogs for every new device session'),
                  value: authService.isStrictVerificationEnabled,
                  onChanged: (val) => authService.setStrictVerification(val),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
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

  void _showFingerprintQR(BuildContext context, String fingerprint) {
    final qrData = 'omemo:fingerprint:${fingerprint.replaceAll(' ', '')}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scan to Verify', style: TextStyle(fontWeight: FontWeight.w900)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Have your contact scan this QR code to verify your identity.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CLOSE'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: fingerprint));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Fingerprint copied')));
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('COPY'),
          ),
        ],
      ),
    );
  }

  void _showResetWarning(BuildContext context, AuthService authService) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Identity?'),
        content: const Text('This will delete your current encryption keys and generate new ones. Your contacts will see a "New Device" warning. This action cannot be undone.'),
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
