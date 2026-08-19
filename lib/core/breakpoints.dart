import 'package:flutter/material.dart';

enum ScreenSize { compact, medium, expanded }

class Breakpoints {
  static const double compactMax = 639;
  static const double mediumMax = 1199;

  static const double sidebarWidth = 320;
  static const double railWidth = 72;
  static const double mediumRailWidth = 280;

  static ScreenSize getSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return getSizeFromWidth(width);
  }

  static ScreenSize getSizeFromWidth(double width) {
    if (width <= compactMax) return ScreenSize.compact;
    if (width <= mediumMax) return ScreenSize.medium;
    return ScreenSize.expanded;
  }

  static bool isCompactWidth(BuildContext context) =>
      getSize(context) == ScreenSize.compact;

  static bool isMediumWidth(BuildContext context) =>
      getSize(context) == ScreenSize.medium;

  static bool isExpandedWidth(BuildContext context) =>
      getSize(context) == ScreenSize.expanded;

  static double contentMaxWidth(BuildContext context) {
    final size = getSize(context);
    if (size == ScreenSize.compact) return double.infinity;
    if (size == ScreenSize.medium) return 900;
    return 1400;
  }
}

class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, ScreenSize size) compact;
  final Widget Function(BuildContext context, ScreenSize size)? medium;
  final Widget Function(BuildContext context, ScreenSize size)? expanded;

  const ResponsiveBuilder({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.getSize(context);
    switch (size) {
      case ScreenSize.compact:
        return compact(context, size);
      case ScreenSize.medium:
        return (medium ?? compact)(context, size);
      case ScreenSize.expanded:
        return (expanded ?? medium ?? compact)(context, size);
    }
  }
}

class ResponsiveLayout extends StatelessWidget {
  final Widget compact;
  final Widget? medium;
  final Widget? expanded;

  const ResponsiveLayout({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.getSize(context);
    switch (size) {
      case ScreenSize.compact:
        return compact;
      case ScreenSize.medium:
        return medium ?? compact;
      case ScreenSize.expanded:
        return expanded ?? medium ?? compact;
    }
  }
}

extension ResponsiveExtensions on BuildContext {
  ScreenSize get screenSize => Breakpoints.getSize(this);
  bool get isCompact => screenSize == ScreenSize.compact;
  bool get isMedium => screenSize == ScreenSize.medium;
  bool get isExpanded => screenSize == ScreenSize.expanded;
  double get sidebarWidth => Breakpoints.sidebarWidth.toDouble();
}
