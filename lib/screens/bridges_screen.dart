import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/breakpoints.dart';
import '../core/design_tokens.dart';
import '../core/app_colors.dart';
import '../models/user_gateway.dart';
import '../services/auth_service.dart';
import '../services/bridge_config_service.dart';
import '../services/jwt_token_service.dart';

class BridgesScreen extends StatefulWidget {
  const BridgesScreen({super.key});

  @override
  State<BridgesScreen> createState() => _BridgesScreenState();
}

class _BridgesScreenState extends State<BridgesScreen> with SingleTickerProviderStateMixin {
  late BridgeConfigService _bridgeService;
  bool _isLoading = true;
  String? _error;
  Timer? _statusPoller;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initService());
  }

  Future<void> _initService() async {
    final jwtService = Provider.of<JwtTokenService>(context, listen: false);
    _bridgeService = BridgeConfigService(jwtService);
    await _loadGateways();
    _startStatusPolling();
  }

  void _startStatusPolling() {
    _statusPoller?.cancel();
    _statusPoller = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _pollStatus();
    });
  }

  Future<void> _pollStatus() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;
    await _bridgeService.listUserGateways(userId);
  }

  Future<void> _loadGateways() async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) {
      setState(() { _isLoading = false; _error = 'Not logged in'; });
      return;
    }

    setState(() => _isLoading = true);
    await _bridgeService.listUserGateways(userId);
    if (mounted) {
      setState(() {
        _isLoading = false;
        _error = _bridgeService.error;
      });
    }
  }

  @override
  void dispose() {
    _statusPoller?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  UserGateway? _gatewayForType(String type) {
    try {
      return _bridgeService.userGateways.firstWhere((g) => g.gatewayType == type);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final size = Breakpoints.getSize(context);

    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      body: CustomScrollView(
        slivers: [
          _buildHeader(theme, isDark, size),
          if (_isLoading)
            const SliverFillRemaining(child: _LoadingState())
          else if (_error != null && _bridgeService.userGateways.isEmpty)
            SliverFillRemaining(child: _ErrorState(error: _error!, onRetry: _loadGateways))
          else
            SliverPadding(
              padding: _contentPadding(size),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _buildPlatformGrid(theme, isDark, size),
                  const SizedBox(height: DesignTokens.space32),
                  _buildInfoCard(theme, isDark),
                  const SizedBox(height: DesignTokens.space48),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  EdgeInsets _contentPadding(ScreenSize size) {
    switch (size) {
      case ScreenSize.compact:
        return const EdgeInsets.all(DesignTokens.space16);
      case ScreenSize.medium:
        return const EdgeInsets.symmetric(horizontal: DesignTokens.space32, vertical: DesignTokens.space16);
      case ScreenSize.expanded:
        return const EdgeInsets.symmetric(horizontal: DesignTokens.space64, vertical: DesignTokens.space24);
    }
  }

  Widget _buildHeader(ThemeData theme, bool isDark, ScreenSize size) {
    final connected = _bridgeService.userGateways.where((g) => g.enabled).length;
    final total = 5;

    return SliverAppBar(
      expandedHeight: size == ScreenSize.compact ? 140 : 120,
      floating: false,
      pinned: true,
      backgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Platform Bridges',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
                letterSpacing: -0.5,
              ),
            ),
            if (size != ScreenSize.compact) ...[
              const SizedBox(height: 2),
              Text(
                '$connected of $total connected',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadGateways,
          tooltip: 'Refresh',
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildPlatformGrid(ThemeData theme, bool isDark, ScreenSize size) {
    final platforms = ['telegram', 'discord', 'irc', 'matrix', 'whatsapp'];
    final crossAxisCount = switch (size) {
      ScreenSize.compact => 1,
      ScreenSize.medium => 2,
      ScreenSize.expanded => 3,
    };

    if (crossAxisCount == 1) {
      return Column(
        children: platforms.map((p) => Padding(
          padding: const EdgeInsets.only(bottom: DesignTokens.space12),
          child: _PlatformCard(
            platform: p,
            gateway: _gatewayForType(p),
            bridgeService: _bridgeService,
            onConfigure: () => _showConfigDialog(context, p),
            onEnable: () => _enableGateway(context, p),
            onDisable: () => _disableGateway(context, p),
            onRemove: () => _removeGateway(context, p),
          ),
        )).toList(),
      );
    }

    return Wrap(
      spacing: DesignTokens.space16,
      runSpacing: DesignTokens.space16,
      children: platforms.map((p) {
        final width = switch (size) {
          ScreenSize.compact => double.infinity,
          ScreenSize.medium => (MediaQuery.of(context).size.width - 32 - 32 - 16) / 2,
          ScreenSize.expanded => (MediaQuery.of(context).size.width - 128 - 48 - 32) / 3,
        };
        return SizedBox(
          width: width,
          child: _PlatformCard(
            platform: p,
            gateway: _gatewayForType(p),
            bridgeService: _bridgeService,
            onConfigure: () => _showConfigDialog(context, p),
            onEnable: () => _enableGateway(context, p),
            onDisable: () => _disableGateway(context, p),
            onRemove: () => _removeGateway(context, p),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildInfoCard(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(DesignTokens.space20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [AppColors.primarySurface, AppColors.primarySurface.withValues(alpha: 0.6)]
              : [const Color(0xFFF3E8FF), const Color(0xFFE8E0FF)],
        ),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(DesignTokens.space12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
            ),
            child: Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 24),
          ),
          const SizedBox(width: DesignTokens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Isolated & Secure',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Each platform runs in its own isolated container with your personal credentials.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showConfigDialog(BuildContext context, String type) async {
    final info = GatewayTypeInfo.available[type]!;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _BridgeConfigSheet(
        type: type,
        info: info,
        existingGateway: _gatewayForType(type),
      ),
    );

    if (result != null && mounted) {
      await _saveConfig(type, result);
    }
  }

  Future<void> _saveConfig(String type, Map<String, dynamic> config) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;

    final result = await _bridgeService.configureGateway(
      userId: userId,
      type: type,
      config: config,
    );

    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${GatewayTypeInfo.available[type]!.name} configured'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (_bridgeService.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_bridgeService.error!),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _enableGateway(BuildContext context, String type) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final userId = auth.activeAccountId;
    if (userId == null) return;

    final result = await _bridgeService.enableGateway(userId, type);
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${GatewayTypeInfo.available[type]!.name} connecting…'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (_bridgeService.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_bridgeService.error!),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _disableGateway(BuildContext context, String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Bridge'),
        content: Text('Are you sure you want to disconnect ${GatewayTypeInfo.available[type]!.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final auth = Provider.of<AuthService>(context, listen: false);
      final userId = auth.activeAccountId;
      if (userId == null) return;

      await _bridgeService.disableGateway(userId, type);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${GatewayTypeInfo.available[type]!.name} disconnected'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeGateway(BuildContext context, String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Bridge'),
        content: Text(
          'This will permanently remove your ${GatewayTypeInfo.available[type]!.name} bridge configuration. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final auth = Provider.of<AuthService>(context, listen: false);
      final userId = auth.activeAccountId;
      if (userId == null) return;

      await _bridgeService.removeGateway(userId, type);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${GatewayTypeInfo.available[type]!.name} bridge removed'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading bridges…'),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: AppColors.danger),
          const SizedBox(height: 16),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PlatformCard extends StatelessWidget {
  final String platform;
  final UserGateway? gateway;
  final BridgeConfigService bridgeService;
  final VoidCallback onConfigure;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onRemove;

  const _PlatformCard({
    required this.platform,
    required this.gateway,
    required this.bridgeService,
    required this.onConfigure,
    required this.onEnable,
    required this.onDisable,
    required this.onRemove,
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
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  platformColor.withValues(alpha: 0.15),
                  platformColor.withValues(alpha: 0.05),
                ],
              )
            : null,
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        border: Border.all(
          color: isConnected
              ? platformColor.withValues(alpha: 0.5)
              : (isDark ? AppColors.borderDark : AppColors.borderLight),
          width: isConnected ? 2 : 1,
        ),
        boxShadow: isConnected
            ? [
                BoxShadow(
                  color: platformColor.withValues(alpha: 0.2),
                  blurRadius: 16,
                  spreadRadius: 0,
                ),
              ]
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
                Row(
                  children: [
                    _PlatformIcon(platform: platform, color: platformColor, isConnected: isConnected),
                    const SizedBox(width: DesignTokens.space12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            info.name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          _StatusBadge(
                            isConnected: isConnected,
                            isConfigured: isConfigured,
                            isStarting: isStarting,
                            platformColor: platformColor,
                          ),
                        ],
                      ),
                    ),
                    _StatusIndicator(isConnected: isConnected, isStarting: isStarting, color: platformColor),
                  ],
                ),
                const SizedBox(height: DesignTokens.space16),
                if (isConfigured && gateway?.componentJid != null) ...[
                  Text(
                    gateway!.componentJid!,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: isDark ? AppColors.textDarkTertiary : AppColors.textLightTertiary,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space12),
                ],
                Row(
                  children: [
                    if (isConnected) ...[
                      Expanded(
                        child: _ActionButton(
                          label: 'Test',
                          icon: Icons.flash_on_rounded,
                          onPressed: () {},
                          color: platformColor,
                          filled: false,
                        ),
                      ),
                      const SizedBox(width: DesignTokens.space8),
                      Expanded(
                        child: _ActionButton(
                          label: 'Disconnect',
                          icon: Icons.link_off_rounded,
                          onPressed: onDisable,
                          color: AppColors.danger,
                          filled: false,
                        ),
                      ),
                    ] else if (isConfigured) ...[
                      Expanded(
                        child: _ActionButton(
                          label: 'Connect',
                          icon: Icons.play_arrow_rounded,
                          onPressed: isStarting ? null : onEnable,
                          color: platformColor,
                          filled: true,
                        ),
                      ),
                      const SizedBox(width: DesignTokens.space8),
                      Expanded(
                        child: _ActionButton(
                          label: 'Edit',
                          icon: Icons.settings_rounded,
                          onPressed: onConfigure,
                          color: isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary,
                          filled: false,
                        ),
                      ),
                    ] else ...[
                      Expanded(
                        child: _ActionButton(
                          label: 'Configure',
                          icon: Icons.add_rounded,
                          onPressed: onConfigure,
                          color: platformColor,
                          filled: true,
                        ),
                      ),
                    ],
                  ],
                ),
                if (isConnected) ...[
                  const SizedBox(height: DesignTokens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: onRemove,
                      icon: Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.danger),
                      label: Text('Remove bridge', style: TextStyle(color: AppColors.danger, fontSize: 12)),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                    ),
                  ),
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
    final icon = _iconForPlatform(platform);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isConnected ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
        border: Border.all(
          color: color.withValues(alpha: isConnected ? 0.5 : 0.2),
          width: 1,
        ),
      ),
      child: Icon(icon, color: color, size: 24),
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
  final bool isConnected;
  final bool isConfigured;
  final bool isStarting;
  final Color platformColor;

  const _StatusBadge({
    required this.isConnected,
    required this.isConfigured,
    required this.isStarting,
    required this.platformColor,
  });

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    if (isStarting) {
      label = 'Connecting…';
      color = Colors.orange;
    } else if (isConnected) {
      label = 'Connected';
      color = platformColor;
    } else if (isConfigured) {
      label = 'Configured';
      color = Colors.grey;
    } else {
      label = 'Not configured';
      color = Colors.grey;
    }

    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: color,
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final bool isConnected;
  final bool isStarting;
  final Color color;

  const _StatusIndicator({
    required this.isConnected,
    required this.isStarting,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (isStarting) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isConnected ? color : Colors.grey.shade400,
        boxShadow: isConnected
            ? [
                BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1),
              ]
            : null,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool filled;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.color,
    required this.filled,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );

    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
        ),
        child: child,
      );
    }

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
      ),
      child: child,
    );
  }
}

