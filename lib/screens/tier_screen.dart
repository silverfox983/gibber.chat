import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/entitlement_service.dart';
import '../services/miner_service.dart';
import '../services/backend_config.dart';

class TierScreen extends StatefulWidget {
  const TierScreen({super.key});

  @override
  State<TierScreen> createState() => _TierScreenState();
}

class _TierScreenState extends State<TierScreen> {
  final _codeController = TextEditingController();
  bool _redeeming = false;

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
        title: Text('Tier & Mining', style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 18)),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Consumer3<EntitlementService, MinerService, BackendConfig>(
        builder: (context, entitlement, miner, backendConfig, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildCurrentTierCard(theme, entitlement),
              const SizedBox(height: 16),
              _buildTierComparisonCard(theme, entitlement),
              const SizedBox(height: 16),
              _buildMiningCard(theme, miner),
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
                Text('Current Tier', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                Text(tier.label, style: GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
              ],
            )),
            if (entitlement.entitlement.expiresAt != null)
              Text('Exp: ${_formatDate(entitlement.entitlement.expiresAt!)}',
                  style: GoogleFonts.inter(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final proto in tier.allowedProtocols)
              Chip(
                label: Text(proto, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
                backgroundColor: color.withValues(alpha: 0.12),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
            for (final proto in entitlement.entitlement.additionalProtocols)
              Chip(
                label: Text(proto, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green)),
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
          ]),
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
      ),
    );
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
        Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
        Text(displayText, style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
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
        ['XMPP only', '30 min transcription/mo', '10 AI queries/mo', '4-person calls']),
      (UserTier.pro, 'Pro', Icons.star_rounded, Colors.purpleAccent,
        ['XMPP + Slack + Discord + IRC', '300 min transcription/mo', '100 AI queries/mo', '10-person calls']),
      (UserTier.ultimate, 'Ultimate', Icons.workspace_premium_rounded, Colors.amber,
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
          Text('TIER COMPARISON', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          const SizedBox(height: 12),
          for (final (tier, name, icon, color, features) in tiers) ...[
            Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(name, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
              const Spacer(),
              if (entitlement.currentTier == tier)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                  child: Text('Active', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
                ),
            ]),
            const SizedBox(height: 4),
            for (final f in features)
              Padding(padding: const EdgeInsets.only(left: 26, bottom: 2),
                child: Text(f, style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.onSurfaceVariant))),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildMiningCard(ThemeData theme, MinerService miner) {
    final isMining = miner.status == MinerStatus.mining;
    final isPaused = miner.status == MinerStatus.paused;
    final isActive = isMining || isPaused;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? Colors.green.withValues(alpha: 0.5) : theme.colorScheme.outline,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(isMining ? Icons.memory_rounded : Icons.memory_outlined, size: 20, color: isActive ? Colors.green : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('CREDIT MINING', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isMining ? Colors.green.withValues(alpha: 0.15)
                    : isPaused ? Colors.orange.withValues(alpha: 0.15)
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isMining ? 'Mining' : isPaused ? 'Paused' : 'Stopped',
                style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700,
                  color: isMining ? Colors.green : isPaused ? Colors.orange : theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ]),
          if (isActive) ...[
            const SizedBox(height: 12),
            Row(children: [
              _statChip('${miner.stats.hashesPerSecond.toStringAsFixed(1)} H/s', Icons.speed_rounded, theme),
              const SizedBox(width: 8),
              _statChip('${miner.stats.creditsEarned.toStringAsFixed(2)} credits', Icons.monetization_on_rounded, theme),
              const SizedBox(width: 8),
              _statChip(_formatDuration(miner.stats.uptime), Icons.timer_rounded, theme),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Text('Next tier: ${miner.nextTierProgress}', style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ],
          if (miner.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(miner.error, style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _toggleMining(miner),
                icon: Icon(isActive ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                label: Text(isActive ? 'Stop' : 'Start', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: isActive ? Colors.red.shade700 : Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Text('Consent', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            Switch(
              value: miner.consent,
              onChanged: (v) => miner.setConsent(v),
              activeTrackColor: Colors.green,
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Text('CPU Cap: ${(miner.cpuCap * 100).toInt()}%', style: GoogleFonts.inter(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(child: Slider(
              value: miner.cpuCap,
              min: 0.1,
              max: 0.8,
              divisions: 7,
              onChanged: (v) => miner.setCpuCap(v),
            )),
          ]),
        ],
      ),
    );
  }

  Widget _statChip(String text, IconData icon, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
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
            Text('REDEMPTION CODE', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(
              controller: _codeController,
              style: GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Enter code (e.g. GIBBER-PRO-XXXX)',
                hintStyle: GoogleFonts.inter(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
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
                  : Text('Redeem', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
            ),
          ]),
          if (entitlement.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(entitlement.error, style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.error)),
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

  Future<void> _toggleMining(MinerService miner) async {
    if (miner.status == MinerStatus.mining || miner.status == MinerStatus.paused) {
      await miner.stopMining();
    } else {
      if (!miner.consent) {
        final granted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Mining Consent'),
            content: const Text(
              'Gibber will use your browser to mine Monero (XMR) to fund development and unlock higher tiers.\n\n'
              'You can adjust CPU usage and stop at any time.\n\n'
              'Do you consent?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Decline')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Consent')),
            ],
          ),
        );
        if (granted != true) return;
        await miner.setConsent(true);
      }
      await miner.startMining();
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '${h}h ${m}m';
  }

  Widget _buildBackendSettingsCard(ThemeData theme, BackendConfig config) {
    final apiController = TextEditingController(text: config.apiUrl);
    final poolController = TextEditingController(text: config.poolUrl);

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
            Text('BACKEND SERVER', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await config.resetToDefaults();
                apiController.text = config.apiUrl;
                poolController.text = config.poolUrl;
              },
              child: Text('Reset', style: GoogleFonts.inter(fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: apiController,
            style: GoogleFonts.inter(fontSize: 13),
            decoration: InputDecoration(
              labelText: 'API URL',
              labelStyle: GoogleFonts.inter(fontSize: 12),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => config.setApiUrl(v.trim()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: poolController,
            style: GoogleFonts.inter(fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Mining Pool URL',
              labelStyle: GoogleFonts.inter(fontSize: 12),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => config.setPoolUrl(v.trim()),
          ),
        ],
      ),
    );
  }
}