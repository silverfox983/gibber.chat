import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/breakpoints.dart';
import '../core/design_tokens.dart';
import '../core/app_colors.dart';
import '../models/user_gateway.dart';
import '../models/transport_models.dart';
import '../services/auth_service.dart';
import '../services/bridge_config_service.dart';
import '../services/gateway_service.dart';
import '../services/transport_service.dart';
import '../services/database_service.dart';
import '../services/backend_config.dart';
import '../services/jwt_token_service.dart';
import '../services/sip_gateway_config.dart';
import '../widgets/transport_registration_dialog.dart';
import '../widgets/add_transport_contact_dialog.dart';

enum _ConnectionsTab { bridges, discover }

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> with SingleTickerProviderStateMixin {
  _ConnectionsTab _currentTab = _ConnectionsTab.bridges;

  // ─── Bridges tab state ──────────────────────────────────────────
  late final JwtTokenService _jwtService;
  late BridgeConfigService _bridgeService;
  bool _bridgesLoading = true;
  String? _bridgesError;
  Timer? _statusPoller;
  late AnimationController _pulseController;
  final Map<String, String> _previousGatewayStatuses = {};
  String _sipGatewayDomain = 'cheogram.com';

  // ─── Discover tab state ─────────────────────────────────────────
  TransportService? _transportService;
  bool _isDiscovering = true;
  bool _isSearching = false;
  String _statusText = 'Discovering gateways…';
  final List<TransportNode> _gateways = [];
  final Set<String> _seenJids = {};
  final Set<String> _registeredJids = {};
  final TextEditingController _searchController = TextEditingController();
  Map<String, GatewayInfo> _serverGateways = {};
  bool _serverGatewaysLoading = true;
  String? _serverGatewaysError;

  @override
  void initState() {
    super.initState();
    _jwtService = JwtTokenService();
    _bridgeService = BridgeConfigService(_jwtService);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    _initBridges();
    _initDiscover();
  }

  // ─── Bridges ────────────────────────────────────────────────────

  Future<void> _initBridges() async {
    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    await _jwtService.init(apiUrl: backendConfig.apiUrl);
    await _loadUserGateways();
    await _loadRegisteredTransports();
    final sipDomain = await SipGatewayConfig.getGatewayJid();
    if (mounted) setState(() => _sipGatewayDomain = sipDomain);
    _startStatusPolling();
  }

  void _startStatusPolling() {
    _statusPoller?.cancel();
    _statusPoller = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _pollBridgesStatus();
    });
  }

  Future<void> _pollBridgesStatus() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;
    await _bridgeService.listUserGateways(userId);
    if (!mounted) return;

    final current = <String, String>{};
    for (final g in _bridgeService.userGateways) {
      current[g.gatewayType] = g.status;
    }

    for (final entry in current.entries) {
      final type = entry.key;
      final status = entry.value;
      final previous = _previousGatewayStatuses[type];
      final name = GatewayTypeInfo.available[type]?.name ?? type;

      if (previous != null && previous != status) {
        if (status == 'running') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$name bridge connected'), behavior: SnackBarBehavior.floating),
          );
        } else if (status == 'error') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name bridge failed to start'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (previous == 'running' && status != 'running') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name bridge stopped unexpectedly'),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }

    _previousGatewayStatuses.clear();
    _previousGatewayStatuses.addAll(current);
  }

  Future<void> _loadUserGateways() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) {
      setState(() { _bridgesLoading = false; _bridgesError = 'Not logged in'; });
      return;
    }
    setState(() => _bridgesLoading = true);
    await _bridgeService.listUserGateways(userId);
    if (mounted) {
      setState(() {
        _bridgesLoading = false;
        _bridgesError = _bridgeService.error;
      });
      _previousGatewayStatuses.clear();
      for (final g in _bridgeService.userGateways) {
        _previousGatewayStatuses[g.gatewayType] = g.status;
      }
    }
  }

  UserGateway? _gatewayForType(String type) {
    try {
      return _bridgeService.userGateways.firstWhere((g) => g.gatewayType == type);
    } catch (_) {
      return null;
    }
  }

  // ─── Discover ───────────────────────────────────────────────────

  Future<void> _initDiscover() async {
    _initTransports();
    _loadServerGateways();
  }

  Future<void> _loadRegisteredTransports() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final accountId = auth.activeAccountId;
    if (accountId == null) return;
    final db = DatabaseService();
    final all = await db.getRegisteredTransports();
    if (!mounted) return;
    setState(() {
      _registeredJids.clear();
      for (var row in all) {
        final rowAccountId = row['account_id'] as String?;
        if (rowAccountId == accountId) {
          final jid = (row['gateway_jid'] as String?)?.toLowerCase();
          if (jid != null) _registeredJids.add(jid);
        }
      }
    });
  }

  Future<void> _initTransports() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    if (conn == null) {
      if (mounted) setState(() { _isDiscovering = false; _statusText = 'Not connected.'; });
      return;
    }
    if (_transportService == null) {
      _transportService = TransportService(conn);
      _transportService!.setDatabase(DatabaseService());
      _transportService!.setAccountId(auth.activeAccountId);
      _transportService!.startListening();
    }
    final domain = conn.fullJid.domain;
    if (mounted) {
      setState(() { _gateways.clear(); _seenJids.clear(); _isDiscovering = true; _statusText = 'Searching $domain…'; });
    }
    await _loadRegisteredTransports();
    void onGatewayFound(TransportNode gw) {
      if (!_seenJids.contains(gw.jid) && mounted) {
        _seenJids.add(gw.jid);
        setState(() => _gateways.add(gw));
      }
    }
    try {
      await _transportService!.discoverTransports(domain, onGatewayDiscovered: onGatewayFound);
    } catch (e) {
      debugPrint('Local discovery error: $e');
    }
    if (mounted) {
      setState(() {
        _isDiscovering = false;
        _statusText = _gateways.isEmpty
            ? 'No gateways found on your server.'
            : 'Discovery complete. Found ${_gateways.length} local gateway${_gateways.length == 1 ? '' : 's'}.';
      });
    }
  }

  Future<void> _searchTransport(String jid) async {
    final trimmed = jid.trim();
    if (trimmed.isEmpty || _transportService == null) return;
    setState(() { _isSearching = true; _statusText = 'Probing $trimmed…'; });
    try {
      await _transportService!.discoverTransports(trimmed, onGatewayDiscovered: (gw) {
        if (!_seenJids.contains(gw.jid) && mounted) {
          _seenJids.add(gw.jid);
          setState(() => _gateways.add(gw));
        }
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to probe $trimmed')));
    } finally {
      if (mounted) setState(() {
        _isSearching = false;
        _statusText = 'Discovery complete. Found ${_gateways.length} local gateway${_gateways.length == 1 ? '' : 's'}.';
      });
    }
  }

  Future<void> _loadServerGateways() async {
    setState(() { _serverGatewaysLoading = true; _serverGatewaysError = null; });
    try {
      final service = context.read<GatewayService>();
      final response = await service.listGateways();
      if (mounted) {
        setState(() {
          _serverGateways = response.error == null ? response.gateways : {};
          _serverGatewaysError = response.error;
          _serverGatewaysLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _serverGatewaysError = 'Error loading gateways: $e'; _serverGatewaysLoading = false; });
    }
  }

  @override
  void dispose() {
    _statusPoller?.cancel();
    _pulseController.dispose();
    _searchController.dispose();
    _jwtService.dispose();
    super.dispose();
  }

  // ─── UI Router ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/logo.png', height: 24, width: 24),
            const SizedBox(width: 12),
            const Text('Connections', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          ],
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              if (_currentTab == _ConnectionsTab.bridges) {
                _loadUserGateways();
              } else {
                _initDiscover();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTabBar(theme),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: switch (_currentTab) {
                _ConnectionsTab.bridges => _buildBridgesTab(theme),
                _ConnectionsTab.discover => _buildDiscoverTab(theme),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(child: _tabButton(theme, _ConnectionsTab.bridges, Icons.hub_rounded, 'My Bridges')),
            Expanded(child: _tabButton(theme, _ConnectionsTab.discover, Icons.explore_rounded, 'Discover')),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(ThemeData theme, _ConnectionsTab tab, IconData icon, String label) {
    final selected = _currentTab == tab;
    return GestureDetector(
      onTap: () => setState(() => _currentTab = tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 2))] : [],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            )),
          ],
        ),
      ),
    );
  }

  // ─── Bridges Tab ────────────────────────────────────────────────

  Widget _buildBridgesTab(ThemeData theme) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildBridgesHeader(theme)),
        if (_bridgesLoading)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (_bridgesError != null && _bridgeService.userGateways.isEmpty)
          SliverFillRemaining(child: _BridgesErrorState(error: _bridgesError!, onRetry: _loadUserGateways))
        else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _buildPlatformGrid(theme),
                  const SizedBox(height: DesignTokens.space24),
                  _buildSipCard(theme),
                  const SizedBox(height: DesignTokens.space32),
                  _buildInfoCard(theme),
                  const SizedBox(height: DesignTokens.space48),
                ]),
              ),
            ),
      ],
    );
  }

  Widget _buildBridgesHeader(ThemeData theme) {
    final connected = _bridgeService.userGateways.where((g) => g.enabled).length;
    final total = 5;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$connected of $total bridges connected', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
            const SizedBox(height: 2),
            Text('Configure your platform bridges', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ],
        )),
        IconButton.outlined(
          icon: const Icon(Icons.person_add_alt_1_rounded),
          tooltip: 'Add contact via transport',
          onPressed: () => showAddTransportContactDialog(
            context: context,
            transportService: _transportService,
            extraGateways: _runningBridgeGateways,
          ),
        ),
      ]),
    );
  }

  bool _isBridgeComponentRegistered(String? componentJid) {
    if (componentJid == null) return false;
    return _registeredJids.contains(componentJid.toLowerCase());
  }

  List<Map<String, String>> get _runningBridgeGateways {
    return _bridgeService.userGateways
        .where((g) => g.enabled && g.status == 'running' && g.componentJid != null)
        .map((g) => {
              'jid': g.componentJid!,
              'name': GatewayTypeInfo.available[g.gatewayType]?.name ?? g.gatewayType,
              'type': g.gatewayType,
            })
        .toList();
  }

  Widget _buildPlatformGrid(ThemeData theme) {
    final platforms = ['telegram', 'discord', 'irc', 'matrix', 'whatsapp', 'steam'];

    return Column(
      children: platforms.map((p) {
        final gateway = _gatewayForType(p);
        return Padding(
          padding: const EdgeInsets.only(bottom: DesignTokens.space12),
          child: _PlatformCard(
            platform: p,
            gateway: gateway,
            bridgeService: _bridgeService,
            isRegistered: _isBridgeComponentRegistered(gateway?.componentJid),
            onConfigure: () => _showConfigDialog(context, p),
            onEnable: () => _enableBridge(context, p),
            onDisable: () => _disableBridge(context, p),
            onRemove: () => _removeBridge(context, p),
            onRegister: () => _registerBridgeComponent(gateway?.componentJid ?? '', GatewayTypeInfo.available[p]!.name),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSipCard(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        child: InkWell(
          onTap: _showSipConfigDialog,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(DesignTokens.space20),
            child: Row(children: [
              Container(width: 48, height: 48, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(DesignTokens.radiusMd)), child: Icon(Icons.phone_forwarded_rounded, color: AppColors.primary, size: 24)),
              const SizedBox(width: DesignTokens.space12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SIP / Phone Calls', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface)),
                const SizedBox(height: 2),
                Text('Gateway: $_sipGatewayDomain', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant, fontFamily: 'monospace')),
              ])),
              Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _showSipConfigDialog() async {
    final controller = TextEditingController(text: _sipGatewayDomain);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SIP Gateway'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PSTN gateway domain used for phone calls and SMS routing.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Gateway domain',
                hintText: 'cheogram.com',
                prefixIcon: Icon(Icons.dns_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final domain = controller.text.trim().toLowerCase();
      if (domain.isNotEmpty) {
        await SipGatewayConfig.setGatewayJid(domain);
        setState(() => _sipGatewayDomain = domain);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SIP gateway set to $domain'), behavior: SnackBarBehavior.floating),
        );
      }
    }
    controller.dispose();
  }

  Future<void> _showConfigDialog(BuildContext context, String type) async {
    final info = GatewayTypeInfo.available[type]!;
    final auth = Provider.of<AuthService>(context, listen: false);
    final existing = _gatewayForType(type);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _BridgeConfigSheet(
        type: type,
        info: info,
        existingGateway: existing,
        bridgeService: _bridgeService,
        authService: auth,
      ),
    );
    if (result != null && mounted) await _saveConfig(type, result, wasEnabled: existing?.enabled == true);
  }

  Future<void> _enableBridge(BuildContext context, String type) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;
    final result = await _bridgeService.enableGateway(userId, type);
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${GatewayTypeInfo.available[type]!.name} connecting…'), behavior: SnackBarBehavior.floating),
      );
      await _loadRegisteredTransports();
      if (mounted && result.componentJid != null && !_registeredJids.contains(result.componentJid!.toLowerCase())) {
        _showBridgeRegistrationPrompt(type, result.componentJid!);
      }
    } else if (_bridgeService.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_bridgeService.error!), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _showBridgeRegistrationPrompt(String type, String componentJid) {
    final name = GatewayTypeInfo.available[type]?.name ?? type;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$name bridge is running'),
        content: Text('Register with $componentJid to start searching for $name contacts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _registerBridgeComponent(componentJid, name);
            },
            child: const Text('Register'),
          ),
        ],
      ),
    );
  }

  Future<void> _registerBridgeComponent(String componentJid, String name) async {
    if (_transportService == null) return;
    await showTransportRegistrationDialog(
      context: context,
      transportService: _transportService!,
      gatewayJid: componentJid,
      gatewayName: name,
    );
    await _loadRegisteredTransports();
  }

  Future<void> _disableBridge(BuildContext context, String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Bridge'),
        content: Text('Are you sure you want to disconnect ${GatewayTypeInfo.available[type]!.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), style: FilledButton.styleFrom(backgroundColor: AppColors.danger), child: const Text('Disconnect')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final auth = Provider.of<AuthService>(context, listen: false);
      final userId = auth.activeAccountId;
      if (userId == null) return;
      await _bridgeService.disableGateway(userId, type);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${GatewayTypeInfo.available[type]!.name} disconnected'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _removeBridge(BuildContext context, String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Bridge'),
        content: Text('This will permanently remove your ${GatewayTypeInfo.available[type]!.name} bridge configuration.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), style: FilledButton.styleFrom(backgroundColor: AppColors.danger), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final auth = Provider.of<AuthService>(context, listen: false);
      final userId = auth.activeAccountId;
      if (userId == null) return;
      await _bridgeService.removeGateway(userId, type);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${GatewayTypeInfo.available[type]!.name} bridge removed'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _saveConfig(String type, Map<String, dynamic> config, {bool wasEnabled = false}) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;

    if (wasEnabled) {
      await _bridgeService.disableGateway(userId, type);
      if (!mounted) return;
    }

    final result = await _bridgeService.configureGateway(userId: userId, type: type, config: config);
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${GatewayTypeInfo.available[type]!.name} configured'), behavior: SnackBarBehavior.floating),
      );
      if (wasEnabled) {
        await _enableBridge(context, type);
      }
    } else if (_bridgeService.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_bridgeService.error!), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating),
      );
    }
  }

  Widget _buildInfoCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(DesignTokens.space20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primarySurface, AppColors.primarySurface.withValues(alpha: 0.6)],
        ),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(DesignTokens.space12),
          decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
          child: Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 24),
        ),
        const SizedBox(width: DesignTokens.space16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Isolated & Secure', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 4),
          Text('Each platform runs in its own isolated container with your personal credentials.', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
        ])),
      ]),
    );
  }

  // ─── Discover Tab ──────────────────────────────────────────────

  Widget _buildDiscoverTab(ThemeData theme) {
    return CustomScrollView(
      slivers: [
        // ── Transports section ──
        SliverToBoxAdapter(child: _buildTransportsSection(theme)),
        // ── Server gateways section ──
        SliverToBoxAdapter(child: _buildServerGatewaysSection(theme)),
        SliverToBoxAdapter(child: const SizedBox(height: 48)),
      ],
    );
  }

  Widget _buildTransportsSection(ThemeData theme) {
    final isLoading = _isDiscovering || _isSearching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('DISCOVER TRANSPORTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          color: isLoading ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            Icon(isLoading ? Icons.radar_rounded : Icons.check_circle_outline_rounded, size: 14,
                color: isLoading ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            Expanded(child: Text(_statusText, style: TextStyle(fontSize: 12, color: isLoading ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)))),
          ]),
        ),
        const SizedBox(height: 8),
        if (_gateways.isEmpty && !isLoading)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Column(children: [
              Icon(Icons.hub_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2)),
              const SizedBox(height: 12),
              Text('No local gateways found', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            ])),
          )
        else
          ...List.generate(_gateways.length, (i) => _buildTransportCard(theme, _gateways[i])),
      ],
    );
  }

  Widget _buildTransportCard(ThemeData theme, TransportNode gw) {
    final meta = _transportMeta(gw.type);
    final cardColor = meta.color.withValues(alpha: 0.10);
    final bareJid = gw.jid.split('/').first.toLowerCase();
    final isRegistered = _registeredJids.contains(bareJid);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: meta.color.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showTransportRegistration(gw),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12)),
                child: Stack(alignment: Alignment.center, children: [
                  Icon(meta.icon, color: meta.color, size: 22),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(gw.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
                  if (isRegistered) ...[
                    const SizedBox(width: 6),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                        child: const Text('Registered', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.green))),
                  ],
                ]),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: meta.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                  child: Text(meta.label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: meta.color)),
                ),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isRegistered ? Colors.green : meta.color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(isRegistered ? 'Connected' : 'Connect',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _showTransportRegistration(TransportNode gateway) async {
    if (_transportService == null) return;
    final success = await showTransportRegistrationDialog(
      context: context,
      transportService: _transportService!,
      gatewayJid: gateway.jid,
      gatewayName: gateway.name,
    );
    if (success == true) { await _loadRegisteredTransports(); }
  }

  _TransportMeta _transportMeta(String type) {
    switch (type.toLowerCase()) {
      case 'discord': return _TransportMeta(Icons.discord, const Color(0xFF5865F2), 'Discord');
      case 'irc': return _TransportMeta(Icons.tag_rounded, const Color(0xFF7B68EE), 'IRC');
      case 'sms': return _TransportMeta(Icons.sms_rounded, const Color(0xFF43A047), 'SMS');
      case 'telegram': return _TransportMeta(Icons.telegram_rounded, const Color(0xFF26A5E4), 'Telegram');
      case 'whatsapp': return _TransportMeta(Icons.chat_rounded, const Color(0xFF25D366), 'WhatsApp');
      case 'xmpp': return _TransportMeta(Icons.hub_rounded, const Color(0xFF006EFF), 'Gibber');
      case 'mattermost': return _TransportMeta(Icons.grid_view_rounded, const Color(0xFF0058CC), 'Mattermost');
      case 'slack': return _TransportMeta(Icons.grid_on_rounded, const Color(0xFF4A154B), 'Slack');
      case 'matrix': return _TransportMeta(Icons.dns_rounded, const Color(0xFF0DBD8B), 'Matrix');
      case 'steam': return _TransportMeta(Icons.games_rounded, const Color(0xFF1B2838), 'Steam');
      default: return _TransportMeta(Icons.compare_arrows_rounded, const Color(0xFF9E9E9E), type.isNotEmpty ? type[0].toUpperCase() + type.substring(1) : 'Gateway');
    }
  }

  Widget _buildServerGatewaysSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Row(
            children: [
              Text('SERVER GATEWAYS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Admin', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.orange)),
              ),
            ],
          ),
        ),
        if (_serverGatewaysLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (_serverGatewaysError != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_serverGatewaysError!, style: TextStyle(fontSize: 12, color: theme.colorScheme.error))),
                ],
              ),
            ),
          )
        else if (_serverGateways.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: Text('No server gateways configured', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))),
          )
        else
          ..._serverGateways.entries.map((e) => _ServerGatewayCard(gateway: e.value, onStatusChanged: _loadServerGateways)),
      ],
    );
  }
}

