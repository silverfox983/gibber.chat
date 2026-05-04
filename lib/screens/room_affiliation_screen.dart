import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../services/auth_service.dart';

class RoomAffiliationScreen extends StatefulWidget {
  final Conversation room;

  const RoomAffiliationScreen({super.key, required this.room});

  @override
  State<RoomAffiliationScreen> createState() => _RoomAffiliationScreenState();
}

class _RoomAffiliationScreenState extends State<RoomAffiliationScreen> {
  bool _isLoading = true;
  List<Map<String, String>> _outcasts = [];
  List<Map<String, String>> _members = [];

  @override
  void initState() {
    super.initState();
    _fetchAffiliations();
  }

  Future<void> _fetchAffiliations() async {
    setState(() => _isLoading = true);
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.room.accountId ?? authService.activeAccountId;
    
    if (accountId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final outcasts = await authService.fetchRoomAffiliations(accountId, widget.room.id, 'outcast');
    final members = await authService.fetchRoomAffiliations(accountId, widget.room.id, 'member');
    
    if (mounted) {
      setState(() {
        _outcasts = outcasts;
        _members = members;
        _isLoading = false;
      });
    }
  }

  Future<void> _updateAffiliation(String jid, String affiliation) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.room.accountId ?? authService.activeAccountId;
    if (accountId == null) return;

    // Use existing method to set affiliation
    await authService.setMucAffiliation(accountId, widget.room.id, jid, affiliation);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated affiliation for $jid to $affiliation')),
      );
      _fetchAffiliations();
    }
  }

  Future<void> _showAddUserDialog(String affiliation) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add ${affiliation == 'outcast' ? 'Ban' : 'Member'}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'User JID',
            hintText: 'user@example.com',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('ADD'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _updateAffiliation(result, affiliation);
    }
  }

  Widget _buildList(List<Map<String, String>> list, String type, IconData icon, Color iconColor) {
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Text('No $type found.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }

    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final jid = list[index]['jid'] ?? 'Unknown';
        return ListTile(
          leading: Icon(icon, color: iconColor),
          title: Text(jid),
          trailing: IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.red),
            tooltip: 'Remove',
            onPressed: () => _updateAffiliation(jid, 'none'),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bans & Members'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'BANNED'),
              Tab(text: 'MEMBERS'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _fetchAffiliations,
              tooltip: 'Refresh',
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // Bans Tab
                  Column(
                    children: [
                      Expanded(child: _buildList(_outcasts, 'banned users', Icons.block, Colors.red)),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: ElevatedButton.icon(
                          onPressed: () => _showAddUserDialog('outcast'),
                          icon: const Icon(Icons.add),
                          label: const Text('BAN USER BY JID'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.withValues(alpha: 0.1),
                            foregroundColor: Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Members Tab
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'Members list is primarily used for invite-only rooms.',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Expanded(child: _buildList(_members, 'members', Icons.person, theme.colorScheme.primary)),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: ElevatedButton.icon(
                          onPressed: () => _showAddUserDialog('member'),
                          icon: const Icon(Icons.add),
                          label: const Text('ADD PRE-APPROVED MEMBER'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
