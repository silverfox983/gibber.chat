import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import './create_room_screen.dart';

class RoomDiscoveryScreen extends StatefulWidget {
  const RoomDiscoveryScreen({super.key});

  @override
  State<RoomDiscoveryScreen> createState() => _RoomDiscoveryScreenState();
}

class _RoomDiscoveryScreenState extends State<RoomDiscoveryScreen> {
  final TextEditingController _serviceController = TextEditingController(text: 'conference.jabb3r.org');
  List<Map<String, String>> _rooms = [];
  bool _isLoading = false;
  String? _error;

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
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _joinRoom(String roomJid, String roomName) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = authService.activeAccountId;
    if (accountId == null) return;

    final nickname = authService.currentProfile?.nickName ?? authService.currentProfile?.displayName ?? 'User';
    
    await authService.joinRoom(accountId, roomJid, nickname);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Joined $roomName'), backgroundColor: Colors.green),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Discover Rooms', style: TextStyle(fontWeight: FontWeight.w900)),
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            color: theme.colorScheme.primary,
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
                      controller: _serviceController,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        hintText: 'MUC Service (e.g. conference.server.id)',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.search_rounded, color: Colors.white, size: 28),
                  onPressed: _searchRooms,
                ),
              ],
            ),
          ),
          if (_isLoading)
            Expanded(child: Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)))
          else if (_error != null)
             Expanded(child: Center(child: Text('Error: $_error', style: const TextStyle(color: Colors.red))))
          else if (_rooms.isEmpty)
             const Expanded(child: Center(child: Text('Enter a MUC service to discover rooms', style: TextStyle(color: Colors.black38))))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _rooms.length,
                itemBuilder: (context, index) {
                  final room = _rooms[index];
                  return Card(
                    color: theme.cardColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: theme.dividerColor)),
                    margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                    elevation: 0,
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                        child: Icon(Icons.groups_rounded, color: theme.colorScheme.primary),
                      ),
                      title: Text(room['name'] ?? 'Untitled Room', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      subtitle: Text(room['jid'] ?? '', style: TextStyle(color: theme.hintColor)),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () => _joinRoom(room['jid']!, room['name']!),
                        child: const Text('JOIN'),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const CreateRoomScreen()),
          );
        },
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('CREATE ROOM'),
      ),
    );
  }
}
