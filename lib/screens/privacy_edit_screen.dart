import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class PrivacyEditScreen extends StatefulWidget {
  final String listName;
  const PrivacyEditScreen({super.key, required this.listName});

  @override
  State<PrivacyEditScreen> createState() => _PrivacyEditScreenState();
}

class _PrivacyEditScreenState extends State<PrivacyEditScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  Future<void> _loadList() async {
    try {
      final auth = context.read<AuthService>();
      final items = await auth.getPrivacyListItems(widget.listName);
      if (mounted) setState(() { _items = items; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _error = e.toString(); });
    }
  }

  Future<void> _addRule() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddRuleSheet(
        order: _items.length,
        onSave: (item) => Navigator.pop(ctx, item),
      ),
    );
    if (result == null) return;
    setState(() => _items.add(result));
    await _saveList();
  }

  Future<void> _removeRule(int index) async {
    setState(() => _items.removeAt(index));
    await _saveList();
  }

  Future<void> _saveList() async {
    try {
      final auth = context.read<AuthService>();
      await auth.createPrivacyList(widget.listName, _items);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Privacy list saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(widget.listName),
        actions: [IconButton(icon: const Icon(Icons.save_rounded), onPressed: _saveList)],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.rule_outlined, size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text('No rules in this list', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(onPressed: _addRule, icon: const Icon(Icons.add), label: const Text('Add Rule')),
                        ],
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _items.length,
                      onReorder: (oldIdx, newIdx) {
                        setState(() {
                          if (newIdx > oldIdx) newIdx -= 1;
                          final item = _items.removeAt(oldIdx);
                          _items.insert(newIdx, item);
                          for (var i = 0; i < _items.length; i++) {
                            _items[i]['order'] = i;
                          }
                        });
                        _saveList();
                      },
                      itemBuilder: (ctx, index) {
                        final item = _items[index];
                        final isAllow = item['action'] == 'allow';
                        return Container(
                          key: ValueKey('$index'),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Theme.of(context).colorScheme.outline),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            leading: Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: (isAllow ? Colors.green : Colors.red).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Icon(isAllow ? Icons.check_rounded : Icons.block_rounded,
                                  color: isAllow ? Colors.green : Colors.red),
                            ),
                            title: Text(
                              item['type'] == 'jid' ? item['value'] : '${item['type']}: ${item['value']}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            subtitle: Wrap(
                              spacing: 4,
                              children: [
                                if (item['block_messages'] == true) _chip('Messages', Colors.orange),
                                if (item['block_iq'] == true) _chip('IQs', Colors.purple),
                                if (item['block_presence_in'] == true) _chip('Incoming Presence', Colors.blue),
                                if (item['block_presence_out'] == true) _chip('Outgoing Presence', Colors.indigo),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                                  onPressed: () => _removeRule(index),
                                ),
                                const Icon(Icons.drag_handle_rounded, color: Colors.grey),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
      floatingActionButton: _items.isNotEmpty
          ? FloatingActionButton(onPressed: _addRule, child: const Icon(Icons.add_rounded))
          : null,
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }
}

class _AddRuleSheet extends StatefulWidget {
  final int order;
  final Function(Map<String, dynamic>) onSave;
  const _AddRuleSheet({required this.order, required this.onSave});

  @override
  State<_AddRuleSheet> createState() => _AddRuleSheetState();
}

class _AddRuleSheetState extends State<_AddRuleSheet> {
  final _valueController = TextEditingController();
  String _type = 'jid';
  String _action = 'deny';
  bool _blockMessages = true;
  bool _blockIq = false;
  bool _blockPresenceIn = false;
  bool _blockPresenceOut = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 24, right: 24, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(
                color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2),
              )),
            ),
            const SizedBox(height: 20),
            const Text('Add Privacy Rule', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 20),
            const Text('Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'jid', label: Text('JID')),
                ButtonSegment(value: 'group', label: Text('Group')),
                ButtonSegment(value: 'subscription', label: Text('Subscription')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: _type == 'jid' ? 'JID (e.g., spam@example.com)'
                    : _type == 'group' ? 'Group name'
                    : 'Subscription (both / to / from)',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Action', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'deny', label: Text('Block'), icon: Icon(Icons.block_rounded)),
                ButtonSegment(value: 'allow', label: Text('Allow'), icon: Icon(Icons.check_rounded)),
              ],
              selected: {_action},
              onSelectionChanged: (s) => setState(() => _action = s.first),
            ),
            const SizedBox(height: 16),
            const Text('Block', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilterChip(label: const Text('Messages'), selected: _blockMessages, onSelected: (v) => setState(() => _blockMessages = v)),
                FilterChip(label: const Text('IQs'), selected: _blockIq, onSelected: (v) => setState(() => _blockIq = v)),
                FilterChip(label: const Text('Incoming Presence'), selected: _blockPresenceIn, onSelected: (v) => setState(() => _blockPresenceIn = v)),
                FilterChip(label: const Text('Outgoing Presence'), selected: _blockPresenceOut, onSelected: (v) => setState(() => _blockPresenceOut = v)),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (_valueController.text.isEmpty) return;
                  widget.onSave({
                    'type': _type,
                    'value': _valueController.text.trim(),
                    'action': _action,
                    'order': widget.order,
                    'block_messages': _blockMessages,
                    'block_iq': _blockIq,
                    'block_presence_in': _blockPresenceIn,
                    'block_presence_out': _blockPresenceOut,
                  });
                },
                child: const Text('ADD RULE'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
