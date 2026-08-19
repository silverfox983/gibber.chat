import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../models/chat_models.dart';

class ChatInfoScreen extends StatelessWidget {
  final Conversation conversation;

  const ChatInfoScreen({super.key, required this.conversation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGroup = conversation.isGroup;

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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('View profile not yet available')),
              );
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
              context.pop();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: Colors.red),
            title: const Text('Block contact', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
