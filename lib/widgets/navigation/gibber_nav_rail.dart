import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../models/chat_models.dart';
import '../../services/auth_service.dart';

class GibberNavRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onExpandSidebar;

  const GibberNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onExpandSidebar,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: NavigationRail(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                indicatorColor: (isDark ? AppColors.primary : AppColors.primaryLight).withValues(alpha: 0.2),
                selectedIconTheme: IconThemeData(
                  color: isDark ? AppColors.primaryLight : AppColors.primaryDark,
                ),
                unselectedIconTheme: IconThemeData(
                  color: isDark
                      ? AppColors.textDarkSecondary
                      : AppColors.textLightSecondary,
                ),
                selectedLabelTextStyle: TextStyle(
                  color: isDark ? AppColors.primaryLight : AppColors.primaryDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
                unselectedLabelTextStyle: TextStyle(
                  color: isDark
                      ? AppColors.textDarkSecondary
                      : AppColors.textLightSecondary,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
                labelType: constraints.maxHeight > 600
                    ? NavigationRailLabelType.all
                    : NavigationRailLabelType.selected,
                leading: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        _buildLogo(isDark),
                        const SizedBox(height: 24),
                        _buildAccountSwitcher(context),
                        const SizedBox(height: 20),
                        const Divider(indent: 16, endIndent: 16),
                        if (onExpandSidebar != null) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: IconButton(
                              icon: const Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 20),
                              onPressed: onExpandSidebar,
                              tooltip: 'Expand Sidebar',
                              style: IconButton.styleFrom(
                                backgroundColor: isDark ? Colors.white12 : Colors.black12,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                destinations: _destinations,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogo(bool isDark) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primaryDark,
          ],
        ),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.4),
            blurRadius: 12,
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
    final authService = Provider.of<AuthService>(context, listen: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: authService.savedAccounts.map((acc) {
        final status = authService.getAccountStatus(acc.fullJid);
        final isSelected = authService.activeAccountId == acc.fullJid;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: '${acc.fullJid} (${status.name})',
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: isSelected
                      ? (isDark ? AppColors.primaryLight : AppColors.primaryDark)
                      : (isDark ? Colors.white12 : Colors.black12),
                  child: Icon(
                    acc.protocol == 'Discord'
                        ? Icons.discord
                        : (acc.protocol == 'IRC'
                            ? Icons.tag
                            : Icons.chat_bubble_outline),
                    color: isSelected
                        ? Colors.white
                        : (isDark ? Colors.white70 : Colors.black54),
                    size: 16,
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _statusColor(status),
                      shape: BoxShape.circle,
                      border: Border.all(color: isDark ? Colors.black : Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _statusColor(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.online:
        return Colors.green;
      case ConnectionStatus.connecting:
        return Colors.orange;
      default:
        return Colors.grey;
    }
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
}
