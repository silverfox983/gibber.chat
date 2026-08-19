import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/entitlement_service.dart';
import '../services/backend_config.dart';
import '../services/subscription_service.dart';

class TierScreen extends StatefulWidget {
  const TierScreen({super.key});

  @override
  State<TierScreen> createState() => _TierScreenState();
}

class _TierScreenState extends State<TierScreen> {
  final _codeController = TextEditingController();
  bool _redeeming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sub = Provider.of<SubscriptionService>(context, listen: false);
      sub.setBackendUrl(Provider.of<BackendConfig>(context, listen: false).apiUrl);
      sub.fetchPricing();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Subscription', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Consumer3<EntitlementService, BackendConfig, SubscriptionService>(
        builder: (context, entitlement, backendConfig, subscription, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildCurrentTierCard(theme, entitlement),
              const SizedBox(height: 16),
              if (entitlement.currentTier == UserTier.free) ...[
                _buildUpgradeCard(theme, subscription, entitlement),
                const SizedBox(height: 16),
              ],
              if (entitlement.currentTier != UserTier.free) ...[
                _buildManageSubscriptionCard(theme, subscription, entitlement),
                const SizedBox(height: 16),
              ],
              _buildTierComparisonCard(theme, entitlement),
              const SizedBox(height: 16),
              _buildSupportCard(theme),
              const SizedBox(height: 16),
              _buildRedeemCard(theme, entitlement),
              const SizedBox(height: 16),
              _buildBackendSettingsCard(theme, backendConfig),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCurrentTierCard(ThemeData theme, EntitlementService entitlement) {
    final tier = entitlement.currentTier;
    final color = tier == UserTier.ultimate
        ? Colors.amber
        : tier == UserTier.pro
            ? Colors.purpleAccent
            : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: tier == UserTier.ultimate
              ? [Colors.amber.withValues(alpha: 0.15), Colors.orange.withValues(alpha: 0.1)]
              : tier == UserTier.pro
                  ? [Colors.purpleAccent.withValues(alpha: 0.15), Colors.deepPurple.withValues(alpha: 0.1)]
                  : [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(tier == UserTier.ultimate ? Icons.workspace_premium_rounded
                : tier == UserTier.pro ? Icons.star_rounded
                : Icons.person_rounded,
                size: 28, color: color),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current Tier', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                Text(tier.label, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
              ],
            )),
            if (entitlement.entitlement.expiresAt != null)
              Text('Exp: ${_formatDate(entitlement.entitlement.expiresAt!)}',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final proto in tier.allowedProtocols)
              Chip(
                label: Text(proto, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                backgroundColor: color.withValues(alpha: 0.12),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
            for (final proto in entitlement.entitlement.additionalProtocols)
              Chip(
                label: Text(proto, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green)),
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
          ]),
          if (entitlement.currentTier != UserTier.free) ...[
            const SizedBox(height: 12),
            _buildUsageRow(theme, Icons.subtitles_outlined, 'Transcription',
                entitlement.transcriptionSecondsUsed ~/ 60,
                entitlement.currentTier.transcriptionMinutesPerMonth == -1 ? null : entitlement.currentTier.transcriptionMinutesPerMonth,
                'min'),
            const SizedBox(height: 4),
            _buildUsageRow(theme, Icons.auto_awesome_rounded, 'AI Queries',
                entitlement.aiQueriesUsed,
                entitlement.currentTier.aiQueriesPerMonth == -1 ? null : entitlement.currentTier.aiQueriesPerMonth,
                ''),
          ],
        ],
      ),
    );
  }

  Widget _buildUpgradeCard(ThemeData theme, SubscriptionService subscription, EntitlementService entitlement) {
    final proTier = subscription.proTier;
    final ultimateTier = subscription.ultimateTier;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('UPGRADE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 12),
          if (proTier != null) ...[
            _buildUpgradeRow(theme, proTier, Colors.purpleAccent, entitlement, subscription),
            const SizedBox(height: 10),
          ],
          if (ultimateTier != null) ...[
            _buildUpgradeRow(theme, ultimateTier, Colors.amber, entitlement, subscription),
          ],
          if (proTier == null && ultimateTier == null && subscription.isLoading)
            const Center(child: CircularProgressIndicator()),
          if (proTier == null && ultimateTier == null && !subscription.isLoading)
            Text('Pricing unavailable', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildUpgradeRow(ThemeData theme, PricingTier tier, Color color, EntitlementService entitlement, SubscriptionService subscription) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tier.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text('\$${tier.price.toStringAsFixed(2)}/${tier.interval}',
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
          ],
        )),
        if (subscription.stripeEnabled)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: FilledButton(
              onPressed: () => _handleSubscribe(tier.id, 'stripe', entitlement),
              style: FilledButton.styleFrom(backgroundColor: color, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: Text('Card', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        if (subscription.btcpayEnabled)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: OutlinedButton(
              onPressed: () => _handleSubscribe(tier.id, 'btcpay', entitlement),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), side: BorderSide(color: color)),
              child: Text('Crypto', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            ),
          ),
      ]),
    );
  }

  Future<void> _handleSubscribe(String tierId, String method, EntitlementService entitlement) async {
    final subscription = Provider.of<SubscriptionService>(context, listen: false);
    final jid = entitlement.entitlement.additionalProtocols.isEmpty ? 'user@gibberapp.online' : '';

    String? url;
    if (method == 'stripe') {
      url = await subscription.createStripeCheckout(jid.isEmpty ? 'user@gibberapp.online' : jid, tierId);
    } else {
      url = await subscription.createBtcpayInvoice(jid.isEmpty ? 'user@gibberapp.online' : jid, tierId);
    }

    if (url != null && mounted) {
      final uri = Uri.tryParse(url);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open payment page'), backgroundColor: Colors.red),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(subscription.error.isNotEmpty ? subscription.error : 'Payment failed'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildManageSubscriptionCard(ThemeData theme, SubscriptionService subscription, EntitlementService entitlement) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.credit_card_rounded, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('MANAGE SUBSCRIPTION', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          ]),
          const SizedBox(height: 12),
          Text(
            entitlement.currentTier == UserTier.pro ? 'Pro plan — \$9.99/month' : 'Ultimate plan — \$19.99/month',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          if (entitlement.entitlement.expiresAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Renews: ${_formatDate(entitlement.entitlement.expiresAt!)}',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _handleCancelSubscription(entitlement),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
            child: Text('Cancel Subscription', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCancelSubscription(EntitlementService entitlement) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel Subscription?', style: TextStyle(fontWeight: FontWeight.w800)),
        content: Text('Your subscription will remain active until the end of your billing period. After that, you\'ll revert to the Free tier.', style: TextStyle()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Keep', style: TextStyle())),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Cancel Sub', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;

    final subscription = Provider.of<SubscriptionService>(context, listen: false);
    final jid = 'user@gibberapp.online';
    final success = await subscription.cancelSubscription(jid);
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Subscription cancellation requested.'), backgroundColor: Colors.orange),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(subscription.error.isNotEmpty ? subscription.error : 'Failed to cancel'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildUsageRow(ThemeData theme, IconData icon, String label, int used, int? limit, String unit) {
    final isUnlimited = limit == null;
    final progress = isUnlimited ? 0.0 : (limit == 0 ? 1.0 : (used / limit).clamp(0.0, 1.0));
    final unitSuffix = unit.isEmpty ? '' : ' $unit';
    final displayText = isUnlimited
        ? '$used$unitSuffix used (unlimited)'
        : '$used / $limit$unitSuffix used';
    return Row(children: [
      Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        Text(displayText, style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
      ])),
      if (!isUnlimited) SizedBox(
        width: 60,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          color: progress > 0.9 ? Colors.red : progress > 0.7 ? Colors.orange : theme.colorScheme.primary,
        ),
      ),
    ]);
  }

  Widget _buildTierComparisonCard(ThemeData theme, EntitlementService entitlement) {
    final tiers = [
      (UserTier.free, 'Free', Icons.person_rounded, theme.colorScheme.onSurfaceVariant,
        ['Gibber protocol only', '4-person calls']),
      (UserTier.pro, 'Pro — \$9.99/mo', Icons.star_rounded, Colors.purpleAccent,
        ['Gibber + Slack + Discord + IRC', '300 min transcription/mo', '100 AI queries/mo', '10-person calls']),
      (UserTier.ultimate, 'Ultimate — \$19.99/mo', Icons.workspace_premium_rounded, Colors.amber,
        ['All protocols', 'Unlimited transcription', 'Unlimited AI', 'Unlimited calls']),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TIER COMPARISON', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 12),
          for (final (tier, name, icon, color, features) in tiers) ...[
            Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color))),
              if (entitlement.currentTier == tier)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                  child: Text('Active', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
                ),
            ]),
            const SizedBox(height: 4),
            for (final f in features)
              Padding(padding: const EdgeInsets.only(left: 26, bottom: 2),
                child: Text(f, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant))),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildSupportCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.favorite_rounded, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('SUPPORT GIBBER', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          ]),
          const SizedBox(height: 12),
          Text(
            'Free users can donate idle CPU power to support development. Opt in from Settings.',
            style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildRedeemCard(ThemeData theme, EntitlementService entitlement) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.card_giftcard_rounded, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('REDEMPTION CODE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(
              controller: _codeController,
              style: TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Enter code (e.g. GIBBER-PRO-XXXX)',
                hintStyle: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            )),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _redeeming ? null : _redeemCode,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: _redeeming
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Redeem', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          if (entitlement.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(entitlement.error, style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Future<void> _redeemCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _redeeming = true);
    final entitlement = Provider.of<EntitlementService>(context, listen: false);
    final success = await entitlement.redeemCode(code);
    if (!mounted) return;
    setState(() => _redeeming = false);
    if (success) {
      _codeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tier upgraded to ${entitlement.currentTier.label}!'), backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(entitlement.error.isNotEmpty ? entitlement.error : 'Invalid code'), backgroundColor: Colors.red),
      );
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Widget _buildBackendSettingsCard(ThemeData theme, BackendConfig config) {
    final apiController = TextEditingController(text: config.apiUrl);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.dns_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('BACKEND SERVER', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await config.resetToDefaults();
                apiController.text = config.apiUrl;
              },
              child: Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: apiController,
            style: TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: 'API URL',
              labelStyle: TextStyle(fontSize: 12),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => config.setApiUrl(v.trim()),
          ),
        ],
      ),
    );
  }
}