class _TransportMeta {
  final IconData icon;
  final Color color;
  final String label;
  const _TransportMeta(this.icon, this.color, this.label);
}

// ─── Bridges widgets ────────────────────────────────────────────────────────

class _BridgesErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _BridgesErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.error_outline_rounded, size: 48, color: AppColors.danger),
      const SizedBox(height: 16),
      Text(error, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      FilledButton(onPressed: onRetry, child: const Text('Retry')),
    ]));
  }
}

class _PlatformCard extends StatelessWidget {
  final String platform;
  final UserGateway? gateway;
  final BridgeConfigService bridgeService;
  final bool isRegistered;
  final VoidCallback onConfigure;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onRemove;
  final VoidCallback onRegister;

  const _PlatformCard({
    required this.platform, required this.gateway, required this.bridgeService,
    required this.isRegistered, required this.onConfigure,
    required this.onEnable, required this.onDisable, required this.onRemove,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final info = GatewayTypeInfo.available[platform]!;
    final isConnected = gateway?.enabled == true && gateway?.status == 'running';
    final isConfigured = gateway != null;
    final isStarting = gateway?.status == 'starting' || gateway?.status == 'configuring';
    final platformColor = _platformColor(platform);

    return Container(
      decoration: BoxDecoration(
        gradient: isConnected
            ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [platformColor.withValues(alpha: 0.15), platformColor.withValues(alpha: 0.05)])
            : null,
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        border: Border.all(
          color: isConnected ? platformColor.withValues(alpha: 0.5) : theme.colorScheme.outline,
          width: isConnected ? 2 : 1,
        ),
        boxShadow: isConnected
            ? [BoxShadow(color: platformColor.withValues(alpha: 0.2), blurRadius: 16, spreadRadius: 0)]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        child: InkWell(
          onTap: onConfigure,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(DesignTokens.space20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _PlatformIcon(platform: platform, color: platformColor, isConnected: isConnected),
                  const SizedBox(width: DesignTokens.space12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(info.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 2),
                    _StatusBadge(isConnected: isConnected, isConfigured: isConfigured, isStarting: isStarting, platformColor: platformColor),
                  ])),
                  _StatusIndicator(isConnected: isConnected, isStarting: isStarting, color: platformColor),
                ]),
                const SizedBox(height: DesignTokens.space16),
                if (isConfigured && gateway?.componentJid != null) ...[
                  Text(gateway!.componentJid!, style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: DesignTokens.space12),
                ],
                Row(children: [
                  if (isConnected) ...[
                    if (!isRegistered) ...[
                      Expanded(child: _ActionButton(label: 'Register', icon: Icons.app_registration_rounded, onPressed: onRegister, color: platformColor, filled: true)),
                      const SizedBox(width: DesignTokens.space8),
                    ],
                    Expanded(child: _ActionButton(label: 'Disconnect', icon: Icons.link_off_rounded, onPressed: onDisable, color: AppColors.danger, filled: false)),
                  ] else if (isConfigured) ...[
                    Expanded(child: _ActionButton(label: 'Connect', icon: Icons.play_arrow_rounded, onPressed: isStarting ? null : onEnable, color: platformColor, filled: true)),
                    const SizedBox(width: DesignTokens.space8),
                    Expanded(child: _ActionButton(label: 'Edit', icon: Icons.settings_rounded, onPressed: onConfigure, color: theme.colorScheme.onSurfaceVariant, filled: false)),
                  ] else ...[
                    Expanded(child: _ActionButton(label: 'Configure', icon: Icons.add_rounded, onPressed: onConfigure, color: platformColor, filled: true)),
                  ],
                ]),
                if (isConnected) ...[
                  const SizedBox(height: DesignTokens.space8),
                  SizedBox(width: double.infinity, child: TextButton.icon(
                    onPressed: onRemove,
                    icon: Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.danger),
                    label: Text('Remove bridge', style: TextStyle(color: AppColors.danger, fontSize: 12)),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                  )),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _platformColor(String platform) {
    switch (platform) {
      case 'telegram': return AppColors.telegram;
      case 'discord': return AppColors.discord;
      case 'irc': return AppColors.irc;
      case 'matrix': return AppColors.matrix;
      case 'whatsapp': return AppColors.whatsapp;
      default: return AppColors.primary;
    }
  }
}

class _PlatformIcon extends StatelessWidget {
  final String platform;
  final Color color;
  final bool isConnected;
  const _PlatformIcon({required this.platform, required this.color, required this.isConnected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isConnected ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
        border: Border.all(color: color.withValues(alpha: isConnected ? 0.5 : 0.2)),
      ),
      child: Icon(_iconForPlatform(platform), color: color, size: 24),
    );
  }

