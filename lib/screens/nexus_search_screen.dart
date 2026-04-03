import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/chat_provider.dart';
import '../models/chat_models.dart';

class NexusSearchScreen extends StatefulWidget {
  const NexusSearchScreen({super.key});

  @override
  State<NexusSearchScreen> createState() => _NexusSearchScreenState();
}

class _NexusSearchScreenState extends State<NexusSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedProtocol = 'All';

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);
    final results = _selectedProtocol == 'All' 
        ? chatProvider.globalSearchResults 
        : chatProvider.globalSearchResults.where((m) => m.protocol == _selectedProtocol).toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Nexus Search', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 1. Search Bar Surface
          Container(
            padding: const EdgeInsets.all(20),
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  decoration: InputDecoration(
                    hintText: 'Search across all accounts...',
                    prefixIcon: const Icon(Icons.travel_explore_rounded),
                    suffixIcon: _searchController.text.isNotEmpty 
                        ? IconButton(icon: const Icon(Icons.close), onPressed: () {
                            _searchController.clear();
                            chatProvider.searchGlobalMessages('');
                          })
                        : null,
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (val) => chatProvider.searchGlobalMessages(val),
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: ['All', 'XMPP', 'IRC', 'Discord'].map((p) {
                      final isSelected = _selectedProtocol == p;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(p),
                          selected: isSelected,
                          onSelected: (val) => setState(() => _selectedProtocol = p),
                          selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          labelStyle: TextStyle(
                            fontWeight: FontWeight.bold, 
                            color: isSelected ? Theme.of(context).colorScheme.primary : Colors.black45
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          // 2. Results List
          Expanded(
            child: results.isEmpty 
                ? _buildEmptyState(chatProvider.isSyncing)
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final msg = results[index];
                      return _buildResultTile(msg, chatProvider);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(ChatMessage msg, ChatProvider chatProvider) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          child: Icon(
            msg.protocol == 'Discord' ? Icons.discord : (msg.protocol == 'IRC' ? Icons.alternate_email : Icons.chat_bubble_outline),
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(msg.senderName ?? msg.senderId!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
            Text(DateFormat('MMM d, HH:mm').format(msg.timestamp), style: const TextStyle(fontSize: 10, color: Colors.black26)),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(msg.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Colors.black87)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
              child: Text(msg.conversationId ?? 'Global', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black38)),
            ),
          ],
        ),
        onTap: () {
          if (msg.conversationId != null) {
            chatProvider.setActiveConversation(msg.conversationId!);
            chatProvider.setSidebarTab(0);
            Navigator.pop(context);
          }
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isSyncing) {
    if (isSyncing) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 64, color: Colors.black.withValues(alpha: 0.05)),
          const SizedBox(height: 16),
          Text(
            _searchController.text.isEmpty ? 'Search for any message...' : 'No results found',
            style: const TextStyle(color: Colors.black26, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
