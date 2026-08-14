import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';
import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../providers/chat_provider.dart';
import '../models/chat_models.dart';
import 'dart:ui';

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
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              expandedHeight: 180.0,
              floating: false,
              pinned: true,
              backgroundColor: Theme.of(context).colorScheme.primary,
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsets.only(left: 24, bottom: 64),
                title: Text(
                  'Social Spaces',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.onPrimary,
                    shadows: [Shadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10)],
                  ),
                ),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Theme.of(context).colorScheme.primary,
                            Theme.of(context).colorScheme.secondary,
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: -50,
                      top: -50,
                      child: Icon(Icons.hub_rounded, size: 200, color: Colors.white.withValues(alpha: 0.1)),
                    ),
                  ],
                ),
              ),
              actions: [
                Container(
                  margin: const EdgeInsets.only(right: 16, top: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(Icons.person_add_alt_1_rounded, color: Theme.of(context).colorScheme.onPrimary),
                    onPressed: () {
                      context.goNamed('addContact');
                    },
                  ),
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(100),
                child: Column(
                  children: [
                    // Glassmorphic Search Bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                            ),
                            child: TextField(
                              controller: _searchController,
                              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
                              decoration: InputDecoration(
                                hintText: 'Search connections...',
                                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                                prefixIcon: Icon(Icons.search_rounded, color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
                      ),
                    ),
                    TabBar(
                      controller: _tabController,
                      labelColor: Theme.of(context).colorScheme.onPrimary,
                      unselectedLabelColor: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
                      indicatorColor: Theme.of(context).colorScheme.onPrimary,
                      indicatorWeight: 4,
                      tabs: const [
                        Tab(text: 'CONTACTS'),
                        Tab(text: 'GROUPS'),
                        Tab(text: 'BLOCKED'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildContactList(context, authService),
            _buildGroupsList(context),
            _buildBlockedList(context, authService),
          ],
        ),
      ),
    );
  }

  Widget _buildContactList(BuildContext context, AuthService authService) {
    return StreamBuilder<List<Map<String, String>>>(
      stream: authService.subscriptionRequests,
      initialData: authService.currentSubscriptionRequests,
      builder: (context, reqSnapshot) {
        final requests = reqSnapshot.data ?? [];
        
        return StreamBuilder<List<Contact>>(
          stream: authService.contacts,
          initialData: authService.currentContacts,
          builder: (context, contactSnapshot) {
            final contacts = contactSnapshot.data ?? [];
            final filtered = contacts.where((c) => 
              c.name.toLowerCase().contains(_searchQuery) || 
              c.id.toLowerCase().contains(_searchQuery)
            ).toList();

            if (requests.isEmpty && filtered.isEmpty) {
              return _buildEmptyState(Icons.people_outline_rounded, 'No contacts found');
            }

            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (requests.isNotEmpty) _buildRequestsSection(context, authService, requests),
                if (filtered.isNotEmpty) ..._buildGroupedContactsSection(context, filtered),
              ],
            );
          }
        );
      }
    );
  }

  Widget _buildRequestsSection(BuildContext context, AuthService authService, List<Map<String, String>> requests) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
          child: Text('FRIEND REQUESTS', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary, fontSize: 12, letterSpacing: 1.2)),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final jid = requests[index]['jid'] ?? '';
              return Container(
                width: 240,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                  boxShadow: [
                    BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _AvatarView(jid: jid),
                    const SizedBox(height: 8),
                    Text(jid.split('@').first, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        FilledButton.tonal(
                          onPressed: () => authService.declineSubscription(jid),
                          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer, foregroundColor: Theme.of(context).colorScheme.onErrorContainer, padding: const EdgeInsets.symmetric(horizontal: 16)),
                          child: const Text('IGNORE'),
                        ),
                        FilledButton(
                          onPressed: () => authService.acceptSubscription(jid),
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
                          child: const Text('ACCEPT'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  List<Widget> _buildGroupedContactsSection(BuildContext context, List<Contact> contacts) {
    // Group contacts
    final Map<String, List<Contact>> grouped = {};
    for (var c in contacts) {
      if (c.groups.isEmpty) {
        grouped.putIfAbsent('General', () => []).add(c);
      } else {
        for (var g in c.groups) {
          grouped.putIfAbsent(g, () => []).add(c);
        }
      }
    }

    // Sort keys: 'General' last, otherwise alphabetical
    final keys = grouped.keys.toList();
    keys.sort((a, b) {
      if (a == 'General') return 1;
      if (b == 'General') return -1;
      return a.compareTo(b);
    });

    final widgets = <Widget>[];
    for (var key in keys) {
      final groupContacts = grouped[key]!;
      groupContacts.sort((a, b) {
        if (a.status != b.status) {
          if (a.status == ContactStatus.online) return -1;
          if (b.status == ContactStatus.online) return 1;
        }
        return a.name.compareTo(b.name);
      });

      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
          child: Text(key.toUpperCase(), style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, letterSpacing: 1.2)),
        ),
      );
      widgets.addAll(groupContacts.map((c) => _ContactTile(contact: c)));
    }
    return widgets;
  }



  Widget _buildGroupsList(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        final groupConvs = chatProvider.conversations.where((c) => c.isGroup).toList();
        
        if (groupConvs.isEmpty) {
          return _buildEmptyState(Icons.group_rounded, 'No groups found');
        }

        return ListView.builder(
          itemCount: groupConvs.length,
          padding: const EdgeInsets.all(16),
          itemBuilder: (context, index) {
            final conv = groupConvs[index];
            return _buildGroupTile(Theme.of(context), conv, chatProvider);
          },
        );
      },
    );
  }

  Widget _buildGroupTile(ThemeData theme, Conversation conv, ChatProvider cp) {
    final isIrc = conv.protocol == 'IRC';
    final isDiscord = conv.protocol == 'Discord';
    final themeColor = isDiscord
        ? const Color(0xFF5865F2)
        : (isIrc ? theme.colorScheme.secondary : theme.colorScheme.primary);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.8), width: 1.5),
      ),
      child: InkWell(
        onTap: () {
          cp.setActiveConversation(conv.id);
          Navigator.popUntil(context, (route) => route.isFirst);
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: themeColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: isDiscord
                    ? Icon(Icons.discord, color: themeColor, size: 28)
                    : (isIrc ? Icon(Icons.alternate_email, color: themeColor, size: 28)
                             : Text(conv.name.isNotEmpty ? conv.name[0].toUpperCase() : '?', style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 24))),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(conv.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                    const SizedBox(height: 4),
                    Text('${conv.protocol} Group', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              if (conv.unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    conv.unreadCount.toString(),
                    style: TextStyle(color: theme.colorScheme.onError, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              const SizedBox(width: 16),
              Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
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

  // Removing _showAddContactDialog since we have AddContactScreen
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
      context.goNamed('contactProfile', extra: {'contact': contact});
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
