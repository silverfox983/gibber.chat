import 'package:flutter/material.dart';
import '../breakpoints.dart';

class AdaptiveScaffold extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onNavigationChanged;
  final List<AdaptiveNavItem> navigationItems;
  final Widget Function(BuildContext context) builder;
  final Widget? leading;
  final String? title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final NavigationDirection direction;

  const AdaptiveScaffold({
    super.key,
    required this.currentIndex,
    required this.onNavigationChanged,
    required this.navigationItems,
    required this.builder,
    this.leading,
    this.title,
    this.actions,
    this.floatingActionButton,
    this.direction = NavigationDirection.left,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.getSize(context);

    switch (size) {
      case ScreenSize.compact:
        return _buildCompact(context);
      case ScreenSize.medium:
        return _buildMedium(context);
      case ScreenSize.expanded:
        return _buildExpanded(context);
    }
  }

  Widget _buildCompact(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: title != null
          ? AppBar(
              title: Text(title!),
              leading: leading,
              actions: actions,
              elevation: 0,
              backgroundColor: theme.scaffoldBackgroundColor,
            )
          : null,
      body: builder(context),
      bottomNavigationBar: _AdaptiveBottomNav(
        items: navigationItems,
        currentIndex: currentIndex,
        onTap: onNavigationChanged,
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _buildMedium(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: title != null
          ? AppBar(
              title: Text(title!),
              leading: leading,
              actions: actions,
              elevation: 0,
              backgroundColor: theme.scaffoldBackgroundColor,
            )
          : null,
      body: Row(
        children: [
          if (direction == NavigationDirection.left) ...[
            _AdaptiveNavRail(
              items: navigationItems,
              currentIndex: currentIndex,
              onTap: onNavigationChanged,
              extended: false,
            ),
            const VerticalDivider(width: 1, thickness: 1),
          ],
          Expanded(child: builder(context)),
          if (direction == NavigationDirection.right) ...[
            const VerticalDivider(width: 1, thickness: 1),
            _AdaptiveNavRail(
              items: navigationItems,
              currentIndex: currentIndex,
              onTap: onNavigationChanged,
              extended: false,
            ),
          ],
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _buildExpanded(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          if (direction == NavigationDirection.left) ...[
            _AdaptiveNavRail(
              items: navigationItems,
              currentIndex: currentIndex,
              onTap: onNavigationChanged,
              extended: true,
            ),
            const VerticalDivider(width: 1, thickness: 1),
          ],
          Expanded(child: builder(context)),
          if (direction == NavigationDirection.right) ...[
            const VerticalDivider(width: 1, thickness: 1),
            _AdaptiveNavRail(
              items: navigationItems,
              currentIndex: currentIndex,
              onTap: onNavigationChanged,
              extended: true,
            ),
          ],
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}

enum NavigationDirection { left, right }

class AdaptiveNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final Widget? badge;

  const AdaptiveNavItem({
    required this.icon,
    this.selectedIcon,
    required this.label,
    this.badge,
  });
}

class _AdaptiveBottomNav extends StatelessWidget {
  final List<AdaptiveNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _AdaptiveBottomNav({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      backgroundColor: theme.colorScheme.surface,
      indicatorColor: theme.colorScheme.primaryContainer,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: items.map((item) {
        return NavigationDestination(
          icon: Icon(item.icon),
          selectedIcon: Icon(item.selectedIcon ?? item.icon),
          label: item.label,
        );
      }).toList(),
    );
  }
}

class _AdaptiveNavRail extends StatelessWidget {
  final List<AdaptiveNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool extended;

  const _AdaptiveNavRail({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.extended,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final railWidth = extended
        ? Breakpoints.mediumRailWidth.toDouble()
        : Breakpoints.railWidth.toDouble();

    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      extended: extended,
      minWidth: railWidth,
      backgroundColor: theme.colorScheme.surface,
      indicatorColor: theme.colorScheme.primaryContainer,
      leading: extended
          ? null
          : null,
      destinations: items.map((item) {
        return NavigationRailDestination(
          icon: Icon(item.icon),
          selectedIcon: Icon(item.selectedIcon ?? item.icon),
          label: Text(item.label),
          padding: const EdgeInsets.symmetric(vertical: 4),
        );
      }).toList(),
    );
  }
}

class AdaptivePanel extends StatelessWidget {
  final Widget header;
  final Widget body;
  final Widget? footer;
  final ScrollController? scrollController;
  final bool showHeader;
  final double? headerHeight;

  const AdaptivePanel({
    super.key,
    required this.header,
    required this.body,
    this.footer,
    this.scrollController,
    this.showHeader = true,
    this.headerHeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!showHeader) {
      return body;
    }

    return Column(
      children: [
        SizedBox(
          height: headerHeight ?? 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: header),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(child: body),
        if (footer != null) ...[
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          footer!,
        ],
      ],
    );
  }
}
