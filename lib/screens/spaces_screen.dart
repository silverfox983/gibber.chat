import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../core/design_tokens.dart';

import '../services/auth_service.dart';
import '../services/spaces_service.dart';

import '../models/space_models.dart';
import '../models/unified_community.dart';
import '../widgets/create_space_dialog.dart';
import '../widgets/join_space_dialog.dart';
import 'space_detail_view.dart';
import '../widgets/create_post_dialog.dart';

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

  StreamSubscription? _connectionStateSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      final auth = Provider.of<AuthService>(context, listen: false);
      final conn = auth.activeXmppConnection;
      if (conn != null) {
        _connectionStateSub = conn.connectionStateStream.listen((state) {
          if (state.toString().contains('Ready') || state.toString().contains('Resumed')) {
            if (!_exploreLoading && _exploreResults.isEmpty) {
              _addOwnServerToExploreSources();
              _loadExplore();
            }
            if (!_roomsLoading && _rooms.isEmpty) {
              _addOwnMucService();
              _loadRooms();
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _connectionStateSub?.cancel();
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
    _addOwnMucService();
    _loadExplore();
    _loadRooms();
  }

  void _addOwnServerToExploreSources() {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn != null) {
      final userDomain = conn.fullJid.domain;
      if (userDomain == null || userDomain.isEmpty) return;

      // Add user's own server PubSub services (discovered via disco)
      final accountId = auth.activeAccountId;
      if (accountId != null) {
        final pubsubServices = auth.getPubsubServices(accountId);
        for (final svc in pubsubServices) {
          if (!_exploreSources.contains(svc)) {
            _exploreSources.add(svc);
          }
        }
        final mucServices = auth.getMucServices(accountId);
        for (final svc in mucServices) {
          if (!_mucServices.contains(svc)) {
            _mucServices.add(svc);
          }
        }
        if (pubsubServices.isNotEmpty || mucServices.isNotEmpty) {
          debugPrint('SpacesScreen: Loaded ${pubsubServices.length} PubSub and ${mucServices.length} MUC services from server discovery');
        }
      }

      // Fallback: add pubsub.$userDomain if no disco services found yet
      final pubsubDomain = 'pubsub.$userDomain';
      if (!_exploreSources.contains(pubsubDomain) && !_exploreSources.contains(userDomain)) {
        _exploreSources.insert(0, pubsubDomain);
      }
    }
  }

  void _addOwnMucService() {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn != null) {
      final userDomain = conn.fullJid.domain;
      if (userDomain == null || userDomain.isEmpty) return;
      final likelyMucService = 'conference.$userDomain';
      if (!_mucServices.contains(likelyMucService)) {
        _mucServices.insert(0, likelyMucService);
      }
      _selectedMucService = likelyMucService;
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
          enriched.add(meta ?? s);
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

  Future<void> _loadExplore({bool forceRefresh = false}) async {
    if (_spacesService == null) {
      if (mounted) setState(() => _exploreLoading = false);
      return;
    }
    if (_exploreLoading) return;
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
          final spaces = await _spacesService!.discoverAllSpaces(domain, forceRefresh: forceRefresh).timeout(
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
              enriched.add(meta ?? s);
            } catch (_) {
              enriched.add(s);
            }
          }

          for (final s in enriched) {
            final key = '${s.domain}|${s.node}';
            if (!seen.contains(key)) {
              seen.add(key);
              allCommunities.add(UnifiedCommunity.fromSpaceNode(s));
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
      }));
    }

    // Sort and update UI only once at the end to prevent flicker
    allCommunities.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    if (mounted) {
      setState(() {
        _exploreResults.clear();
        _exploreResults.addAll(allCommunities);
        _exploreLoading = false;
      });
    }
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
    _loadExplore(forceRefresh: true);
    _loadRooms();
  }

  // ─── Tab builder delegates ─────────────────────────────────────────────

  Widget _buildExplore() => _buildUnifiedList(
        items: _filteredExplore(),
        loading: _exploreLoading,
        emptyIcon: Icons.explore_outlined,
        emptyTitle: 'No communities found',
        emptySubtitle: 'Try a different search or check your connection.',
        onRefresh: () async { _loadExplore(forceRefresh: true); },
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
              // Tag-based discovery: find spaces matching the keyword across pubsub services
              final searchTargets = _exploreSources.where((d) => d.contains('.')).toList();
              final spaces = await _spacesService!.fetchSpacesByTag(query, searchTargets.take(5).toList());
              final communities = spaces.map((s) => UnifiedCommunity.fromSpaceNode(s)).toList();
              if (mounted) {
                setState(() {
                  _exploreResults.clear();
                  _exploreResults.addAll(communities);
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
                    final svc = auth.spacesService;
                    if (conn != null && svc != null) {
                      showDialog(
                        context: context,
                        builder: (context) => CreateSpaceDialog(
                          spacesService: svc,
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
                    final svc = auth.spacesService;
                    if (conn != null && svc != null) {
                      showDialog(
                        context: context,
                        builder: (context) => JoinSpaceDialog(
                          spacesService: svc,
                          currentUserDomain: conn.fullJid.domain,
                          onSuccess: _refresh,
                        ),
                      );
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.rss_feed_rounded),
                  tooltip: 'My Subscriptions',
                  onPressed: () {
                    context.push('/app/subscriptions');
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
