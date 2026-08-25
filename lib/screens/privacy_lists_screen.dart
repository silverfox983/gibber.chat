import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class PrivacyListsScreen extends StatefulWidget {
  const PrivacyListsScreen({super.key});

  @override
  State<PrivacyListsScreen> createState() => _PrivacyListsScreenState();
}

class _PrivacyListsScreenState extends State<PrivacyListsScreen> {
  List<String> _lists = [];
  String? _activeList;
  String? _defaultList;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  Future<void> _loadLists() async {
    final auth = context.read<AuthService>();
    if (!auth.isPrivacyListsSupported()) {
      if (mounted) setState(() { _isLoading = false; _error = 'Privacy lists not supported by your server'; });
      return;
    }
    try {
      final lists = await auth.getPrivacyLists();
      final active = await auth.getActivePrivacyList();
      final def = await auth.getDefaultPrivacyList();
      if (mounted) setState(() { _lists = lists; _activeList = active; _defaultList = def; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _error = e.toString(); });
    }
  }

  Future<void> _createList() async {
    final name = await _showNameDialog('New Privacy List');
    if (name == null || name.isEmpty) return;
    try {
      await context.read<AuthService>().createPrivacyList(name, []);
      await _loadLists();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _deleteList(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete List?', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text('Are you sure you want to delete "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await context.read<AuthService>().removePrivacyList(name);
      await _loadLists();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _setActive(String name) async {
    try {
      await context.read<AuthService>().setActivePrivacyList(name);
      await _loadLists();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<String?> _showNameDialog(String title, {String? initial}) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'List name', hintText: 'e.g., block_spam'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('SAVE')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Privacy Lists'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _loadLists),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: _createList,
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          TextButton(onPressed: () => context.pop(), child: const Text('Go Back')),
        ],
      ),
    );
    if (_lists.isEmpty) return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('No privacy lists yet', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          const Text('Tap + to create one', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _lists.length,
      itemBuilder: (context, index) {
        final list = _lists[index];
        final isActive = list == _activeList;
        final isDefault = list == _defaultList;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
              width: isActive ? 2 : 1,
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: Icon(
              isActive ? Icons.shield_rounded : Icons.shield_outlined,
              color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey,
            ),
            title: Text(list, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Row(
              children: [
                if (isActive) Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('ACTIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                ),
                if (isDefault) Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('DEFAULT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber)),
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'activate': _setActive(list); break;
                  case 'delete': _deleteList(list); break;
                  case 'edit': context.pushNamed('privacy_edit', extra: list); break;
                }
              },
              itemBuilder: (ctx) => [
                if (!isActive) const PopupMenuItem(value: 'activate', child: Text('Set as Active')),
                const PopupMenuItem(value: 'edit', child: Text('Edit Rules')),
                if (!isActive) const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.redAccent))),
              ],
            ),
            onTap: () => context.pushNamed('privacy_edit', extra: list),
          ),
        );
      },
    );
  }
}
