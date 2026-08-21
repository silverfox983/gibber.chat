import 'dart:math' as math;
import 'package:flutter/material.dart';

class AuthLayout extends StatelessWidget {
  final Widget form;
  final String? title;
  final String? subtitle;

  const AuthLayout({
    super.key,
    required this.form,
    this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWide = width >= 900;

    if (isWide) {
      return _WideLayout(form: form, title: title, subtitle: subtitle);
    }
    return _NarrowLayout(form: form, title: title, subtitle: subtitle);
  }
}

class _WideLayout extends StatelessWidget {
  final Widget form;
  final String? title;
  final String? subtitle;

  const _WideLayout({required this.form, this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 5,
            child: _BrandPanel(isDark: isDark),
          ),
          Expanded(
            flex: 5,
            child: _FormPanel(
              form: form,
              isDark: isDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  final Widget form;
  final String? title;
  final String? subtitle;

  const _NarrowLayout({required this.form, this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.primary,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primary,
              isDark ? const Color(0xFF4C1D95) : const Color(0xFF1D4ED8),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CompactBrandHeader(isDark: isDark),
                  const SizedBox(height: 32),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: form,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FormPanel extends StatelessWidget {
  final Widget form;
  final bool isDark;

  const _FormPanel({required this.form, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Container(
      color: surfaceColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: form,
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatefulWidget {
  final bool isDark;
  const _BrandPanel({required this.isDark});

  @override
  State<_BrandPanel> createState() => _BrandPanelState();
}

class _BrandPanelState extends State<_BrandPanel> with TickerProviderStateMixin {
  late AnimationController _orbController;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _orbController = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();
    _fadeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
  }

  @override
  void dispose() {
    _orbController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = isDark ? const Color(0xFF06B6D4) : const Color(0xFF10B981);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary,
            isDark ? const Color(0xFF4C1D95) : const Color(0xFF1D4ED8),
          ],
        ),
      ),
      child: Stack(
        children: [
          CustomPaint(
            painter: _AuthOrbPainter(_orbController, primary, secondary),
            size: Size.infinite,
          ),
          FadeTransition(
            opacity: _fadeController,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(flex: 1),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                      child: Image.asset('assets/logo.png', width: 72, height: 72, fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'Gibber',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Secure Communication',
                      style: TextStyle(
                        fontSize: 20,
                        color: Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 48),
                    _FeatureTile(
                      icon: Icons.shield_rounded,
                      title: 'End-to-end encrypted',
                      subtitle: 'Your messages stay private, always.',
                      color: secondary,
                    ),
                    const SizedBox(height: 24),
                    _FeatureTile(
                      icon: Icons.person_off_rounded,
                      title: 'No phone number required',
                      subtitle: 'Sign up with just a username.',
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 24),
                    _FeatureTile(
                      icon: Icons.hub_rounded,
                      title: 'Open XMPP protocol',
                      subtitle: 'Connect with any XMPP client.',
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                    const Spacer(flex: 2),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactBrandHeader extends StatelessWidget {
  final bool isDark;
  const _CompactBrandHeader({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          child: Image.asset('assets/logo.png', width: 64, height: 64, fit: BoxFit.contain),
        ),
        const SizedBox(height: 16),
        const Text(
          'Gibber',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Secure Communication',
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _AuthOrbPainter extends CustomPainter {
  final AnimationController controller;
  final Color primary;
  final Color secondary;

  _AuthOrbPainter(this.controller, this.primary, this.secondary);

  @override
  void paint(Canvas canvas, Size size) {
    final t = controller.value;

    final orbs = [
      _Orb(primary, 0.3, 0.3, 0.4, 0),
      _Orb(secondary, 0.7, 0.65, 0.32, 90),
      _Orb(primary.withValues(alpha: 0.5), 0.5, 0.8, 0.25, 180),
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