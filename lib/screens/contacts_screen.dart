import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';
import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../providers/chat_provider.dart';
import '../models/chat_models.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Social Hub', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.person_add_rounded, color: Theme.of(context).colorScheme.onPrimary),
            onPressed: () => _showAddContactDialog(context),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).colorScheme.onPrimary,
          unselectedLabelColor: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
          indicatorColor: Theme.of(context).colorScheme.secondary,
          indicatorWeight: 4,
          tabs: const [
            Tab(text: 'CONTACTS'),
            Tab(text: 'PENDING'),
            Tab(text: 'BLOCKED'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Premium Search Bar (GPU Hardened)
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.primary,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
                decoration: InputDecoration(
                  hintText: 'Search contacts...',
                  hintStyle: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                  prefixIcon: Icon(Icons.search_rounded, color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  suffixIcon: _searchQuery.isNotEmpty 
                    ? IconButton(
                        icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                ),
                onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
              ),
            ),
          ),
          
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildContactList(context, authService),
                _buildPendingRequests(context, authService),
                _buildBlockedList(context, authService),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactList(BuildContext context, AuthService authService) {
    return StreamBuilder<List<Contact>>(
      stream: authService.contacts,
      initialData: const [],
      builder: (context, snapshot) {
        final contacts = snapshot.data ?? [];
        final filtered = contacts.where((c) => 
          c.name.toLowerCase().contains(_searchQuery) || 
          c.id.toLowerCase().contains(_searchQuery)
        ).toList();

        if (filtered.isEmpty) {
          return _buildEmptyState(Icons.people_outline_rounded, 'No contacts found');
        }

        // Sort by status then name
        filtered.sort((a, b) {
          if (a.status != b.status) {
            if (a.status == ContactStatus.online) return -1;
            if (b.status == ContactStatus.online) return 1;
          }
          return a.name.compareTo(b.name);
        });

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: filtered.length,
          itemBuilder: (context, index) => _ContactTile(contact: filtered[index]),
        );
      }
    );
  }

  Widget _buildPendingRequests(BuildContext context, AuthService authService) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        final requests = chatProvider.pendingSubscriptions;

        if (requests.isEmpty) {
          return _buildEmptyState(Icons.mail_outline_rounded, 'No pending friend requests');
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          itemCount: requests.length,
          itemBuilder: (context, index) {
            final req = requests[index];
            final jid = req['jid'] ?? 'Unknown';
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03), blurRadius: 10),
                ],
              ),
              child: Row(
                children: [
                  _AvatarView(jid: jid),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(jid, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('wants to be your friend', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.secondary), 
                        onPressed: () => chatProvider.respondToSubscription(jid, true, authService)
                      ),
                      IconButton(
                        icon: const Icon(Icons.cancel, color: Colors.redAccent), 
                        onPressed: () => chatProvider.respondToSubscription(jid, false, authService)
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBlockedList(BuildContext context, AuthService authService) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        final blocked = chatProvider.blockedJids;
        if (blocked.isEmpty) {
          return _buildEmptyState(Icons.block_rounded, 'No blocked contacts');
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: blocked.length,
          itemBuilder: (context, index) {
            final jid = blocked[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03), blurRadius: 10),
                ],
              ),
              child: ListTile(
                leading: _AvatarView(jid: jid),
                title: Text(jid, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Blocked contact', style: TextStyle(fontSize: 12, color: Colors.redAccent)),
                trailing: TextButton(
                  onPressed: () => chatProvider.unblockContact(jid, authService),
                  child: Text('UNBLOCK', style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.bold)),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 80, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12)),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  void _showAddContactDialog(BuildContext context) {
    final jidController = TextEditingController();
    final nameController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add New Contact', style: TextStyle(fontWeight: FontWeight.w900)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: jidController,
              decoration: const InputDecoration(
                labelText: 'JID (e.g. user@domain.com)',
                hintText: 'Required',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                hintText: 'Optional',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
               if (jidController.text.isNotEmpty) {
                  Provider.of<AuthService>(context, listen: false).addContact(
                    jidController.text, 
                    nickname: nameController.text.isNotEmpty ? nameController.text : null
                  );
                  Navigator.pop(context);
               }
            },
            child: const Text('ADD CONTACT'),
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact contact;
  const _ContactTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03), blurRadius: 10, spreadRadius: 1),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            _AvatarView(jid: contact.id),
            _StatusIndicator(status: contact.status),
          ],
        ),
        title: Text(
          contact.name, 
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contact.id, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (contact.presenceMessage != null && contact.presenceMessage!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  contact.presenceMessage!, 
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12)),
          onSelected: (val) {
            if (val == 'rename') _showRenameDialog(context, chatProvider, authService);
            if (val == 'block') chatProvider.blockContact(contact.id, authService);
            if (val == 'remove') chatProvider.removeContact(contact.id, authService);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_rounded, size: 18), title: Text('Rename'), dense: true)),
            const PopupMenuItem(value: 'block', child: ListTile(leading: Icon(Icons.block_rounded, size: 18, color: Colors.redAccent), title: Text('Block'), dense: true)),
            const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_forever_rounded, size: 18, color: Colors.redAccent), title: Text('Remove'), dense: true)),
          ],
        ),
        onTap: () => _showContactDetails(context, contact, authService),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, ChatProvider cp, AuthService auth) {
     final ctrl = TextEditingController(text: contact.name);
     showDialog(
       context: context,
       builder: (context) => AlertDialog(
         title: const Text('Rename Contact'),
         content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'New Nickname')),
         actions: [
           TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
           ElevatedButton(
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

  void _showContactDetails(BuildContext context, Contact contact, AuthService auth) {
     showModalBottomSheet(
       context: context,
       backgroundColor: Colors.transparent,
        builder: (context) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
             color: Theme.of(context).colorScheme.surface,
             borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          ),
         child: Column(
           mainAxisSize: MainAxisSize.min,
           children: [
             _AvatarView(jid: contact.id),
              const SizedBox(height: 16),
              Text(contact.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              Text(contact.id, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
             const SizedBox(height: 24),
             if (contact.presenceMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Theme.of(context).colorScheme.secondary),
                      const SizedBox(width: 12),
                      Expanded(child: Text(contact.presenceMessage!, style: const TextStyle(fontStyle: FontStyle.italic))),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
             ],
             Row(
               children: [
                 Expanded(
                   child: ElevatedButton.icon(
                     style: ElevatedButton.styleFrom(
                       backgroundColor: const Color(0xFFE91E63),
                       foregroundColor: Theme.of(context).colorScheme.onPrimary,
                       padding: const EdgeInsets.symmetric(vertical: 16),
                       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                     ),
                     icon: const Icon(Icons.chat_bubble_rounded),
                     label: const Text('MESSAGE', style: TextStyle(fontWeight: FontWeight.bold)),
                     onPressed: () {
                        final chatProvider = Provider.of<ChatProvider>(context, listen: false);
                        chatProvider.setActiveConversation(contact.id);
                        Navigator.pop(context);
                     },
                   ),
                 ),
               ],
             ),
             const SizedBox(height: 12),
           ],
         ),
       ),
     );
  }
}

class _AvatarView extends StatelessWidget {
  final String jid;
  const _AvatarView({required this.jid});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: AvatarCacheService().getAvatar(jid),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
            image: bytes != null ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover) : null,
          ),
          child: bytes == null 
            ? Icon(Icons.person_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)) 
            : null,
        );
      }
    );
  }
}

class _StatusIndicator extends StatefulWidget {
  final ContactStatus status;
  const _StatusIndicator({required this.status});

  @override
  State<_StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends State<_StatusIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
       vsync: this,
       duration: const Duration(seconds: 2),
    );
    if (widget.status == ContactStatus.online) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_StatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == ContactStatus.online) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (widget.status) {
      case ContactStatus.online: color = Theme.of(context).colorScheme.secondary; break;
      case ContactStatus.away: color = Colors.orange; break;
      case ContactStatus.xa: color = Colors.orange.shade700; break;
      case ContactStatus.dnd: color = Theme.of(context).colorScheme.primary; break;
      case ContactStatus.offline: color = Colors.grey; break;
    }

    return ScaleTransition(
      scale: Tween(begin: 0.8, end: 1.2).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut)),
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
        ),
      ),
    );
  }
}
