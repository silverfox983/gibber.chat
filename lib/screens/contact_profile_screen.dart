import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../providers/chat_provider.dart';
import '../providers/call_provider.dart';
import 'dart:ui';

class ContactProfileScreen extends StatelessWidget {
  final Contact contact;

  const ContactProfileScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final chatProvider = Provider.of<ChatProvider>(context);

    // Calculate shared groups - match contact's roster groups against group conversation names
    final sharedGroups = chatProvider.conversations.where((c) {
      if (!c.isGroup) return false;
      if (contact.groups.isEmpty) return false;
      final convNameLower = c.name.toLowerCase();
      return contact.groups.any((g) => convNameLower.contains(g.toLowerCase()) || g.toLowerCase().contains(convNameLower));
    }).toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Contact'),
        actions: [
          Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
              onSelected: (val) async {
                if (val == 'rename') {
                  _showRenameDialog(context, chatProvider, authService);
                } else if (val == 'share') {
                  _showShareQRDialog(context);
                } else if (val == 'verify') {
                  _showVerifyFingerprintDialog(context, authService);
                } else if (val == 'refresh') {
                  authService.fetchContactVCard(contact.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Refreshing profile...'), duration: Duration(seconds: 1)),
                  );
                } else if (val == 'block') {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Block ${contact.name}?'),
                      content: Text('Are you sure you want to block ${contact.id}? You will no longer receive messages or calls from this contact.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), style: TextButton.styleFrom(foregroundColor: Colors.redAccent), child: const Text('BLOCK')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    chatProvider.blockContact(contact.id, authService);
                    Navigator.pop(context);
                  }
                } else if (val == 'remove') {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Remove ${contact.name}?'),
                      content: Text('Are you sure you want to remove ${contact.id} from your contacts? This will not block the contact.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), style: TextButton.styleFrom(foregroundColor: Colors.redAccent), child: const Text('REMOVE')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    chatProvider.removeContact(contact.id, authService);
                    Navigator.pop(context);
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_rounded, size: 18), title: Text('Rename'), dense: true)),
                const PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.refresh_rounded, size: 18), title: Text('Refresh Profile'), dense: true)),
                const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.qr_code_rounded, size: 18), title: Text('Share via QR'), dense: true)),
                const PopupMenuItem(value: 'verify', child: ListTile(leading: Icon(Icons.verified_user_rounded, size: 18), title: Text('Verify Fingerprint'), dense: true)),
                const PopupMenuItem(value: 'block', child: ListTile(leading: Icon(Icons.block_rounded, size: 18, color: Colors.redAccent), title: Text('Block'), dense: true)),
                const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_forever_rounded, size: 18, color: Colors.redAccent), title: Text('Remove'), dense: true)),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildHeroHeader(context),
            _buildActionButtons(context, chatProvider),
            _buildContactDetails(context),
            if (sharedGroups.isNotEmpty) _buildSharedGroups(context, sharedGroups),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: AvatarCacheService().getAvatar(contact.id),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        
        return SizedBox(
          height: 380,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background Blur
              if (bytes != null) ...[
                Image.memory(bytes, fit: BoxFit.cover),
                ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(color: Colors.black.withValues(alpha: 0.4)),
                  ),
                ),
              ] else ...[
                Container(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
              
              // Content
              SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            image: bytes != null ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover) : null,
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 10)),
                            ]
                          ),
                          child: bytes == null 
                            ? const Icon(Icons.person_rounded, size: 80, color: Colors.white70) 
                            : null,
                        ),
                        Container(
                          margin: const EdgeInsets.all(4),
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: _getStatusColor(context, contact.status),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      contact.fullName ?? contact.name, 
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white, shadows: [Shadow(color: Colors.black45, blurRadius: 10)]),
                    ),
                    if (contact.fullName != null && contact.name != contact.fullName)
                      Text(
                        '~${contact.name}', 
                        style: const TextStyle(fontSize: 16, color: Colors.white70, fontStyle: FontStyle.italic),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        );
      }
    );
  }

  Color _getStatusColor(BuildContext context, ContactStatus status) {
    switch (status) {
      case ContactStatus.online: return Colors.green;
      case ContactStatus.away: return Colors.orange;
      case ContactStatus.xa: return Colors.orange.shade700;
      case ContactStatus.dnd: return Colors.red;
      case ContactStatus.offline: return Colors.grey;
    }
  }

  Widget _buildActionButtons(BuildContext context, ChatProvider cp) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionButton(
            icon: Icons.chat_bubble_rounded,
            label: 'Message',
            color: Theme.of(context).colorScheme.secondary,
            onTap: () {
               cp.setActiveConversation(contact.id);
               Navigator.popUntil(context, (route) => route.isFirst);
            },
          ),
          _ActionButton(
            icon: Icons.call_rounded,
            label: 'Voice',
            color: Colors.green,
            onTap: () {
              final callProvider = Provider.of<CallProvider>(context, listen: false);
              callProvider.startCall(contact.id, isVideo: false, protocol: contact.protocol);
            },
          ),
          _ActionButton(
            icon: Icons.videocam_rounded,
            label: 'Video',
            color: Colors.blue,
            onTap: () {
              final callProvider = Provider.of<CallProvider>(context, listen: false);
              callProvider.startCall(contact.id, isVideo: true, protocol: contact.protocol);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildContactDetails(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05), blurRadius: 20),
          ]
        ),
        child: Column(
          children: [
            _DetailTile(icon: Icons.alternate_email_rounded, title: 'JID', subtitle: contact.id),
            if (contact.email != null && contact.email!.isNotEmpty)
              _DetailTile(icon: Icons.email_rounded, title: 'Email', subtitle: contact.email!),
            if (contact.phone != null && contact.phone!.isNotEmpty)
              _DetailTile(icon: Icons.phone_rounded, title: 'Phone', subtitle: contact.phone!),
            if (contact.organization != null && contact.organization!.isNotEmpty)
              _DetailTile(icon: Icons.business_rounded, title: 'Organization', subtitle: contact.organization!),
            if (contact.title != null && contact.title!.isNotEmpty)
              _DetailTile(icon: Icons.badge_rounded, title: 'Title', subtitle: contact.title!),
            if (contact.role != null && contact.role!.isNotEmpty)
              _DetailTile(icon: Icons.work_rounded, title: 'Role', subtitle: contact.role!),
            if (contact.birthday != null && contact.birthday!.isNotEmpty)
              _DetailTile(icon: Icons.cake_rounded, title: 'Birthday', subtitle: contact.birthday!),
            if (contact.url != null && contact.url!.isNotEmpty)
              _DetailTile(icon: Icons.link_rounded, title: 'Website', subtitle: contact.url!),
            if (contact.bio != null && contact.bio!.isNotEmpty)
              _DetailTile(icon: Icons.info_outline_rounded, title: 'Biography', subtitle: contact.bio!),
            if (contact.presenceMessage != null && contact.presenceMessage!.isNotEmpty)
              _DetailTile(icon: Icons.chat_bubble_outline_rounded, title: 'Status Message', subtitle: contact.presenceMessage!),
            if (contact.groups.isNotEmpty)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.group_work_rounded, color: Theme.of(context).colorScheme.onSecondaryContainer),
                ),
                title: Text('Roster Groups', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Wrap(
                    spacing: 8,
                    children: contact.groups.map((g) => Chip(
                      label: Text(g, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      backgroundColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
                      side: BorderSide.none,
                      padding: EdgeInsets.zero,
                    )).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharedGroups(BuildContext context, List<Conversation> shared) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text('SHARED GROUPS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
        ),
        const SizedBox(height: 16),
        ...shared.map((s) => ListTile(
          title: Text(s.name),
        )),
      ],
    );
  }

  void _showShareQRDialog(BuildContext context) {
    final uri = 'xmpp:${contact.id}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share Contact', style: TextStyle(fontWeight: FontWeight.w900)),
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
                data: uri,
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              contact.id,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Scan to add contact',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
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
              Share.share(uri, subject: 'XMPP Contact: ${contact.name}');
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.share_rounded, size: 18),
            label: const Text('SHARE'),
          ),
        ],
      ),
    );
  }

  Future<void> _showVerifyFingerprintDialog(BuildContext context, AuthService authService) async {
    final fingerprints = await authService.getOmemoFingerprintsDetailed(contact.id);
    final myFingerprint = await authService.getMyOmemoFingerprint();
    if (!context.mounted) return;

    if (fingerprints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No OMEMO fingerprints found. Send an encrypted message first.')),
      );
      return;
    }

    final firstDevice = fingerprints.entries.firstWhere(
      (e) => !(e.value['isOwn'] as bool? ?? false),
      orElse: () => fingerprints.entries.first,
    );
    final contactFp = firstDevice.value['fingerprint'] as String? ?? '';
    final contactDeviceId = firstDevice.key;

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Fingerprint', style: TextStyle(fontWeight: FontWeight.w900)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Compare these fingerprints in person or via a trusted channel.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(
                  data: 'omemo:verify:${contact.id}:$contactDeviceId:${contactFp.replaceAll(' ', '')}',
                  version: QrVersions.auto,
                  size: 160,
                ),
              ),
              const SizedBox(height: 16),
              const Text('CONTACT\'S FINGERPRINT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: contactFp));
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Contact fingerprint copied')));
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(contactFp, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 16),
              Icon(Icons.swap_vert_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(height: 16),
              const Text('YOUR FINGERPRINT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: myFingerprint));
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Your fingerprint copied')));
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(myFingerprint, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CLOSE')),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, ChatProvider cp, AuthService auth) {
     final ctrl = TextEditingController(text: contact.name);
     showDialog(
       context: context,
       builder: (context) => AlertDialog(
         title: const Text('Rename Contact', style: TextStyle(fontWeight: FontWeight.w900)),
         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
         content: TextField(
            controller: ctrl, 
            decoration: InputDecoration(
              labelText: 'New Nickname',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
         ),
         actions: [
           TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
           FilledButton(
             onPressed: () {
               cp.renameContact(contact.id, ctrl.text, auth);
               Navigator.pop(context);
             },
             child: const Text('SAVE')
           ),
         ],
       ),
     );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface, fontSize: 13)),
        ],
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _DetailTile({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Theme.of(context).colorScheme.onSecondaryContainer),
      ),
      title: Text(title, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child: Text(subtitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
