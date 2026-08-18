import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../providers/chat_provider.dart';
import '../models/chat_models.dart';

class NewMessageScreen extends StatefulWidget {
  const NewMessageScreen({super.key});

  @override
  State<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends State<NewMessageScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val) {
    setState(() {
      _searchQuery = val.toLowerCase();
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
    _searchFocusNode.requestFocus();
  }

  Future<void> _startConversation(String jid) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    await chatProvider.setActiveConversation(jid);
    if (mounted) {
      context.goNamed('home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: const Text(
          'New Message',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          _buildSearchBar(theme),
          Expanded(
            child: _searchQuery.isEmpty
                ? _buildDefaultView(chatProvider, authService)
                : _buildSearchResults(chatProvider, authService),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onSearchChanged,
        style: TextStyle(color: theme.colorScheme.onSurface),
        decoration: InputDecoration(
          hintText: 'Search people or enter a JID...',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: _clearSearch,
                )
              : null,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildDefaultView(ChatProvider chatProvider, AuthService authService) {
    final conversations = chatProvider.conversations;

    final recent = conversations
        .where((c) => !c.isGroup && c.lastMessage != null)
        .toList()
      ..sort((a, b) {
        final aTime = a.lastMessage?.timestamp ?? DateTime(1970);
        final bTime = b.lastMessage?.timestamp ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });

    final suggestions = conversations
        .where((c) => !c.isGroup && c.unreadCount > 0)
        .toList()
      ..sort((a, b) => b.unreadCount.compareTo(a.unreadCount));

    final sortedContacts = List<Contact>.from(authService.currentContacts)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return CustomScrollView(
      slivers: [
        if (recent.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader('Recent'),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: recent.take(8).length,
                itemBuilder: (context, index) {
                  return _RecentTile(
                    conversation: recent[index],
                    onTap: () => _startConversation(recent[index].id),
                  );
                },
              ),
            ),
          ),
        ],
        if (suggestions.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader('Unread'),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final conv = suggestions[index];
                return _ConversationTile(
                  conversation: conv,
                  onTap: () => _startConversation(conv.id),
                );
              },
              childCount: suggestions.take(5).length,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: _buildSectionHeader('All Contacts'),
        ),
        if (sortedContacts.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.person_add_alt_1_rounded,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No contacts yet',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Add buddies to start chatting',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final contact = sortedContacts[index];
                return _ContactTile(
                  contact: contact,
                  onTap: () => _startConversation(contact.id),
                );
              },
              childCount: sortedContacts.length,
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 32),
        ),
      ],
    );
  }

  Widget _buildSearchResults(ChatProvider chatProvider, AuthService authService) {
    final q = _searchQuery;

    final filteredContacts = authService.currentContacts
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.id.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final filteredConvs = chatProvider.conversations
        .where((c) =>
            !c.isGroup &&
            (c.name.toLowerCase().contains(q) || c.id.toLowerCase().contains(q)))
        .toList();

    final hasContactMatch = filteredContacts.isNotEmpty;
    final hasConvMatch = filteredConvs.isNotEmpty;
    final isJidLike = q.contains('@') && q.contains('.');
    final showJidFallback = isJidLike &&
        !authService.currentContacts.any((c) => c.id.toLowerCase() == q);

    if (!hasContactMatch && !hasConvMatch && !showJidFallback) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'No results for "$_searchQuery"',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (hasConvMatch) ...[
          _buildSectionHeader('Conversations'),
          ...filteredConvs.map((conv) => _ConversationTile(
                conversation: conv,
                onTap: () => _startConversation(conv.id),
              )),
        ],
        if (hasContactMatch) ...[
          _buildSectionHeader('Contacts'),
          ...filteredContacts.map((contact) => _ContactTile(
                contact: contact,
                onTap: () => _startConversation(contact.id),
              )),
        ],
        if (showJidFallback) ...[
          _buildSectionHeader('Start Chat'),
          _JidFallbackTile(
            jid: _searchQuery,
            onTap: () => _startConversation(_searchQuery),
          ),
        ],
        const SizedBox(height: 32),
      ],
    );
  }

  ThemeData get theme => Theme.of(context);

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _RecentTile({required this.conversation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                conversation.name.isNotEmpty ? conversation.name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              conversation.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationTile({required this.conversation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.03),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            conversation.name.isNotEmpty ? conversation.name[0].toUpperCase() : '?',
            style: TextStyle(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                conversation.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
            if (conversation.unreadCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${conversation.unreadCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: conversation.lastMessage != null
            ? Text(
                conversation.lastMessage!.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;

  const _ContactTile({required this.contact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.03),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: _statusColor(contact.status),
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.surface, width: 2),
              ),
            ),
          ],
        ),
        title: Text(
          contact.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
        subtitle: Text(
          contact.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Icon(
          Icons.chat_bubble_outline_rounded,
          size: 18,
          color: theme.colorScheme.primary.withValues(alpha: 0.7),
        ),
        onTap: onTap,
      ),
    );
  }

  Color _statusColor(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return Colors.greenAccent;
      case ContactStatus.away:
      case ContactStatus.xa:
        return Colors.orangeAccent;
      case ContactStatus.dnd:
        return Colors.redAccent;
      case ContactStatus.offline:
        return Colors.grey;
    }
  }
}

class _JidFallbackTile extends StatelessWidget {
  final String jid;
  final VoidCallback onTap;

  const _JidFallbackTile({required this.jid, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
          child: Icon(
            Icons.person_add_rounded,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          jid,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            color: theme.colorScheme.primary,
          ),
        ),
        subtitle: Text(
          'Not in your contacts',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios_rounded,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        onTap: onTap,
      ),
    );
  }
}
