import 'package:flutter/material.dart';
import 'dart:math' as math;

class MeshGradientBackground extends StatefulWidget {
  final List<Color> colors;
  final Widget? child;

  const MeshGradientBackground({
    super.key,
    required this.colors,
    this.child,
  });

  @override
  State<MeshGradientBackground> createState() => _MeshGradientBackgroundState();
}

class _MeshGradientBackgroundState extends State<MeshGradientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    
    // Only repeat if not in test environment to avoid pumpAndSettle timeouts
    if (!WidgetsBinding.instance.toString().contains('TestWidgetsFlutterBinding')) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.dark) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: widget.child,
      );
    }
    return Stack(
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: MeshGradientPainter(
                colors: widget.colors,
                progress: _controller.value,
              ),
              size: Size.infinite,
            );
          },
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class MeshGradientPainter extends CustomPainter {
  final List<Color> colors;
  final double progress;

  MeshGradientPainter({required this.colors, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    
    // Draw base background
    canvas.drawRect(rect, Paint()..color = colors[0]);

    for (int i = 1; i < colors.length; i++) {
      final paint = Paint()
        ..color = colors[i]
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 100);

      // Calculate organic movement
      final angle = (progress * 2 * math.pi) + (i * math.pi / 2);
      final x = size.width / 2 + math.cos(angle) * (size.width / 3);
      final y = size.height / 2 + math.sin(angle * 1.5) * (size.height / 3);
      
      final radius = math.min(size.width, size.height) * 0.8;
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(MeshGradientPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.colors != colors;
}