  IconData _iconForPlatform(String platform) {
    switch (platform) {
      case 'telegram': return Icons.telegram_rounded;
      case 'discord': return Icons.discord_rounded;
      case 'irc': return Icons.tag_rounded;
      case 'matrix': return Icons.dns_rounded;
      case 'whatsapp': return Icons.chat_rounded;
      default: return Icons.hub_rounded;
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isConnected, isConfigured, isStarting;
  final Color platformColor;
  const _StatusBadge({required this.isConnected, required this.isConfigured, required this.isStarting, required this.platformColor});

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    if (isStarting) { label = 'Connecting…'; color = Colors.orange; }
    else if (isConnected) { label = 'Connected'; color = platformColor; }
    else if (isConfigured) { label = 'Configured'; color = Colors.grey; }
    else { label = 'Not configured'; color = Colors.grey; }
    return Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color));
  }
}

class _StatusIndicator extends StatelessWidget {
  final bool isConnected, isStarting;
  final Color color;
  const _StatusIndicator({required this.isConnected, required this.isStarting, required this.color});

  @override
  Widget build(BuildContext context) {
    if (isStarting) return SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color));
    return Container(width: 12, height: 12, decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: isConnected ? color : Colors.grey.shade400,
      boxShadow: isConnected ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)] : null,
    ));
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool filled;
  const _ActionButton({required this.label, required this.icon, required this.onPressed, required this.color, required this.filled});

  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))]);
    if (filled) return FilledButton(onPressed: onPressed, style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd))), child: child);
    return OutlinedButton(onPressed: onPressed, style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: color.withValues(alpha: 0.5)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd))), child: child);
  }
}

