import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../providers/theme_provider.dart';
import 'package:provider/provider.dart';

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen>
    with TickerProviderStateMixin {
  late AnimationController _orbController;
  late AnimationController _pulseController;
  late AnimationController _fadeController;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
  }

  @override
  void dispose() {
    _orbController.dispose();
    _pulseController.dispose();
    _fadeController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 700;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          CustomPaint(painter: _OrbPainter(_orbController, isDark, Theme.of(context).colorScheme.primary), size: size),
          FadeTransition(
            opacity: _fadeController,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(child: _buildNavBar(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildHero(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildFeatures(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildHowItWorks(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildTiers(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildSecurity(isDark, isMobile)),
                SliverToBoxAdapter(child: _buildFooter(isDark)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavBar(bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 16 : 48,
        vertical: 16,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow.withValues(alpha: 0.85),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          Image.asset('assets/logo.png', width: 32, height: 32),
          const SizedBox(width: 10),
          Text(
            'GIBBER',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const Spacer(),
          if (!isMobile) ...[
            _navLink('Features', 700),
            _navLink('Tiers', 1400),
            _navLink('Support', 2100),
            _navLink('Security', 2800),
          ],
          const SizedBox(width: 16),
          Consumer<ThemeProvider>(
            builder: (context, tp, _) => IconButton(
              icon: Icon(
                tp.isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 20,
              ),
              onPressed: () => tp.toggleTheme(),
              tooltip: 'Toggle Theme',
            ),
          ),
          const SizedBox(width: 8),
          _ctaButton('Sign In', isDark: isDark, outlined: true, onTap: () => context.go('/login')),
          if (!isMobile) ...[
            const SizedBox(width: 8),
            _ctaButton('Get Started Free', isDark: isDark, onTap: () => context.go('/register')),
          ],
        ],
      ),
    );
  }

  Widget _navLink(String label, double scrollOffset) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        onTap: () => _scrollController.animateTo(
          scrollOffset,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
        ),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _ctaButton(
    String label, {
    required bool isDark,
    bool outlined = false,
    VoidCallback? onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 40,
      child: outlined
          ? OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: primary, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              child: Text(
                label,
                style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 14),
              ),
            )
          : ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: primary,
                foregroundColor: Colors.white,
                elevation: 4,
                shadowColor: primary.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
    );
  }

  Widget _buildHero(bool isDark, bool isMobile) {
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = isDark ? const Color(0xFF06B6D4) : const Color(0xFF10B981);

    return Container(
      constraints: BoxConstraints(minHeight: isMobile ? 500 : 600),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 24 : 80,
        vertical: isMobile ? 40 : 80,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isMobile) Image.asset('assets/logo.png', width: 64, height: 64),
          if (isMobile) const SizedBox(height: 24),
          ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
            ),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 12 : 20,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: secondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Private & Secure',
                    style: TextStyle(
                      color: primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Your Network, Your Rules.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isMobile ? 32 : 56,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.5,
              height: 1.1,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Chat, call, and post across every network — without the compromise.\n'
            'No account required. No tracking. No ads.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isMobile ? 15 : 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 36),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              _ctaButton('Create Free Account', isDark: isDark, onTap: () => context.go('/register')),
              _ctaButton('Sign In', isDark: isDark, outlined: true, onTap: () => context.go('/login')),
            ],
          ),
          const SizedBox(height: 48),
          _buildMockupChat(isDark, isMobile, primary),
        ],
      ),
    );
  }

  Widget _buildMockupChat(bool isDark, bool isMobile, Color primary) {
    final surface = Theme.of(context).colorScheme.surface;
    final onSurface = isDark ? Colors.white : const Color(0xFF111827);

    return Container(
      width: isMobile ? double.infinity : 480,
      constraints: BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: primary.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.15),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.15),
                  border: Border(bottom: BorderSide(color: primary.withValues(alpha: 0.1))),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: primary.withValues(alpha: 0.2),
                      child: Icon(Icons.person, color: primary, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Alice', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: onSurface)),
                        Row(
                          children: [
                            Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
                            const SizedBox(width: 4),
                            Text('Online', style: TextStyle(fontSize: 11, color: onSurface.withValues(alpha: 0.6))),
                            const SizedBox(width: 8),
                            Icon(Icons.lock_outline, size: 10, color: Colors.green),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(),
                    Icon(Icons.videocam_outlined, color: onSurface.withValues(alpha: 0.5), size: 20),
                    const SizedBox(width: 8),
                    Icon(Icons.phone_outlined, color: onSurface.withValues(alpha: 0.5), size: 20),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _mockBubble('Hey! Are you coming to the meeting?', isLeft: true, isDark: isDark),
                      const SizedBox(height: 8),
                      _mockBubble('Yes, joining in 5 min', isLeft: false, isDark: isDark),
                      const SizedBox(height: 8),
                      _mockBubble('Great! I\'ll share the notes securely 🔒', isLeft: true, isDark: isDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mockBubble(String text, {required bool isLeft, required bool isDark}) {
    final bg = isLeft
        ? Theme.of(context).colorScheme.surface
        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15);
    final align = isLeft ? Alignment.centerLeft : Alignment.centerRight;
    return Align(
      alignment: align,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : const Color(0xFF374151))),
      ),
    );
  }

  Widget _buildFeatures(bool isDark, bool isMobile) {
    final primary = Theme.of(context).colorScheme.primary;
    final features = [
      _FeatureData(Icons.lock_outline_rounded, 'End-to-End Encryption', 'Military-grade encryption protects every message and call. Your data never leaves your device.', primary),
      _FeatureData(Icons.mic_rounded, 'Live Transcription', 'On-device Whisper WASM transcribes voice calls in real time. No cloud, no data leaks.', primary),
      _FeatureData(Icons.compare_arrows_rounded, 'Protocol Gateway', 'Gibber, Slack, Discord, IRC, Teams, Matrix, Telegram, SMS — one inbox, every network.', primary),
      _FeatureData(Icons.videocam_rounded, 'Encrypted Voice & Video', 'WebRTC calls with live captions, call recording, and identity verification — no Zoom.', primary),
      _FeatureData(Icons.cloud_off_rounded, 'Zero-Knowledge Architecture', 'All processing happens on your device. No cloud servers ever see your messages or calls.', primary),
    ];

    return _sectionWrapper(
      label: 'FEATURES',
      title: 'Everything you need. Nothing you don\'t.',
      isDark: isDark,
      isMobile: isMobile,
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        children: features.map((f) => _featureCard(f, isDark, isMobile)).toList(),
      ),
    );
  }

  Widget _featureCard(_FeatureData f, bool isDark, bool isMobile) {
    final surface = Theme.of(context).colorScheme.surface;
    final cardWidth = isMobile ? double.infinity : 320.0;

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: f.color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: f.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(f.icon, color: f.color, size: 24),
          ),
          const SizedBox(height: 16),
          Text(
            f.title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            f.desc,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHowItWorks(bool isDark, bool isMobile) {
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = isDark ? const Color(0xFF06B6D4) : const Color(0xFF10B981);
    final steps = [
      _StepData('1', 'Create Account', 'Sign up for free — no credit card needed. Start messaging securely right away.', Icons.person_add_rounded, primary),
      _StepData('2', 'Connect & Communicate', 'Message and call anyone — encrypted and processed on your device. Zero knowledge.', Icons.chat_rounded, secondary),
      _StepData('3', 'Take Back Control', 'Own your identity, your contacts, and your conversations. No company in the middle.', Icons.verified_rounded, primary),
    ];

    return _sectionWrapper(
      label: 'HOW IT WORKS',
      title: 'Three steps to full power',
      isDark: isDark,
      isMobile: isMobile,
      child: isMobile
          ? Column(children: steps.map((s) => _stepCard(s, isDark, true)).toList())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: steps
                  .asMap()
                  .entries
                  .map((e) => Expanded(child: _stepCard(e.value, isDark, false)))
                  .toList(),
            ),
    );
  }

  Widget _stepCard(_StepData s, bool isDark, bool isMobile) {
    final surface = Theme.of(context).colorScheme.surface;
    return Padding(
      padding: EdgeInsets.only(bottom: isMobile ? 12 : 0, right: isMobile ? 0 : 12),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: s.color.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: s.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(child: Text(s.num, style: TextStyle(color: s.color, fontWeight: FontWeight.w900, fontSize: 18))),
                ),
                const SizedBox(width: 12),
                Icon(s.icon, color: s.color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Theme.of(context).colorScheme.onSurface)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(s.desc, style: TextStyle(fontSize: 14, height: 1.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _buildTiers(bool isDark, bool isMobile) {
    final primary = Theme.of(context).colorScheme.primary;
    final tiers = [
      _TierData(
        'Free',
        '\$0',
        'Forever free',
        const Color(0xFF6B7280),
        ['Gibber messaging & calls', '1:1 encrypted chat', 'Unlimited transcription', '4-person group calls', '30-day history'],
        [],
        ['Slack, Discord, IRC', 'Teams, Matrix, Telegram, SMS', '10+ person group calls', '365-day history'],
      ),
      _TierData(
        'Pro',
        '\$9.99/mo',
        'Cancel anytime',
        primary,
        ['Gibber messaging & calls', '1:1 encrypted chat', 'Unlimited transcription', '10-person group calls', '365-day history', 'Slack, Discord, IRC'],
        ['Teams, Matrix, Telegram, SMS'],
        [],
      ),
      _TierData(
        'Ultimate',
        '\$19.99/mo',
        'Cancel anytime',
        const Color(0xFF8B5CF6),
        ['Everything in Pro, plus:', 'Teams, Matrix, Telegram, SMS', 'Unlimited group calls', 'Unlimited history', 'Priority support'],
        [],
        [],
      ),
    ];

    return _sectionWrapper(
      label: 'PRICING',
      title: 'Simple, transparent pricing',
      isDark: isDark,
      isMobile: isMobile,
      child: isMobile
          ? Column(children: tiers.map((t) => _tierCard(t, isDark, true)).toList())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: tiers.map((t) => Expanded(child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _tierCard(t, isDark, false),
              ))).toList(),
            ),
    );
  }

  Widget _tierCard(_TierData t, bool isDark, bool isMobile) {
    final surface = Theme.of(context).colorScheme.surface;
    final isFree = t.name == 'Free';
    final isUltimate = t.name == 'Ultimate';

    return Container(
      margin: EdgeInsets.only(bottom: isMobile ? 12 : 0),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: isUltimate ? 0.8 : 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isUltimate ? t.color.withValues(alpha: 0.6) : t.color.withValues(alpha: 0.15),
          width: isUltimate ? 2 : 1,
        ),
        boxShadow: isUltimate
            ? [BoxShadow(color: t.color.withValues(alpha: 0.2), blurRadius: 30, offset: const Offset(0, 10))]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isUltimate)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: t.color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(999)),
              child: Text('BEST VALUE', style: TextStyle(color: t.color, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1)),
            ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: t.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                child: Icon(
                  isFree ? Icons.chat_bubble_outline : (isUltimate ? Icons.verified_rounded : Icons.workspaces_outline),
                  color: t.color,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Theme.of(context).colorScheme.onSurface)),
                    Text(t.priceLabel, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: t.color)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(t.sublabel, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
          const Divider(height: 24),
          ...t.features.map((f) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 16, color: t.color),
                const SizedBox(width: 8),
                Expanded(child: Text(f, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface, height: 1.3))),
              ],
            ),
          )),
          if (t.locked.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...t.locked.map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5), height: 1.3))),
                ],
              ),
            )),
          ],
          const SizedBox(height: 16),
          if (!isFree)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => context.go('/register'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.color,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  isUltimate ? 'Get Ultimate' : 'Get Started',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSecurity(bool isDark, bool isMobile) {
    final primary = Theme.of(context).colorScheme.primary;
    final points = [
      ('End-to-End Encryption', 'Military-grade encryption protects every 1:1 and group message. Only you and your contacts can read them.'),
      ('On-Device Processing', 'Whisper WASM runs entirely in your browser. Zero cloud dependency.'),
      ('Private Infrastructure', 'Secure server infrastructure with full encryption. Your data stays yours.'),
      ('Transparent & Auditable', 'Our encryption protocols are built on proven standards. No backdoors, no compromises.'),
    ];

    return _sectionWrapper(
      label: 'SECURITY',
      title: 'Privacy isn\'t a feature. It\'s the foundation.',
      isDark: isDark,
      isMobile: isMobile,
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        children: points.map((p) => Container(
          width: isMobile ? double.infinity : 280,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: primary.withValues(alpha: 0.1)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_rounded, color: primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.$1, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Theme.of(context).colorScheme.onSurface)),
                    const SizedBox(height: 4),
                    Text(p.$2, style: TextStyle(fontSize: 13, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildFooter(bool isDark) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15))),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/logo.png', width: 24, height: 24),
              const SizedBox(width: 8),
              Text('GIBBER', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1, color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
          Text(
            'Secure communication for everyone.',
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '100% Free & Open Source \u00B7 Built on XMPP \u00B7 No account required',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _footerLink('GitHub'),
              _footerLink('Docs'),
              _footerLink('Privacy'),
              _footerLink('Terms'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footerLink(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
    );
  }

  Widget _sectionWrapper({
    required String label,
    required String title,
    required bool isDark,
    required bool isMobile,
    required Widget child,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 24 : 80,
        vertical: isMobile ? 48 : 72,
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isMobile ? 24 : 36,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 36),
          child,
        ],
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final AnimationController controller;
  final bool isDark;
  final Color primary;

  _OrbPainter(this.controller, this.isDark, this.primary);

  @override
  void paint(Canvas canvas, Size size) {
    final t = controller.value;
    final secondary = isDark ? const Color(0xFF06B6D4) : const Color(0xFF10B981);

    final orbs = [
      _Orb(primary, 0.3, 0.25, 0.35, 180),
      _Orb(secondary, 0.7, 0.6, 0.28, 120),
      _Orb(primary.withValues(alpha: 0.5), 0.5, 0.75, 0.22, 200),
    ];

    for (final orb in orbs) {
      final cx = size.width * orb.baseX + math.sin(t * 2 * math.pi + orb.phase) * size.width * 0.08;
      final cy = size.height * orb.baseY + math.cos(t * 1.5 * math.pi + orb.phase) * size.height * 0.06;
      final radius = size.shortestSide * orb.radiusFactor;

      final paint = Paint()
        ..shader = RadialGradient(
          colors: [orb.color.withValues(alpha: 0.25), orb.color.withValues(alpha: 0)],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius));
      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _Orb {
  final Color color;
  final double baseX;
  final double baseY;
  final double radiusFactor;
  final double phase;
  const _Orb(this.color, this.baseX, this.baseY, this.radiusFactor, this.phase);
}

class _FeatureData {
  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  const _FeatureData(this.icon, this.title, this.desc, this.color);
}

class _StepData {
  final String num;
  final String title;
  final String desc;
  final IconData icon;
  final Color color;
  const _StepData(this.num, this.title, this.desc, this.icon, this.color);
}

class _TierData {
  final String name;
  final String priceLabel;
  final String sublabel;
  final Color color;
  final List<String> features;
  final List<String> locked;
  final List<String> excluded;
  const _TierData(this.name, this.priceLabel, this.sublabel, this.color, this.features, this.locked, this.excluded);
}