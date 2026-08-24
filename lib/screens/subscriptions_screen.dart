import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/space_models.dart';
import '../models/unified_community.dart';
import '../services/auth_service.dart';
import '../services/spaces_service.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  bool _isLoading = true;
  String? _error;
  List<SpaceNode> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _loadSubscriptions();
  }

  Future<void> _loadSubscriptions() async {
    setState(() { _isLoading = true; _error = null; });

    final auth = Provider.of<AuthService>(context, listen: false);
    final spacesService = auth.spacesService;
    if (spacesService == null) {
      setState(() { _isLoading = false; _error = 'Not connected'; });
      return;
    }

    final accountId = auth.activeAccountId;
    if (accountId == null) {
      setState(() { _isLoading = false; _error = 'No active account'; });
      return;
    }

    final pubsubServices = auth.getPubsubServices(accountId);
    if (pubsubServices.isEmpty) {
      final userDomain = auth.activeXmppConnection?.fullJid.domain;
      if (userDomain != null) {
        pubsubServices.add('pubsub.$userDomain');
      }
    }

    try {
      final subs = await spacesService.fetchMySubscriptions(pubsubServices);
      if (mounted) {
        setState(() {
          _subscriptions = subs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isLoading = false; _error = e.toString(); });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Subscriptions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSubscriptions,
          ),
        ],
      ),
      body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loadSubscriptions,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _subscriptions.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.rss_feed, size: 64, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                      'No subscriptions yet',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Explore communities to follow their posts',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: _loadSubscriptions,
                child: ListView.builder(
                  itemCount: _subscriptions.length,
                  itemBuilder: (context, index) {
                    final space = _subscriptions[index];
                    return _SubscriptionTile(
                      space: space,
                      onUnsubscribe: () async {
                        final auth = Provider.of<AuthService>(context, listen: false);
                        final spacesService = auth.spacesService;
                        if (spacesService != null) {
                          await spacesService.unsubscribeFromSpace(
                            space.domain, space.node,
                            auth.activeXmppConnection?.fullJid.userAtDomain ?? '',
                            spaceType: space.type,
                          );
                          setState(() {
                            _subscriptions.removeWhere((s) => s.domain == space.domain && s.node == space.node);
                          });
                        }
                      },
                    );
                  },
                ),
              ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  final SpaceNode space;
  final VoidCallback onUnsubscribe;

  const _SubscriptionTile({required this.space, required this.onUnsubscribe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: CircleAvatar(
        backgroundImage: space.avatarUrl != null ? NetworkImage(space.avatarUrl!) : null,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: space.avatarUrl == null
            ? Text(space.name.isNotEmpty ? space.name[0].toUpperCase() : '?')
            : null,
      ),
      title: Text(space.name.isNotEmpty ? space.name : space.node),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${space.node}@${space.domain}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (space.affiliation != null)
            Chip(
              label: Text(space.affiliation!),
              labelStyle: theme.textTheme.labelSmall,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'unsubscribe') {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Unsubscribe'),
                content: Text('Stop following "${space.name}"?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      onUnsubscribe();
                    },
                    child: const Text('Unsubscribe'),
                  ),
                ],
              ),
            );
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'unsubscribe', child: Text('Unsubscribe')),
        ],
      ),
      isThreeLine: space.affiliation != null,
    );
  }
}