class _BridgeConfigSheet extends StatefulWidget {
  final String type;
  final GatewayTypeInfo info;
  final UserGateway? existingGateway;
  final BridgeConfigService bridgeService;
  final AuthService authService;
  const _BridgeConfigSheet({required this.type, required this.info, this.existingGateway, required this.bridgeService, required this.authService});
  @override
  State<_BridgeConfigSheet> createState() => _BridgeConfigSheetState();
}

class _BridgeConfigSheetState extends State<_BridgeConfigSheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  bool _isSaving = false;
  bool _isTesting = false;
  String? _testMessage;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    for (final field in [...widget.info.requiredFields, ...widget.info.optionalFields]) {
      _controllers[field] = TextEditingController(text: widget.existingGateway?.config[field]?.toString() ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final platformColor = _platformColor(widget.type);
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottomPadding),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: platformColor, width: 2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)))),
        Padding(padding: const EdgeInsets.all(DesignTokens.space20), child: Row(children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: platformColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
              child: Icon(_iconForPlatform(widget.type), color: platformColor, size: 24)),
          const SizedBox(width: DesignTokens.space12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Configure ${widget.info.name}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface)),
            Text(widget.info.description, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ])),
          IconButton(icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurfaceVariant), onPressed: () => Navigator.of(context).pop()),
        ])),
        const Divider(height: 1),
        Flexible(child: SingleChildScrollView(padding: const EdgeInsets.all(DesignTokens.space20), child: Form(key: _formKey, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.info.requiredFields.isNotEmpty) ...[
            _SectionLabel(label: 'REQUIRED'),
            const SizedBox(height: DesignTokens.space12),
            ...widget.info.requiredFields.map((f) => _buildField(f, required: true, isDark: isDark)),
          ],
          if (widget.info.optionalFields.isNotEmpty) ...[
            const SizedBox(height: DesignTokens.space20),
            _SectionLabel(label: 'OPTIONAL'),
            const SizedBox(height: DesignTokens.space12),
            ...widget.info.optionalFields.map((f) => _buildField(f, required: false, isDark: isDark)),
          ],
          if (_testMessage != null) ...[
            const SizedBox(height: DesignTokens.space20),
            Container(
              padding: const EdgeInsets.all(DesignTokens.space12),
              decoration: BoxDecoration(
                color: (_testSuccess == true ? Colors.green : AppColors.danger).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
              ),
              child: Row(children: [
                Icon(_testSuccess == true ? Icons.check_circle_rounded : Icons.error_rounded, color: _testSuccess == true ? Colors.green : AppColors.danger, size: 20),
                const SizedBox(width: DesignTokens.space8),
                Expanded(child: Text(_testMessage!, style: TextStyle(color: _testSuccess == true ? Colors.green : AppColors.danger, fontSize: 13))),
              ]),
            ),
          ],
        ])))),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(DesignTokens.space20), child: Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: (_isSaving || _isTesting) ? null : _test,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd))),
            child: _isTesting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Test'),
          )),
          const SizedBox(width: DesignTokens.space12),
          Expanded(flex: 2, child: FilledButton(
            onPressed: (_isSaving || _isTesting) ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: platformColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd))),
            child: _isSaving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_saveButtonLabel),
          )),
        ])),
      ]),
    );
  }

  Widget _buildField(String field, {required bool required, required bool isDark}) {
    final docUrl = _docUrlFor(field);
    return Padding(padding: const EdgeInsets.only(bottom: DesignTokens.space16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _controllers[field],
          obscureText: _isSensitive(field),
          decoration: InputDecoration(
            labelText: _labelFor(field),
            hintText: _hintFor(field),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd), borderSide: BorderSide(color: Theme.of(context).colorScheme.outline)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd), borderSide: BorderSide(color: AppColors.primary, width: 2)),
          ),
          validator: required ? (v) => v == null || v.isEmpty ? 'Required' : null : null,
        ),
        if (docUrl != null) ...[
          const SizedBox(height: 6),
          InkWell(
            onTap: () async {
              final uri = Uri.parse(docUrl);
              if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new_rounded, size: 14, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(_docLabelFor(field), style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ],
    ));
  }

  String get _saveButtonLabel {
    if (widget.existingGateway == null) return 'Configure & Connect';
    if (widget.existingGateway!.enabled) return 'Save & Restart';
    return 'Save Changes';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final config = <String, dynamic>{};
    for (final entry in _controllers.entries) {
      if (entry.value.text.isNotEmpty) config[entry.key] = entry.value.text;
    }
    Navigator.of(context).pop(config);
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isTesting = true;
      _testMessage = null;
      _testSuccess = null;
    });

    final config = <String, dynamic>{};
    for (final entry in _controllers.entries) {
      if (entry.value.text.isNotEmpty) config[entry.key] = entry.value.text;
    }

    try {
      final result = await widget.bridgeService.testGateway(type: widget.type, config: config);
      if (!mounted) return;
      if (result != null && result['valid'] == true) {
        setState(() {
          _testSuccess = true;
          _testMessage = result['message'] as String? ?? 'Configuration looks valid';
        });
      } else {
        setState(() {
          _testSuccess = false;
          _testMessage = result?['error'] as String? ?? 'Configuration test failed';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testSuccess = false;
        _testMessage = 'Test error: $e';
      });
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  bool _isSensitive(String field) => field.contains('token') || field.contains('password') || field.contains('secret') || field.contains('hash') || field.contains('key');
  String _labelFor(String field) => field.replaceAll('_', ' ').split(' ').map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '').join(' ');
  String _hintFor(String field) {
    switch (field) {
      case 'api_id': return 'e.g. 12345';
      case 'api_hash': return 'e.g. a1b2c3d4e5f6...';
      case 'bot_token': return 'Paste token from Discord Developer Portal';
      case 'homeserver_url': return 'https://matrix.org';
      case 'access_token': return 'Matrix access token';
      case 'server_hostname': return 'e.g. irc.libera.chat';
      case 'server_port': return 'e.g. 6697';
      case 'phone_number': return 'E.164 format, e.g. +1234567890';
      default: return '';
    }
  }

  String? _docUrlFor(String field) {
    switch (field) {
      case 'api_id':
      case 'api_hash':
        return 'https://my.telegram.org/apps';
      case 'bot_token':
        return 'https://discord.com/developers/applications';
      case 'access_token':
      case 'homeserver_url':
        return 'https://matrix.org';
      default:
        return null;
    }
  }

  String _docLabelFor(String field) {
    switch (field) {
      case 'api_id':
      case 'api_hash':
        return 'Get Telegram credentials';
      case 'bot_token':
        return 'Create Discord bot';
      case 'access_token':
      case 'homeserver_url':
        return 'Matrix homeserver info';
      default:
        return '';
    }
  }

  Color _platformColor(String platform) {
    switch (platform) {
      case 'telegram': return AppColors.telegram;
      case 'discord': return AppColors.discord;
      case 'irc': return AppColors.irc;
      case 'matrix': return AppColors.matrix;
      case 'whatsapp': return AppColors.whatsapp;
      default: return AppColors.primary;
    }
  }

  IconData _iconForPlatform(String platform) {
    switch (platform) {
      case 'telegram': return Icons.telegram_rounded;
      case 'discord': return Icons.discord_rounded;
      case 'irc': return Icons.tag_rounded;
      case 'matrix': return Icons.dns_rounded;
      case 'whatsapp': return Icons.chat_rounded;
      default: return Icons.hub_rounded;
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) => Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2));
}

