import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:html2md/html2md.dart' as html2md;

import 'package:share_plus/share_plus.dart';
import '../core/design_tokens.dart';
import '../widgets/glassmorphic_container.dart';
import '../widgets/media_carousel.dart';

import '../services/auth_service.dart';
import '../services/spaces_service.dart';

import '../models/space_models.dart';
import '../models/unified_community.dart';
import '../providers/chat_provider.dart';
import '../widgets/create_space_dialog.dart';
import '../widgets/join_space_dialog.dart';
import '../widgets/space_invite_dialog.dart';
import '../widgets/common/empty_state.dart';

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

enum _SpacesTab { explore, myCommunities, rooms }

class _SpacesScreenState extends State<SpacesScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  SpaceNode? _selectedSpace;
  final List<SpaceNode> _spaceHistory = [];

  // ── Explore ──
  final List<UnifiedCommunity> _exploreResults = [];
  bool _exploreLoading = false;
  String _exploreQuery = '';
  final _exploreSearchController = TextEditingController();
  String _exploreSort = 'Popular'; // Popular / Newest / A-Z
  List<String> _exploreSources = ['movim.eu', 'patchwork.chat', 'yax.im', 'jabber.at', 'movim.in'];
  final Map<String, bool> _exploreDomainLoading = {};
  final Map<String, String?> _exploreDomainErrors = {};

  // ── My Communities ──
  List<UnifiedCommunity> _myCommunities = [];
  final _mySearchController = TextEditingController();
  String _mySearchQuery = '';

  // ── Rooms ──
  List<UnifiedCommunity> _rooms = [];
  bool _roomsLoading = false;
  String _selectedMucService = 'conference.movim.eu';
  final _mucServices = [
    'conference.movim.eu',
    'conference.patchwork.chat',
    'conference.yax.im',
    'conference.jabber.at',
    'chat.jabber.at',
  ];
  final _roomsSearchController = TextEditingController();
  String _roomsSearchQuery = '';

  Set<String> get _joinedKeys => _myCommunities.map((c) => c.id).toSet();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _exploreSearchController.dispose();
    _mySearchController.dispose();
    _roomsSearchController.dispose();
    super.dispose();
  }

  SpacesService? get _spacesService {
    final auth = Provider.of<AuthService>(context, listen: false);
    return auth.spacesService;
  }

  Future<void> _init() async {
    await _loadMyCommunities();
    _addOwnServerToExploreSources();
    _loadExplore();
    _loadRooms();
  }

  void _addOwnServerToExploreSources() {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn != null) {
      final userDomain = conn.fullJid.domain;
      final pubsubDomain = 'pubsub.$userDomain';
      if (!_exploreSources.contains(pubsubDomain) && !_exploreSources.contains(userDomain)) {
        _exploreSources.insert(0, pubsubDomain);
      }
    }
  }

  Future<void> _loadMyCommunities() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final persisted = auth.joinedSpaces;
    final mucRooms = auth.joinedRooms;

    final communities = <UnifiedCommunity>[];

    // Refresh subscribed spaces metadata from server
    for (final space in persisted) {
      if (_spacesService != null) {
        try {
          final enriched = await _spacesService!.fetchSpaceMetadata(
            space.domain,
            space.node,
            fallbackName: space.name,
          ).timeout(const Duration(seconds: 10), onTimeout: () => space);
          communities.add(UnifiedCommunity.fromSpaceNode(enriched ?? space, isJoined: true));
        } catch (_) {
          communities.add(UnifiedCommunity.fromSpaceNode(space, isJoined: true));
        }
      } else {
        communities.add(UnifiedCommunity.fromSpaceNode(space, isJoined: true));
      }
    }
    for (final room in mucRooms) {
      final jid = room.id;
      if (jid.contains('@')) {
        communities.add(UnifiedCommunity(
          id: jid,
          name: room.name,
          description: room.topic,
          memberCount: room.participants.length,
          isJoined: true,
          type: CommunityType.room,
          domain: jid.contains('@') ? jid.split('@').last : jid,
          jid: jid,
          isPublic: true,
          features: [],
        ));
      }
    }

    communities.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (mounted) {
      setState(() => _myCommunities = communities);
    }
  }

  Future<void> _loadExploreDomain(String domain) async {
    if (_spacesService == null) return;
    setState(() {
      _exploreDomainLoading[domain] = true;
      _exploreDomainErrors[domain] = null;
    });
    try {
      final spaces = await _spacesService!.discoverAllSpaces(domain).timeout(
        const Duration(seconds: 30),
        onTimeout: () => <SpaceNode>[],
      );
      final enriched = <SpaceNode>[];
      for (final s in spaces.take(20)) {
        try {
          final meta = await _spacesService!.fetchSpaceMetadata(s.domain, s.node, fallbackName: s.name).timeout(
            const Duration(seconds: 10),
            onTimeout: () => s,
          );
          if (meta != null) enriched.add(meta);
        } catch (_) {
          enriched.add(s);
        }
      }
      for (final s in enriched) {
        final key = '${s.domain}|${s.node}';
        if (!_exploreResults.any((c) => c.id == key)) {
          setState(() {
            _exploreResults.add(UnifiedCommunity.fromSpaceNode(s));
          });
        }
      }
      if (mounted) {
        setState(() {
          _exploreDomainLoading[domain] = false;
          _exploreDomainErrors[domain] = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _exploreDomainLoading[domain] = false;
          _exploreDomainErrors[domain] = 'Failed to load';
        });
      }
    }
  }

  Future<void> _loadExplore() async {
    if (_spacesService == null) {
      if (mounted) setState(() => _exploreLoading = false);
      return;
    }
    setState(() => _exploreLoading = true);

    final allCommunities = <UnifiedCommunity>[];
    final seen = <String>{};
    final loadingMap = <String, bool>{};

    // Mark all domains as loading
    for (final d in _exploreSources) loadingMap[d] = true;
    if (mounted) setState(() { _exploreDomainLoading.clear(); _exploreDomainLoading.addAll(loadingMap); });

    // Load domains in parallel batches of 3
    for (var i = 0; i < _exploreSources.length; i += 3) {
      final batch = _exploreSources.skip(i).take(3).toList();
      await Future.wait(batch.map((domain) async {
        try {
          final spaces = await _spacesService!.discoverAllSpaces(domain).timeout(
            const Duration(seconds: 30),
            onTimeout: () => <SpaceNode>[],
          );

          final enriched = <SpaceNode>[];
          for (final s in spaces.take(20)) {
            try {
              final meta = await _spacesService!.fetchSpaceMetadata(s.domain, s.node, fallbackName: s.name).timeout(
                const Duration(seconds: 10),
                onTimeout: () => s,
              );
              if (meta != null) enriched.add(meta);
            } catch (_) {
              enriched.add(s);
            }
          }

          final batchResults = <UnifiedCommunity>[];
          for (final s in enriched) {
            final key = '${s.domain}|${s.node}';
            if (!seen.contains(key)) {
              seen.add(key);
              batchResults.add(UnifiedCommunity.fromSpaceNode(s));
            }
          }

          if (mounted) {
            allCommunities.addAll(batchResults);
            allCommunities.sort((a, b) => b.memberCount.compareTo(a.memberCount));
            setState(() {
              _exploreDomainLoading[domain] = false;
              _exploreDomainErrors[domain] = null;
              _exploreResults.clear();
              _exploreResults.addAll(allCommunities);
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _exploreDomainLoading[domain] = false;
              _exploreDomainErrors[domain] = 'Failed to load';
            });
          }
        }
      }));
    }

    if (mounted) setState(() => _exploreLoading = false);
  }

  Future<void> _loadRooms() async {
    if (_spacesService == null) {
      if (mounted) setState(() => _roomsLoading = false);
      return;
    }
    setState(() => _roomsLoading = true);

    try {
      final mucSpaces = await _spacesService!.discoverMucRoomsAsSpaces(_selectedMucService);

      final rooms = <UnifiedCommunity>[];
      for (int i = 0; i < mucSpaces.length; i += 5) {
        final batch = mucSpaces.skip(i).take(5);
        final details = await Future.wait(
          batch.map((s) async {
            try {
              return await _spacesService!.fetchSpaceDetails(s);
            } catch (_) {
              return s;
            }
          }),
        );
        rooms.addAll(details.map((s) => UnifiedCommunity.fromSpaceNode(s)));
      }

      rooms.sort((a, b) => b.memberCount.compareTo(a.memberCount));

      if (mounted) {
        setState(() {
          _rooms = rooms;
          _roomsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _roomsLoading = false);
    }
  }

  Future<void> _refresh() async {
    await _loadMyCommunities();
    _loadExplore();
    _loadRooms();
  }

  // ─── Tab builder delegates ─────────────────────────────────────────────

  Widget _buildExplore() => _buildUnifiedList(
        items: _filteredExplore(),
        loading: _exploreLoading,
        emptyIcon: Icons.explore_outlined,
        emptyTitle: 'No communities found',
        emptySubtitle: 'Try a different search or check your connection.',
        onRefresh: () async { _loadExplore(); },
        searchHint: 'Search communities...',
        searchController: _exploreSearchController,
        onSearchChanged: (v) => setState(() => _exploreQuery = v),
        onSearchSubmit: (v) async {
          if (v.trim().isEmpty) { _loadExplore(); return; }
          if (_spacesService == null) return;
          setState(() => _exploreLoading = true);
          try {
            final query = v.trim();
            final isDomain = query.contains('.');

            if (isDomain) {
              // Treat as a domain to discover spaces from
              final results = await _spacesService!.discoverAllSpaces(query);
              final enriched = await Future.wait(
                results.take(30).map((s) async {
                  try {
                    return await _spacesService!.fetchSpaceDetails(s);
                  } catch (_) { return s; }
                }),
              );
              final communities = enriched.map((s) => UnifiedCommunity.fromSpaceNode(s)).toList();
              if (mounted) {
                setState(() {
                  _exploreResults.clear();
                  _exploreResults.addAll(communities);
                  _exploreLoading = false;
                });
              }
            } else {
              // Keyword search across known spaces using searchPosts
              final searchResults = <UnifiedCommunity>[];
              final searchTargets = _exploreSources.where((d) => d.contains('.')).toList();
              for (final domain in searchTargets.take(5)) {
                try {
                  final items = await _spacesService!.searchPosts(domain, '', query);
                  for (final item in items) {
                    if (item.sourceSpace != null) {
                      searchResults.add(UnifiedCommunity.fromSpaceNode(item.sourceSpace!));
                    }
                  }
                } catch (_) {}
              }
              if (mounted) {
                setState(() {
                  _exploreResults.clear();
                  _exploreResults.addAll(searchResults);
                  _exploreLoading = false;
                });
              }
            }
          } catch (_) {
            if (mounted) setState(() => _exploreLoading = false);
          }
        },
        sortValue: _exploreSort,
        sortOptions: const ['Popular', 'Newest', 'A-Z'],
        onSortChanged: (v) => setState(() => _exploreSort = v),
        domainChips: _exploreSources,
        onDomainChip: (domain) {
          _exploreSearchController.text = domain;
          setState(() => _exploreQuery = domain);
        },
        domainLoading: _exploreDomainLoading,
        domainErrors: _exploreDomainErrors,
        onRetryDomain: (domain) async {
          await _loadExploreDomain(domain);
        },
      );

  Widget _buildMyCommunities() {
    final items = _filteredMy();
    return _buildUnifiedList(
      items: items,
      loading: false,
      emptyIcon: Icons.workspaces_outline,
      emptyTitle: _mySearchQuery.isNotEmpty
          ? 'No communities match "$_mySearchQuery"'
          : "You haven't joined any communities yet.",
      emptySubtitle: _mySearchQuery.isEmpty
          ? 'Explore communities and join ones you like.'
          : null,
      onRefresh: () async { await _loadMyCommunities(); },
      searchHint: 'Filter my communities...',
      searchController: _mySearchController,
      onSearchChanged: (v) => setState(() => _mySearchQuery = v),
      onSearchSubmit: null,
      showEmptyAsCenter: true,
      extraEmptyAction: _mySearchQuery.isEmpty
          ? () => DefaultTabController.of(context).animateTo(0)
          : null,
      extraEmptyActionLabel: _mySearchQuery.isEmpty ? 'Explore Communities' : null,
    );
  }

  Widget _buildRooms() => _buildUnifiedList(
        items: _filteredRooms(),
        loading: _roomsLoading,
        emptyIcon: Icons.forum_outlined,
        emptyTitle: 'No rooms found',
        emptySubtitle: 'Try a different service or search.',
        onRefresh: () async { _loadRooms(); },
        searchHint: 'Filter rooms...',
        searchController: _roomsSearchController,
        onSearchChanged: (v) => setState(() => _roomsSearchQuery = v),
        onSearchSubmit: null,
        domainChips: _mucServices,
        onDomainChip: (svc) {
          setState(() => _selectedMucService = svc);
          _loadRooms();
        },
        selectedDomainChip: _selectedMucService,
      );

  // ─── Unified list renderer ─────────────────────────────────────────────

  Widget _buildUnifiedList({
    required List<UnifiedCommunity> items,
    required bool loading,
    required IconData emptyIcon,
    required String emptyTitle,
    String? emptySubtitle,
    required Future<void> Function() onRefresh,
    required String searchHint,
    required TextEditingController searchController,
    required void Function(String) onSearchChanged,
    void Function(String)? onSearchSubmit,
    String? sortValue,
    List<String>? sortOptions,
    void Function(String)? onSortChanged,
    List<String>? domainChips,
    void Function(String)? onDomainChip,
    String? selectedDomainChip,
    bool showEmptyAsCenter = false,
    VoidCallback? extraEmptyAction,
    String? extraEmptyActionLabel,
    Map<String, bool>? domainLoading,
    Map<String, String?>? domainErrors,
    Future<void> Function(String)? onRetryDomain,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final isWide = constraints.maxWidth > 500;
        final cardW = isWide ? 340.0 : 300.0;
        final coverH = isWide ? 150.0 : 110.0;
        final horiz = isWide ? 24.0 : 16.0;

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: CustomScrollView(
            slivers: [
              // ── Search ──
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(horiz, 16, horiz, 8),
                  child: TextField(
                    controller: searchController,
                    decoration: InputDecoration(
                      hintText: searchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: loading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : (searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded),
                                  onPressed: () {
                                    searchController.clear();
                                    onSearchChanged('');
                                  },
                                )
                              : null),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: onSearchChanged,
                    onSubmitted: onSearchSubmit,
                  ),
                ),
              ),

              // ── Domain chips ──
              if (domainChips != null && domainChips.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 44,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: horiz),
                      itemCount: domainChips.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final chip = domainChips[i];
                        final selected = chip == selectedDomainChip;
                        return Padding(
                          padding: const EdgeInsets.only(right: 0),
                          child: FilterChip(
                            label: Text(chip, style: const TextStyle(fontSize: 12)),
                            selected: selected,
                            onSelected: (_) => onDomainChip?.call(chip),
                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                            selectedColor: Theme.of(context).colorScheme.primaryContainer,
                            side: BorderSide.none,
                            showCheckmark: false,
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // ── Domain error banners (per-domain retry) ──
              if (domainErrors != null)
                SliverToBoxAdapter(
                  child: Column(
                    children: domainErrors.entries
                        .where((e) => e.value != null && e.key != selectedDomainChip)
                        .map((e) => Container(
                              margin: EdgeInsets.fromLTRB(horiz, 8, horiz, 0),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${e.key}: ${e.value}',
                                      style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                                    ),
                                  ),
                                  if (onRetryDomain != null)
                                    TextButton(
                                      onPressed: () => onRetryDomain(e.key),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text('Retry', style: TextStyle(fontSize: 12)),
                                    ),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ),

              // ── Skeleton loading cards ──
              if (loading && items.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horiz, vertical: 12),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: cardW,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: cardW * 0.72,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _buildSkeletonCard(theme, cardW * 0.72),
                      childCount: 6,
                    ),
                  ),
                ),

              // ── Sort row ──
              if (sortOptions != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(horiz, 12, horiz, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.sort_rounded, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        ...sortOptions.map((opt) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: InkWell(
                                onTap: () => onSortChanged?.call(opt),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: opt == sortValue
                                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    opt,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: opt == sortValue ? FontWeight.bold : FontWeight.normal,
                                      color: opt == sortValue
                                          ? Theme.of(context).colorScheme.primary
                                          : Colors.grey,
                                    ),
                                  ),
                                ),
                              ),
                            )),
                      ],
                    ),
                  ),
                ),

              // ── Results ──
              if (items.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horiz, vertical: 12),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: cardW,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: cardW * 0.72,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _buildUnifiedCommunityCard(
                        items[i],
                        coverHeight: coverH,
                        isJoined: _joinedKeys.contains(items[i].id),
                      ),
                      childCount: items.length,
                    ),
                  ),
                ),

              // ── Empty state ──
              if (items.isEmpty && !loading)
                if (showEmptyAsCenter)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(
                      emptyIcon, emptyTitle, emptySubtitle,
                      extraEmptyAction: extraEmptyAction,
                      extraEmptyActionLabel: extraEmptyActionLabel,
                    ),
                  )
                else
                  SliverToBoxAdapter(
                    child: _buildEmptyState(
                      emptyIcon, emptyTitle, emptySubtitle,
                      extraEmptyAction: extraEmptyAction,
                      extraEmptyActionLabel: extraEmptyActionLabel,
                    ),
                  ),

              SliverToBoxAdapter(child: SizedBox(height: isWide ? 80 : 120)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(
    IconData icon, String title, String? subtitle, {
    VoidCallback? extraEmptyAction,
    String? extraEmptyActionLabel,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          if (extraEmptyAction != null && extraEmptyActionLabel != null) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: extraEmptyAction,
              icon: const Icon(Icons.explore_rounded, size: 18),
              label: Text(extraEmptyActionLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSkeletonCard(ThemeData theme, double cardH) {
    return Container(
      height: cardH,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 10,
                    width: 100,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Inline card subscribe button ──────────────────────────────────────

  Future<void> _handleFollow(UnifiedCommunity c) async {
    if (_spacesService == null) return;
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) return;

    final success = await _spacesService!.subscribeToSpace(
      c.domain, c.node ?? c.id.split('|').last,
      conn.fullJid.userAtDomain,
      spaceType: c.type.name,
    );
    if (!success) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to follow. Please try again.')),
      );
      return;
    }
    await auth.joinPersistedSpace(c.domain, c.node ?? c.id.split('|').last, c.name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Following "${c.name}"!')),
      );
      await _loadMyCommunities();
    }
  }

  Future<void> _handleUnfollow(UnifiedCommunity c) async {
    if (_spacesService == null) return;
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) return;

    await _spacesService!.unsubscribeFromSpace(
      c.domain, c.node ?? c.id.split('|').last,
      conn.fullJid.userAtDomain,
      spaceType: c.type.name,
    );
    await auth.leavePersistedSpace(c.domain, c.node ?? c.id.split('|').last);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unfollowed "${c.name}"')),
      );
      await _loadMyCommunities();
    }
  }

  // ─── Unified card ───────────────────────────────────────────────────────

  Widget cardSubscribeButton({
    required UnifiedCommunity community,
    required VoidCallback onChanged,
  }) {
    final auth = Provider.of<AuthService>(context, listen: false);
    final isJoined = auth.joinedSpaces.any(
      (s) => s.domain == community.domain && (s.node == community.node || s.node == community.id.split('|').last),
    );

    if (isJoined) {
      return GestureDetector(
        onTap: onChanged,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, size: 12, color: Colors.white),
              SizedBox(width: 4),
              Text('Following', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onChanged,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 12, color: Colors.black87),
            SizedBox(width: 4),
            Text('Follow', style: TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildUnifiedCommunityCard(UnifiedCommunity c, {double coverHeight = 130, bool isJoined = false}) {
    final theme = Theme.of(context);
    final hue = (c.id.hashCode.abs() % 360).toDouble();
    final accent = HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor();

    final typeIcon = switch (c.type) {
      CommunityType.space => Icons.workspaces_rounded,
      CommunityType.room => Icons.forum_rounded,
      CommunityType.microblog => Icons.article_rounded,
    };

    final typeLabel = switch (c.type) {
      CommunityType.space => 'SPACE',
      CommunityType.room => 'ROOM',
      CommunityType.microblog => 'BLOG',
    };

    return Hero(
      tag: 'space-card-${c.domain}|${c.node}',
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openCommunity(c),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cover with overlay
                Stack(
                  children: [
                    SizedBox(
                      height: coverHeight,
                      width: double.infinity,
                      child: c.avatarUrl != null
                          ? Image.network(c.avatarUrl!, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _gradientPlaceholder(accent))
                          : _gradientPlaceholder(accent),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                          ),
                        ),
                      ),
                    ),
                    // Type badge (top-left)
                    Positioned(
                      top: 10, left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
                        ),
                        child: Row(children: [
                          Icon(typeIcon, size: 10, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(typeLabel, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900)),
                        ]),
                      ),
                    ),
                    // Subscribe/Joined button (top-right)
                    Positioned(
                      top: 8, right: 8,
                      child: cardSubscribeButton(
                        community: c,
                        onChanged: () {
                          if (isJoined) {
                            _handleUnfollow(c);
                          } else {
                            _handleFollow(c);
                          }
                        },
                      ),
                    ),
                    // Member count (bottom-left)
                    Positioned(
                      bottom: 8, left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          const Icon(Icons.people_outline_rounded, size: 10, color: Colors.white70),
                          const SizedBox(width: 4),
                          Text(
                            c.memberCount > 0 ? _formatCount(c.memberCount) : '?',
                            style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ]),
                      ),
                    ),
                    // Domain (bottom-center)
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            c.domain.toUpperCase(),
                            style: const TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Details
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name,
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, height: 1.2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 5),
                        if (c.description != null && c.description!.isNotEmpty)
                          Expanded(
                            child: Text(
                              c.description!,
                              style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          )
                        else
                          const Spacer(),
                        Row(
                          children: [
                            Icon(
                              c.isPublic ? Icons.public_rounded : Icons.lock_outline_rounded,
                              size: 11,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                c.isPublic ? 'Open Community' : 'Private',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _gradientPlaceholder(Color accent) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent, accent.withValues(alpha: 0.45)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.workspaces_rounded, size: 40, color: Colors.white54),
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  // ─── Filtering ──────────────────────────────────────────────────────────

  List<UnifiedCommunity> _filteredExplore() {
    var items = List<UnifiedCommunity>.from(_exploreResults);
    if (_exploreQuery.isNotEmpty) {
      final q = _exploreQuery.toLowerCase();
      items = items.where((c) =>
        c.name.toLowerCase().contains(q) ||
        (c.description?.toLowerCase().contains(q) ?? false) ||
        c.domain.toLowerCase().contains(q)
      ).toList();
    }
    if (_exploreSort == 'Popular') {
      items.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    } else if (_exploreSort == 'Newest') {
      items.sort((a, b) {
        final aTime = a.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    } else if (_exploreSort == 'A-Z') {
      items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return items;
  }

  List<UnifiedCommunity> _filteredMy() {
    if (_mySearchQuery.isEmpty) return _myCommunities;
    final q = _mySearchQuery.toLowerCase();
    return _myCommunities.where((c) =>
      c.name.toLowerCase().contains(q) ||
      (c.description?.toLowerCase().contains(q) ?? false) ||
      c.domain.toLowerCase().contains(q)
    ).toList();
  }

  List<UnifiedCommunity> _filteredRooms() {
    if (_roomsSearchQuery.isEmpty) return _rooms;
    final q = _roomsSearchQuery.toLowerCase();
    return _rooms.where((c) =>
      c.name.toLowerCase().contains(q) ||
      (c.description?.toLowerCase().contains(q) ?? false)
    ).toList();
  }

  // ─── Navigation ────────────────────────────────────────────────────────

  void _openCommunity(UnifiedCommunity c) {
    if (c.type == CommunityType.room) {
      final auth = Provider.of<AuthService>(context, listen: false);
      final conn = auth.activeXmppConnection;
      if (conn != null && c.jid != null) {
        context.goNamed('roomInfo', extra: {
          'room': {'jid': c.jid, 'name': c.name, 'topic': c.description ?? ''},
          'accountId': conn.fullJid.userAtDomain,
        });
      }
      return;
    }

    if (c.node == null || c.domain.isEmpty) return;

    final spaceNode = SpaceNode(
      domain: c.domain,
      node: c.node!,
      name: c.name,
      description: c.description,
      avatarUrl: c.avatarUrl,
      coverUrl: c.coverUrl,
      features: c.features,
      accessModel: c.isPublic ? 'open' : 'authorize',
      type: 'leaf',
    );

    setState(() {
      _selectedSpace = spaceNode;
      _spaceHistory.add(spaceNode);
    });

    if (_spacesService == null) return;
    _spacesService!.fetchSpaceDetails(spaceNode).then((details) {
      if (mounted && _selectedSpace?.node == spaceNode.node) {
        setState(() {
          _selectedSpace = details;
          if (_spaceHistory.isNotEmpty) _spaceHistory.last = details;
        });
      }
    });
  }

  // ─── UI ROUTER ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final canGoBack = _selectedSpace != null;

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
              title: Text(_selectedSpace?.name ?? 'Community'),
            )
          : AppBar(
              title: Row(
                children: [
                  Image.asset('assets/logo.png', height: 24, width: 24),
                  const SizedBox(width: 12),
                  const Text(
                    'Communities Hub',
                    style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5),
                  ),
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
                      final svc = auth.spacesService;
                      showDialog(
                        context: context,
                        builder: (context) => CreateSpaceDialog(
                          spacesService: svc ?? SpacesService(conn),
                          domain: conn.fullJid.domain,
                          onSuccess: _refresh,
                        ),
                      );
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.login_rounded),
                  tooltip: 'Join Space',
                  onPressed: () {
                    final auth = Provider.of<AuthService>(context, listen: false);
                    final conn = auth.activeXmppConnection;
                    if (conn != null) {
                      final svc = auth.spacesService;
                      showDialog(
                        context: context,
                        builder: (context) => JoinSpaceDialog(
                          spacesService: svc ?? SpacesService(conn),
                          currentUserDomain: conn.fullJid.domain,
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
              onCreated: _refresh,
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
          : _buildBody(theme),
      floatingActionButton: _selectedSpace != null && _spacesService != null
          ? FloatingActionButton.extended(
              heroTag: null,
              onPressed: () {
                final auth = Provider.of<AuthService>(context, listen: false);
                showDialog(
                  context: context,
                  builder: (context) => CreatePostDialog(
                    spacesService: _spacesService!,
                    space: _selectedSpace!,
                    onSuccess: () {},
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

  _SpacesTab _currentTab = _SpacesTab.explore;

  Widget _buildBody(ThemeData theme) {
    return Column(
      children: [
        // ── 3-tab segmented control ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(child: _tabButton(theme, _SpacesTab.explore, Icons.explore_rounded, 'Explore')),
                Expanded(child: _tabButton(theme, _SpacesTab.myCommunities, Icons.groups_rounded, 'My Communities')),
                Expanded(child: _tabButton(theme, _SpacesTab.rooms, Icons.forum_rounded, 'Rooms')),
              ],
            ),
          ),
        ),
        // ── Tab content ──
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: switch (_currentTab) {
              _SpacesTab.explore => _buildExplore(),
              _SpacesTab.myCommunities => _buildMyCommunities(),
              _SpacesTab.rooms => _buildRooms(),
            },
          ),
        ),
      ],
    );
  }

  Widget _tabButton(ThemeData theme, _SpacesTab tab, IconData icon, String label) {
    final selected = _currentTab == tab;
    return GestureDetector(
      onTap: () => setState(() => _currentTab = tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 2))]
              : [],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// ============================================================
// SPACE DETAIL VIEW — tabbed rich detail
// ============================================================
class SpaceDetailView extends StatefulWidget {
  final SpaceNode space;
  final SpacesService spacesService;
  final VoidCallback onBack;
  final VoidCallback? onCreated;

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

  // Per-item UI state — stored here so SpaceItem stays immutable
  final Map<String, Map<String, int>> _itemReactions = {};
  final Set<String> _expandedItems = {}; // tracks read-more expanded state

  // Posts search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Future<List<SpaceMember>>? _membersFuture;
  final TextEditingController _membersSearchController = TextEditingController();
  String _membersSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    if (widget.onCreated != null) {
      widget.onCreated!();
    }
    _load();
    _membersFuture = widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
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
    // Fire both requests independently so the header renders ASAP
    widget.spacesService.fetchSpaceDetails(widget.space, forceRefresh: forceRefresh)
        .then((details) {
          if (mounted) setState(() { _details = details; _loadingDetails = false; });
        })
        .catchError((e) { 
          debugPrint('fetchSpaceDetails error: $e'); 
          if (mounted) setState(() { _loadingDetails = false; }); 
        });

    widget.spacesService.fetchSpaceContent(
        widget.space.domain, widget.space.node,
        spaceContext: widget.space, forceRefresh: forceRefresh)
        .then((items) {
          if (mounted) setState(() { _items = items; _loadingItems = false; });
        })
        .catchError((e) { 
          debugPrint('fetchSpaceContent error: $e'); 
          if (mounted) setState(() { _loadingItems = false; _items = []; }); 
        });
  }

  Future<void> _reload() async {
    setState(() { _loadingItems = true; _items = null; _newLiveCount = 0; });
    await _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _liveStreamSub?.cancel();
    _searchController.dispose();
    _membersSearchController.dispose();
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
            Tab(icon: Icon(Icons.forum_rounded), text: 'Rooms'),
            Tab(icon: Icon(Icons.article_outlined), text: 'Posts'),
            Tab(icon: Icon(Icons.photo_library_outlined), text: 'Media'),
            Tab(icon: Icon(Icons.person_search_rounded), text: 'People'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildInfoTab(theme, space),
              _buildActivityTab(theme),
              _buildMembersTab(theme),
              _buildRoomsTab(theme),
              _buildPostsTab(theme),
              _buildMediaTab(theme),
              _buildPeopleTab(theme),
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
                  style: TextStyle(color: Colors.white, fontSize: 26,
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
                    space.isPublic ? Icons.public_rounded : Icons.lock_rounded,
                    space.isPublic ? 'Public' : 'Private',
                    space.isPublic ? Colors.green : Colors.redAccent,
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
                final changed = await context.pushNamed('spaceSettings', extra: {'space': space, 'spacesService': widget.spacesService});
                if (changed == 'deleted') {
                  widget.onBack();
                } else if (changed == true) {
                  _reload();
                }
              }, theme),
              const SizedBox(height: 6),
              _iconBtn(Icons.adaptive.share, () {
                _showInviteKeyDialog(space);
              }, theme),
              const SizedBox(height: 6),
              _iconBtn(
                Icons.notifications_outlined,
                () => _showNotificationSheet(space),
                theme,
                badge: space.notificationLevel == 'off'
                    ? 'MUTED'
                    : space.notificationLevel == 'mentions'
                        ? ' @ '
                        : null,
              ),
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
            await widget.spacesService.unsubscribeFromSpace(space.domain, space.node, conn.fullJid.userAtDomain, spaceType: space.type);
            await auth.leavePersistedSpace(space.domain, space.node);
            widget.onCreated?.call();
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
            final success = await widget.spacesService.subscribeToSpace(space.domain, space.node, conn.fullJid.userAtDomain, spaceType: space.type);
            if (!success) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to subscribe. Please try again.')));
              }
              return;
            }
            await auth.joinPersistedSpace(space.domain, space.node, space.name);
            final enriched = space.copyWith(isSubscribed: true, syncedAt: DateTime.now());
            await auth.updatePersistedSpace(enriched);
            widget.onCreated?.call();
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

  void _showInviteKeyDialog(SpaceNode space) {
    final inviteUri = 'xmpp:${space.domain}?;node=${space.node}';
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Invite to ${space.name}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurface)),
                  const SizedBox(height: 8),
                  Text('Share this key or QR code', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  QrImageView(
                    data: inviteUri,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    foregroundColor: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
                    ),
                    child: Text(inviteUri, style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface), textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: inviteUri));
                            if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Copied!')));
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('Copy'),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () { Share.shareUri(Uri.parse(inviteUri)); },
                          icon: const Icon(Icons.share_rounded, size: 16),
                          label: const Text('Share'),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), backgroundColor: theme.colorScheme.primary, foregroundColor: theme.colorScheme.onPrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showNotificationSheet(SpaceNode space) {
    final prefKey = 'notif_level_${space.domain}|${space.node}';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // Load current level on first build — FutureBuilder inside StatefulBuilder
          return FutureBuilder<SharedPreferences>(
            future: SharedPreferences.getInstance(),
            builder: (ctx, snap) {
              final prefs = snap.data;
              final currentLevel = prefs?.getString(prefKey) ?? 'all';

              Future<void> saveLevel(String level) async {
                await prefs?.setString(prefKey, level);
                setSheetState(() {});
                if (ctx.mounted) Navigator.pop(ctx);
                await widget.spacesService.setSpaceNotificationLevel(
                  space.domain, space.node, level,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Notifications set to: $level')),
                  );
                }
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
                    Text('Notification Preferences', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                    const SizedBox(height: 4),
                    Text(space.name, style: TextStyle(color: Colors.grey, fontSize: 13)),
                    const SizedBox(height: 20),
                    ListTile(
                      leading: const Icon(Icons.notifications_active_rounded),
                      title: const Text('All Notifications'),
                      subtitle: const Text('Get notified for every new post'),
                      trailing: currentLevel == 'all' ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                      onTap: () => saveLevel('all'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('Mentions Only'),
                      subtitle: const Text('Only when you are mentioned'),
                      trailing: currentLevel == 'mentions' ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                      onTap: () => saveLevel('mentions'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.notifications_off_outlined),
                      title: const Text('Off'),
                      subtitle: const Text('No notifications from this space'),
                      trailing: currentLevel == 'off' ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                      onTap: () => saveLevel('off'),
                    ),
                  ],
                ),
              );
            },
          );
        },
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
        Text(label, style: TextStyle(color: Colors.white,
            fontSize: 10, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, ThemeData theme, {String? badge}) {
    return Stack(clipBehavior: Clip.none, children: [
      Material(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        child: InkWell(
          borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(8),
              child: Icon(icon, color: Colors.white, size: 20)),
        ),
      ),
      if (badge != null)
        Positioned(
          top: -6, right: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: badge == 'MUTED' ? Colors.red.shade700 : theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(badge, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
          ),
        ),
    ]);
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
            child: MarkdownBody(
              data: space.description!,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(fontSize: 15, height: 1.6, color: theme.colorScheme.onSurface),
              ),
            ),
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
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
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
            Text('Delete Space', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 4),
            Text('Permanently delete this space and all contents.', style: TextStyle(fontSize: 12, color: Colors.redAccent)),
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
                    widget.onCreated?.call();
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
    if (_loadingItems) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 4,
        itemBuilder: (context, index) => _buildActivitySkeleton(theme),
      );
    }
    final allItems = _items ?? [];
    if (allItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.timeline_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('No activity yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('Posts and updates will appear here', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );
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
                    Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                    if (isPost && (item.name?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(item.name!, style: TextStyle(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
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
                    space.domain, space.node, conn.fullJid.userAtDomain, spaceType: space.type);
                await auth.leavePersistedSpace(space.domain, space.node);
                widget.onCreated?.call();
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
              if (conn == null) return;
              final success = await widget.spacesService.subscribeToSpace(
                  space.domain, space.node, conn.fullJid.userAtDomain, spaceType: space.type);
              if (!success) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to subscribe. Please try again.')));
                }
                return;
              }
              await auth.joinPersistedSpace(space.domain, space.node, space.name);
              final enriched = space.copyWith(isSubscribed: true, syncedAt: DateTime.now());
              await auth.updatePersistedSpace(enriched);
              widget.onCreated?.call();
              setState(() {});
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Subscribed to space! Content will now appear in your Feed.')));
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
          Text(value, style: TextStyle(
              fontWeight: FontWeight.w900, fontSize: 20)),
          Text(label, style: TextStyle(
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
        Text('$label ', style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
        Expanded(child: Text(value, textAlign: TextAlign.end,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Text(text, style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
        color: theme.colorScheme.primary));
  }

  // ── MEMBERS TAB ───────────────────────────────────────────
  Widget _buildPeopleTab(ThemeData theme) {
    return Column(children: [
      // Search bar
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          controller: _membersSearchController,
          onChanged: (v) => setState(() => _membersSearchQuery = v.trim()),
          decoration: InputDecoration(
            hintText: 'Search people on this server...',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _membersSearchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: () { _membersSearchController.clear(); setState(() => _membersSearchQuery = ''); },
                  )
                : null,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
      ),
      // Invite by JID
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: () => _showInviteByJidDialog(theme),
          icon: const Icon(Icons.person_add_rounded, size: 16),
          label: const Text('Invite by JID'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      const SizedBox(height: 8),
      // Results
      Expanded(
        child: _membersSearchQuery.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.person_search_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                  const SizedBox(height: 12),
                  Text('Search for people on this server', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              )
            : FutureBuilder<List<Map<String, String>>>(
                future: () async {
                  final auth = Provider.of<AuthService>(context, listen: false);
                  return auth.searchUsers(_membersSearchQuery, accountId: auth.activeAccountId);
                }(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final results = snap.data ?? [];
                  if (results.isEmpty) {
                    return Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.search_off_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                        const SizedBox(height: 12),
                        Text('No users found for "$_membersSearchQuery"', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                      ]),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: results.length,
                    itemBuilder: (ctx, i) {
                      final user = results[i];
                      final jid = user['jid'] ?? '';
                      final name = user['name'] ?? user['nickname'] ?? jid;
                      final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
                      final colorSeed = jid.hashCode;
                      final colors = [Colors.purple, Colors.blue, Colors.teal, Colors.orange, Colors.pink, Colors.indigo];
                      final color = colors[colorSeed.abs() % colors.length];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: 0.8),
                          child: Text(initial, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(jid, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                        trailing: IconButton(
                          icon: Icon(Icons.person_add_rounded, color: theme.colorScheme.primary),
                          tooltip: 'Add to space',
                          onPressed: () => _inviteUserToSpace(jid, name),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    ]);
  }

  void _showInviteByJidDialog(ThemeData theme) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite by JID'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the full JID of the user you want to invite:'),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'user@domain.example',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.alternate_email_rounded),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final jid = controller.text.trim();
              if (jid.isNotEmpty) _inviteUserToSpace(jid, jid);
            },
            child: const Text('Invite'),
          ),
        ],
      ),
    );
  }

  Future<void> _inviteUserToSpace(String jid, String displayName) async {
    final success = await widget.spacesService.inviteMember(
      widget.space.domain, widget.space.node, jid, 'member',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'Invitation sent to $displayName!' : 'Failed to invite $displayName')),
      );
    }
  }

  Widget _buildMembersTab(ThemeData theme) {
    return FutureBuilder<List<SpaceMember>>(
      future: _membersFuture,
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
              Text('No members found', style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant)),
            ],
          ));
        }
        final owners = members.where((m) => m.affiliation == 'owner').toList();
        final publishers = members.where((m) => m.affiliation == 'publisher').toList();
        final rest = members.where((m) =>
            m.affiliation != 'owner' && m.affiliation != 'publisher').toList();

        return RefreshIndicator(
          onRefresh: () async {
            _membersFuture = widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
            await _membersFuture;
          },
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
            if (owners.isNotEmpty) ...[
              _membersHeader(theme, '👑  Owners', owners.length),
              ...owners.map((m) => _buildMemberTile(theme, m, 'Owner')),
            ],
            if (publishers.isNotEmpty) ...[
              _membersHeader(theme, '✏️  Publishers', publishers.length),
              ...publishers.map((m) => _buildMemberTile(theme, m, 'Publisher')),
            ],
            if (rest.isNotEmpty) ...[
              _membersHeader(theme, '👥  Members', rest.length),
              ...rest.map((m) => _buildMemberTile(theme, m,
                  m.affiliation.isNotEmpty ? m.affiliation[0].toUpperCase() + m.affiliation.substring(1) : 'Member')),
            ],
            const SizedBox(height: 80),
          ]),
        );
      },
    );
  }

  Widget _buildMemberTile(ThemeData theme, SpaceMember member, String roleLabel) {
    final displayName = member.resolvedDisplayName;
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final colorSeed = member.jid.hashCode;
    final avatarColors = [
      Colors.purple, Colors.blue, Colors.teal,
      Colors.orange, Colors.pink, Colors.indigo,
    ];
    final avatarColor = avatarColors[colorSeed.abs() % avatarColors.length];

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: avatarColor.withValues(alpha: 0.8),
        child: member.avatarUrl != null
            ? ClipOval(child: Image.network(member.avatarUrl!, fit: BoxFit.cover))
            : Text(initial, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      title: Text(displayName, style: TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(member.jid, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(roleLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
            ),
            if (member.subscriptionState != null && member.subscriptionState != 'subscribed') ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(member.subscriptionState!, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.orange.shade700)),
              ),
            ],
          ]),
        ],
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert_rounded, color: theme.colorScheme.onSurfaceVariant),
          onSelected: (action) async {
          switch (action) {
            case 'promote':
              final ok = await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'publisher');
              if (ok) _membersFuture = widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
              if (mounted) setState(() {});
              break;
            case 'owner':
              final ok = await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'owner');
              if (ok) _membersFuture = widget.spacesService.fetchMembers(widget.space.domain, widget.space.node);
              if (mounted) setState(() {});
              break;
            case 'demote':
              await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'member');
              if (mounted) setState(() {});
              break;
            case 'ban':
              await widget.spacesService.setAffiliation(widget.space.domain, widget.space.node, member.jid, 'outcast');
              if (mounted) setState(() {});
              break;
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'promote', child: ListTile(leading: Icon(Icons.arrow_upward_rounded), title: Text('Make Publisher'))),
          PopupMenuItem(value: 'owner', child: ListTile(leading: Icon(Icons.star_rounded), title: Text('Make Owner'))),
          PopupMenuItem(value: 'demote', child: ListTile(leading: Icon(Icons.arrow_downward_rounded), title: Text('Demote to Member'))),
          PopupMenuItem(value: 'ban', child: ListTile(leading: Icon(Icons.block_rounded, color: Colors.red), title: Text('Ban', style: TextStyle(color: Colors.red)))),
        ],
      ),
    );
  }

  Widget _membersHeader(ThemeData theme, String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(children: [
        Text(title, style: TextStyle(
            fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
          ),
          child: Text('$count', style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer)),
        ),
      ]),
    );
  }

  // ── ROOMS TAB ─────────────────────────────────────────────
  Widget _buildRoomsTab(ThemeData theme) {
    final channels = (_items ?? []).where((i) => i.type == 'room').toList();
    final space = _details ?? widget.space;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Icon(Icons.forum_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text('ROOMS', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
                  color: theme.colorScheme.primary)),
              const Spacer(),
              Text('${channels.length}', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 12),
          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showCreateChannelDialog(),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Create Room'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showBrowseRoomsDialog(theme),
                  icon: const Icon(Icons.explore_rounded, size: 18),
                  label: const Text('Browse'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (channels.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
              ),
              child: Column(
                children: [
                  Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text('No rooms yet', style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15,
                      color: theme.colorScheme.onSurface)),
                  const SizedBox(height: 4),
                  Text('Create a chat room or browse existing rooms to add them to this space.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            )
          else
            ...channels.asMap().entries.map((entry) {
              final idx = entry.key;
              final ch = entry.value;
              final isOwner = space.affiliation == 'owner';
              return _buildEnhancedRoomTile(theme, ch, space,
                onMoveUp: isOwner && idx > 0 ? () => _moveRoom(channels, idx, idx - 1) : null,
                onMoveDown: isOwner && idx < channels.length - 1 ? () => _moveRoom(channels, idx, idx + 1) : null,
              );
            }),
        ],
      ),
    );
  }

  void _moveRoom(List<SpaceItem> channels, int from, int to) {
    final item = channels.removeAt(from);
    channels.insert(to, item);
    setState(() {});
  }

  Widget _buildEnhancedRoomTile(ThemeData theme, SpaceItem ch, SpaceNode space, {VoidCallback? onMoveUp, VoidCallback? onMoveDown}) {
    final roomJid = ch.jid ?? ch.id;
    final isOwner = space.affiliation == 'owner';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.tag_rounded, color: theme.colorScheme.onPrimaryContainer, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ch.name ?? ch.id, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  if (ch.description != null && ch.description!.isNotEmpty)
                    Text(ch.description!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(roomJid, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () {
                final auth = Provider.of<AuthService>(context, listen: false);
                if (auth.activeAccountId != null && roomJid.contains('@')) {
                  auth.joinXmppRoom(roomJid,
                      auth.getResolvedNickname(auth.activeAccountId!),
                      accountId: auth.activeAccountId!);
                  Provider.of<ChatProvider>(context, listen: false)
                      .setActiveConversation(roomJid);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Joined ${ch.name ?? roomJid}')),
                  );
                }
              },
              child: const Text('JOIN', style: TextStyle(fontSize: 12)),
            ),
            if (isOwner) ...[
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                itemBuilder: (_) => [
                  if (onMoveUp != null) const PopupMenuItem(value: 'moveUp', child: Text('Move Up')),
                  if (onMoveDown != null) const PopupMenuItem(value: 'moveDown', child: Text('Move Down')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove from Space')),
                ],
                onSelected: (val) async {
                  if (val == 'moveUp') { onMoveUp?.call(); return; }
                  if (val == 'moveDown') { onMoveDown?.call(); return; }
                  if (val == 'remove') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Remove Room?'),
                        content: Text('Remove "${ch.name ?? ch.id}" from this space?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await widget.spacesService.retractItem(space.domain, space.node, ch.id);
                      _reload();
                    }
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showBrowseRoomsDialog(ThemeData theme) {
    final searchController = TextEditingController();
    List<SpaceNode>? _browseResults;
    bool _browsing = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Browse Rooms'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Search rooms on this server...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search_rounded, size: 20),
                      onPressed: () async {
                        setDialogState(() => _browsing = true);
                        final space = _details ?? widget.space;
                        final baseDomain = space.domain.startsWith('pubsub.') || space.domain.startsWith('spaces.')
                            ? space.domain.substring(space.domain.indexOf('.') + 1)
                            : space.domain;
                        final results = await widget.spacesService.discoverMucRoomsAsSpaces(
                          'conference.$baseDomain',
                        );
                        setDialogState(() { _browseResults = results; _browsing = false; });
                      },
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                if (_browsing)
                  const Center(child: CircularProgressIndicator())
                else if (_browseResults != null)
                  Flexible(
                    child: _browseResults!.isEmpty
                        ? const Text('No rooms found.')
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: _browseResults!.length,
                            itemBuilder: (_, i) {
                              final room = _browseResults![i];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.tag_rounded),
                                title: Text(room.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(room.domain, style: const TextStyle(fontSize: 11)),
                                trailing: TextButton(
                                  onPressed: () async {
                                    final space = _details ?? widget.space;
                                    final baseDomain = space.domain.startsWith('pubsub.') || space.domain.startsWith('spaces.')
                                        ? space.domain.substring(space.domain.indexOf('.') + 1)
                                        : space.domain;
                                    final channelJid = '${room.name}@conference.$baseDomain';
                                    await widget.spacesService.createSpaceChannel(
                                      space.domain, space.node, room.name, channelJid,
                                    );
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _reload();
                                  },
                                  child: const Text('Add'),
                                ),
                              );
                            },
                          ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
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

    // Split pinned vs normal for display order
    final pinnedPosts = posts.where((p) => p.isPinned).toList();
    final normalPosts = posts.where((p) => !p.isPinned).toList();
    final orderedPosts = [...pinnedPosts, ...normalPosts];

    // Header items count: 1 (live banner, maybe) + 1 (search bar) + channels section + posts header
    // Use a sliver-based approach for true lazy rendering
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(slivers: [
        // Live banner
        if (_newLiveCount > 0)
          SliverToBoxAdapter(
            child: GestureDetector(
              onTap: () => setState(() => _newLiveCount = 0),
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
        // Search bar
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
        ),
        // Posts header
        if (orderedPosts.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text('POSTS', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4,
                  color: theme.colorScheme.primary)),
            ),
          ),
        // Lazy-rendered posts
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _buildPostCard(theme, orderedPosts[i],
                  pinned: orderedPosts[i].isPinned),
              childCount: orderedPosts.length,
            ),
          ),
        ),
        if (orderedPosts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _searchQuery.isNotEmpty
                ? EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No posts match "$_searchQuery"',
                    subtitle: 'Try a different search term',
                  )
                : EmptyState(
                    icon: Icons.article_outlined,
                    title: 'No posts yet',
                    subtitle: 'Be the first to post in this space',
                  ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ]),
    );
  }

  Widget _buildPostSkeleton(ThemeData theme) {
    final base = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(DesignTokens.radiusCard)),
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

  Widget _buildActivitySkeleton(ThemeData theme) {
    final base = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(DesignTokens.radiusCard)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: base, shape: BoxShape.circle)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: double.infinity, height: 12, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(4))),
                const SizedBox(height: 8),
                Container(width: 100, height: 10, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(4))),
              ],
            ),
          ),
        ],
      ),
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
            style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: ch.description != null
            ? Text(ch.description!, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12))
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
          borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
          side: BorderSide(
            color: pinned ? theme.colorScheme.primary.withValues(alpha: 0.4) : theme.dividerColor.withValues(alpha: 0.7),
            width: pinned ? 1.5 : 1,
          )),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            context.pushNamed('postDetail', extra: {'post': item, 'space': widget.space, 'spacesService': widget.spacesService, 'allItems': _items ?? []}).then((_) => _reload());
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
                  Text('Pinned Post', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
                ]),
              ),
            // Header
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(authorInitial, style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
              ),
              title: Row(children: [
                Flexible(child: Text(item.author ?? 'Anonymous', style: TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                if (item.isEdited) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('edited', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ],
              ]),
              subtitle: item.publishedDate != null
                  ? Text(_timeAgo(item.publishedDate!), style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant))
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
                child: Text(item.name!, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, height: 1.25)),
              ),
            // Body with read-more
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

              const maxLen = 500;
              final isLong = display.length > maxLen;
              final isExpanded = _expandedItems.contains(item.id);
              final shown = isLong && !isExpanded ? '${display.substring(0, maxLen)}…' : display;

              final linked = shown.replaceAllMapped(
                RegExp(r'(?<!\S)#(\w+)'),
                (m) => '[#${m[1]}](tag:${Uri.encodeComponent(m[1]!)})',
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: MarkdownBody(
                      data: linked, shrinkWrap: true,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(fontSize: 15, color: theme.colorScheme.onSurface, height: 1.55),
                        a: TextStyle(color: theme.colorScheme.primary),
                        code: TextStyle(backgroundColor: theme.colorScheme.surfaceContainerHighest, fontFamily: 'monospace', fontSize: 13),
                      ),
                      onTapLink: (text, href, title) {
                        if (href != null) {
                          if (href.startsWith('tag:')) {
                            final tag = Uri.decodeComponent(href.substring(4));
                            _showPostsByTag(tag);
                          } else {
                            try { launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication); } catch (_) {}
                          }
                        }
                      },
                    ),
                  ),
                  if (isLong)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isExpanded) {
                              _expandedItems.remove(item.id);
                            } else {
                              _expandedItems.add(item.id);
                            }
                          });
                        },
                        child: Text(
                          isExpanded ? 'Show less' : 'Read more',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                        ),
                      ),
                    ),
                ],
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
                _emojiReactionBtn(theme, '👍', item, item.reactions['👍'] ?? 0, isLiked: SpacesScreenManager.likedItems.contains(item.id)),
                _emojiReactionBtn(theme, '❤️', item, item.reactions['❤️'] ?? 0),
                _emojiReactionBtn(theme, '😂', item, item.reactions['😂'] ?? 0),
                _reactionBtn(theme, Icons.chat_bubble_outline_rounded, 'Reply', theme.colorScheme.onSurfaceVariant, onTap: () => _showReplyDialog(item)),
                _reactionBtn(theme, Icons.forum_rounded, 'Thread', theme.colorScheme.onSurfaceVariant, onTap: () {
                  context.pushNamed('postThread', extra: {'post': item, 'space': widget.space, 'spacesService': widget.spacesService}).then((_) => _reload());
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

  Widget _emojiReactionBtn(ThemeData theme, String emoji, SpaceItem item, int count, {bool isLiked = false}) {
    return InkWell(
      borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
      onTap: () {
        if (emoji == '👍') {
          _handleLike(item);
        } else {
          _handleEmojiReaction(item, emoji);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(emoji, style: TextStyle(fontSize: 17, color: isLiked ? Colors.blue : null)),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Text('$count', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isLiked ? Colors.blue : theme.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  void _handleEmojiReaction(SpaceItem item, String emoji) async {
    // Mutate per-item reactions in the local Map (immutable SpaceItem)
    setState(() {
      final reactions = Map<String, int>.from(_itemReactions[item.id] ?? item.reactions);
      reactions[emoji] = (reactions[emoji] ?? 0) + 1;
      _itemReactions[item.id] = reactions;
    });
    final auth = Provider.of<AuthService>(context, listen: false);
    final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
    await widget.spacesService.publishReaction(widget.space.domain, widget.space.node, item.id, emoji, userJid);
  }

  void _handleLike(SpaceItem item) async {
    final reactions = Map<String, int>.from(_itemReactions[item.id] ?? item.reactions);
    final wasLiked = SpacesScreenManager.likedItems.contains(item.id);
    setState(() {
      if (wasLiked) {
        SpacesScreenManager.likedItems.remove(item.id);
        reactions['👍'] = ((reactions['👍'] ?? 1) - 1).clamp(0, 9999);
      } else {
        SpacesScreenManager.likedItems.add(item.id);
        reactions['👍'] = (reactions['👍'] ?? 0) + 1;
      }
      _itemReactions[item.id] = reactions;
    });
    final auth = Provider.of<AuthService>(context, listen: false);
    final userJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? 'unknown';
    if (wasLiked) {
      await widget.spacesService.retractItem(
        widget.space.domain,
        '${widget.space.node}/${item.id}/reactions',
        userJid.replaceAll('@', '_'),
      );
    } else {
      await widget.spacesService.publishReaction(widget.space.domain, widget.space.node, item.id, '👍', userJid);
    }
  }

  void _showPostContextMenu(SpaceItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
        if (item.type == 'entry')
          ListTile(
            leading: Icon(Icons.edit_rounded, color: Theme.of(ctx).colorScheme.primary),
            title: Text('Edit Post', style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
            onTap: () {
              Navigator.pop(ctx);
              showDialog(
                context: this.context,
                builder: (ctx) => CreatePostDialog(
                  spacesService: widget.spacesService,
                  space: widget.space,
                  authService: Provider.of<AuthService>(this.context, listen: false),
                  editItem: item,
                  onSuccess: _reload,
                ),
              );
            },
          ),
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
          onTap: () async {
            Navigator.pop(ctx);
            final link = 'xmpp:${widget.space.domain}?;node=${widget.space.node};item=${item.id}';
            await Clipboard.setData(ClipboardData(text: link));
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied to clipboard')));
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
        if (item.type == 'entry')
          ListTile(
            leading: Icon(Icons.repeat_rounded, color: Theme.of(ctx).colorScheme.primary),
            title: Text('Repost to Space', style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
            onTap: () {
              Navigator.pop(ctx);
              _showRepostDialog(item);
            },
          ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _reactionBtn(ThemeData theme, IconData icon, String label, Color color, {required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 19, color: color),
          if (label.isNotEmpty && label != '0') ...[
            const SizedBox(width: 5),
            Text(label, style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ]),
      ),
    );
  }

  void _handleShare(SpaceItem item) {
    final text = '${item.name ?? 'Post'} by ${item.author ?? 'Anonymous'}\n\n${item.description ?? ''}';
    Share.share(text, subject: item.name);
  }

  void _showRepostDialog(SpaceItem item) {
    final auth = Provider.of<AuthService>(context, listen: false);
    final spaces = auth.joinedSpaces;
    if (spaces.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Join a space first to repost')));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repost to...'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: spaces.length,
            itemBuilder: (_, i) {
              final s = spaces[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(ctx).colorScheme.primaryContainer,
                  child: Text(s.node[0].toUpperCase()),
                ),
                title: Text(s.name ?? s.node),
                subtitle: Text(s.domain),
                onTap: () async {
                  Navigator.pop(ctx);
                  final body = item.rawContent ?? item.description ?? '';
                  final title = item.name ?? '';
                  final ok = await widget.spacesService.publishMicroblogEntry(
                    s.domain,
                    s.node,
                    title: title,
                    content: body,
                    authorName: item.author,
                  );
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(ok ? 'Reposted to ${s.name ?? s.node}' : 'Failed to repost')),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showReplyDialog(SpaceItem item) {
    final controller = TextEditingController();
    bool _isPosting = false;
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.reply_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Reply to ${item.author ?? 'post'}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Quoted original
              if (item.name != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    item.name!,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 12),
              // Reply input
              TextField(
                controller: controller,
                maxLines: 5,
                minLines: 3,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Write your reply...\n\nMarkdown: **bold**, _italic_, `code`',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
              const SizedBox(height: 8),
              // Formatting toolbar
              Row(
                children: [
                  IconButton(
                    tooltip: 'Bold',
                    icon: const Icon(Icons.format_bold_rounded, size: 20),
                    onPressed: () {
                      final sel = controller.selection;
                      final text = controller.text;
                      final selected = sel.isValid ? text.substring(sel.start, sel.end) : '';
                      final replacement = '**$selected**';
                      controller.text = text.replaceRange(sel.start, sel.end, replacement);
                      controller.selection = TextSelection.collapsed(offset: sel.start + replacement.length);
                    },
                  ),
                  IconButton(
                    tooltip: 'Italic',
                    icon: const Icon(Icons.format_italic_rounded, size: 20),
                    onPressed: () {
                      final sel = controller.selection;
                      final text = controller.text;
                      final selected = sel.isValid ? text.substring(sel.start, sel.end) : '';
                      final replacement = '_${selected}_';
                      controller.text = text.replaceRange(sel.start, sel.end, replacement);
                      controller.selection = TextSelection.collapsed(offset: sel.start + replacement.length);
                    },
                  ),
                  IconButton(
                    tooltip: 'Code',
                    icon: const Icon(Icons.code_rounded, size: 20),
                    onPressed: () {
                      final sel = controller.selection;
                      final text = controller.text;
                      final selected = sel.isValid ? text.substring(sel.start, sel.end) : '';
                      final replacement = '`$selected`';
                      controller.text = text.replaceRange(sel.start, sel.end, replacement);
                      controller.selection = TextSelection.collapsed(offset: sel.start + replacement.length);
                    },
                  ),
                  const Spacer(),
                  Text(
                    '${controller.text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length} w',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _isPosting || controller.text.trim().isEmpty
                  ? null
                  : () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      setDialogState(() => _isPosting = true);
                      Navigator.pop(dialogContext);
                      final targetDomain = item.commentService ?? widget.space.domain;
                      final targetNode = item.commentNode ?? widget.space.node;
                      final messenger = ScaffoldMessenger.of(context);
                      final auth = context.read<AuthService>();
                      final authorName = auth.getResolvedNickname(null);
                      var success = await widget.spacesService.postReply(
                        targetDomain,
                        targetNode,
                        text,
                        replyToId: item.id,
                        authorName: authorName,
                      );
                      if (!success && item.commentNode != null) {
                        success = await widget.spacesService.postReply(
                          widget.space.domain,
                          widget.space.node,
                          text,
                          replyToId: item.id,
                          authorName: authorName,
                          autoCreateNode: false,
                        );
                      }
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(success ? 'Reply posted!' : 'Failed to post reply: The server may require owner permissions.')),
                        );
                        if (success) _reload();
                      }
                    },
              child: _isPosting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Post Reply'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPostsByTag(String tag) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(Icons.tag_rounded, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('#$tag', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<SpaceItem>>(
                future: widget.spacesService.searchPostsByTag(widget.space.domain, widget.space.node, tag),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                  if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
                  final items = snap.data ?? [];
                  if (items.isEmpty) return EmptyState(icon: Icons.tag_rounded, title: 'No posts found with this tag');
                  return ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _buildPostCard(Theme.of(ctx), items[i]),
                  );
                },
              ),
            ),
          ],
        ),
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
    final nameController = TextEditingController();
    final jidController = TextEditingController();
    bool _linkExisting = false;
    final theme = Theme.of(context);
    final space = _details ?? widget.space;
    final baseDomain = space.domain.startsWith('pubsub.') || space.domain.startsWith('spaces.')
        ? space.domain.substring(space.domain.indexOf('.') + 1)
        : space.domain;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Room'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => _linkExisting = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: !_linkExisting ? theme.colorScheme.primary.withValues(alpha: 0.1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: !_linkExisting ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(child: Text('Create New', style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: !_linkExisting ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                          ))),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => _linkExisting = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _linkExisting ? theme.colorScheme.primary.withValues(alpha: 0.1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _linkExisting ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(child: Text('Link Existing', style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _linkExisting ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                          ))),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!_linkExisting) ...[
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Room Name', hintText: 'e.g. General'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Room JID: ${nameController.text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]'), '')}@conference.$baseDomain',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant),
                  ),
                ] else ...[
                  TextField(
                    controller: jidController,
                    decoration: InputDecoration(
                      labelText: 'Room JID',
                      hintText: 'room@conference.example.com',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Paste the full JID of an existing MUC room to link it to this space.',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final existingJids = (_items ?? []).map((i) => i.node).toSet();
                if (_linkExisting) {
                  final jid = jidController.text.trim();
                  if (jid.isEmpty || !jid.contains('@')) return;
                  if (existingJids.contains(jid)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('This room is already linked to the space')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext);
                  final name = jid.split('@').first;
                  final success = await widget.spacesService.createSpaceChannel(
                    widget.space.domain, widget.space.node, name, jid,
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(success ? 'Room linked!' : 'Failed to link room')),
                  );
                  if (success) _reload();
                } else {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;
                  final cleanLocal = name.toLowerCase()
                      .replaceAll(RegExp(r'[^a-z0-9\-_]'), '')
                      .replaceAll(RegExp(r'-+'), '-')
                      .replaceAll(RegExp(r'^-+|-+$'), '');
                  if (cleanLocal.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Room name must contain letters or numbers')),
                    );
                    return;
                  }
                  final channelJid = '$cleanLocal@conference.$baseDomain';
                  if (existingJids.contains(channelJid)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('A room with this name already exists in the space')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext);
                  final success = await widget.spacesService.createSpaceChannel(
                    widget.space.domain, widget.space.node, name, channelJid,
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(success ? 'Room created!' : 'Failed to create room')),
                  );
                  if (success) _reload();
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
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
    this.editItem,
  });

  final SpacesService spacesService;
  final SpaceNode space;
  final VoidCallback onSuccess;
  final AuthService authService;
  final SpaceItem? editItem;

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

    if (widget.editItem != null) {
      _titleController.text = widget.editItem!.name ?? '';
      _contentController.text = widget.editItem!.rawContent ?? widget.editItem!.description ?? '';
      final cats = widget.editItem!.categories;
      _tagsController.text = cats.join(', ');
      _attachedImageUrl = widget.editItem!.imageUrl;
    } else {
      // Restore draft asynchronously (skip when editing existing post)
      widget.spacesService.loadDraft(widget.space.node).then((draft) {
        if (draft != null && mounted) {
          setState(() {
            _titleController.text = draft['title'] ?? '';
            _contentController.text = draft['content'] ?? '';
            _tagsController.text = draft['tags'] ?? '';
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _autosaveDraft() {
    widget.spacesService.saveDraft(
      widget.space.node,
      title: _titleController.text,
      content: _contentController.text,
      tags: _tagsController.text,
    );
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null || !mounted) return;
      // For now, store the local path as a placeholder. In production,
      // upload via XEP-0363 HTTP File Upload and replace with the URL.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image selected. It will be attached on publish.')),
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
    final wordCount = content.trim().isEmpty ? 0 : content.trim().split(RegExp(r'\s+')).length;
    final hasContent = content.trim().isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!hasContent) {
          // Nothing to discard — just clear draft and close
          await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) Navigator.of(context).pop();
          return;
        }
        final discard = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your draft will be saved and restored next time.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && mounted) {
          await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Dialog.fullscreen(
        child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
              widget.editItem != null ? 'Edit Post' : 'New Post in ${widget.space.name}',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
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
                  icon: Icon(widget.editItem != null ? Icons.check_rounded : Icons.send_rounded, size: 16),
                  label: Text(widget.editItem != null ? 'Save' : 'Publish'),
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
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
                  decoration: InputDecoration(
                    hintText: 'Post title (optional)...',
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontWeight: FontWeight.w900, fontSize: 20),
                    border: InputBorder.none,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) { setState(() {}); _autosaveDraft(); },
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Tags
                TextField(
                  controller: _tagsController,
                  style: TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Tags (comma separated)...',
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.tag_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    isDense: true,
                  ),
                  onChanged: (_) { setState(() {}); _autosaveDraft(); },
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Markdown formatting toolbar
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _toolbarBtn(Icons.format_bold_rounded, 'Bold', () => _insertMarkdown('**', '**')),
                    _toolbarBtn(Icons.format_italic_rounded, 'Italic', () => _insertMarkdown('_', '_')),
                    _toolbarBtn(Icons.code_rounded, 'Code', () => _insertMarkdown('`', '`')),
                    _toolbarBtn(Icons.format_list_bulleted_rounded, 'List', () => _insertMarkdown('\n- ', '')),
                    _toolbarBtn(Icons.format_list_numbered_rounded, 'Numbered', () => _insertMarkdown('\n1. ', '')),
                    _toolbarBtn(Icons.link_rounded, 'Link', () => _insertMarkdown('[', '](url)')),
                    _toolbarBtn(Icons.format_quote_rounded, 'Quote', () => _insertMarkdown('\n> ', '')),
                    _toolbarBtn(Icons.title_rounded, 'Heading', () => _insertMarkdown('\n## ', '')),
                  ]),
                ),
                const SizedBox(height: 8),
                // Body
                TextField(
                  controller: _contentController,
                  maxLines: null,
                  minLines: 10,
                  style: TextStyle(fontSize: 16, height: 1.6),
                  decoration: InputDecoration(
                    hintText: "What's on your mind?\n\nMarkdown is supported: **bold**, _italic_, [links](url)",
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 15, height: 1.6),
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
                          : kIsWeb ? const SizedBox.shrink() : Image.file(File(_attachedImageUrl!), height: 180, width: double.infinity, fit: BoxFit.cover,
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
                  Text(_titleController.text, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24, height: 1.2)),
                  const SizedBox(height: 16),
                ],
                if (content.isEmpty)
                  Text('Nothing to preview yet. Write something in the Write tab.',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 15))
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
            Text('$wordCount w · ${content.length} ch',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    ),
  );
  }

  Widget _toolbarBtn(IconData icon, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
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
      if (_attachedImageUrl != null && !_attachedImageUrl!.startsWith('http') && !kIsWeb) {
        final uploadService = widget.authService.activeUploadService;
        if (uploadService == null) {
          throw Exception('HTTP Upload service not available on this server.');
        }

        final file = File(_attachedImageUrl!);
        final fileName = file.path.split(RegExp(r'[/\\]')).last;
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

      final isEditing = widget.editItem != null;
      final success = await widget.spacesService.publishMicroblogEntry(
        widget.space.domain,
        widget.space.node,
        content: content,
        title: _titleController.text.trim(),
        imageUrl: finalImageUrl,
        categories: tags.isNotEmpty ? tags : null,
        itemId: isEditing ? widget.editItem!.id : null,
      );

      if (mounted) {
        setState(() => _isPublishing = false);
        if (success) {
          if (!isEditing) await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isEditing ? 'Post updated!' : 'Post published!')),
          );
          if (mounted) Navigator.pop(context);
          widget.onSuccess();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isEditing ? 'Failed to update post.' : 'Failed to publish. Check permissions.')),
          );
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