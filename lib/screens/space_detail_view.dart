import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../widgets/space_invite_dialog.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/create_post_dialog.dart';

// Provides global state for liked items across the session
class SpacesScreenManager {
  static Set<String> likedItems = {};
  static Future<void> loadLikedItems() async {}
}

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
              if (space.affiliation == 'owner' || space.affiliation == 'publisher') ...[
                const SizedBox(height: 6),
                _iconBtn(Icons.edit_rounded, () => _showInlineEditDialog(space), theme),
              ],
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

  Future<void> _showInlineEditDialog(SpaceNode space) async {
    final nameController = TextEditingController(text: space.name);
    final descController = TextEditingController(text: space.description ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Space'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      final newName = nameController.text.trim();
      final newDesc = descController.text.trim();
      if (newName.isNotEmpty && (newName != space.name || newDesc != (space.description ?? ''))) {
        final ok = await widget.spacesService.updateSpaceConfig(
          space.domain, space.node,
          name: newName,
          description: newDesc.isNotEmpty ? newDesc : null,
        );
        if (ok != null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Space updated')));
          _reload();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update space')));
        }
      }
    }

    nameController.dispose();
    descController.dispose();
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
                  const PopupMenuItem(value: 'settings', child: Text('Room Settings')),
                  if (onMoveUp != null) const PopupMenuItem(value: 'moveUp', child: Text('Move Up')),
                  if (onMoveDown != null) const PopupMenuItem(value: 'moveDown', child: Text('Move Down')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove from Space')),
                ],
                onSelected: (val) async {
                  if (val == 'settings') {
                    final auth = Provider.of<AuthService>(context, listen: false);
                    final accountId = auth.activeAccountId;
                    if (accountId != null && roomJid.contains('@')) {
                      final nick = auth.getResolvedNickname(accountId);
                      await auth.joinXmppRoom(roomJid, nick, accountId: accountId);
                      final room = Room(
                        id: roomJid,
                        name: ch.name ?? roomJid.split('@').first,
                        topic: ch.description,
                        participants: [],
                        protocol: 'XMPP',
                        isGroup: true,
                        accountId: accountId,
                      );
                      final result = await context.pushNamed('roomSettings', extra: {'room': room});
                      if (result == 'left') {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Left ${ch.name ?? roomJid}')));
                      }
                    }
                    return;
                  }
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
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final auth = Provider.of<AuthService>(context, listen: false);
        final chats = Provider.of<ChatProvider>(context, listen: false).conversations;
        final rooms = auth.joinedRooms;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.onSurfaceVariant.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 12),
              Text('Share Post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Theme.of(ctx).colorScheme.onSurface)),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(Icons.ios_share_rounded, color: Theme.of(ctx).colorScheme.primary),
                title: const Text('Share externally'),
                subtitle: const Text('Share via system share sheet'),
                onTap: () {
                  Navigator.pop(ctx);
                  final text = '${item.name ?? 'Post'} by ${item.author ?? 'Anonymous'}\n\n${item.description ?? ''}';
                  Share.share(text, subject: item.name);
                },
              ),
              if (chats.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Align(alignment: Alignment.centerLeft, child: Text('SHARE TO CHAT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                ),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: chats.length > 10 ? 10 : chats.length,
                    itemBuilder: (_, i) {
                      final chat = chats[i];
                      return InkWell(
                        onTap: () async {
                          Navigator.pop(ctx);
                          final accountId = auth.activeAccountId;
                          if (accountId == null) return;
                          final postUrl = 'xmpp:${widget.space.domain}?;node=${widget.space.node};item=${item.id}';
                          await auth.pubsubInteractionService.sharePostToChat(
                            accountId: accountId,
                            targetJid: chat.id,
                            postId: item.id,
                            postUrl: postUrl,
                            postTitle: item.name,
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Shared to ${chat.name}'), backgroundColor: Colors.green));
                          }
                        },
                        child: Container(
                          width: 80,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: Theme.of(ctx).colorScheme.primaryContainer,
                                child: Text(chat.name.isNotEmpty ? chat.name[0].toUpperCase() : '?', style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(ctx).colorScheme.onPrimaryContainer)),
                              ),
                              const SizedBox(height: 4),
                              Text(chat.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (rooms.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Align(alignment: Alignment.centerLeft, child: Text('SHARE TO ROOM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                ),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: rooms.length > 10 ? 10 : rooms.length,
                    itemBuilder: (_, i) {
                      final room = rooms[i];
                      return InkWell(
                        onTap: () async {
                          Navigator.pop(ctx);
                          final accountId = auth.activeAccountId;
                          if (accountId == null) return;
                          final postUrl = 'xmpp:${widget.space.domain}?;node=${widget.space.node};item=${item.id}';
                          await auth.pubsubInteractionService.sharePostToRoom(
                            accountId: accountId,
                            roomJid: room.id,
                            postId: item.id,
                            postUrl: postUrl,
                            postTitle: item.name,
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Shared to ${room.name}'), backgroundColor: Colors.green));
                          }
                        },
                        child: Container(
                          width: 80,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: Theme.of(ctx).colorScheme.tertiaryContainer,
                                child: Icon(Icons.groups_rounded, color: Theme.of(ctx).colorScheme.onTertiaryContainer, size: 20),
                              ),
                              const SizedBox(height: 4),
                              Text(room.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
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