// ─── Server gateway card ────────────────────────────────────────────────────

class _ServerGatewayCard extends StatelessWidget {
  final GatewayInfo gateway;
  final VoidCallback onStatusChanged;
  const _ServerGatewayCard({required this.gateway, required this.onStatusChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showDetails(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
                child: Icon(gateway.iconData, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(gateway.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
                const SizedBox(height: 2),
                Text(gateway.description, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: gateway.statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: gateway.statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(gateway.statusLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gateway.statusColor)),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: theme.colorScheme.outline, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ServerGatewayDetailsSheet(gateway: gateway, onStatusChanged: onStatusChanged),
    );
  }
}

class _ServerGatewayDetailsSheet extends StatefulWidget {
  final GatewayInfo gateway;
  final VoidCallback onStatusChanged;
  const _ServerGatewayDetailsSheet({required this.gateway, required this.onStatusChanged});
  @override
  State<_ServerGatewayDetailsSheet> createState() => _ServerGatewayDetailsSheetState();
}

class _ServerGatewayDetailsSheetState extends State<_ServerGatewayDetailsSheet> {
  bool _isLoading = false;

  Future<void> _enable() async {
    setState(() => _isLoading = true);
    final service = context.read<GatewayService>();
    final result = await service.enableGateway(widget.gateway.componentJid);
    if (mounted) {
      Navigator.pop(context);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? 'Gateway enabled'), behavior: SnackBarBehavior.floating, backgroundColor: result.error == null ? Colors.green : null));
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _disable() async {
    setState(() => _isLoading = true);
    final service = context.read<GatewayService>();
    final result = await service.disableGateway(widget.gateway.componentJid);
    if (mounted) {
      Navigator.pop(context);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? 'Gateway disabled'), behavior: SnackBarBehavior.floating, backgroundColor: result.error == null ? Colors.green : null));
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _showSetupInstructions() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('Setup ${widget.gateway.name}'),
      content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('To enable the ${widget.gateway.name} gateway, you need to:', style: Theme.of(ctx).textTheme.bodyMedium),
        const SizedBox(height: 16),
        const Text('1. Set the following environment variables on your server:'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(_getEnvVarsText(), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        const SizedBox(height: 16),
        const Text('2. Restart the Prosody server'),
        const SizedBox(height: 16),
        const Text('3. Return to this screen to verify the gateway is active'),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
    ));
  }

