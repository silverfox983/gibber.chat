import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/transport_service.dart';
import '../models/transport_models.dart';
import '../widgets/transport_registration_dialog.dart';

class TransportsScreen extends StatefulWidget {
  const TransportsScreen({super.key});

  @override
  State<TransportsScreen> createState() => _TransportsScreenState();
}

class _TransportsScreenState extends State<TransportsScreen> {
  TransportService? _transportService;
  bool _isLoading = true;
  String _statusText = 'Discovering gateways…';
  final List<TransportNode> _gateways = [];
  final Set<String> _seenJids = {};
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initTransports());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _transportService?.dispose();
    super.dispose();
  }

  Future<void> _searchTransport(String jid) async {
    final trimmed = jid.trim();
    if (trimmed.isEmpty || _transportService == null) return;
    
    setState(() {
      _isLoading = true;
      _statusText = 'Probing $trimmed…';
    });

    try {
      await _transportService!.discoverTransports(trimmed, onGatewayDiscovered: (gw) {
        if (!_seenJids.contains(gw.jid) && mounted) {
          _seenJids.add(gw.jid);
          setState(() {
            _gateways.add(gw);
            _isLoading = false;
          });
        }
      });
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to probe $trimmed')));
      }
    }
  }

  Future<void> _initTransports() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;

    if (conn == null) {
      if (mounted) setState(() { _isLoading = false; _statusText = 'Not connected.'; });
      return;
    }

    _transportService?.dispose();
    _transportService = TransportService(conn);

    final domain = conn.fullJid.domain;

    // Reset state on refresh
    if (mounted) {
      setState(() {
        _gateways.clear();
        _seenJids.clear();
        _isLoading = true;
        _statusText = 'Searching $domain…';
      });
    }

    void onGatewayFound(TransportNode gw) {
      if (!_seenJids.contains(gw.jid) && mounted) {
        _seenJids.add(gw.jid);
        setState(() {
          _gateways.add(gw);
          _isLoading = false;
        });
      }
    }

    // Discover strictly on the user's own server
    try {
      await _transportService!.discoverTransports(domain, onGatewayDiscovered: (gw) {
        onGatewayFound(gw);
      });
    } catch (e) {
      debugPrint('Local discovery error: $e');
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (_gateways.isEmpty) {
          _statusText = 'No gateways found on your server.';
        } else {
          _statusText = 'Discovery complete. Found ${_gateways.length} local gateway${_gateways.length == 1 ? '' : 's'}.';
        }
      });
    }
  }

  // ── Type metadata ────────────────────────────────────────────
  _GatewayMeta _metaForType(String type) {
    switch (type.toLowerCase()) {
      case 'discord':
        return _GatewayMeta(Icons.discord, const Color(0xFF5865F2), 'Discord');
      case 'irc':
        return _GatewayMeta(Icons.tag_rounded, const Color(0xFF7B68EE), 'IRC');
      case 'sms':
        return _GatewayMeta(Icons.sms_rounded, const Color(0xFF43A047), 'SMS');
      case 'telegram':
        return _GatewayMeta(Icons.telegram_rounded, const Color(0xFF26A5E4), 'Telegram');
      case 'whatsapp':
        return _GatewayMeta(Icons.chat_rounded, const Color(0xFF25D366), 'WhatsApp');
      case 'xmpp':
        return _GatewayMeta(Icons.hub_rounded, const Color(0xFF006EFF), 'XMPP');
      case 'mattermost':
        return _GatewayMeta(Icons.grid_view_rounded, const Color(0xFF0058CC), 'Mattermost');
      case 'slack':
        return _GatewayMeta(Icons.grid_on_rounded, const Color(0xFF4A154B), 'Slack');
      case 'matrix':
        return _GatewayMeta(Icons.dns_rounded, const Color(0xFF0DBD8B), 'Matrix');
      default:
        return _GatewayMeta(Icons.compare_arrows_rounded, const Color(0xFF9E9E9E), type.isNotEmpty ? type[0].toUpperCase() + type.substring(1) : 'Gateway');
    }
  }

  Future<void> _showRegistrationDialog(TransportNode gateway) async {
    if (_transportService == null) return;
    final entitlement = Provider.of<EntitlementService>(context, listen: false);
    final protocol = gateway.type.isNotEmpty ? gateway.type[0].toUpperCase() + gateway.type.substring(1).toLowerCase() : '';
    if (!entitlement.isProtocolAllowed(protocol)) {
      if (!mounted) return;
      final currentTier = entitlement.currentTier;
      final neededTier = protocol == 'Slack' || protocol == 'Discord' || protocol == 'Irc'
          ? UserTier.pro : UserTier.ultimate;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Upgrade Required'),
          content: Text(
            '$protocol is available on the ${neededTier.label} tier.\n'
            'You are currently on the ${currentTier.label} tier.\n\n'
            'Mine credits to upgrade, or enter a redemption code.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                context.goNamed('tier');
              },
              child: Text('Upgrade'),
            ),
          ],
        ),
      );
      return;
    }
    await showTransportRegistrationDialog(
      context: context,
      transportService: _transportService!,
      gatewayJid: gateway.jid,
      gatewayName: gateway.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Gateways & Transports',
                style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 18)),
            if (_gateways.isNotEmpty)
              Text('${_gateways.length} available',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600)),
          ],
        ),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        actions: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
              onPressed: _initTransports,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Specify gateway JID (e.g., telegram.hot-chilli.im)',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
              onSubmitted: _searchTransport,
            ),
          ),
          
          // ── Status bar ──
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            color: _isLoading
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Icon(
                _isLoading ? Icons.radar_rounded : Icons.check_circle_outline_rounded,
                size: 14,
                color: _isLoading
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                _statusText,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: _isLoading
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ]),
          ),

          // ── Gateway list ──
          Expanded(
            child: _gateways.isEmpty && !_isLoading
                ? _buildEmptyState(theme)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _gateways.length,
                    itemBuilder: (ctx, i) => _buildGatewayCard(theme, isDark, _gateways[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGatewayCard(ThemeData theme, bool isDark, TransportNode gw) {
    final meta = _metaForType(gw.type);
    final cardColor = isDark
        ? meta.color.withValues(alpha: 0.10)
        : meta.color.withValues(alpha: 0.07);
    final entitlement = Provider.of<EntitlementService>(context);
    final protocol = gw.type.isNotEmpty ? gw.type[0].toUpperCase() + gw.type.substring(1).toLowerCase() : '';
    final isLocked = !entitlement.isProtocolAllowed(protocol);
    final neededTier = protocol == 'Slack' || protocol == 'Discord' || protocol == 'Irc'
        ? UserTier.pro : UserTier.ultimate;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isLocked ? Colors.orange.withValues(alpha: 0.5) : meta.color.withValues(alpha: 0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(color: meta.color.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showRegistrationDialog(gw),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // ── Icon bubble ──
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: isLocked
                      ? Stack(alignment: Alignment.center, children: [
                          Icon(meta.icon, color: meta.color.withValues(alpha: 0.4), size: 26),
                          Positioned(bottom: 2, right: 2, child: Icon(Icons.lock_rounded, size: 14, color: Colors.orange)),
                        ])
                      : Icon(meta.icon, color: meta.color, size: 26),
                ),
                const SizedBox(width: 14),
                // ── Info ──
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(gw.name, style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 16)),
                        if (isLocked) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('${neededTier.label} only',
                                style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.orange)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: meta.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          meta.label,
                          style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: meta.color),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Action ──
                Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isLocked ? Colors.orange : meta.color,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(isLocked ? 'Upgrade' : 'Connect',
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.hub_outlined, size: 72,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.25)),
              const SizedBox(height: 24),
              Text('No Local Gateways',
                  style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              Text(
                'Your home server does not currently advertise any transport gateways.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 14, height: 1.6,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _initTransports,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GatewayMeta {
  final IconData icon;
  final Color color;
  final String label;
  const _GatewayMeta(this.icon, this.color, this.label);
}