class _BridgeConfigSheet extends StatefulWidget {
  final String type;
  final GatewayTypeInfo info;
  final UserGateway? existingGateway;

  const _BridgeConfigSheet({
    required this.type,
    required this.info,
    this.existingGateway,
  });

  @override
  State<_BridgeConfigSheet> createState() => _BridgeConfigSheetState();
}

class _BridgeConfigSheetState extends State<_BridgeConfigSheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    for (final field in [...widget.info.requiredFields, ...widget.info.optionalFields]) {
      _controllers[field] = TextEditingController(
        text: widget.existingGateway?.config[field]?.toString() ?? '',
      );
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
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: platformColor, width: 2),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHandle(),
          _buildHeader(theme, isDark, platformColor),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(DesignTokens.space20),
              child: Form(key: _formKey, child: _buildForm(theme, isDark)),
            ),
          ),
          const Divider(height: 1),
          _buildActions(theme, platformColor),
        ],
      ),
    );
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark, Color platformColor) {
    return Padding(
      padding: const EdgeInsets.all(DesignTokens.space20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: platformColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
            ),
            child: Icon(_iconForPlatform(widget.type), color: platformColor, size: 24),
          ),
          const SizedBox(width: DesignTokens.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Configure ${widget.info.name}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
                  ),
                ),
                Text(
                  widget.info.description,
                  style: TextStyle(fontSize: 12, color: isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, color: isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.info.requiredFields.isNotEmpty) ...[
          _SectionLabel(label: 'REQUIRED', isDark: isDark),
          const SizedBox(height: DesignTokens.space12),
          ...widget.info.requiredFields.map((f) => _buildField(f, required: true, isDark: isDark)),
        ],
        if (widget.info.optionalFields.isNotEmpty) ...[
          const SizedBox(height: DesignTokens.space20),
          _SectionLabel(label: 'OPTIONAL', isDark: isDark),
          const SizedBox(height: DesignTokens.space12),
          ...widget.info.optionalFields.map((f) => _buildField(f, required: false, isDark: isDark)),
        ],
      ],
    );
  }

  Widget _buildField(String field, {required bool required, required bool isDark}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DesignTokens.space16),
      child: TextFormField(
        controller: _controllers[field],
        obscureText: _isSensitive(field),
        decoration: InputDecoration(
          labelText: _labelFor(field),
          hintText: _hintFor(field),
          filled: true,
          fillColor: isDark ? AppColors.darkSurfaceRaised : AppColors.lightSurfaceRaised,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
            borderSide: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
            borderSide: BorderSide(color: AppColors.primary, width: 2),
          ),
        ),
        validator: required ? (v) => v == null || v.isEmpty ? 'Required' : null : null,
      ),
    );
  }

  Widget _buildActions(ThemeData theme, Color platformColor) {
    return Padding(
      padding: const EdgeInsets.all(DesignTokens.space20),
      child: Row(
        children: [
          if (widget.existingGateway != null)
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
                ),
                child: const Text('Cancel'),
              ),
            ),
          if (widget.existingGateway != null) const SizedBox(width: DesignTokens.space12),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: _isSaving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: platformColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusMd)),
              ),
              child: _isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(widget.existingGateway != null ? 'Save Changes' : 'Configure & Connect'),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSensitive(String field) {
    return field.contains('token') || field.contains('password') || field.contains('secret') || field.contains('hash') || field.contains('key');
  }

  String _labelFor(String field) {
    return field.replaceAll('_', ' ').split(' ').map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '').join(' ');
  }

  String _hintFor(String field) {
    switch (field) {
      case 'api_id': return 'From my.telegram.org';
      case 'api_hash': return 'From my.telegram.org';
      case 'bot_token': return 'From @BotFather';
      case 'homeserver_url': return 'https://matrix.org';
      case 'access_token': return 'Matrix access token';
      default: return '';
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final config = <String, dynamic>{};
    for (final entry in _controllers.entries) {
      if (entry.value.text.isNotEmpty) {
        config[entry.key] = entry.value.text;
      }
    }

    Navigator.of(context).pop(config);
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
  final bool isDark;

  const _SectionLabel({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: isDark ? AppColors.textDarkTertiary : AppColors.textLightTertiary,
        letterSpacing: 1.2,
      ),
    );
  }
}