  String _getEnvVarsText() {
    final prefix = widget.gateway.componentJid.toUpperCase();
    final buffer = StringBuffer();
    buffer.writeln('# Enable ${widget.gateway.name} gateway');
    buffer.writeln('GIBBER_${prefix}_ENABLED=true');
    buffer.writeln('GIBBER_${prefix}_SECRET=your-secret-here');
    for (final config in widget.gateway.requiresConfig) {
      buffer.writeln('${config.toUpperCase()}=your-$config-here');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: theme.colorScheme.outline.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2))),
          Expanded(child: ListView(controller: scrollController, padding: const EdgeInsets.all(20), children: [
            Row(children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
                  child: Icon(widget.gateway.iconData, size: 32, color: theme.colorScheme.primary)),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.gateway.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: widget.gateway.statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Text(widget.gateway.statusLabel, style: theme.textTheme.labelSmall?.copyWith(color: widget.gateway.statusColor, fontWeight: FontWeight.bold))),
              ])),
            ]),
            const SizedBox(height: 24),
            _DetailSection(title: 'Description', children: [Text(widget.gateway.description)]),
            const SizedBox(height: 16),
            _DetailSection(title: 'Component JID', children: [Text('${widget.gateway.componentJid}.gibberapp.online', style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'))]),
            if (widget.gateway.requiresConfig.isNotEmpty) ...[
              const SizedBox(height: 16),
              _DetailSection(title: 'Required Configuration', children: [Wrap(spacing: 8, runSpacing: 8, children: widget.gateway.requiresConfig.map((c) => Chip(label: Text(c), backgroundColor: theme.colorScheme.surfaceContainerHighest)).toList())]),
            ],
            const SizedBox(height: 16),
            _DetailSection(title: 'Docker Image', children: [Text(widget.gateway.slidgeImage, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.primary))]),
            const SizedBox(height: 24),
            if (_isLoading) const Center(child: CircularProgressIndicator())
            else ...[
              if (widget.gateway.status == 'disabled') ...[
                ElevatedButton.icon(onPressed: _showSetupInstructions, icon: const Icon(Icons.settings), label: const Text('Setup Gateway'), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48))),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _enable, icon: const Icon(Icons.power_settings_new), label: const Text('Enable Gateway'), style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48))),
              ] else if (widget.gateway.status == 'not_configured') ...[
                ElevatedButton.icon(onPressed: _showSetupInstructions, icon: const Icon(Icons.settings), label: const Text('Configure Gateway'), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48))),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _enable, icon: const Icon(Icons.power_settings_new), label: const Text('Enable Gateway'), style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48))),
              ] else ...[
                OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.check), label: const Text('Gateway Active'), style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48))),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _disable, icon: const Icon(Icons.power_off), label: const Text('Disable Gateway'), style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red), minimumSize: const Size(double.infinity, 48))),
              ],
            ],
          ])),
        ]),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _DetailSection({required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      ...children,
    ]);
  }
}
