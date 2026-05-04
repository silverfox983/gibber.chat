import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'room_info_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/glassmorphic_container.dart';
import '../widgets/member_tile.dart';
import '../widgets/media_carousel.dart';

import '../services/auth_service.dart';
import '../services/spaces_service.dart';
import '../services/transport_service.dart';
import '../models/space_models.dart';
import '../providers/chat_provider.dart';
import '../widgets/create_space_dialog.dart';
import '../widgets/transport_registration_dialog.dart';
import 'space_settings_screen.dart';
import 'post_detail_screen.dart';
import 'post_thread_screen.dart';
import '../widgets/space_invite_dialog.dart';

// Provides global state for liked items across the session
class SpacesScreenManager {
  static Set<String> likedItems = {};
  static Future<void> loadLikedItems() async {}
}

class SpacesScreen extends StatefulWidget {
  const SpacesScreen({super.key});

  @override
  State<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends State<SpacesScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  SpaceNode? _selectedSpace;
  final List<SpaceNode> _spaceHistory = [];
  
  SpacesService? _spacesService;
  List<SpaceNode> _mySpaces = [];
  List<SpaceNode> _lastSeenJoinedSpaces = [];
  List<SpaceNode> _featuredSpaces = [];
  bool _isLoading = false;
  
  final TextEditingController _searchController = TextEditingController();
  VoidCallback? _refreshSpace;
  int _tabIndex = 0; // 0 = Featured, 1 = My Communities

  String _selectedCategory = 'All';
  final List<String> _categories = ['All', 'Tech', 'News', 'Gaming', 'Art', 'Music', 'Science', 'General'];
  
