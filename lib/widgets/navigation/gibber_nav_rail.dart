import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../models/chat_models.dart';
import '../../services/auth_service.dart';

class GibberNavRail extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onToggleSidebar;
  final bool sidebarCollapsed;

  const GibberNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onToggleSidebar,
    this.sidebarCollapsed = false,
  });

  @override
  State<GibberNavRail> createState() => _GibberNavRailState();
}

class _GibberNavRailState extends State<GibberNavRail> {
  bool _fabOpen = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? AppColors.primaryLight : AppColors.primaryDark;
    final dividerColor = Theme.of(context).dividerColor;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          width: 72,
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.75),
            border: Border(
              right: BorderSide(
                color: dividerColor.withValues(alpha: 0.15),
              ),
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 12),
                _buildLogo(isDark),
                const SizedBox(height: 20),
                _buildAccountSwitcher(context),
                const SizedBox(height: 16),
                Divider(indent: 14, endIndent: 14, thickness: 1, color: dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                Expanded(
                  child: Column(
                    children: List.generate(_destinations.length, (i) {
                      final dest = _destinations[i];
                      final isSelected = widget.selectedIndex == i;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: _NavRailItem(
                          icon: isSelected ? (dest.selectedIcon ?? dest.icon) : dest.icon,
                          label: dest.label,
                          isSelected: isSelected,
                          primary: primary,
                          isDark: isDark,
                          onTap: () => widget.onDestinationSelected(i),
                        ),
                      );
                    }),
                  ),
                ),
                _buildQuickActionsFab(isDark),
                if (widget.onToggleSidebar != null) ...[
                  Divider(indent: 14, endIndent: 14, thickness: 1, color: dividerColor.withValues(alpha: 0.3)),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton(
                      icon: Icon(widget.sidebarCollapsed ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 20),
                      color: isDark ? Colors.white54 : Colors.black54,
                      onPressed: widget.onToggleSidebar,
                      tooltip: widget.sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar',
                      style: IconButton.styleFrom(
                        backgroundColor: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.08),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(bool isDark) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryDark],
        ),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Center(
        child: Text(
          'G',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildAccountSwitcher(BuildContext context) {
    final authService = context.watch<AuthService>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accounts = authService.savedAccounts;
    if (accounts.isEmpty) return const SizedBox.shrink();

    return Column(
      children: accounts.map((acc) {
        final status = authService.getAccountStatus(acc.fullJid);
        final isSelected = authService.activeAccountId == acc.fullJid;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: '${acc.fullJid} (${status.name})',
            child: GestureDetector(
              onTap: () => authService.switchAccount(acc.fullJid),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isDark ? AppColors.primaryLight : AppColors.primaryDark)
                      : (isDark ? Colors.white12 : Colors.black12),
                  shape: BoxShape.circle,
                  border: isSelected
                      ? Border.all(color: AppColors.primary, width: 2)
                      : null,
                ),
                child: Icon(
                  acc.protocol == 'Discord'
                      ? Icons.discord
                      : (acc.protocol == 'IRC' ? Icons.tag : Icons.chat_bubble_outline),
                  color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black54),
                  size: 16,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  List<NavigationRailDestination> get _destinations => const [
        NavigationRailDestination(
          icon: Icon(Icons.chat_outlined),
          selectedIcon: Icon(Icons.chat),
          label: Text('Chats'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: Text('Buddies'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.dynamic_feed_rounded),
          selectedIcon: Icon(Icons.dynamic_feed),
          label: Text('Feed'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.workspaces_outline),
          selectedIcon: Icon(Icons.workspaces_filled),
          label: Text('Spaces'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('Profile'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.manage_search_rounded),
          selectedIcon: Icon(Icons.search_rounded),
          label: Text('Search'),
        ),
      ];

  Widget _buildQuickActionsFab(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuickActionMenu(
            isOpen: _fabOpen,
            onToggle: () => setState(() => _fabOpen = !_fabOpen),
            onNewChat: () {
              setState(() => _fabOpen = false);
              context.pushNamed('newChat');
            },
            onNewSpace: () {
              setState(() => _fabOpen = false);
              context.pushNamed('createSpace');
            },
            onNewPost: () {
              setState(() => _fabOpen = false);
              context.pushNamed('createPost');
            },
            isDark: isDark,
          ),
        ],
      ),
    );
  }
}

class _QuickActionMenu extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onToggle;
  final VoidCallback onNewChat;
  final VoidCallback onNewSpace;
  final VoidCallback onNewPost;
  final bool isDark;

  const _QuickActionMenu({
    required this.isOpen,
    required this.onToggle,
    required this.onNewChat,
    required this.onNewSpace,
    required this.onNewPost,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final primary = isDark ? AppColors.primaryLight : AppColors.primaryDark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isOpen) ...[
          _AnimatedActionBtn(icon: Icons.chat_bubble_outline_rounded, label: 'Chat', onTap: onNewChat, primary: primary, isDark: isDark),
          const SizedBox(height: 6),
          _AnimatedActionBtn(icon: Icons.workspaces_outlined, label: 'Space', onTap: onNewSpace, primary: primary, isDark: isDark),
          const SizedBox(height: 6),
          _AnimatedActionBtn(icon: Icons.edit_note_rounded, label: 'Post', onTap: onNewPost, primary: primary, isDark: isDark),
          const SizedBox(height: 6),
        ],
        GestureDetector(
          onTap: onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [primary, primary.withValues(alpha: 0.8)],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: primary.withValues(alpha: 0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: AnimatedRotation(
              turns: isOpen ? 0.125 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
            ),
          ),
        ),
      ],
    );
  }

}

class _AnimatedActionBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color primary;
  final bool isDark;

  const _AnimatedActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primary,
    required this.isDark,
  });

  @override
  State<_AnimatedActionBtn> createState() => _AnimatedActionBtnState();
}

class _AnimatedActionBtnState extends State<_AnimatedActionBtn> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    _controller.forward();
  }

  @override
  void dispose() => _controller.dispose();

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Tooltip(
        message: widget.label,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: widget.isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.primary.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: Icon(widget.icon, size: 18, color: widget.primary),
          ),
        ),
      ),
    );
  }
}

class _NavRailItem extends StatefulWidget {
  final Widget icon;
  final Widget label;
  final bool isSelected;
  final Color primary;
  final bool isDark;
  final VoidCallback onTap;

  const _NavRailItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.primary,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_NavRailItem> createState() => _NavRailItemState();
}

class _NavRailItemState extends State<_NavRailItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? widget.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTheme(
                data: IconThemeData(
                  color: widget.isSelected
                      ? widget.primary
                      : (widget.isDark ? Colors.white54 : Colors.black54),
                  size: 22,
                ),
                child: widget.icon,
              ),
              const SizedBox(height: 5),
              DefaultTextStyle(
                style: TextStyle(
                  color: widget.isSelected
                      ? widget.primary
                      : (widget.isDark ? Colors.white54 : Colors.black54),
                  fontWeight: widget.isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 10.5,
                ),
                child: widget.label,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
