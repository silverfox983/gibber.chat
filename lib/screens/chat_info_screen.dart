import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../services/auth_service.dart';

class ChatInfoScreen extends StatelessWidget {
  final Conversation conversation;

  const ChatInfoScreen({super.key, required this.conversation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGroup = conversation.isGroup;
    final authService = Provider.of<AuthService>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(isGroup ? 'Group info' : 'Chat info'),
      ),
      body: ListView(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32),
            color: theme.colorScheme.primary.withValues(alpha: 0.05),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                  child: Text(
                    conversation.name.isNotEmpty ? conversation.name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 32,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  conversation.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                if (isGroup && conversation.topic != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    conversation.topic!,
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  conversation.id,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (isGroup)
            ListTile(
              leading: const Icon(Icons.people_rounded),
              title: const Text('Members'),
              subtitle: Text('${conversation.participants.length} members'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                context.pushNamed('groupMembers', extra: {'conversation': conversation});
              },
            ),
          ListTile(
            leading: Icon(
              Icons.lock_rounded,
              color: (conversation.encryptionType?.isNotEmpty ?? false) ? Colors.green : Colors.grey,
            ),
            title: const Text('Encryption'),
            subtitle: Text((conversation.encryptionType?.isNotEmpty ?? false)
                ? 'End-to-end encrypted'
                : 'Not encrypted'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _showSecurityInfo(context, conversation),
          ),
          if (!isGroup) ...[
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: const Text('View profile'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                final contact = chatProvider.contacts.firstWhere(
                  (c) => c.id.toLowerCase() == conversation.id.toLowerCase(),
                  orElse: () => Contact(
                    id: conversation.id,
                    name: conversation.name,
                    protocol: conversation.protocol,
                  ),
                );
                context.pushNamed('contactProfile', extra: {'contact': contact});
              },
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_rounded),
            title: const Text('Notifications'),
            subtitle: const Text('Customize notifications for this chat'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              context.pushNamed('chatSettings', extra: {'conversation': conversation});
            },
          ),
          ListTile(
            leading: const Icon(Icons.search_rounded),
            title: const Text('Search messages'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.pop(context);
              chatProvider.setMessageSearchQuery('');
            },
          ),
          const Divider(),
          if (!isGroup)
            ListTile(
              leading: const Icon(Icons.block_rounded, color: Colors.red),
              title: const Text('Block contact', style: TextStyle(color: Colors.red)),
              onTap: () => _showBlockConfirmation(context, authService),
            ),
        ],
      ),
    );
  }

  void _showBlockConfirmation(BuildContext context, AuthService authService) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block contact?'),
        content: Text('You will no longer receive messages from ${conversation.name}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await authService.blockContact(conversation.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${conversation.name} blocked')),
                );
              }
            },
            child: const Text('BLOCK', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showSecurityInfo(BuildContext context, Conversation conversation) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final isOmemo = conversation.encryptionType == 'omemo';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
            Row(
              children: [
                Icon(Icons.lock_rounded, color: isOmemo ? Colors.green : Colors.grey, size: 28),
                const SizedBox(width: 12),
                Text('Security Details', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: (isOmemo ? Colors.green : Colors.grey).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: (isOmemo ? Colors.green : Colors.grey).withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isOmemo ? 'End-to-End Encrypted' : 'No Encryption',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15,
                      color: isOmemo ? Colors.green.shade700 : Colors.grey.shade700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isOmemo
                      ? 'Messages in this conversation are encrypted using the OMEMO protocol (AxOLOTL). Only you and the recipient(s) can read them.'
                      : 'Messages are NOT encrypted. They are sent in plain text over the network.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (isOmemo) ...[
              ListTile(
                leading: const Icon(Icons.key_rounded, size: 20),
                title: const Text('Fingerprints', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  conversation.id,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  context.pushNamed('identityTrust', extra: {'jid': conversation.id});
                },
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_rounded, color: Colors.orange.shade700, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'This conversation is not encrypted. Consider enabling OMEMO in settings.',
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
