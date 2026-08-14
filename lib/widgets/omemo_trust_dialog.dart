import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class OmemoTrustDialog extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? accountId;

  const OmemoTrustDialog({
    super.key,
    required this.chatId,
    required this.chatName,
    this.accountId,
  });

  @override
  State<OmemoTrustDialog> createState() => _OmemoTrustDialogState();
}

class _OmemoTrustDialogState extends State<OmemoTrustDialog> {
  Map<int, Map<String, dynamic>>? _fingerprints;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFingerprints();
  }

  Future<void> _loadFingerprints() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    var data = await authService.getOmemoFingerprintsDetailed(widget.chatId);
    
    // If we only see our own device (or nothing), try to discover the contact's devices
    if (data.isEmpty || (data.length == 1 && data.values.first['isOwn'] == true)) {
      await authService.refreshOmemoDevices(widget.chatId, accountId: widget.accountId);
      data = await authService.getOmemoFingerprintsDetailed(widget.chatId);
    }

    if (mounted) {
      setState(() {
        _fingerprints = data;
        _loading = false;
      });
    }
  }

  Future<void> _updateTrust(int deviceId, int level) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    await authService.updateOmemoTrust(widget.chatId, deviceId, level);
    await _loadFingerprints(); // Refresh UI
  }

  Widget _getStatusIcon(int? level) {
    switch (level) {
      case 1: // Trusted
        return const Icon(Icons.verified_user_rounded, color: Colors.green, size: 24);
      case 2: // Distrusted
        return const Icon(Icons.block_rounded, color: Colors.red, size: 24);
      case 0: // Unverified
      default:
        return const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24);
    }
  }

  String _getStatusText(int? level) {
    switch (level) {
      case 1: return 'TRUSTED';
      case 2: return 'DISTRUSTED';
      case 0:
      default: return 'UNVERIFIED';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Device Security'),
          const SizedBox(height: 4),
          Text(
            'Managing identity for ${widget.chatName}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.normal,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
            : _fingerprints == null || _fingerprints!.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('No secure sessions established yet.'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _fingerprints!.length,
                    separatorBuilder: (context, index) => const Divider(),
                    itemBuilder: (context, index) {
                      final deviceId = _fingerprints!.keys.elementAt(index);
                      final info = _fingerprints![deviceId]!;
                      final fingerprint = info['fingerprint'] as String;
                      final trustLevel = info['trustLevel'] as int?;
                      final isOwn = info['isOwn'] == true;

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _getStatusIcon(trustLevel),
                        title: Row(
                          children: [
                            Text('Device ID: $deviceId', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            if (isOwn)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'YOU',
                                  style: TextStyle(
                                    color: colorScheme.onPrimaryContainer,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              _getStatusText(trustLevel),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                fingerprint,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                              ),
                            ),
                          ],
                        ),
                        trailing: isOwn 
                          ? null 
                          : PopupMenuButton<int>(
                              icon: const Icon(Icons.more_vert_rounded),
                              onSelected: (level) => _updateTrust(deviceId, level),
                              itemBuilder: (context) => [
                                const PopupMenuItem(value: 1, child: Text('Verify / Trust')),
                                const PopupMenuItem(value: 0, child: Text('Revoke Trust')),
                                const PopupMenuItem(value: 2, child: Text('Block / Distrust')),
                              ],
                            ),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}
