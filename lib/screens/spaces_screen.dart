import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/spaces_service.dart';
import '../models/space_models.dart';
import '../providers/chat_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/create_space_dialog.dart';

class SpacesScreen extends StatefulWidget {
  const SpacesScreen({Key? key}) : super(key: key);

  @override
  State<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends State<SpacesScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<SpaceNode> _spaces = [];
  bool _isLoading = false;
  String? _errorMessage;
  SpacesService? _spacesService;
  int _currentTab = 0; // 0: Discover, 1: My Spaces
  List<SpaceNode> _mySpaces = [];
  bool _isMySpacesLoading = false;

  @override
  void initState() {
    super.initState();
    _searchController.text = 'spaces.movim.eu';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMySpaces();
    });
  }

  Future<void> _loadMySpaces() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) return;

    setState(() => _isMySpacesLoading = true);

    if (_spacesService == null || _spacesService!.connection != conn) {
      _spacesService?.dispose();
      _spacesService = SpacesService(conn);
    }

    // Usually my spaces are on my own server's pubsub service or PEP
    final domain = conn.fullJid.domain;
    
    // Fetch server-side spaces
    final serverSpaces = await _spacesService!.fetchSpaces(domain);
    
    // Combine with locally joined spaces
    final localSpaces = auth.joinedSpaces;
    
    // Deduplicate by node and domain
    final Map<String, SpaceNode> uniqueSpaces = {};
    for (var s in serverSpaces) {
      uniqueSpaces['${s.domain}|${s.node}'] = s;
    }
    for (var s in localSpaces) {
      if (!uniqueSpaces.containsKey('${s.domain}|${s.node}')) {
        uniqueSpaces['${s.domain}|${s.node}'] = s;
      }
    }

    // Enrich with metadata
    final spacesList = uniqueSpaces.values.toList();
    final enriched = await Future.wait(spacesList.map((s) => _spacesService!.fetchSpaceMetadata(s.domain, s.node)));
    
    if (mounted) {
      setState(() {
        _mySpaces = enriched.whereType<SpaceNode>().toList();
        
        // Add back spaces that failed to fetch metadata
        for (var i = 0; i < spacesList.length; i++) {
          if (enriched[i] == null) {
            _mySpaces.add(spacesList[i]);
          }
        }
        _isMySpacesLoading = false;
      });
    }
  }

  void _showCreateSpaceDialog() {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) return;
    final domain = conn.fullJid.domain;

    if (_spacesService == null || _spacesService!.connection != conn) {
      _spacesService?.dispose();
      _spacesService = SpacesService(conn);
    }

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (context) => CreateSpaceDialog(
        spacesService: _spacesService!,
        domain: domain,
        onSuccess: _loadMySpaces,
      ),
    );
  }

  @override
  void dispose() {
    _spacesService?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchSpaces() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('XMPP not connected'), backgroundColor: Theme.of(context).colorScheme.error));
      return;
    }

    setState(() {
      _isLoading = true;
      _spaces = [];
      _errorMessage = null;
    });

    if (_spacesService == null || _spacesService!.connection != conn) {
      _spacesService?.dispose();
      _spacesService = SpacesService(conn);
    }
    
    final domain = _searchController.text.trim();
    if (domain.isNotEmpty) {
      final spaces = await _spacesService!.fetchSpaces(domain);
      setState(() {
        _spaces = spaces;
        if (spaces.isEmpty) {
          _errorMessage = 'No Spaces found on this server.';
        }
      });
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _showSpaceContent(SpaceNode space) async {
    if (_spacesService == null) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)),
    );

    final items = await _spacesService!.fetchSpaceContent(space.domain, space.node);
    
    if (!mounted) return;
    Navigator.pop(context); // Close loading dialog

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _SpaceContentSheet(
        space: space, 
        items: items,
        onNavigateSpace: (nodeId) {
          Navigator.pop(context);
          _showSpaceContent(SpaceNode(
            domain: space.domain,
            node: nodeId,
            name: nodeId.split(':').last,
          ));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
        title: Text('Discover Spaces', style: TextStyle(fontWeight: FontWeight.w900, color: theme.colorScheme.onPrimary)),
        elevation: 0,
        centerTitle: true,
        backgroundColor: theme.colorScheme.primary,
        iconTheme: IconThemeData(color: theme.colorScheme.onPrimary),
      ),
      body: Column(
        children: [
          Container(
            color: theme.colorScheme.primary,
            child: TabBar(
              onTap: (index) => setState(() => _currentTab = index),
              indicatorColor: theme.colorScheme.secondary,
              indicatorWeight: 4,
              labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              tabs: const [
                Tab(text: 'DISCOVER'),
                Tab(text: 'MY SPACES'),
              ],
            ),
          ),
          if (_currentTab == 0) ...[
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primary,
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.white24,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          hintText: 'Spaces Domain (e.g. spaces.movim.eu)',
                          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                          border: InputBorder.none,
                          prefixIcon: Icon(Icons.dns_rounded, color: Colors.white.withValues(alpha: 0.7)),
                        ),
                        onSubmitted: (_) => _searchSpaces(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.secondary.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton(
                      onPressed: _searchSpaces,
                      icon: Icon(Icons.search_rounded, color: theme.colorScheme.onSecondary, size: 28),
                    ),
                  ),
                ],
              ),
            ),
            if (_isLoading)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: theme.colorScheme.secondary),
                      const SizedBox(height: 16),
                      Text('Discovering spaces...', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              )
            else if (_spaces.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _errorMessage != null ? Icons.search_off_rounded : Icons.explore_rounded,
                        size: 80,
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage ?? 'Search a domain to discover Server-Side Spaces.',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: _buildSpaceList(context, _spaces),
              ),
          ] else ...[
            if (_isMySpacesLoading)
              Expanded(child: Center(child: CircularProgressIndicator(color: theme.colorScheme.primary)))
            else if (_mySpaces.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.2)),
                      const SizedBox(height: 16),
                      const Text('You haven\'t created any spaces yet.', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      ElevatedButton(onPressed: _showCreateSpaceDialog, child: const Text('CREATE YOUR FIRST SPACE')),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _loadMySpaces,
                  child: _buildSpaceList(context, _mySpaces),
                ),
              ),
          ],
        ],
      ),
      floatingActionButton: _currentTab == 1 ? FloatingActionButton.extended(
        onPressed: _showCreateSpaceDialog,
        icon: const Icon(Icons.add_rounded),
        label: const Text('NEW SPACE', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: theme.colorScheme.secondary,
        foregroundColor: theme.colorScheme.onSecondary,
      ) : null,
    ));
  }

  Widget _buildSpaceList(BuildContext context, List<SpaceNode> spaces) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: spaces.length,
      itemBuilder: (context, index) {
        final space = spaces[index];
        final auth = Provider.of<AuthService>(context, listen: false);
        final isJoined = auth.joinedSpaces.any((s) => s.domain == space.domain && s.node == space.node);

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black26 : Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _showSpaceContent(space),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primaryContainer,
                          theme.colorScheme.secondaryContainer,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        space.name.isNotEmpty ? space.name[0].toUpperCase() : '?',
                        style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontSize: 24, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                space.name,
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isJoined)
                              Icon(Icons.bookmark_added_rounded, color: theme.colorScheme.secondary, size: 16),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (space.description != null)
                          Text(space.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13))
                        else
                          Text(space.node, style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SpaceContentSheet extends StatelessWidget {
  final SpaceNode space;
  final List<SpaceItem> items;
  final Function(String nodeId) onNavigateSpace;

  const _SpaceContentSheet({
    Key? key, 
    required this.space, 
    required this.items,
    required this.onNavigateSpace,
  }) : super(key: key);

  void _showAddRoomDialog(BuildContext context) {
    final jidController = TextEditingController();
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Room to Space', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: jidController,
              decoration: const InputDecoration(labelText: 'Room JID', hintText: 'room@conference.example.com'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Display Name (Optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              final jid = jidController.text.trim();
              if (jid.isEmpty) return;

              final auth = Provider.of<AuthService>(context, listen: false);
              final conn = auth.activeXmppConnection;
              if (conn == null) return;

              final spacesService = SpacesService(conn);
              final success = await spacesService.addRoomToSpace(space.domain, space.node, jid, roomName: nameController.text.trim());
              
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(success ? 'Room added!' : 'Failed to add room (check permissions).'))
                );
              }
            },
            child: const Text('ADD'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSpace(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Space?', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text('Are you sure you want to permanently delete "${space.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Colors.white),
            onPressed: () async {
              final auth = Provider.of<AuthService>(context, listen: false);
              final conn = auth.activeXmppConnection;
              if (conn == null) return;
              final service = SpacesService(conn);
              final success = await service.deleteSpace(space.domain, space.node);
              if (context.mounted) {
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Close sheet
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(success ? 'Space deleted.' : 'Failed to delete space (check permissions).'))
                );
              }
            },
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final auth = Provider.of<AuthService>(context);
    final isJoined = auth.joinedSpaces.any((s) => s.domain == space.domain && s.node == space.node);

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
                  theme.colorScheme.surface,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (space.avatarUrl != null)
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          image: DecorationImage(
                            image: NetworkImage(space.avatarUrl!),
                            fit: BoxFit.cover,
                          ),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 4)),
                          ],
                        ),
                      )
                    else
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4)),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            space.name.isNotEmpty ? space.name[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurfaceVariant, size: 28),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  space.name,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 28),
                ),
                if (space.description != null && space.description!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    space.description!,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${space.node} • ${space.domain}',
                  style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 24),
                // Action Row
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ActionChip(
                        label: Text(isJoined ? 'LEAVE SPACE' : 'JOIN SPACE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: isJoined ? theme.colorScheme.error : theme.colorScheme.onSecondary)),
                        onPressed: () async {
                          if (isJoined) {
                            await auth.leavePersistedSpace(space.domain, space.node);
                          } else {
                            await auth.joinPersistedSpace(space.domain, space.node, space.name);
                          }
                        },
                        avatar: Icon(isJoined ? Icons.bookmark_remove_rounded : Icons.bookmark_add_rounded, size: 18, color: isJoined ? theme.colorScheme.error : theme.colorScheme.onSecondary),
                        backgroundColor: isJoined ? theme.colorScheme.errorContainer.withValues(alpha: 0.3) : theme.colorScheme.secondary,
                        side: BorderSide.none,
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('JOIN ALL ROOMS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
                        onPressed: () async {
                          final chat = Provider.of<ChatProvider>(context, listen: false);
                          final acc = auth.activeAccountId;
                          if (acc == null) return;
                          final nick = auth.getResolvedNickname(acc);
                          for (var item in items.where((e) => e.type == 'room')) {
                            await auth.joinXmppRoom(item.id, nick, accountId: acc);
                          }
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Joining all rooms...')));
                          Navigator.pop(context);
                        },
                        avatar: const Icon(Icons.group_add_rounded, size: 16),
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        side: BorderSide.none,
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('DELETE SPACE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
                        onPressed: () => _confirmDeleteSpace(context),
                        avatar: Icon(Icons.delete_forever_rounded, size: 16, color: theme.colorScheme.error),
                        backgroundColor: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                        side: BorderSide.none,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          // Content Area
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${items.length} ITEMS AVAILABLE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                TextButton.icon(
                  onPressed: () => _showAddRoomDialog(context),
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                  label: const Text('ADD ROOM', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(child: Text('This space is empty.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      IconData icon;
                      switch (item.type) {
                        case 'room': icon = Icons.chat_bubble_rounded; break;
                        case 'url': icon = Icons.link_rounded; break;
                        case 'subscription': icon = Icons.subscriptions_rounded; break;
                        default: icon = Icons.insert_drive_file_rounded;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.black.withValues(alpha: 0.02),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          leading: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: theme.colorScheme.onPrimaryContainer, size: 20),
                          ),
                          title: Text(item.name ?? item.id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          subtitle: Text(item.type.toUpperCase(), style: TextStyle(fontSize: 10, color: theme.colorScheme.primary, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                          trailing: _buildTrailingAction(context, item),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget? _buildTrailingAction(BuildContext context, SpaceItem item) {
    if (item.type == 'room') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5),
            onPressed: () async {
              final auth = Provider.of<AuthService>(context, listen: false);
              final conn = auth.activeXmppConnection;
              if (conn == null) return;
              final success = await SpacesService(conn).removeRoomFromSpace(space.domain, space.node, item.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Room removed.' : 'Failed to remove room.')));
                if (success) Navigator.pop(context);
              }
            },
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            onPressed: () async {
              final chatProvider = Provider.of<ChatProvider>(context, listen: false);
              final authService = Provider.of<AuthService>(context, listen: false);
              final accountId = authService.activeAccountId;
              
              if (accountId != null) {
                final nickname = authService.getResolvedNickname(accountId);
                await authService.joinXmppRoom(item.id, nickname, accountId: accountId);
                chatProvider.setActiveConversation(item.id);
              }
              
              if (context.mounted) {
                Navigator.pop(context); // Close sheet
                Navigator.pop(context); // Close spaces screen
              }
            },
            child: const Text('JOIN', style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      );
    } else if (item.type == 'url' && item.url != null) {
      return IconButton(
        icon: const Icon(Icons.open_in_browser_rounded),
        color: Theme.of(context).colorScheme.primary,
        onPressed: () async {
          final uri = Uri.parse(item.url!);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
      );
    } else if (item.type == 'subscription' && item.node != null) {
      return IconButton(
        icon: const Icon(Icons.chevron_right_rounded),
        color: Theme.of(context).colorScheme.primary,
        onPressed: () => onNavigateSpace(item.node!),
      );
    } else if (item.type == 'unknown' && item.url != null) {
      return IconButton(
        icon: const Icon(Icons.code_rounded),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Unknown Item XML'),
              content: SingleChildScrollView(
                child: Text(item.url!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CLOSE'),
                ),
              ],
            ),
          );
        },
      );
    }
    return null;
  }
}