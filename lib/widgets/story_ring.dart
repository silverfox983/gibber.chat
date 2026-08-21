import 'package:flutter/material.dart';
import 'dart:math' as math;

class StoryRing extends StatelessWidget {
  final Widget child;
  final bool hasUnviewed;
  final double radius;
  final VoidCallback? onTap;
  final bool isOwn;

  const StoryRing({
    super.key,
    required this.child,
    this.hasUnviewed = false,
    this.radius = 28,
    this.onTap,
    this.isOwn = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: radius * 2 + 6,
        height: radius * 2 + 6,
        child: CustomPaint(
          painter: _StoryRingPainter(
            hasUnviewed: hasUnviewed,
            isOwn: isOwn,
            primaryColor: Theme.of(context).colorScheme.primary,
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _StoryRingPainter extends CustomPainter {
  final bool hasUnviewed;
  final bool isOwn;
  final Color primaryColor;

  _StoryRingPainter({
    required this.hasUnviewed,
    required this.isOwn,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;

    if (isOwn) {
      final paint = Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 2,
          colors: [
            primaryColor,
            primaryColor.withValues(alpha: 0.6),
            primaryColor,
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(math.pi / 4),
        ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
      return;
    }

    if (!hasUnviewed) {
      final paint = Paint()
        ..color = Colors.grey.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, r, paint);
      return;
    }

    final paint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          primaryColor,
          primaryColor.withValues(alpha: 0.7),
          Colors.purpleAccent,
          primaryColor,
        ],
        stops: const [0.0, 0.3, 0.6, 1.0],
        transform: GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, paint);
  }

  @override
  bool shouldRepaint(covariant _StoryRingPainter oldDelegate) {
    return oldDelegate.hasUnviewed != hasUnviewed ||
        oldDelegate.isOwn != isOwn ||
        oldDelegate.primaryColor != primaryColor;
  }
}