  String _sortMode = 'Trending';
  final List<String> _sortOptions = ['Trending', 'Newest', 'A-Z'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeSpaces();
    });
  }

  Future<void> _initializeSpaces({bool forceRefresh = false}) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;

    // Always show persisted/joined spaces immediately — no connection needed
    final persisted = auth.joinedSpaces;
    _lastSeenJoinedSpaces = List.from(persisted);

    if (conn == null) {
      if (mounted) {
        setState(() {
          _mySpaces = persisted;
          _isLoading = false;
        });
      }
      return;
    }

    setState(() => _isLoading = true);

    if (_spacesService == null || _spacesService!.connection != conn) {
      _spacesService?.dispose();
      _spacesService = SpacesService(conn);
    }
    if (mounted) {
      setState(() {
        _mySpaces = persisted;
      });
    }

    // Load featured spaces from public hub in background — don't block UI
    _loadFeaturedSpaces(forceRefresh: forceRefresh);
    
    // Sync metadata for local spaces in background
    _syncMySpacesMetadata(forceRefresh: forceRefresh);

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadFeaturedSpaces({bool forceRefresh = false}) async {
    if (_spacesService == null) return;
    try {
      final featured = await _spacesService!.discoverAllSpaces('movim.eu', forceRefresh: forceRefresh);
      if (mounted) setState(() => _featuredSpaces = featured);
    } catch (e) {
      debugPrint('Error loading featured spaces: $e');
    }
  }

  Future<void> _syncMySpacesMetadata({bool forceRefresh = false}) async {
    if (_spacesService == null || _mySpaces.isEmpty) return;
    
    final spacesToSync = List<SpaceNode>.from(_mySpaces);

    for (int i = 0; i < spacesToSync.length; i++) {
      final space = spacesToSync[i];
      try {
        final metadata = await _spacesService!.fetchSpaceMetadata(space.domain, space.node, fallbackName: space.name, forceRefresh: forceRefresh);
        if (metadata != null) {
          // Update incrementally for a smoother UI experience
          if (mounted) {
            setState(() {
              final idx = _mySpaces.indexWhere((s) => s.domain == space.domain && s.node == space.node);
              if (idx != -1) {
                _mySpaces[idx] = metadata;
              }
            });
          }
        }
      } catch (e) {
        debugPrint('Error syncing metadata for ${space.node}: $e');
      }
    }
  }

  Future<void> _refresh() async {
    await _initializeSpaces(forceRefresh: true);
  }

  // === UI ROUTER ===
  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final theme = Theme.of(context);
    final canGoBack = _selectedSpace != null;

    // Check if joined spaces changed (intelligent delta check)
    final auth = Provider.of<AuthService>(context);
    final joined = auth.joinedSpaces;
    bool changed = joined.length != _lastSeenJoinedSpaces.length;
    if (!changed) {
      for (int i = 0; i < joined.length; i++) {
        if (joined[i].domain != _lastSeenJoinedSpaces[i].domain || joined[i].node != _lastSeenJoinedSpaces[i].node) {
          changed = true;
          break;
        }
      }
    }
    
    if (changed && !canGoBack && !_isLoading) {
       WidgetsBinding.instance.addPostFrameCallback((_) => _initializeSpaces());
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: canGoBack
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {
                  setState(() {
                    if (_spaceHistory.isNotEmpty) {
                      _spaceHistory.removeLast();
                      _selectedSpace = _spaceHistory.isEmpty ? null : _spaceHistory.last;
                    } else {
                      _selectedSpace = null;
                    }
                  });
                },
              ),
              title: Text(_selectedSpace?.name ?? 'Space'),
            )
            : AppBar(
                title: Row(
                  children: [
                    Image.asset(
                      'assets/logo.png',
                      height: 24,
                      width: 24,
                    ),
                    const SizedBox(width: 12),
                    const Text('Communities Hub',
                        style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                  ],
                ),
              centerTitle: false,
              elevation: 0,
              backgroundColor: theme.scaffoldBackgroundColor,
              actions: [
                IconButton(
                  icon: const Icon(Icons.add_box_rounded),
                  tooltip: 'Create Community',
                  onPressed: () {
                    final auth = Provider.of<AuthService>(context, listen: false);
                    final conn = auth.activeXmppConnection;
                    if (conn != null) {
                      showDialog(
                        context: context,
                        builder: (context) => CreateSpaceDialog(
                          spacesService: _spacesService ?? SpacesService(conn),
                          domain: conn.fullJid.domain,
                          onSuccess: _refresh,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
      body: _selectedSpace != null
          ? SpaceDetailView(
              space: _selectedSpace!,
              spacesService: _spacesService!,
              onCreated: (refresh) => _refreshSpace = refresh,
              onBack: () {
                setState(() {
                  if (_spaceHistory.isNotEmpty) {
                    _spaceHistory.removeLast();
                    _selectedSpace = _spaceHistory.isEmpty ? null : _spaceHistory.last;
                  } else {
                    _selectedSpace = null;
                  }
                });
              },
            )
          : _buildDashboard(theme),
      floatingActionButton: _selectedSpace != null && _spacesService != null
          ? FloatingActionButton.extended(
              heroTag: null,
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => CreatePostDialog(
                    spacesService: _spacesService!,
                    space: _selectedSpace!,
                    onSuccess: () {
                      _refreshSpace?.call();
                    },
                    authService: auth,
                  ),
                );
              },
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Create Post'),
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
            )
          : null,
    );
  }

  // === DASHBOARD VIEW ===
  Widget _buildDashboard(ThemeData theme) {
    if (_isLoading && _mySpaces.isEmpty && _featuredSpaces.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final auth = Provider.of<AuthService>(context, listen: false);
    final joinedJids = auth.joinedSpaces.map((s) => '${s.domain}|${s.node}').toSet();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        slivers: [
          // Search Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search a domain (e.g., movim.eu)',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
                onSubmitted: (domain) async {
                  final trimmed = domain.trim();
                  if (trimmed.isEmpty || _spacesService == null) return;
                  setState(() { _isLoading = true; _tabIndex = 0; });
                  try {
                    final results = await _spacesService!.discoverAllSpaces(trimmed);
                    if (mounted) setState(() { _featuredSpaces = results; _isLoading = false; });
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isLoading = false);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to search $trimmed')));
                    }
                  }
                },
              ),
            ),
          ),
          
          // Server Presets
          if (_tabIndex == 0) SliverToBoxAdapter(
            child: SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 8, top: 10),
                    child: Text('Explore:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                  ),
                  _buildServerChip('movim.eu'),
                  _buildServerChip('patchwork.chat'),
                  _buildServerChip('jabber.at'),
                  _buildServerChip('yax.im'),
                ],
              ),
            ),
          ),

          // Filters and Sorting
          if (_tabIndex == 0) SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final cat = _categories[index];
                        final selected = cat == _selectedCategory;
                        final theme = Theme.of(context);
                        return ChoiceChip(
                          label: Text(cat, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                          selected: selected,
                          onSelected: (val) => setState(() => _selectedCategory = cat),
                          backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          selectedColor: theme.colorScheme.primaryContainer,
                          labelStyle: TextStyle(color: selected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide.none),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.sort_rounded, size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      ..._sortOptions.map((sort) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => setState(() => _sortMode = sort),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _sortMode == sort ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1) : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(sort, style: TextStyle(
                              fontSize: 12,
                              fontWeight: _sortMode == sort ? FontWeight.bold : FontWeight.normal,
                              color: _sortMode == sort ? Theme.of(context).colorScheme.primary : Colors.grey,
                            )),
                          ),
                        ),
                      )).toList(),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          // Tabs
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _tabIndex = 0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _tabIndex == 0 ? theme.colorScheme.surface : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: _tabIndex == 0 ? [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))] : [],
                          ),
                          alignment: Alignment.center,
                          child: Text('Featured', style: TextStyle(
                            fontWeight: _tabIndex == 0 ? FontWeight.bold : FontWeight.normal,
                            color: _tabIndex == 0 ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                          )),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _tabIndex = 1),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _tabIndex == 1 ? theme.colorScheme.surface : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: _tabIndex == 1 ? [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))] : [],
                          ),
                          alignment: Alignment.center,
                          child: Text('My Spaces', style: TextStyle(
                            fontWeight: _tabIndex == 1 ? FontWeight.bold : FontWeight.normal,
                            color: _tabIndex == 1 ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                          )),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Active Grid
          if (_tabIndex == 0 && _featuredSpaces.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  mainAxisExtent: 340,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    var items = List<SpaceNode>.from(_featuredSpaces);
                    // Apply Category Filter
                    if (_selectedCategory != 'All') {
                      items = items.where((s) => s.description?.toLowerCase().contains(_selectedCategory.toLowerCase()) ?? false).toList();
                    }
                    // Apply Sort
                    if (_sortMode == 'Trending') {
                      items.sort((a, b) => (b.numSubscribers ?? 0).compareTo(a.numSubscribers ?? 0));
                    } else if (_sortMode == 'A-Z') {
                      items.sort((a, b) => a.name.compareTo(b.name));
                    }
                    if (index >= items.length) return const SizedBox.shrink();
                    final space = items[index];
                    final isJoined = joinedJids.contains('${space.domain}|${space.node}');
                    return _buildSpaceGridCard(theme, space, isJoined: isJoined);
                  },
                  childCount: _featuredSpaces.length,
                ),
              ),
            ),
            
          if (_tabIndex == 1 && _mySpaces.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  mainAxisExtent: 340,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final space = _mySpaces[index];
                    return Dismissible(
                      key: ValueKey('${space.domain}|${space.node}'),
                      direction: DismissDirection.startToEnd,
                      background: Container(
                        decoration: BoxDecoration(color: Colors.red.shade400, borderRadius: BorderRadius.circular(24)),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 20),
                        child: const Icon(Icons.exit_to_app_rounded, color: Colors.white, size: 32),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Leave Space?'),
                            content: Text('Are you sure you want to leave ${space.name}?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(c, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Leave')),
                            ],
                          ),
                        );
                      },
                      onDismissed: (direction) async {
                        final auth = Provider.of<AuthService>(context, listen: false);
                        final conn = auth.activeXmppConnection;
                        if (conn != null) {
                          await _spacesService?.unsubscribeFromSpace(space.domain, space.node, conn.fullJid.userAtDomain);
                          await auth.leavePersistedSpace(space.domain, space.node);
                          setState(() { _mySpaces.removeAt(index); });
                        }
                      },
                      child: _buildSpaceGridCard(theme, space, isJoined: true),
                    );
                  },
                  childCount: _mySpaces.length,
                ),
              ),
            ),

          if (_tabIndex == 0 && _featuredSpaces.isEmpty && !_isLoading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.search_off_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                    const SizedBox(height: 16),
                    Text('No featured spaces found.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            
          if (_tabIndex == 1 && _mySpaces.isEmpty && !_isLoading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.workspaces_outline, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                    const SizedBox(height: 16),
                    Text('You haven\'t joined any spaces yet.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),



          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  Widget _buildServerChip(String domain) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(domain, style: const TextStyle(fontSize: 12)),
        onPressed: () async {
          _searchController.text = domain;
          setState(() { _isLoading = true; _tabIndex = 0; });
          try {
            final results = await _spacesService?.discoverAllSpaces(domain) ?? [];
            if (mounted) setState(() { _featuredSpaces = results; _isLoading = false; });
          } catch (_) {
            if (mounted) setState(() => _isLoading = false);
          }
        },
        backgroundColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        side: BorderSide.none,
      ),
    );
  }


  // === VERBOSE UI WIDGETS ===
  // === VERBOSE UI WIDGETS ===

  // ── FEATURED SPACE CARD (horizontal scroll) ─────────────────────────────
  Widget _buildSpaceGridCard(ThemeData theme, SpaceNode space, {bool isJoined = false}) {
    final auth = Provider.of<AuthService>(context, listen: false);
    final isOwner = space.ownerJid == auth.activeXmppConnection?.fullJid.userAtDomain;
    final affiliation = auth.joinedSpaces.where((s) => s.domain == space.domain && s.node == space.node).firstOrNull?.affiliation;
    final isPrivate = space.accessModel == 'authorize';
    final hue = (space.node.hashCode.abs() % 360).toDouble();
    final accent = HSLColor.fromAHSL(1, hue, 0.45, 0.5).toColor();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _navigateTo(space),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header / Cover ──
              Stack(
                children: [
                  SizedBox(
                    height: 100,
                    width: double.infinity,
                    child: space.avatarUrl != null
                        ? Image.network(space.avatarUrl!, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _gradientPlaceholder(accent))
                        : _gradientPlaceholder(accent),
                  ),
                  // Overlay gradient
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
                        ),
                      ),
                    ),
                  ),
                  // Affiliation badge
                  if (isJoined || isOwner)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isOwner ? Colors.amber.shade700 : (affiliation == 'publisher' ? Colors.deepPurpleAccent : theme.colorScheme.primary),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(children: [
                          Icon(isOwner ? Icons.shield_rounded : (affiliation == 'publisher' ? Icons.edit_note_rounded : Icons.check_circle_rounded), size: 10, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(isOwner ? 'OWNER' : (affiliation?.toUpperCase() ?? 'JOINED'), style: GoogleFonts.inter(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900)),
                        ]),
                      ),
                    ),
                  // Feature icons
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Row(
                      children: _buildFeatureIcons(space),
                    ),
                  ),
                  // Domain tag
                  Positioned(
                    bottom: 8,
                    left: 10,
                    child: Text(space.domain.toUpperCase(),
                        style: GoogleFonts.inter(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  ),
                ],
              ),

              // ── Extensive Details ──
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      space.name.isNotEmpty ? space.name : space.node,
                      style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 16, height: 1.2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      space.description ?? 'No description provided.',
                      style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 14),
                    // Stats Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (space.type == 'muc')
                          _buildStatPill(theme, Icons.people_outline_rounded, '${space.numSubscribers ?? '?'}', 'Users')
                        else ...[
                          _buildStatPill(theme, Icons.people_outline_rounded, '${space.numSubscribers ?? 0}', 'Subs'),
                          _buildStatPill(theme, Icons.article_outlined, '${space.postCount ?? 0}', 'Posts'),
                        ],
                        if (space.lastActivity != null)
                          _buildStatPill(theme, Icons.history_rounded, _timeAgo(space.lastActivity!), 'Active')
                        else
                          _buildStatPill(theme, Icons.history_rounded, 'Idle', 'Active'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Access text
                    Row(
                      children: [
                        Icon(isPrivate ? Icons.admin_panel_settings_outlined : Icons.language_rounded, size: 12, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            isPrivate ? 'Approval Required' : 'Open Community',
                            style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (space.publishModel != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            space.publishModel!.toUpperCase(),
                            style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w900, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Sync info
                    Row(
                      children: [
                        Icon(Icons.sync_rounded, size: 10, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                        const SizedBox(width: 4),
                        Text(
                          space.syncedAt != null && _timeAgo(space.syncedAt!) != 'just now'
                              ? 'SYNCED ${_timeAgo(space.syncedAt!).toUpperCase()} AGO'
                              : 'SYNCED JUST NOW',
                          style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatPill(ThemeData theme, IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        const SizedBox(height: 4),
        Text(value, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w900, color: theme.colorScheme.onSurface)),
        Text(label, style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y';
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo';
    if (diff.inDays > 0) return '${diff.inDays}d';
    if (diff.inHours > 0) return '${diff.inHours}h';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return 'now';
  }

  List<Widget> _buildFeatureIcons(SpaceNode space) {
    final List<Widget> icons = [];
    final features = space.features.map((f) => f.toLowerCase()).toList();

    if (features.any((f) => f.contains('microblog'))) {
      icons.add(_featureIcon(Icons.article_rounded));
    }
    if (features.any((f) => f.contains('muc') || f.contains('conference'))) {
      icons.add(_featureIcon(Icons.forum_rounded));
    }
    if (features.any((f) => f.contains('avatar') || f.contains('media'))) {
      icons.add(_featureIcon(Icons.photo_library_rounded));
    }
    if (features.any((f) => f.contains('pubsub'))) {
      icons.add(_featureIcon(Icons.rss_feed_rounded));
    }

    return icons;
  }

  Widget _featureIcon(IconData icon) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(6)),
      child: Icon(icon, size: 10, color: Colors.white70),
    );
  }

  Widget _gradientPlaceholder(Color accent) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent, accent.withValues(alpha: 0.5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.workspaces_rounded, size: 40, color: Colors.white54),
      ),
    );
  }

  void _navigateTo(SpaceNode space) async {
    if (space.type == 'muc') {
      final auth = Provider.of<AuthService>(context, listen: false);
      final conn = auth.activeXmppConnection;
      if (conn != null) {
        Navigator.push(context, MaterialPageRoute(
          builder: (ctx) => RoomInfoScreen(
            room: {
              'jid': '${space.node}@${space.domain}',
              'name': space.name,
              'topic': space.description ?? '',
            },
            accountId: conn.fullJid.userAtDomain,
          ),
        ));
      }
      return;
    }

    setState(() {
      _selectedSpace = space;
      _spaceHistory.add(space);
    });
    if (_spacesService == null) return;
    final details = await _spacesService!.fetchSpaceDetails(space);
    if (mounted && _selectedSpace?.node == space.node) {
      setState(() {
        _selectedSpace = details;
        if (_spaceHistory.isNotEmpty) _spaceHistory.last = details;
      });
    }
  }
}


// ============================================================
// SPACE DETAIL VIEW — tabbed rich detail
// ============================================================
class SpaceDetailView extends StatefulWidget {
  final SpaceNode space;
  final SpacesService spacesService;
  final VoidCallback onBack;
  final Function(VoidCallback refresh)? onCreated;

  const SpaceDetailView({
    super.key,
    required this.space,
    required this.spacesService,
    required this.onBack,
    this.onCreated,
  });

  @override
  State<SpaceDetailView> createState() => _SpaceDetailViewState();
}

class _SpaceDetailViewState extends State<SpaceDetailView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  SpaceNode? _details;
  List<SpaceItem>? _items;
  bool _loadingDetails = true;
  bool _loadingItems = true;

  // Live stream
  StreamSubscription<SpaceItem>? _liveStreamSub;
  int _newLiveCount = 0;

  // Posts search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    if (widget.onCreated != null) {
      widget.onCreated!(() => _reload());
    }
    _load();
    _subscribeToLiveStream();
  }

  void _subscribeToLiveStream() {
    _liveStreamSub = widget.spacesService.liveItemStream.listen((item) {
      // Only surface items for THIS space
      final spaceNode = widget.space.node;
      final itemNode = item.sourceSpace?.node ?? '';
      if (itemNode != spaceNode && !itemNode.startsWith(spaceNode)) return;
      if (!mounted) return;
      setState(() {
        _items = [item, ...(_items ?? [])];
        _newLiveCount++;
      });
    });
  }

  Future<void> _load({bool forceRefresh = false}) async {
    try {
      final d = await widget.spacesService.fetchSpaceDetails(widget.space, forceRefresh: forceRefresh);
      if (mounted) setState(() { _details = d; _loadingDetails = false; });
    } catch (e) {
      debugPrint('SpaceDetailView: fetchSpaceDetails error: \$e');
      if (mounted) setState(() => _loadingDetails = false);
    }
    try {
      final items = await widget.spacesService.fetchSpaceContent(
          widget.space.domain, widget.space.node,
          spaceContext: widget.space, forceRefresh: forceRefresh);
      if (mounted) setState(() { _items = items; _loadingItems = false; });
    } catch (e) {
      debugPrint('SpaceDetailView: fetchSpaceContent error: \$e');
      if (mounted) setState(() { _items = []; _loadingItems = false; });
    }
  }

  Future<void> _reload() async {
    setState(() { _loadingItems = true; _items = null; _newLiveCount = 0; });
    await _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _liveStreamSub?.cancel();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y ago';
    if (diff.inDays > 30)  return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0)   return '${diff.inDays}d ago';
    if (diff.inHours > 0)  return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final space = _details ?? widget.space;
    return Column(
      children: [
        // ── Hero header ──────────────────────────────────────
        _buildHeroHeader(theme, space),
        // ── Tabs ─────────────────────────────────────────────
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.info_outline_rounded), text: 'Info'),
            Tab(icon: Icon(Icons.timeline_rounded), text: 'Activity'),
            Tab(icon: Icon(Icons.group_outlined), text: 'Members'),
            Tab(icon: Icon(Icons.article_outlined), text: 'Posts'),
            Tab(icon: Icon(Icons.photo_library_outlined), text: 'Media'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildInfoTab(theme, space),
              _buildActivityTab(theme),
              _buildMembersTab(theme),
              _buildPostsTab(theme),
              _buildMediaTab(theme),
            ],
          ),
        ),
      ],
    );
  }

  // ── Hero ──────────────────────────────────────────────────
  Widget _buildHeroHeader(ThemeData theme, SpaceNode space) {
    return SizedBox(
      height: 200,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (space.avatarUrl != null)
            Image.network(space.avatarUrl!, fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(color: theme.colorScheme.primary))
          else
            Container(color: theme.colorScheme.primary),
          // gradient
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.78)],
              ),
            ),
          ),
          // text overlay
          Positioned(
            bottom: 16, left: 16, right: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  space.name.isNotEmpty ? space.name : space.node,
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 26,
                      fontWeight: FontWeight.w900, height: 1.15),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                ),
                if (space.description != null && space.description!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(space.description!, maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
                  _badge(
                    space.accessModel == 'authorize' ? Icons.lock_rounded : Icons.public_rounded,
                    space.accessModel == 'authorize' ? 'Private' : 'Public',
                    space.accessModel == 'authorize' ? Colors.redAccent : Colors.green,
                  ),
                  if (space.numSubscribers != null)
                    _badge(Icons.people_alt_rounded, '${space.numSubscribers} subscribers', Colors.blueGrey),
                ]),
              ],
            ),
          ),
          // action buttons
          Positioned(
            top: 8, right: 8,
            child: Column(children: [
              _iconBtn(Icons.settings_rounded, () async {
                final changed = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SpaceSettingsScreen(
                      space: space,
                      spacesService: widget.spacesService,
                    ),
                  ),
                );
                if (changed == 'deleted') {
                  widget.onBack();
                } else if (changed == true) {
                  _reload();
                }
              }, theme),
              const SizedBox(height: 6),
                _iconBtn(Icons.adaptive.share, () {
                final text = '${space.name}\n${space.description ?? ''}\n\n${space.domain}/${space.node}';
                Share.share(text, subject: space.name);
              }, theme),
              const SizedBox(height: 6),
              _iconBtn(Icons.notifications_outlined, () => _showNotificationSheet(space), theme),
            ]),
          ),
          // Subscribe/Joined button in hero
          Positioned(
            bottom: 16,
            right: 8,
            child: _buildHeroSubscribeButton(space),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSubscribeButton(SpaceNode space) {
    final auth = Provider.of<AuthService>(context, listen: false);
    final isJoined = auth.joinedSpaces.any((s) => s.domain == space.domain && s.node == space.node);
    return isJoined
      ? OutlinedButton.icon(
          onPressed: () async {
            final conn = auth.activeXmppConnection;
            if (conn == null) return;
            await widget.spacesService.unsubscribeFromSpace(space.domain, space.node, conn.fullJid.userAtDomain);
            await auth.leavePersistedSpace(space.domain, space.node);
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.check_rounded, size: 16, color: Colors.white70),
          label: const Text('Joined', style: TextStyle(color: Colors.white70, fontSize: 13)),
          style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
        )
      : FilledButton.icon(
          onPressed: () async {
            final conn = auth.activeXmppConnection;
            if (conn == null) return;
            await widget.spacesService.subscribeToSpace(space.domain, space.node, conn.fullJid.userAtDomain);
            await auth.joinPersistedSpace(space.domain, space.node, space.name);
            if (mounted) {
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscribed! Posts will appear in your Feed.')));
            }
          },
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('Subscribe', style: TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
        );
  }

  void _showNotificationSheet(SpaceNode space) {
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
            Text('Notification Preferences', style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 4),
            Text(space.name, style: GoogleFonts.inter(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.notifications_active_rounded),
              title: const Text('All Notifications'),
              subtitle: const Text('Get notified for every new post'),
              trailing: const Icon(Icons.check_rounded),
              onTap: () => Navigator.pop(ctx),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Mentions Only'),
              subtitle: const Text('Only when you are mentioned'),
              onTap: () => Navigator.pop(ctx),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Off'),
              subtitle: const Text('No notifications from this space'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: Colors.white),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.inter(color: Colors.white,
            fontSize: 10, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, ThemeData theme) {
    return Material(
      color: Colors.black45,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(8),
            child: Icon(icon, color: Colors.white, size: 20)),
      ),
    );
  }

  // ── INFO TAB ──────────────────────────────────────────────
  Widget _buildInfoTab(ThemeData theme, SpaceNode space) {
    if (_loadingDetails) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Subscribe button
        _buildSubscribeButton(theme, space),
        const SizedBox(height: 12),
        // Invite button
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => SpaceInviteDialog(
                  spacesService: widget.spacesService,
                  domain: space.domain,
                  node: space.node,
                ),
              );
              if (ok == true) _reload();
            },
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Invite Member'),
          ),
        ),
        const SizedBox(height: 16),
        // Stats row
        _buildStatsRow(theme, space),
        const SizedBox(height: 20),
        // Description card
        if (space.description != null && space.description!.isNotEmpty) ...[
          _sectionLabel(theme, 'ABOUT'),
          const SizedBox(height: 8),
          GlassMorphicContainer(
            child: Text(space.description!,
                style: GoogleFonts.inter(fontSize: 15, height: 1.6)),
          ),
          const SizedBox(height: 20),
        ],
        // Metadata card
        _sectionLabel(theme, 'DETAILS'),
        const SizedBox(height: 8),
        GlassMorphicContainer(
          child: Column(children: [
            _infoRow(theme, Icons.tag_rounded, 'Node', space.node),
            _infoRow(theme, Icons.domain_rounded, 'Domain', space.domain),
            if (space.ownerJid != null)
              _infoRow(theme, Icons.shield_rounded, 'Owner', space.ownerJid!),
            if (space.accessModel != null)
              _infoRow(theme, Icons.security_rounded, 'Access', space.accessModel!),
            if (space.publishModel != null)
              _infoRow(theme, Icons.edit_document, 'Publish model', space.publishModel!),
            if (space.type != null)
              _infoRow(theme, Icons.category_rounded, 'Type', space.type!),
          ]),
        ),
        // Features
        if (space.features.isNotEmpty) ...[
          const SizedBox(height: 20),
          _sectionLabel(theme, 'FEATURES'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8,
            children: space.features.map((f) {
              final short = f.contains('#') ? f.split('#').last : f.split('/').last;
              return Chip(
                label: Text(short,
                    style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
                avatar: const Icon(Icons.check_circle_outline_rounded, size: 14),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              );
            }).toList()),
        ],
        // Danger Zone
        const SizedBox(height: 20),
        _sectionLabel(theme, 'DANGER ZONE'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(16),
            color: Colors.red.withValues(alpha: 0.05),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Delete Space', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 4),
            Text('Permanently delete this space and all contents.', style: GoogleFonts.inter(fontSize: 12, color: Colors.redAccent)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete Space?'),
                    content: const Text('This action cannot be undone. Are you sure?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
                    ],
                  ),
                );
                if (confirm == true) {
                  final ok = await widget.spacesService.deleteSpace(space.domain, space.node);
                  if (mounted && ok) {
                    Provider.of<AuthService>(context, listen: false).leavePersistedSpace(space.domain, space.node);
                    Navigator.pop(context); // close detail view
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Space deleted')));
                  }
                }
              },
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
              child: const Text('Delete Space'),
            ),
          ]),
        ),
        const SizedBox(height: 80),
      ]),
    );
  }

  // ── ACTIVITY TAB ──────────────────────────────────────────
  Widget _buildActivityTab(ThemeData theme) {
    if (_loadingItems) return const Center(child: CircularProgressIndicator());
    final allItems = _items ?? [];
    if (allItems.isEmpty) {
      return Center(child: Text('No activity yet.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)));
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: allItems.length,
      itemBuilder: (context, index) {
        final item = allItems[index];
        final isPost = item.type == 'entry';
        final isChannel = item.type == 'room';
        
        IconData icon = Icons.info_outline;
        Color color = Colors.grey;
        String title = '';
        String subtitle = _timeAgo(item.publishedDate ?? item.updatedDate ?? DateTime.now());

        if (isPost) {
          icon = Icons.article_rounded;
          color = theme.colorScheme.primary;
          title = '${item.author ?? 'Someone'} published a post';
        } else if (isChannel) {
          icon = Icons.tag_rounded;
          color = Colors.green;
          title = 'Channel "${item.name ?? item.id}" created';
        } else {
          title = 'New activity';
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: GoogleFonts.inter(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                    if (isPost && (item.name?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(item.name!, style: GoogleFonts.inter(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    ]
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSubscribeButton(ThemeData theme, SpaceNode space) {
    final auth = Provider.of<AuthService>(context, listen: false);
    final isJoined = auth.joinedSpaces.any((s) => s.domain == space.domain && s.node == space.node);

    return SizedBox(
      width: double.infinity,
      child: isJoined 
        ? OutlinedButton.icon(
            onPressed: () async {
              final conn = auth.activeXmppConnection;
              if (conn != null) {
                await widget.spacesService.unsubscribeFromSpace(
                    space.domain, space.node, conn.fullJid.userAtDomain);
                await auth.leavePersistedSpace(space.domain, space.node);
                setState(() {});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Unsubscribed from space')));
                }
              }
            },
            icon: const Icon(Icons.person_remove_rounded, color: Colors.red),
            label: const Text('Unsubscribe from Space', style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
          )
        : FilledButton.icon(
            onPressed: () async {
              final conn = auth.activeXmppConnection;
              if (conn != null) {
                await widget.spacesService.subscribeToSpace(
                    space.domain, space.node, conn.fullJid.userAtDomain);
                await auth.joinPersistedSpace(space.domain, space.node, space.name);
                setState(() {});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Subscribed to space! Content will now appear in your Feed.')));
                }
              }
            },
            icon: const Icon(Icons.person_add_rounded),
            label: const Text('Subscribe to Space'),
          ),
    );
  }

  Widget _buildStatsRow(ThemeData theme, SpaceNode space) {
    return Row(children: [
      _statBox(theme, Icons.people_alt_rounded,
          space.numSubscribers?.toString() ?? '—', 'Subscribers'),
      const SizedBox(width: 12),
      _statBox(theme, Icons.article_rounded,
          _items == null ? '…' : _items!.where((i) => i.type == 'entry').length.toString(),
          'Posts'),
      const SizedBox(width: 12),
      _statBox(theme, Icons.tag_rounded,
          _items == null ? '…' : _items!.where((i) => i.type == 'room').length.toString(),
          'Channels'),
    ]);
  }

  Widget _statBox(ThemeData theme, IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
        child: Column(children: [
          Icon(icon, color: theme.colorScheme.primary, size: 22),
          const SizedBox(height: 4),
          Text(value, style: GoogleFonts.inter(
              fontWeight: FontWeight.w900, fontSize: 20)),
          Text(label, style: GoogleFonts.inter(
              fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _infoRow(ThemeData theme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Text('$label ', style: GoogleFonts.inter(
            color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
        Expanded(child: Text(value, textAlign: TextAlign.end,
            style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Text(text, style: GoogleFonts.inter(
        fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
        color: theme.colorScheme.primary));
  }

  // ── MEMBERS TAB ───────────────────────────────────────────
  Widget _buildMembersTab(ThemeData theme) {
    return FutureBuilder<List<SpaceMember>>(
      future: widget.spacesService.fetchMembers(
          widget.space.domain, widget.space.node),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final members = snap.data ?? [];
        if (members.isEmpty) {
          return Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.group_off_rounded, size: 56,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('No members found', style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurfaceVariant)),
            ],
          ));
        }
        final owners = members.where((m) => m.affiliation == 'owner').toList();
        final publishers = members.where((m) => m.affiliation == 'publisher').toList();
        final rest = members.where((m) =>
            m.affiliation != 'owner' && m.affiliation != 'publisher').toList();

        return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          if (owners.isNotEmpty) ...[
            _membersHeader(theme, '👑  Owners', owners.length),
            ...owners.map((m) => MemberTile(
                displayName: m.jid, role: 'Owner')),
          ],
          if (publishers.isNotEmpty) ...[
            _membersHeader(theme, '✏️  Publishers', publishers.length),
            ...publishers.map((m) => MemberTile(
                displayName: m.jid, role: 'Publisher')),
          ],
          if (rest.isNotEmpty) ...[
            _membersHeader(theme, '👥  Members', rest.length),
            ...rest.map((m) => MemberTile(
                displayName: m.jid,
                role: m.affiliation.isNotEmpty ? m.affiliation : 'Member')),
          ],
          const SizedBox(height: 80),
        ]);
      },
    );
  }

  Widget _membersHeader(ThemeData theme, String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(children: [
        Text(title, style: GoogleFonts.inter(
            fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('$count', style: GoogleFonts.inter(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer)),
        ),
      ]),
    );
  }

  // ── POSTS TAB ─────────────────────────────────────────────
  Widget _buildPostsTab(ThemeData theme) {
    if (_loadingItems) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: List.generate(4, (_) => _buildPostSkeleton(theme)),
      );
    }
    final allPosts = (_items ?? []).where((i) => i.type == 'entry').toList();
    final channels = (_items ?? []).where((i) => i.type == 'room').toList();

    // Apply search filter
    final posts = _searchQuery.isEmpty
        ? allPosts
        : allPosts.where((p) {
            final q = _searchQuery.toLowerCase();
            return (p.name?.toLowerCase().contains(q) ?? false) ||
                   (p.rawContent?.toLowerCase().contains(q) ?? false) ||
                   (p.description?.toLowerCase().contains(q) ?? false) ||
                   (p.author?.toLowerCase().contains(q) ?? false);
          }).toList();

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        // Live banner
        if (_newLiveCount > 0)
          GestureDetector(
            onTap: () => setState(() => _newLiveCount = 0),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Icon(Icons.fiber_new_rounded, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('$_newLiveCount new post${_newLiveCount > 1 ? 's' : ''} — tap to dismiss',
                    style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13,
                        color: theme.colorScheme.onPrimaryContainer)),
              ]),
            ),
          ),
        // Search bar
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search posts...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); })
                  : null,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        // Channels section
        if (channels.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('CHANNELS', style: GoogleFonts.inter(
                    fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
                    color: theme.colorScheme.primary)),
                TextButton.icon(
                  onPressed: () => _showCreateChannelDialog(),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Create Channel', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                ),
              ],
            ),
          ),
          ...channels.map((ch) => _buildChannelTile(theme, ch)),
          const SizedBox(height: 16),
        ],
        // Posts section
        if (posts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('POSTS', style: GoogleFonts.inter(
                fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
                color: theme.colorScheme.primary)),
          ),
          // Pinned posts first
          ...posts.where((p) => p.isPinned).map((p) => _buildPostCard(theme, p, pinned: true)),
          ...posts.where((p) => !p.isPinned).map((p) => _buildPostCard(theme, p)),
        ],
        if (posts.isEmpty && channels.isEmpty && !_loadingItems)
          Center(child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.article_outlined, size: 56, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text(_searchQuery.isNotEmpty ? 'No posts match "$_searchQuery"' : 'No posts yet',
                  style: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          )),
        const SizedBox(height: 80),
      ]),
    );
  }

  Widget _buildPostSkeleton(ThemeData theme) {
    final base = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 20, backgroundColor: base),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 120, height: 12, color: base),
            const SizedBox(height: 6),
            Container(width: 80, height: 10, color: base),
          ]),
        ]),
        const SizedBox(height: 14),
        Container(width: double.infinity, height: 14, color: base),
        const SizedBox(height: 8),
        Container(width: 200, height: 12, color: base),
        const SizedBox(height: 8),
        Container(width: 150, height: 12, color: base),
      ]),
    );
  }

  Widget _buildChannelTile(ThemeData theme, SpaceItem ch) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5))),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.tag_rounded,
              color: theme.colorScheme.onPrimaryContainer, size: 18),
        ),
        title: Text(ch.name ?? ch.id,
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        subtitle: ch.description != null
            ? Text(ch.description!, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 12))
            : null,
        trailing: FilledButton.tonal(
          onPressed: () {
            final auth = Provider.of<AuthService>(context, listen: false);
            final targetJid = ch.jid ?? ch.id;
            if (auth.activeAccountId != null && targetJid.contains('@')) {
              auth.joinXmppRoom(targetJid,
                  auth.getResolvedNickname(auth.activeAccountId!),
                  accountId: auth.activeAccountId!);
              Provider.of<ChatProvider>(context, listen: false)
                  .setActiveConversation(targetJid);
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Joined ${ch.name ?? targetJid}'))
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invalid channel address'))
              );
            }
          },
          child: const Text('JOIN'),
        ),
      ),
    );
  }

  Widget _buildPostCard(ThemeData theme, SpaceItem item, {bool pinned = false}) {
    final authorInitial = (item.author?.isNotEmpty == true) ? item.author![0].toUpperCase() : '?';
    return GestureDetector(
      onLongPress: () => _showPostContextMenu(item),
      child: Card(
        margin: const EdgeInsets.only(bottom: 16),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: pinned ? theme.colorScheme.primary.withValues(alpha: 0.4) : theme.dividerColor.withValues(alpha: 0.7),
            width: pinned ? 1.5 : 1,
          )),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => PostDetailScreen(post: item, space: widget.space, spacesService: widget.spacesService, allItems: _items ?? []),
            )).then((_) => _reload());
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Pinned badge
            if (pinned)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                child: Row(children: [
                  Icon(Icons.push_pin_rounded, size: 13, color: theme.colorScheme.primary),
                  const SizedBox(width: 5),
                  Text('Pinned Post', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
                ]),
              ),
            // Header
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(authorInitial, style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
              ),
              title: Text(item.author ?? 'Anonymous', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
              subtitle: item.publishedDate != null
                  ? Text(_timeAgo(item.publishedDate!), style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.onSurfaceVariant))
                  : null,
              trailing: IconButton(
                icon: Icon(Icons.more_horiz_rounded, color: theme.colorScheme.onSurfaceVariant),
                onPressed: () => _showPostContextMenu(item),
              ),
            ),
            // Title
            if (item.name?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(item.name!, style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 18, height: 1.25)),
              ),
            // Body
            Builder(builder: (_) {
              String? body = item.rawContent?.trim();
              if (body == null || body.isEmpty) body = item.description?.trim();
              if (body == null || body.isEmpty) return const SizedBox.shrink();
              final isHtml = item.contentType == 'text/html' || item.contentType == 'xhtml' || (body.trimLeft().startsWith('<') && body.contains('</'));
              String display = body;
              if (isHtml) {
                try { display = html2md.convert(body); } catch (_) {
                  display = body.replaceAll(RegExp(r'<[^>]+>'), '').trim();
                }
              }
              final title = item.name?.trim() ?? '';
              if (title.isNotEmpty && display.startsWith(title)) display = display.substring(title.length).trimLeft();
              if (display.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: MarkdownBody(
                  data: display, shrinkWrap: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(fontSize: 15, color: theme.colorScheme.onSurface, height: 1.55),
                    a: TextStyle(color: theme.colorScheme.primary),
                    code: TextStyle(backgroundColor: theme.colorScheme.surfaceContainerHighest, fontFamily: 'monospace', fontSize: 13),
                  ),
                  onTapLink: (text, href, title) {
                    if (href != null) { try { launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication); } catch (_) {} }
                  },
                ),
              );
            }),
            // Images
            if (item.mediaAttachments.isNotEmpty)
              SizedBox(
                height: 220,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: item.mediaAttachments.length,
                  itemBuilder: (_, i) => Container(
                    width: 280, margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      image: DecorationImage(image: NetworkImage(item.mediaAttachments[i].url), fit: BoxFit.cover),
                    ),
                  ),
                ),
              )
            else if (item.imageUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Image.network(item.imageUrl!, height: 220, width: double.infinity, fit: BoxFit.cover),
              ),
            // Reaction bar with emoji buttons + reply + share
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(children: [
                _emojiReactionBtn(theme, '👍', item, item.reactions['👍'] ?? 0),
                _emojiReactionBtn(theme, '❤️', item, item.reactions['❤️'] ?? 0),
                _emojiReactionBtn(theme, '😂', item, item.reactions['😂'] ?? 0),
                _reactionBtn(theme, Icons.chat_bubble_outline_rounded, 'Reply', theme.colorScheme.onSurfaceVariant, onTap: () => _showReplyDialog(item)),
                _reactionBtn(theme, Icons.forum_rounded, 'Thread', theme.colorScheme.onSurfaceVariant, onTap: () {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => PostThreadScreen(post: item, space: widget.space, spacesService: widget.spacesService),
                  )).then((_) => _reload());
                }),
                const Spacer(),
                _reactionBtn(theme, Icons.ios_share_rounded, '', theme.colorScheme.onSurfaceVariant, onTap: () => _handleShare(item)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _emojiReactionBtn(ThemeData theme, String emoji, SpaceItem item, int count) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _handleEmojiReaction(item, emoji),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(emoji, style: const TextStyle(fontSize: 17)),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Text('$count', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  void _handleEmojiReaction(SpaceItem item, String emoji) async {
    setState(() => item.reactions[emoji] = (item.reactions[emoji] ?? 0) + 1);
    final auth = Provider.of<AuthService>(context, listen: false);
    final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
    await widget.spacesService.publishReaction(widget.space.domain, widget.space.node, item.id, emoji, userJid);
  }

  void _showPostContextMenu(SpaceItem item) {
    final auth = Provider.of<AuthService>(context, listen: false);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
        ListTile(
          leading: const Icon(Icons.push_pin_rounded),
          title: const Text('Pin Post'),
          onTap: () async {
            Navigator.pop(ctx);
            final ok = await widget.spacesService.pinItem(widget.space.domain, widget.space.node, item.id);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Post pinned!' : 'Failed to pin post')));
            if (ok) _reload();
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
          title: const Text('Retract Post', style: TextStyle(color: Colors.red)),
          onTap: () async {
            Navigator.pop(ctx);
            final ok = await widget.spacesService.retractItem(widget.space.domain, widget.space.node, item.id);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Post retracted' : 'Failed to retract')));
            if (ok) _reload();
          },
        ),
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('Copy Link'),
          onTap: () {
            Navigator.pop(ctx);
            final link = 'xmpp:${widget.space.domain}?;node=${widget.space.node};item=${item.id}';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied: $link')));
          },
        ),
        ListTile(
          leading: const Icon(Icons.ios_share_rounded),
          title: const Text('Share'),
          onTap: () {
            Navigator.pop(ctx);
            _handleShare(item);
          },
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _reactionBtn(ThemeData theme, IconData icon, String label, Color color, {required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 19, color: color),
          if (label.isNotEmpty && label != '0') ...[
            const SizedBox(width: 5),
            Text(label, style: GoogleFonts.inter(
                color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ]),
      ),
    );
  }

  void _handleLike(SpaceItem item) async {
    setState(() {
      if (item.isLikedByMe) {
        item.isLikedByMe = false;
        item.reactions['👍'] = ((item.reactions['👍'] ?? 1) - 1).clamp(0, 9999);
      } else {
        item.isLikedByMe = true;
        item.reactions['👍'] = (item.reactions['👍'] ?? 0) + 1;
      }
    });
    if (!item.isLikedByMe) return; // optimistic: only send on like, not unlike
    final auth = Provider.of<AuthService>(context, listen: false);
    final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
    await widget.spacesService.publishReaction(widget.space.domain, widget.space.node, item.id, '👍', userJid);
  }

  void _handleShare(SpaceItem item) {
    final text = '${item.name ?? 'Post'} by ${item.author ?? 'Anonymous'}\n\n${item.description ?? ''}';
    Share.share(text, subject: item.name);
  }

  void _showReplyDialog(SpaceItem item) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reply to ${item.author ?? 'Post'}'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Write your reply...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              
              Navigator.pop(context);
              
              // If item has a specific comment node, use it. Otherwise use the source space node.
              final targetDomain = item.commentService ?? widget.space.domain;
              final targetNode = item.commentNode ?? widget.space.node;
              
              final messenger = ScaffoldMessenger.of(context);
              final success = await widget.spacesService.postReply(
                targetDomain,
                targetNode,
                text,
                replyToId: item.id,
              );
              
              if (mounted) {
                messenger.showSnackBar(
                  SnackBar(content: Text(success ? 'Reply posted!' : 'Failed to post reply: The server may require owner permissions for this node.'))
                );
                if (success) _reload();
              }
            },
            child: const Text('Post Reply'),
          ),
        ],
      ),
    );
  }

  // ── MEDIA TAB ─────────────────────────────────────────────
  Widget _buildMediaTab(ThemeData theme) {
    if (_loadingItems) return const Center(child: CircularProgressIndicator());
    final mediaUrls = [
      ...(_items ?? []).expand((i) => i.mediaAttachments.map((m) => m.url)),
      ...(_items ?? []).where((i) => i.imageUrl != null).map((i) => i.imageUrl!),
    ];
    return MediaCarousel(mediaUrls: mediaUrls);
  }

  void _showCreateChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Channel Name', hintText: 'e.g. General'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(dialogContext);
              // Provide a generic fallback domain for MUC if not explicitly known.
              // We'll use conference.domain as a standard default guess.
              final conferenceDomain = 'conference.${widget.space.domain}';
              final channelJid = '${name.toLowerCase().replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}@$conferenceDomain';
              final success = await widget.spacesService.createSpaceChannel(widget.space.domain, widget.space.node, name, channelJid);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Channel created!' : 'Failed to create channel. Check permissions.')));
              if (success) _reload();
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class CreatePostDialog extends StatefulWidget {
  const CreatePostDialog({
    super.key,
    required this.spacesService,
    required this.space,
    required this.onSuccess,
    required this.authService,
  });

  final SpacesService spacesService;
  final SpaceNode space;
  final VoidCallback onSuccess;
  final AuthService authService;

  @override
  State<CreatePostDialog> createState() => _CreatePostDialogState();
}

