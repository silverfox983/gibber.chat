import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/transport_models.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/gateway_service.dart';
import 'gateway_registration_sheet.dart';

enum GatewayOfferState { available, registered, needsBridge }

/// One connectable network surfaced in the gateway sheet.
class GatewayOffer {
  final TransportNode node;
  final GatewayInfo? backendInfo;
  final bool registered;

  const GatewayOffer({
    required this.node,
    this.backendInfo,
    required this.registered,
  });

  String get displayName => backendInfo?.name ?? node.name;
  IconData get icon => backendInfo?.iconData ?? Icons.hub_rounded;
  bool get isReady =>
      backendInfo == null ||
      (backendInfo!.enabled && backendInfo!.status != 'disabled');
}

/// The single cohesive entry point for "connect a network": local gateway
/// discovery + backend availability + XEP-0077 registration dialogs + direct
/// IRC room joins, in one bottom sheet.
Future<void> showGatewayConnectSheet(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const GatewayConnectSheet(),
  );
}

class GatewayConnectSheet extends StatefulWidget {
  const GatewayConnectSheet({super.key});

  @override
  State<GatewayConnectSheet> createState() => _GatewayConnectSheetState();
}

class _GatewayConnectSheetState extends State<GatewayConnectSheet> {
  List<GatewayOffer> _offers = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    final transportService = auth.transportService;
    if (conn == null || transportService == null) {
      if (mounted) {
        setState(() {
          _error = 'Not connected yet.';
          _loading = false;
        });
      }
      return;
    }

    final gateways = Provider.of<GatewayService>(context, listen: false);

    // Backend-reported availability (component jids + statuses).
    Map<String, GatewayInfo> backend = {};
    try {
      final response = await gateways.listGateways();
      backend = response.gateways;
    } catch (_) {}

    // Local discovery over disco (finds every gateway component on the server).
    final nodes = <TransportNode>[];
    try {
      await transportService.discoverTransports(
        conn.fullJid.domain,
        onGatewayDiscovered: nodes.add,
        maxDepth: 2,
      );
    } catch (e) {
      debugPrint('GatewaySheet: discovery error: $e');
    }

    if (!mounted) return;

    // Fallback: derive offers directly from the backend list when disco finds
    // nothing (e.g. filtered discovery).
    if (nodes.isEmpty && backend.isNotEmpty) {
      for (final entry in backend.entries) {
        final info = entry.value;
        if (info.componentJid.isEmpty) continue;
        nodes.add(TransportNode(
          jid: info.componentJid,
          name: info.name,
          type: entry.key,
        ));
      }
    }

    // Merge with registered transports from the local store.
    List<Map<String, String>> registered = [];
    try {
      final raw = await DatabaseService().getRegisteredTransports();
      registered = raw.map((row) => row.map((k, v) => MapEntry(k as String, v?.toString() ?? ''))).toList();
    } catch (_) {}
    final registeredJids = registered.map((r) => ((r['gateway_jid'] ?? r['jid'] ?? '') as String).toLowerCase()).toSet();

    final offers = <GatewayOffer>[];
    final seen = <String>{};
    for (final node in nodes) {
      if (!seen.add(node.jid.toLowerCase())) continue;
      offers.add(GatewayOffer(
        node: node,
        backendInfo: backend[_typeFor(node, backend)],
        registered: registeredJids.contains(node.jid.toLowerCase()),
      ));
    }

    offers.sort((a, b) {
      if (a.isReady != b.isReady) return a.isReady ? -1 : 1;
      if (a.registered != b.registered) return a.registered ? -1 : 1;
      return a.displayName.compareTo(b.displayName);
    });

    setState(() {
      _offers = offers;
      _loading = false;
      if (offers.isEmpty) {
        _error = 'No networks to connect on this server — enable gateways with '
            'docker compose --profile slidge up.';
      }
    });
  }

  String _typeFor(TransportNode node, Map<String, GatewayInfo> backend) {
    final lower = node.jid.toLowerCase();
    for (final entry in backend.entries) {
      if (lower.contains(entry.key)) return entry.key;
    }
    return node.type;
  }

  Future<void> _connect(GatewayOffer offer) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final transportService = auth.transportService;
    if (transportService == null) return;
    final result = await showGatewayRegistrationSheet(
      context: context,
      transportService: transportService,
      gatewayJid: offer.node.jid,
      gatewayName: offer.displayName,
    );
    if (result == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _joinIrcRoom() {
    Navigator.of(context).pop();
    context.pushNamed('joinRoom');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Container(
      constraints: const BoxConstraints(maxHeight: 560),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, color: primary, size: 22),
              const SizedBox(width: 10),
              Text('Connect a network', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Bridges live on your server: chat with Telegram, Discord, '
            'WhatsApp, Matrix and IRC contacts from the same app.',
            style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: _loading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _error != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 22),
                        child: Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _offers.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _buildJoinIrcTile(theme, primary);
                          }
                          return _buildOfferTile(theme, _offers[index - 1]);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinIrcTile(ThemeData theme, Color primary) {
    return InkWell(
      onTap: _joinIrcRoom,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primary.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.tag_rounded, color: primary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Join an IRC room', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: theme.colorScheme.onSurface)),
                  Text('Pick a trending room or type #channel@irc-server', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildOfferTile(ThemeData theme, GatewayOffer offer) {
    final primary = theme.colorScheme.primary;
    final color = offer.isReady
        ? (offer.registered ? Colors.green : primary)
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);

    return InkWell(
      onTap: offer.isReady ? () => _connect(offer) : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(offer.icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    offer.displayName,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: theme.colorScheme.onSurface),
                  ),
                  Text(
                    offer.node.jid,
                    style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                offer.registered
                    ? 'Connected'
                    : (offer.isReady ? 'Connect' : 'Offline'),
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}