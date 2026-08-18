import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/gateway_service.dart';

class GatewaysScreen extends StatefulWidget {
  const GatewaysScreen({super.key});

  @override
  State<GatewaysScreen> createState() => _GatewaysScreenState();
}

class _GatewaysScreenState extends State<GatewaysScreen> {
  Map<String, GatewayInfo> _gateways = {};
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGateways();
  }

  Future<void> _loadGateways() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final gatewayService = context.read<GatewayService>();
      final response = await gatewayService.listGateways();

      if (response.error == null) {
        setState(() {
          _gateways = response.gateways;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = response.error;
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading gateways: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _showGatewayDetails(GatewayInfo gateway) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _GatewayDetailsSheet(
        gateway: gateway,
        onStatusChanged: _loadGateways,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.dns_rounded),
          tooltip: 'Discover Transports',
          onPressed: () => context.push('/transports'),
        ),
        title: const Text('Server Gateways'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadGateways,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                      const SizedBox(height: 16),
                      Text(_error!, style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadGateways,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _gateways.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 64,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No gateways configured',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Server gateways will appear here once configured.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadGateways,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _gateways.length,
                        itemBuilder: (context, index) {
                          final entry = _gateways.entries.elementAt(index);
                          final gateway = entry.value;
                          return _GatewayCard(
                            gateway: gateway,
                            onTap: () => _showGatewayDetails(gateway),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _GatewayCard extends StatelessWidget {
  final GatewayInfo gateway;
  final VoidCallback onTap;

  const _GatewayCard({required this.gateway, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  gateway.iconData,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      gateway.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      gateway.description,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: gateway.statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: gateway.statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  gateway.statusLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: gateway.statusColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GatewayDetailsSheet extends StatelessWidget {
  final GatewayInfo gateway;
  final VoidCallback onStatusChanged;

  const _GatewayDetailsSheet({required this.gateway, required this.onStatusChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            gateway.iconData,
                            size: 32,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                gateway.name,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: gateway.statusColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  gateway.statusLabel,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: gateway.statusColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _DetailSection(
                      title: 'Description',
                      children: [
                        Text(gateway.description),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _DetailSection(
                      title: 'Component JID',
                      children: [
                        Text(
                          '${gateway.componentJid}.gibberapp.online',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    if (gateway.requiresConfig.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _DetailSection(
                        title: 'Required Configuration',
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: gateway.requiresConfig.map((config) {
                              return Chip(
                                label: Text(config),
                                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    _DetailSection(
                      title: 'Docker Image',
                      children: [
                        Text(
                          gateway.slidgeImage,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _ActionButtons(gateway: gateway, onStatusChanged: onStatusChanged),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionButtons extends StatefulWidget {
  final GatewayInfo gateway;
  final VoidCallback onStatusChanged;

  const _ActionButtons({required this.gateway, required this.onStatusChanged});

  @override
  State<_ActionButtons> createState() => _ActionButtonsState();
}

class _ActionButtonsState extends State<_ActionButtons> {
  bool _isLoading = false;

  Future<void> _enableGateway() async {
    setState(() => _isLoading = true);
    final service = context.read<GatewayService>();
    final result = await service.enableGateway(widget.gateway.componentJid);
    if (mounted) {
      Navigator.pop(context);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.error ?? 'Gateway enabled'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: result.error == null ? Colors.green : null,
        ),
      );
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _disableGateway() async {
    setState(() => _isLoading = true);
    final service = context.read<GatewayService>();
    final result = await service.disableGateway(widget.gateway.componentJid);
    if (mounted) {
      Navigator.pop(context);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.error ?? 'Gateway disabled'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: result.error == null ? Colors.green : null,
        ),
      );
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _showSetupInstructions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Setup ${widget.gateway.name}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'To enable the ${widget.gateway.name} gateway, you need to:',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              const Text('1. Set the following environment variables on your server:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _getEnvVarsText(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Text('2. Restart the Prosody server'),
              const SizedBox(height: 16),
              const Text('3. Return to this screen to verify the gateway is active'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
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
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.gateway.status == 'disabled') {
      return Column(
        children: [
          ElevatedButton.icon(
            onPressed: _showSetupInstructions,
            icon: const Icon(Icons.settings),
            label: const Text('Setup Gateway'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _enableGateway,
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Enable Gateway'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      );
    }

    if (widget.gateway.status == 'not_configured') {
      return Column(
        children: [
          ElevatedButton.icon(
            onPressed: _showSetupInstructions,
            icon: const Icon(Icons.settings),
            label: const Text('Configure Gateway'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _enableGateway,
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Enable Gateway'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.check),
          label: const Text('Gateway Active'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _disableGateway,
          icon: const Icon(Icons.power_off),
          label: const Text('Disable Gateway'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}
