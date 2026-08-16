import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:share_plus/share_plus.dart';

import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../services/spaces_service.dart';
import '../models/space_models.dart';
import '../providers/chat_provider.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  SpacesService? _spacesService;
  List<SpaceNode> _mySpaces = [];
  List<SpaceNode> _lastSeenJoinedSpaces = [];
  bool _isLoading = false;
  Future<List<SpaceItem>>? _feedFuture;
  List<SpaceItem>? _cachedItems;
  StreamSubscription<SpaceItem>? _liveStreamSub;
  int _newLiveCount = 0;
  String? _attachedImageUrl;

  // UI state for immutable SpaceItems
  final Set<String> _bookmarkedItems = {};
  final Set<String> _expandedItems = {};
  final Set<String> _likedItems = {};
  final Map<String, Map<String, int>> _itemReactions = {};

  // UI state
  late TabController _tabController;
  bool _showSearch = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  static const List<String> _tabs = ['All', 'Posts', 'Media', 'Saved'];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() => setState(() {}));
    _searchController.addListener(() => setState(() => _searchQuery = _searchController.text.toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeFeed();
    });
  }

  Future<void> _initializeFeed() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) return;

    setState(() => _isLoading = true);

    if (_spacesService == null || _spacesService!.connection != conn) {
      _liveStreamSub?.cancel();
      _spacesService?.dispose();
      _spacesService = SpacesService(conn);
      _liveStreamSub = _spacesService!.liveItemStream.listen((item) {
        if (!mounted) return;
        setState(() {
          _cachedItems = [item, ...(_cachedItems ?? [])];
          _newLiveCount++;
        });
      });
    }

    try {
      // Use joined spaces from AuthService for the unified feed
      _lastSeenJoinedSpaces = List.from(auth.joinedSpaces);
      _mySpaces = List.from(auth.joinedSpaces);
      
      final future = _spacesService!.fetchUnifiedFeed(_mySpaces);
      _feedFuture = future;
      
      // Update cache when future completes
      future.then((items) {
        if (mounted) setState(() => _cachedItems = items);
      });
    } catch (e) {
      debugPrint('Error initializing feed: $e');
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _liveStreamSub?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _newLiveCount = 0);
    await _initializeFeed();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final auth = Provider.of<AuthService>(context);

    final joined = auth.joinedSpaces;
    bool changed = joined.length != _lastSeenJoinedSpaces.length;
    if (!changed) {
      for (int i = 0; i < joined.length; i++) {
        if (joined[i].domain != _lastSeenJoinedSpaces[i].domain ||
            joined[i].node != _lastSeenJoinedSpaces[i].node) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initializeFeed());
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        titleSpacing: 16,
        title: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  hintText: 'Search feed...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            : Row(
                children: [
                  Image.asset(
                    'assets/logo.png',
                    height: 24,
                    width: 24,
                  ),
                  const SizedBox(width: 12),
                  const Text('Activity Feed',
                      style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                ],
              ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: Icon(_showSearch ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchController.clear();
                _searchQuery = '';
              }
            }),
          ),
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _refresh),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          indicatorWeight: 3,
          indicatorColor: theme.colorScheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
          dividerHeight: 0,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _showComposeSheet(context),
        icon: const Icon(Icons.edit_rounded),
        label: const Text('Post', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 4,
      ),
      body: _buildDashboard(theme),
    );
  }

  List<SpaceItem> _filteredItems(List<SpaceItem> all) {
    List<SpaceItem> items = all;
    // Search filter
    if (_searchQuery.isNotEmpty) {
      items = items.where((it) =>
        (it.name?.toLowerCase().contains(_searchQuery) ?? false) ||
        (it.author?.toLowerCase().contains(_searchQuery) ?? false) ||
        (it.rawContent?.toLowerCase().contains(_searchQuery) ?? false) ||
        (it.description?.toLowerCase().contains(_searchQuery) ?? false)
      ).toList();
    }
    // Tab filter
    final tab = _tabController.index;
    if (tab == 1) items = items.where((it) => it.type == 'entry').toList();
    if (tab == 2) items = items.where((it) => it.mediaAttachments.isNotEmpty || it.imageUrl != null).toList();
    if (tab == 3) items = items.where((it) => _bookmarkedItems.contains(it.id) || it.isBookmarked).toList();
    return items;
  }

  Widget _buildDashboard(ThemeData theme) {
    if (_isLoading && _mySpaces.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_isLoading && _mySpaces.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.dynamic_feed_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      const Text('No Subscriptions', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('Join some communities in the Spaces tab to see activity here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 16)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        slivers: [
          // Stats header
          SliverToBoxAdapter(child: _buildStatsHeader(theme)),

          // Live banner
          if (_newLiveCount > 0)
            SliverToBoxAdapter(
              child: GestureDetector(
                onTap: () => setState(() => _newLiveCount = 0),
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(children: [
                    Icon(Icons.fiber_new_rounded, color: theme.colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text('$_newLiveCount new post${_newLiveCount > 1 ? 's' : ''} — tap to dismiss',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                            color: theme.colorScheme.onPrimaryContainer)),
                  ]),
                ),
              ),
            ),

          FutureBuilder<List<SpaceItem>>(
            future: _feedFuture,
            initialData: _cachedItems,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  (snapshot.data == null || snapshot.data!.isEmpty)) {
                return const SliverToBoxAdapter(
                    child: Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())));
              }
              final items = _filteredItems(snapshot.data ?? []);
              if (items.isEmpty) {
                final msg = _tabController.index == 3
                    ? 'No saved posts yet.\nBookmark posts to see them here.'
                    : _searchQuery.isNotEmpty
                        ? 'No posts match "$_searchQuery".'
                        : 'No recent activity.';
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.inbox_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(msg, textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 15)),
                      ]),
                    ),
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = items[index];
                    final group = _getDateGroup(item.publishedDate);
                    final prevGroup = index > 0 ? _getDateGroup(items[index - 1].publishedDate) : null;
                    final showHeader = group != prevGroup;

                    final card = _buildSpaceItemCard(theme, item);
                    if (!showHeader) return card;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                          child: Text(group, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.5).copyWith(color: theme.colorScheme.primary)),
                        ),
                        card,
                      ],
                    );
                  },
                  childCount: items.length,
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  Widget _buildStatsHeader(ThemeData theme) {
    final newCount = _newLiveCount + (_cachedItems?.where((i) => i.type == 'entry').length ?? 0);
    final savedCount = _cachedItems?.where((i) => _bookmarkedItems.contains(i.id) || i.isBookmarked).length ?? 0;
    final mediaCount = _cachedItems?.where((i) => i.mediaAttachments.isNotEmpty || i.imageUrl != null).length ?? 0;

    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        children: [
          _buildStatChip(theme, Icons.workspaces_rounded, '${_mySpaces.length}', 'Spaces', theme.colorScheme.primary),
          const SizedBox(width: 10),
          _buildStatChip(theme, Icons.article_rounded, '$newCount', 'Posts', theme.colorScheme.secondary),
          const SizedBox(width: 10),
          _buildStatChip(theme, Icons.image_rounded, '$mediaCount', 'With Media', Colors.deepOrange),
          const SizedBox(width: 10),
          _buildStatChip(theme, Icons.bookmark_rounded, '$savedCount', 'Saved', Colors.amber.shade700),
        ],
      ),
    );
  }

  Widget _buildStatChip(ThemeData theme, IconData icon, String count, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(count, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: color)),
          Text(label, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }


  Widget _buildSpaceItemCard(ThemeData theme, SpaceItem item) {
    final sourceSpace = item.sourceSpace;
    final spaceName = sourceSpace?.name ?? item.node ?? 'Unknown Space';

    if (item.type == 'room') {
      return Card(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5))),
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.tag_rounded, color: Colors.blue)),
          title: Text(item.name ?? item.id, style: const TextStyle(fontWeight: FontWeight.w900)),
          subtitle: Row(
            children: [
              Flexible(
                child: Text('Room in $spaceName', style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (item.publishedDate != null) ...[
                const SizedBox(width: 8),
                Text('• ${_timeAgo(item.publishedDate!)}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              ],
            ],
          ),
          trailing: FilledButton.tonal(
            onPressed: () {
              final auth = Provider.of<AuthService>(context, listen: false);
              if (auth.activeAccountId != null) {
                auth.joinXmppRoom(item.id, auth.getResolvedNickname(auth.activeAccountId!), accountId: auth.activeAccountId!);
                Provider.of<ChatProvider>(context, listen: false).setActiveConversation(item.id);
                // Also switch main tab to chats (index 0)
                Provider.of<ChatProvider>(context, listen: false).setSidebarTab(0);
              }
            },
            child: const Text('JOIN'),
          ),
        ),
      );
    }

    if (item.type != 'entry') return const SizedBox.shrink();

    final content = item.rawContent != null && item.rawContent!.isNotEmpty
        ? (item.contentType == 'text/html' ? html2md.convert(item.rawContent!) : item.rawContent!)
        : (item.description ?? '');
    final wordCount = content.split(' ').length;
    final readMinutes = (wordCount / 200).ceil();
    final isLong = content.length > 400;
    final isExpanded = _expandedItems.contains(item.id);
    final displayContent = (isLong && !isExpanded) ? '${content.substring(0, 400)}…' : content;

    return GestureDetector(
      onLongPress: () => _showReactionPicker(context, item),
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: (item.mediaAttachments.isNotEmpty || item.imageUrl != null)
                ? Colors.deepOrange.withValues(alpha: 0.4)
                : theme.colorScheme.primary.withValues(alpha: 0.2),
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              leading: _AuthorAvatar(jid: item.author ?? ''),
              title: Text(item.author ?? 'Anonymous', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              subtitle: Row(
                children: [
                  Icon(Icons.workspaces_rounded, size: 11, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(item.sourceSpace?.name ?? item.node ?? 'Space',
                        style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (item.publishedDate != null) ...[
                    const SizedBox(width: 6),
                    Text('• ${_timeAgo(item.publishedDate!)}', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                  ],
                  if (readMinutes > 1) ...[
                    const SizedBox(width: 6),
                    Text('· ${readMinutes}m read', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ],
              ),
              trailing: IconButton(
                icon: Icon(
                  (_bookmarkedItems.contains(item.id) || item.isBookmarked) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                  color: (_bookmarkedItems.contains(item.id) || item.isBookmarked) ? Colors.amber.shade700 : theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () => setState(() {
                  if (_bookmarkedItems.contains(item.id) || item.isBookmarked) {
                    _bookmarkedItems.remove(item.id);
                  } else {
                    _bookmarkedItems.add(item.id);
                  }
                }),
              ),
            ),

            // Title
            if (item.name != null && item.name!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                child: Text(item.name!, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 19, height: 1.25)),
              ),

            // Category chips
            if (item.categories.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Wrap(
                  spacing: 6,
                  children: item.categories.map((cat) => Chip(
                    label: Text(cat, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSecondaryContainer)),
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    side: BorderSide.none,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                  )).toList(),
                ),
              ),

            // Body
            if (content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarkdownBody(
                      data: displayContent,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(fontSize: 15, color: theme.colorScheme.onSurface, height: 1.5),
                        a: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
                      ),
                      onTapLink: (text, href, title) {
                        if (href != null) launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
                      },
                    ),
                    if (isLong)
                      GestureDetector(
                        onTap: () => setState(() {
                          if (isExpanded) {
                            _expandedItems.remove(item.id);
                          } else {
                            _expandedItems.add(item.id);
                          }
                        }),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            isExpanded ? 'Show less' : 'Read more',
                            style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            // Media
            if (item.mediaAttachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: SizedBox(
                  height: 220,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: item.mediaAttachments.length,
                    itemBuilder: (context, index) {
                      final media = item.mediaAttachments[index];
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          margin: const EdgeInsets.only(right: 10),
                          width: 280,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Image.network(media.url, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded)),
                        ),
                      );
                    },
                  ),
                ),
              )
            else if (item.imageUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: ClipRRect(
                  child: Image.network(item.imageUrl!, width: double.infinity, height: 220, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),

            // Reactions row
            if ((_itemReactions[item.id] ?? item.reactions).isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Wrap(
                  spacing: 6,
                  children: (_itemReactions[item.id] ?? item.reactions).entries
                      .where((e) => e.value > 0)
                      .map((e) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: theme.dividerColor),
                            ),
                            child: Text('${e.key} ${e.value}', style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                ),
              ),

            // Action bar
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  _buildInteractionButton(
                    icon: (_likedItems.contains(item.id) || item.isLikedByMe) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    label: ((_itemReactions[item.id] ?? item.reactions)['❤️'] ?? 0) > 0 ? '${(_itemReactions[item.id] ?? item.reactions)['❤️']}' : '',
                    color: (_likedItems.contains(item.id) || item.isLikedByMe) ? Colors.red : theme.colorScheme.onSurfaceVariant,
                    onTap: () => _handleLike(item),
                  ),
                  _buildInteractionButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Reply',
                    color: theme.colorScheme.onSurfaceVariant,
                    onTap: () => _showReplyDialog(item),
                  ),
                  _buildInteractionButton(
                    icon: Icons.add_reaction_outlined,
                    label: '',
                    color: theme.colorScheme.onSurfaceVariant,
                    onTap: () => _showReactionPicker(context, item),
                  ),
                  const Spacer(),
                  _buildInteractionButton(
                    icon: Icons.ios_share_rounded,
                    label: '',
                    color: theme.colorScheme.onSurfaceVariant,
                    onTap: () => _handleShare(item),
                  ),
                 ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInteractionButton({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y';
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo';
    if (diff.inDays > 0) return '${diff.inDays}d';
    if (diff.inHours > 0) return '${diff.inHours}h';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return 'now';
  }

  String _getDateGroup(DateTime? d) {
    if (d == null) return 'Older';
    final now = DateTime.now();
    final diff = now.difference(d);
    if (now.year == d.year && now.month == d.month && now.day == d.day) return 'TODAY';
    final yesterday = now.subtract(const Duration(days: 1));
    if (yesterday.year == d.year && yesterday.month == d.month && yesterday.day == d.day) return 'YESTERDAY';
    if (diff.inDays < 7) return 'THIS WEEK';
    if (now.year == d.year && now.month == d.month) return 'THIS MONTH';
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    return '${months[d.month - 1]} ${d.year}';
  }

  void _handleLike(SpaceItem item) async {
    final reactions = Map<String, int>.from(_itemReactions[item.id] ?? item.reactions);
    final wasLiked = _likedItems.contains(item.id) || item.isLikedByMe;
    setState(() {
      if (wasLiked) {
        _likedItems.remove(item.id);
        reactions['❤️'] = ((reactions['❤️'] ?? 1) - 1).clamp(0, 9999);
      } else {
        _likedItems.add(item.id);
        reactions['❤️'] = (reactions['❤️'] ?? 0) + 1;
      }
      _itemReactions[item.id] = reactions;
    });
    if (wasLiked) return;
    final domain = item.sourceSpace?.domain ?? '';
    final node = item.sourceSpace?.node ?? '';
    if (domain.isEmpty || node.isEmpty) return;
    final auth = Provider.of<AuthService>(context, listen: false);
    final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
    await _spacesService?.publishReaction(domain, node, item.id, '❤️', userJid);
  }

  void _handleShare(SpaceItem item) {
    final text = '${item.name ?? 'Post'} by ${item.author ?? 'Anonymous'}\n\n${item.description ?? ''}';
    Share.share(text, subject: item.name);
  }

  void _showReactionPicker(BuildContext ctx2, SpaceItem item) {
    const emojis = ['❤️', '😂', '😮', '😢', '👍', '🔥'];
    showModalBottomSheet(
      context: ctx2,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(ctx2).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('React', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Theme.of(ctx2).colorScheme.onSurface)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: emojis.map((emoji) => GestureDetector(
              onTap: () {
                Navigator.pop(ctx2);
                setState(() {
                  final reactions = Map<String, int>.from(_itemReactions[item.id] ?? item.reactions);
                  reactions[emoji] = (reactions[emoji] ?? 0) + 1;
                  _itemReactions[item.id] = reactions;
                });
                final domain = item.sourceSpace?.domain ?? '';
                final node = item.sourceSpace?.node ?? '';
                if (domain.isNotEmpty && node.isNotEmpty) {
                  final auth = Provider.of<AuthService>(ctx2, listen: false);
                  final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
                  _spacesService?.publishReaction(domain, node, item.id, emoji, userJid);
                }
              },
              child: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: Theme.of(ctx2).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(child: Text(emoji, style: const TextStyle(fontSize: 26))),
              ),
            )).toList(),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
  Future<void> _pickImage(StateSetter setM) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null || !mounted) return;
      setM(() => _attachedImageUrl = file.path);
    } catch (e) {
      debugPrint('Image pick error: $e');
    }
  }

  void _showComposeSheet(BuildContext ctx2) {
    if (_mySpaces.isEmpty) {
      ScaffoldMessenger.of(ctx2).showSnackBar(const SnackBar(content: Text('Join a space first to post.')));
      return;
    }
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    SpaceNode? sel = _mySpaces.first;
    showModalBottomSheet(
      context: ctx2,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx2).viewInsets.bottom),
        child: StatefulBuilder(builder: (sctx, setM) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Theme.of(ctx2).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Theme.of(ctx2).colorScheme.onSurfaceVariant.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            Text('New Post', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Theme.of(ctx2).colorScheme.onSurface)),
            const SizedBox(height: 16),
            DropdownButtonFormField<SpaceNode>(
              value: sel,
              decoration: InputDecoration(
                labelText: 'Post to Space',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              items: _mySpaces.map((s) => DropdownMenuItem(value: s, child: Text(s.name, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setM(() => sel = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: 'Title (optional)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bodyCtrl,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Write something…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            const SizedBox(height: 12),
            if (_attachedImageUrl != null)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _attachedImageUrl!.startsWith('http')
                      ? Image.network(_attachedImageUrl!, height: 120, width: double.infinity, fit: BoxFit.cover)
                      : kIsWeb ? const SizedBox.shrink() : Image.file(File(_attachedImageUrl!), height: 120, width: double.infinity, fit: BoxFit.cover),
                ),
                Positioned(top: 4, right: 4,
                  child: GestureDetector(
                    onTap: () => setM(() => _attachedImageUrl = null),
                    child: Container(padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, color: Colors.white, size: 14)),
                  )),
              ]),
            const SizedBox(height: 16),
            Row(children: [
              IconButton(
                onPressed: () => _pickImage(setM),
                icon: Icon(Icons.image_rounded, color: _attachedImageUrl != null ? Theme.of(ctx2).colorScheme.primary : null),
                tooltip: 'Attach Image',
              ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(sctx), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Publish'),
                onPressed: () async {
                  final body = bodyCtrl.text.trim();
                  if (body.isEmpty || sel == null) return;
                  final auth = Provider.of<AuthService>(ctx2, listen: false);
                  final authorName = auth.getResolvedNickname(null);
                  
                  setM(() {});

                  try {
                    String? finalImageUrl = _attachedImageUrl;
                    if (_attachedImageUrl != null && !_attachedImageUrl!.startsWith('http') && !kIsWeb) {
                      final uploadService = auth.activeUploadService;
                      if (uploadService != null) {
                        final file = File(_attachedImageUrl!);
                        final fileName = file.path.split(RegExp(r'[/\\]')).last;
                        final size = await file.length();
                        final contentType = 'image/${fileName.split('.').last.toLowerCase()}';
                        final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
                        if (slot != null) {
                          final upSuccess = await uploadService.uploadFile(slot['put']!, file, contentType);
                          if (upSuccess) finalImageUrl = slot['get'];
                        }
                      }
                    }

                    final success = await _spacesService?.publishMicroblogEntry(
                      sel!.domain, sel!.node,
                      title: titleCtrl.text.trim(), content: body, authorName: authorName,
                      imageUrl: finalImageUrl,
                    );
                    
                    if (mounted) {
                      Navigator.pop(sctx);
                      ScaffoldMessenger.of(ctx2).showSnackBar(SnackBar(content: Text(success == true ? 'Posted!' : 'Failed to post.')));
                      if (success == true) {
                        _attachedImageUrl = null;
                        _refresh();
                      }
                    }
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(ctx2).showSnackBar(SnackBar(content: Text('Error: $e')));
                  }
                },
              ),
            ]),
            const SizedBox(height: 8),
          ]),
        )),
      ),
    );
  }

  void _showReplyDialog(SpaceItem item) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx3) => AlertDialog(
        title: Text('Reply to ${item.author ?? 'Post'}'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Write your reply...', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx3), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx3);
              final targetDomain = item.commentService ?? item.sourceSpace?.domain ?? '';
              final targetNode = item.commentNode ?? item.sourceSpace?.node ?? '';
              if (targetDomain.isEmpty || targetNode.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot reply: Target space info missing')));
                return;
              }
              final auth = Provider.of<AuthService>(context, listen: false);
              final authorName = auth.getResolvedNickname(null);
              var success = await _spacesService!.postReply(targetDomain, targetNode, text, replyToId: item.id, authorName: authorName);
              if (!success && item.commentNode != null && item.sourceSpace != null) {
                success = await _spacesService!.postReply(
                  item.sourceSpace!.domain,
                  item.sourceSpace!.node,
                  text,
                  replyToId: item.id,
                  authorName: authorName,
                  autoCreateNode: false,
                );
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Reply posted!' : 'Failed to post reply.')));
                if (success) _refresh();
              }
            },
            child: const Text('Post Reply'),
          ),
        ],
      ),
    );
  }
}

class _AuthorAvatar extends StatefulWidget {
  final String jid;
  const _AuthorAvatar({required this.jid});

  @override
  State<_AuthorAvatar> createState() => _AuthorAvatarState();
}

class _AuthorAvatarState extends State<_AuthorAvatar> {
  bool _fetchTriggered = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, authService, child) {
        return FutureBuilder<Uint8List?>(
          future: AvatarCacheService().getAvatar(widget.jid),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            
            // If missing, trigger a network fetch once
            if (bytes == null && 
                !_fetchTriggered && 
                widget.jid.isNotEmpty && 
                authService.activeAccountId != null) {
              _fetchTriggered = true;
              // Schedule fetch to avoid blocking render
              WidgetsBinding.instance.addPostFrameCallback((_) {
                authService.fetchVCard(authService.activeAccountId!, widget.jid);
              });
            }

            final initials = widget.jid.isNotEmpty ? widget.jid[0].toUpperCase() : '?';
            return CircleAvatar(
              radius: 20,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              backgroundImage: bytes != null ? MemoryImage(bytes) : null,
              child: bytes == null
                  ? Text(initials, style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontWeight: FontWeight.bold, fontSize: 15))
                  : null,
            );
          },
        );
      },
    );
  }
}
