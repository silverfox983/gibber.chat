import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/omemo_storage_stub.dart' if (dart.library.io) '../services/omemo_storage.dart';

class IdentityTrustScreen extends StatefulWidget {
  const IdentityTrustScreen({super.key});

  @override
  State<IdentityTrustScreen> createState() => _IdentityTrustScreenState();
}

class _IdentityTrustScreenState extends State<IdentityTrustScreen> {
  final SQLiteSignalStore _store = SQLiteSignalStore();

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Identity Trust List', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onPrimary),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: authService.fetchOmemoIdentities(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final identities = snapshot.data!;
          if (identities.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.security_rounded, size: 64, color: Theme.of(context).disabledColor),
                  const SizedBox(height: 16),
                  Text('No identities found', style: TextStyle(color: Theme.of(context).disabledColor)),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 48),
                    child: Text(
                      'Identities appear here once you exchange encrypted messages with contacts.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            );
          }

          // Group by JID
          final grouped = <String, List<Map<String, dynamic>>>{};
          for (var iden in identities) {
            final jid = iden['address_name'] as String;
            grouped.putIfAbsent(jid, () => []).add(iden);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: grouped.length,
            itemBuilder: (context, index) {
              final jid = grouped.keys.elementAt(index);
              final devices = grouped[jid]!;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Text(jid, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                  ),
                  ...devices.map((device) {
                    final keyData = device['identity_key_data'] as Uint8List;
                    final trustLevel = device['trust_level'] as int? ?? 0;
                    final deviceId = device['device_id'] as int;
                    final fingerprint = _store.formatFingerprint(keyData);

                    return _buildIdentityCard(context, authService, jid, deviceId, fingerprint, trustLevel);
                  }),
                  const SizedBox(height: 16),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildIdentityCard(BuildContext context, AuthService authService, String jid, int deviceId, String fingerprint, int trustLevel) {
    Color statusColor;
    String statusLabel;
    IconData statusIcon;

    switch (trustLevel) {
      case 1:
        statusColor = Colors.green;
        statusLabel = 'VERIFIED';
        statusIcon = Icons.verified_user_rounded;
        break;
      case 2:
        statusColor = Colors.red;
        statusLabel = 'UNTRUSTED';
        statusIcon = Icons.gpp_bad_rounded;
        break;
      default:
        statusColor = Colors.orange;
        statusLabel = 'UNVERIFIED';
        statusIcon = Icons.security_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.1),
          child: Icon(statusIcon, color: statusColor, size: 20),
        ),
        title: Text('Device ID: $deviceId', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(
          statusLabel, 
          style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2)
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 8),
                const Text('FINGERPRINT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: fingerprint));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fingerprint copied to clipboard')));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      fingerprint,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (trustLevel != 1)
                      TextButton.icon(
                        onPressed: () => authService.updateOmemoTrust(jid, deviceId, 1),
                        icon: const Icon(Icons.verified_rounded, size: 18),
                        label: const Text('VERIFY'),
                        style: TextButton.styleFrom(foregroundColor: Colors.green),
                      ),
                    if (trustLevel == 1)
                      TextButton.icon(
                        onPressed: () => authService.updateOmemoTrust(jid, deviceId, 0),
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: const Text('UNVERIFY'),
                        style: TextButton.styleFrom(foregroundColor: Colors.orange),
                      ),
                    const SizedBox(width: 8),
                    if (trustLevel != 2)
                      TextButton.icon(
                        onPressed: () => authService.updateOmemoTrust(jid, deviceId, 2),
                        icon: const Icon(Icons.block_rounded, size: 18),
                        label: const Text('BLOCK'),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
