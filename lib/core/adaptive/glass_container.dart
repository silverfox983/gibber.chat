import 'dart:ui';
import 'package:flutter/material.dart';
import '../design_tokens.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final Color? backgroundColor;
  final double blur;
  final double opacity;
  final Border? border;
  final Gradient? gradient;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = DesignTokens.radius2xl,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.backgroundColor,
    this.blur = 12,
    this.opacity = 0.35,
    this.border,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: width,
      height: height,
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding ?? const EdgeInsets.all(DesignTokens.space16),
            decoration: BoxDecoration(
              color: backgroundColor ??
                  (isDark
                      ? const Color(0xFF1E293B).withValues(alpha: opacity)
                      : Colors.white.withValues(alpha: opacity * 0.75)),
              border: border ??
                  Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
                    width: 1,
                  ),
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: gradient,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? accentColor;
  final bool selected;
  final bool elevated;

  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = DesignTokens.radiusLg,
    this.padding,
    this.margin,
    this.accentColor,
    this.selected = false,
    this.elevated = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF1E293B).withValues(alpha: 0.6)
        : Colors.white.withValues(alpha: 0.8);

    Widget content = Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: selected
              ? (accentColor ?? theme.colorScheme.primary)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04)),
          width: selected ? 2 : 1,
        ),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Padding(
            padding: padding ?? const EdgeInsets.all(DesignTokens.space16),
            child: child,
          ),
        ),
      ),
    );

    if (accentColor != null && selected) {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border(
            left: BorderSide(color: accentColor!, width: 3),
          ),
        ),
        child: content,
      );
    }

    if (onTap != null) {
      return MarginLink(
        margin: margin,
        onTap: onTap,
        child: content,
      );
    }

    if (margin != null) {
      return Padding(padding: margin!, child: content);
    }

    return content;
  }
}

class MarginLink extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  const MarginLink({
    super.key,
    required this.child,
    this.margin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    if (onTap != null) {
      result = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg),
        child: result,
      );
    }
    return result;
  }
}

class GradientBorderContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double borderWidth;
  final Gradient? gradient;
  final Color? backgroundColor;

  const GradientBorderContainer({
    super.key,
    required this.child,
    this.borderRadius = DesignTokens.radiusLg,
    this.padding,
    this.borderWidth = 1,
    this.gradient,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final defaultGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        (isDark ? Colors.white : Colors.black).withValues(alpha: 0.2),
        (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: gradient ?? defaultGradient,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Padding(
        padding: EdgeInsets.all(borderWidth),
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor ?? theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(borderRadius - borderWidth),
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}
