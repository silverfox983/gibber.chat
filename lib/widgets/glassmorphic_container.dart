import 'dart:ui';
import 'package:flutter/material.dart';

/// A reusable frosted‑glass container.
///
/// This widget applies a [BackdropFilter] with a blur and a semi‑transparent
/// gradient overlay, giving a premium glass‑morphism effect.
class GlassMorphicContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  const GlassMorphicContainer({
    required this.child,
    this.borderRadius = 24.0,
    this.padding,
    this.width,
    this.height,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: width,
          height: height,
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.35),
            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.2)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface.withValues(alpha: 0.25),
                theme.colorScheme.surface.withValues(alpha: 0.55),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          child: child,
        ),
      ),
    );
  }
}
