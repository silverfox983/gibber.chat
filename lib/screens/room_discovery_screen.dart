import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/xmpp_room_enhancements_service.dart';

class RoomDiscoveryScreen extends StatefulWidget {
  const RoomDiscoveryScreen({super.key});

  @override
  State<RoomDiscoveryScreen> createState() => _RoomDiscoveryScreenState();
}

class _RoomDiscoveryScreenState extends State<RoomDiscoveryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _serviceController = TextEditingController(text: 'conference.jabb3r.org');
  final TextEditingController _filterController = TextEditingController();
  final TextEditingController _channelSearchController = TextEditingController();
  final TextEditingController _channelSearchServiceController = TextEditingController(text: 'search.jabb3r.org');
  List<Map<String, dynamic>> _rooms = [];
  List<ChannelSearchResult> _channelResults = [];
  bool _isLoading = false;
  bool _isChannelSearching = false;
  String? _error;
  String? _channelSearchError;

  List<Map<String, dynamic>> get _filteredRooms {
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) return _rooms;
    return _rooms.where((room) {
      final name = (room['name'] ?? '').toString().toLowerCase();
      final topic = (room['topic'] ?? '').toString().toLowerCase();
      final desc = (room['description'] ?? '').toString().toLowerCase();
      return name.contains(query) || topic.contains(query) || desc.contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _serviceController.dispose();
    _filterController.dispose();
    _channelSearchController.dispose();
    _channelSearchServiceController.dispose();
    super.dispose();
  }

  Future<void> _searchRooms() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final accountId = authService.activeAccountId;
      if (accountId == null) throw 'No active account';

      final results = await authService.discoverMucRooms(accountId, _serviceController.text.trim());
      setState(() {
        _rooms = results;
        _isLoading = false;
      });
      
      // Asynchronously fetch extended room info
      for (var i = 0; i < results.length; i++) {
        final index = i;
        authService.getMucRoomInfo(accountId, results[index]['jid']!).then((info) {
          if (mounted && index < _rooms.length) {
            setState(() {
              _rooms[index]['users'] = info['users'] ?? _rooms[index]['users'];
              _rooms[index]['topic'] = info['topic'] ?? _rooms[index]['topic'];
              _rooms[index]['description'] = info['description'] ?? _rooms[index]['description'];
              _rooms[index]['password_protected'] = info['password_protected'] ?? false;
            });
          }
        }).catchError((_) {});
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _joinRoom(Map<String, dynamic> room) async {
    final roomJid = room['jid'] as String;
    final roomName = room['name'] as String;
    final isLocked = room['password_protected'] == true;

    String? password;
    if (isLocked) {
      password = await _showPasswordDialog(roomName);
      if (password == null) return; // User cancelled
    }

    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = authService.activeAccountId;
    if (accountId == null) return;

    final nickname = authService.getResolvedNickname(accountId);
    
    final error = await authService.joinXmppRoom(roomJid, nickname, accountId: accountId, password: password);
    
    if (mounted) {
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to join: $error'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined $roomName'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<String?> _showPasswordDialog(String roomName) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Password Required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('The room "$roomName" is protected by a password.'),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Room Password',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('JOIN'),
          ),
        ],
      ),
    );
  }

  Future<void> _searchChannels() async {
    final query = _channelSearchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isChannelSearching = true;
      _channelSearchError = null;
    });

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final accountId = authService.activeAccountId;
      if (accountId == null) throw 'No active account';

      final results = await authService.channelSearchService.searchChannels(
        accountId: accountId,
        searchService: _channelSearchServiceController.text.trim(),
        query: query,
      );
      if (mounted) {
        setState(() {
          _channelResults = results;
          _isChannelSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _channelSearchError = e.toString();
          _isChannelSearching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filtered = _filteredRooms;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Discover Rooms'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.dns_rounded), text: 'Browse'),
            Tab(icon: Icon(Icons.search_rounded), text: 'Search'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBrowseTab(theme, isDark, filtered),
          _buildChannelSearchTab(theme, isDark),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () {
          context.goNamed('createRoom');
        },
        backgroundColor: theme.colorScheme.tertiary,
        foregroundColor: theme.colorScheme.onTertiary,
        elevation: 6,
        icon: const Icon(Icons.add_rounded),
        label: const Text('CREATE ROOM', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }

  Widget _buildBrowseTab(ThemeData theme, bool isDark, List<Map<String, dynamic>> filtered) {
    return Column(
        children: [
          // Header / Search area
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              children: [
                // Server query row
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.white24,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: TextField(
                          controller: _serviceController,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            hintText: 'MUC Service (e.g. conference.server.id)',
                            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                            border: InputBorder.none,
                            prefixIcon: Icon(Icons.dns_rounded, color: Colors.white.withValues(alpha: 0.7)),
                          ),
                          onSubmitted: (_) => _searchRooms(),
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
                        icon: Icon(Icons.search_rounded, color: theme.colorScheme.onSecondary, size: 28),
                        onPressed: _searchRooms,
                      ),
                    ),
                  ],
                ),
                // Local Filter Row (only if rooms loaded)
                if (_rooms.isNotEmpty && !_isLoading) ...[
                  const SizedBox(height: 16),
                  Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _filterController,
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Filter results...',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                        border: InputBorder.none,
                        icon: Icon(Icons.filter_list_rounded, color: Colors.white.withValues(alpha: 0.8), size: 18),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          // Content Area
          if (_isLoading)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: theme.colorScheme.secondary),
                    const SizedBox(height: 16),
                    Text('Discovering rooms...', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            )
          else if (_error != null)
             Expanded(
               child: Center(
                 child: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     Icon(Icons.error_outline_rounded, color: theme.colorScheme.error, size: 48),
                     const SizedBox(height: 16),
                     Text('Discovery Failed', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold, fontSize: 18)),
                     const SizedBox(height: 8),
                     Text(_error!, style: TextStyle(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
                   ],
                 ),
               ),
             )
          else if (_rooms.isEmpty)
             Expanded(
               child: Center(
                 child: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     Icon(Icons.travel_explore_rounded, color: theme.colorScheme.primary.withValues(alpha: 0.3), size: 80),
                     const SizedBox(height: 16),
                     Text('Enter a MUC service to discover rooms', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                   ],
                 ),
               ),
             )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80), // Padding for FAB
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final room = filtered[index];
                  final isLocked = room['password_protected'] == true;
                  final occupantCount = room['users'] ?? '?';
                  final topic = room['topic'];
                  
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
                      onTap: () {
                        final authService = Provider.of<AuthService>(context, listen: false);
                        final accountId = authService.activeAccountId;
                        if (accountId != null) {
                          context.goNamed('roomInfo', extra: {'room': room, 'accountId': accountId});
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Avatar
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
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
                                child: Icon(
                                  isLocked ? Icons.lock_rounded : Icons.groups_rounded,
                                  color: theme.colorScheme.onPrimaryContainer,
                                  size: 24,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            
                            // Content
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    room['name'] ?? 'Untitled Room',
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    room['jid'] ?? '',
                                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (topic != null && topic.toString().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      topic.toString(),
                                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13, fontStyle: FontStyle.italic),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.person_outline_rounded, size: 12, color: theme.colorScheme.onSurfaceVariant),
                                            const SizedBox(width: 4),
                                            Text('$occupantCount users', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: theme.colorScheme.secondary,
                                          foregroundColor: theme.colorScheme.onSecondary,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          elevation: 4,
                                          shadowColor: theme.colorScheme.secondary.withValues(alpha: 0.5),
                                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                          minimumSize: const Size(0, 36),
                                        ),
                                        onPressed: () => _joinRoom(room),
                                        child: const Text('JOIN', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
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
                },
              ),
            ),
        ],
    );
  }

  Widget _buildChannelSearchTab(ThemeData theme, bool isDark) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.white24,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: _channelSearchServiceController,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          hintText: 'Search service (e.g. search.jabb3r.org)',
                          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                          border: InputBorder.none,
                          prefixIcon: Icon(Icons.dns_rounded, color: Colors.white.withValues(alpha: 0.7)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.white24,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: _channelSearchController,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          hintText: 'Search channels by name...',
                          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                          border: InputBorder.none,
                          prefixIcon: Icon(Icons.search_rounded, color: Colors.white.withValues(alpha: 0.7)),
                        ),
                        onSubmitted: (_) => _searchChannels(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: theme.colorScheme.secondary.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
                      ],
                    ),
                    child: IconButton(
                      icon: Icon(Icons.search_rounded, color: theme.colorScheme.onSecondary, size: 28),
                      onPressed: _searchChannels,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (_isChannelSearching)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_channelSearchError != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, color: theme.colorScheme.error, size: 48),
                  const SizedBox(height: 16),
                  Text('Search Failed', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  Text(_channelSearchError!, style: TextStyle(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
                ],
              ),
            ),
          )
        else if (_channelResults.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.travel_explore_rounded, color: theme.colorScheme.primary.withValues(alpha: 0.3), size: 80),
                  const SizedBox(height: 16),
                  Text('Search for channels by keyword', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('XEP-0433 Channel Search', style: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 12)),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              itemCount: _channelResults.length,
              itemBuilder: (context, index) {
                final result = _channelResults[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(color: isDark ? Colors.black26 : Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      final room = {
                        'jid': result.jid,
                        'name': result.name ?? result.jid.split('@').first,
                        'description': result.description,
                        'users': result.occupants?.toString() ?? '?',
                      };
                      final authService = Provider.of<AuthService>(context, listen: false);
                      final accountId = authService.activeAccountId;
                      if (accountId != null) {
                        context.goNamed('roomInfo', extra: {'room': room, 'accountId': accountId});
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Icon(
                                result.isOpen == true ? Icons.public_rounded : Icons.lock_rounded,
                                color: theme.colorScheme.onPrimaryContainer,
                                size: 24,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  result.name ?? result.jid.split('@').first,
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  result.jid,
                                  style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (result.description != null && result.description!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    result.description!,
                                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13, fontStyle: FontStyle.italic),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    if (result.occupants != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.person_outline_rounded, size: 12, color: theme.colorScheme.onSurfaceVariant),
                                            const SizedBox(width: 4),
                                            Text('${result.occupants} users', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                    if (result.language != null) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.tertiaryContainer,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(result.language!.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.onTertiaryContainer)),
                                      ),
                                    ],
                                    if (result.isOpen == true) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text('Open', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green)),
                                      ),
                                    ],
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
              },
            ),
          ),
      ],
    );
  }
}