class _CreatePostDialogState extends State<CreatePostDialog>
    with SingleTickerProviderStateMixin {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _tagsController = TextEditingController();
  bool _isPublishing = false;
  bool _previewMode = false;
  String? _attachedImageUrl;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() => _previewMode = _tabController.index == 1));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null || !mounted) return;
      // For now, store the local path as a placeholder. In production,
      // upload via XEP-0363 HTTP File Upload and replace with the URL.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image selected. HTTP upload (XEP-0363) will attach it on publish.')),
      );
      setState(() => _attachedImageUrl = file.path);
    } catch (e) {
      debugPrint('Image pick error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = _contentController.text;

    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('New Post in ${widget.space.name}',
              style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 16),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_isPublishing)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _handlePublish,
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Publish'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.edit_rounded, size: 18), text: 'Write'),
              Tab(icon: Icon(Icons.preview_rounded, size: 18), text: 'Preview'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            // ── Write Tab ──
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Title
                TextField(
                  controller: _titleController,
                  style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 20),
                  decoration: InputDecoration(
                    hintText: 'Post title (optional)...',
                    hintStyle: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontWeight: FontWeight.w900, fontSize: 20),
                    border: InputBorder.none,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Tags
                TextField(
                  controller: _tagsController,
                  style: GoogleFonts.inter(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Tags (comma separated)...',
                    hintStyle: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.tag_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Body
                TextField(
                  controller: _contentController,
                  maxLines: null,
                  minLines: 10,
                  style: GoogleFonts.inter(fontSize: 16, height: 1.6),
                  decoration: InputDecoration(
                    hintText: "What's on your mind?\n\nMarkdown is supported: **bold**, _italic_, [links](url)",
                    hintStyle: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 15, height: 1.6),
                    border: InputBorder.none,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                // Attached image preview
                if (_attachedImageUrl != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _attachedImageUrl!.startsWith('http')
                          ? Image.network(_attachedImageUrl!, height: 180, width: double.infinity, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(height: 180, color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.image_rounded, size: 40))))
                          : Image.file(File(_attachedImageUrl!), height: 180, width: double.infinity, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(height: 180, color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.image_rounded, size: 40)))),
                    ),
                    Positioned(top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _attachedImageUrl = null),
                        child: Container(padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 16)),
                      )),
                  ]),
              ]),
            ),
            // ── Preview Tab ──
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_titleController.text.isNotEmpty) ...[
                  Text(_titleController.text, style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 24, height: 1.2)),
                  const SizedBox(height: 16),
                ],
                if (content.isEmpty)
                  Text('Nothing to preview yet. Write something in the Write tab.',
                      style: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 15))
                else
                  MarkdownBody(
                    data: content,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(fontSize: 16, color: theme.colorScheme.onSurface, height: 1.6),
                      a: TextStyle(color: theme.colorScheme.primary),
                    ),
                    onTapLink: (text, href, title) {
                      if (href != null) launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
                    },
                  ),
              ]),
            ),
          ],
        ),
        bottomNavigationBar: _previewMode ? null : BottomAppBar(
          child: Row(children: [
            IconButton(
              tooltip: 'Attach Image',
              icon: Icon(Icons.image_rounded, color: _attachedImageUrl != null ? theme.colorScheme.primary : null),
              onPressed: _pickImage,
            ),
            IconButton(
              tooltip: 'Bold',
              icon: const Icon(Icons.format_bold_rounded),
              onPressed: () => _insertMarkdown('**', '**'),
            ),
            IconButton(
              tooltip: 'Italic',
              icon: const Icon(Icons.format_italic_rounded),
              onPressed: () => _insertMarkdown('_', '_'),
            ),
            IconButton(
              tooltip: 'Link',
              icon: const Icon(Icons.link_rounded),
              onPressed: () => _insertMarkdown('[', '](url)'),
            ),
            IconButton(
              tooltip: 'Code',
              icon: const Icon(Icons.code_rounded),
              onPressed: () => _insertMarkdown('`', '`'),
            ),
            const Spacer(),
            Text('${content.length} chars',
                style: GoogleFonts.inter(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }

  void _insertMarkdown(String prefix, String suffix) {
    final ctrl = _contentController;
    final sel = ctrl.selection;
    final text = ctrl.text;
    final selected = sel.isValid ? text.substring(sel.start, sel.end) : '';
    final replacement = '$prefix$selected$suffix';
    final newText = text.replaceRange(sel.isValid ? sel.start : text.length, sel.isValid ? sel.end : text.length, replacement);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: (sel.isValid ? sel.start : text.length) + prefix.length + selected.length),
    );
    setState(() {});
  }

  Future<void> _handlePublish() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post content cannot be empty')));
      return;
    }

    setState(() => _isPublishing = true);

    try {
      String? finalImageUrl = _attachedImageUrl;

      // If we have a local file attached, upload it first via XEP-0363
      if (_attachedImageUrl != null && !_attachedImageUrl!.startsWith('http')) {
        final uploadService = widget.authService.activeUploadService;
        if (uploadService == null) {
          throw Exception('HTTP Upload service not available on this server.');
        }

        final file = File(_attachedImageUrl!);
        final fileName = file.path.split(Platform.pathSeparator).last;
        final size = await file.length();
        final contentType = 'image/${fileName.split('.').last.toLowerCase()}';

        final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
        if (slot == null) {
          throw Exception('Failed to request upload slot from server.');
        }

        final uploadSuccess = await uploadService.uploadFile(slot['put']!, file, contentType);
        if (!uploadSuccess) {
          throw Exception('Failed to upload image to server.');
        }

        finalImageUrl = slot['get'];
      }

      final tags = _tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

      final success = await widget.spacesService.publishMicroblogEntry(
        widget.space.domain,
        widget.space.node,
        content: content,
        title: _titleController.text.trim(),
        imageUrl: finalImageUrl,
        categories: tags.isNotEmpty ? tags : null,
      );

      if (mounted) {
        setState(() => _isPublishing = false);
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post published!')));
          Navigator.pop(context);
          widget.onSuccess();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to publish. Check permissions.')));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPublishing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}