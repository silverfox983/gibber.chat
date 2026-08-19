import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/chat_provider.dart';
import '../services/spaces_service.dart';
import '../models/chat_models.dart';
import '../models/space_models.dart';

class NexusSearchScreen extends StatefulWidget {
  const NexusSearchScreen({super.key});

  @override
  State<NexusSearchScreen> createState() => _NexusSearchScreenState();
}

class _NexusSearchScreenState extends State<NexusSearchScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  late TabController _tabController;
  List<SpaceItem> _postResults = [];
  bool _searchingPosts = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String query) async {
    if (query.isEmpty) {
      setState(() => _postResults = []);
      return;
    }
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final spacesService = Provider.of<SpacesService>(context, listen: false);
    final spaces = chatProvider.globalSearchResults;

    setState(() => _searchingPosts = true);
    final joinedSpaces = spaces.map((s) => SpaceNode(domain: s.conversationId ?? '', node: '', name: '')).toList();
    final results = <SpaceItem>[];
    for (final space in joinedSpaces) {
      try {
        final items = await spacesService.searchPosts(space.domain, space.node, query);
        results.addAll(items);
      } catch (_) {}
    }
    if (mounted) setState(() { _postResults = results; _searchingPosts = false; });
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);
    final msgResults = chatProvider.globalSearchResults;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Nexus Search'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Messages'),
            Tab(text: 'Posts'),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Search across all XMPP accounts...',
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                prefixIcon: Icon(Icons.travel_explore_rounded, color: Theme.of(context).colorScheme.secondary),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        onPressed: () {
                          _searchController.clear();
                          chatProvider.searchGlobalMessages('');
                          setState(() => _postResults = []);
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)),
              ),
              onChanged: (val) {
                chatProvider.searchGlobalMessages(val);
                _doSearch(val);
              },
              onSubmitted: (val) {
                chatProvider.searchGlobalMessages(val);
                _doSearch(val);
              },
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Messages tab
                msgResults.isEmpty
                    ? _buildEmptyState(chatProvider.isSyncing, 'messages')
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: msgResults.length,
                        itemBuilder: (context, index) {
                          final msg = msgResults[index];
                          return _buildMessageTile(msg, chatProvider);
                        },
                      ),
                // Posts tab
                _searchingPosts
                    ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
                    : _postResults.isEmpty
                        ? _buildEmptyState(false, 'posts')
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _postResults.length,
                            itemBuilder: (context, index) => _buildPostTile(_postResults[index]),
                          ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageTile(ChatMessage msg, ChatProvider chatProvider) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        boxShadow: [
          BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(Icons.chat_bubble_rounded, size: 18, color: Theme.of(context).colorScheme.onPrimaryContainer),
        ),
        title: Row(
          children: [
            Expanded(child: Text(msg.senderName ?? msg.senderId!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
            Text(DateFormat('MMM d, HH:mm').format(msg.timestamp), style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(msg.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
              child: Text(msg.conversationId ?? 'Global', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSecondaryContainer, letterSpacing: 1.0)),
            ),
          ],
        ),
        onTap: () {
          if (msg.conversationId != null) {
            chatProvider.setActiveConversation(msg.conversationId!);
            chatProvider.setSidebarTab(0);
            Navigator.pop(context);
          }
        },
      ),
    );
  }

  Widget _buildPostTile(SpaceItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        boxShadow: [
          BoxShadow(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          child: Icon(Icons.article_rounded, size: 18, color: Theme.of(context).colorScheme.onSecondaryContainer),
        ),
        title: Text(item.name ?? 'Post', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Text(item.description ?? item.rawContent ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('by ${item.author ?? 'Anonymous'}', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
          ],
        ),
        onTap: () {
          Navigator.pop(context);
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isSyncing, String tab) {
    if (isSyncing) return Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary));
    final isMessages = tab == 'messages';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 64, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1)),
          const SizedBox(height: 16),
          Text(
            _searchController.text.isEmpty
                ? (isMessages ? 'Search messages...' : 'Search posts across your spaces...')
                : 'No results found',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
