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
}
