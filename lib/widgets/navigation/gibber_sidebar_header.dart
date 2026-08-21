import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/design_tokens.dart';
import '../../core/app_colors.dart';
import '../../models/chat_models.dart';
import '../../services/auth_service.dart';
import '../../providers/chat_provider.dart';
import '../../providers/theme_provider.dart';

class GibberSidebarHeader extends StatelessWidget {
  final ChatProvider chatProvider;
  final AuthService authService;
  final VoidCallback? onCollapseSidebar;

  const GibberSidebarHeader({
    super.key,
    required this.chatProvider,
    required this.authService,
    this.onCollapseSidebar,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primaryDark,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleRow(context, isDark),
          const SizedBox(height: 24),
          _buildSearchField(context),
          const SizedBox(height: 20),
          _buildStatusRow(context, isDark),
        ],
      ),
    );
  }

  Widget _buildTitleRow(BuildContext context, bool isDark) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
          ),
          child: const Center(
            child: Text(
              'G',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'Gibber',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        const Spacer(),
        if (onCollapseSidebar != null) ...[
          IconButton(
            icon: const Icon(Icons.menu_open_rounded, color: Colors.white70, size: 20),
            onPressed: onCollapseSidebar,
            tooltip: 'Collapse Sidebar',
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        _buildThemeToggle(context),
        const SizedBox(width: 4),
        _buildNexusButton(context),
        const SizedBox(width: 4),
        _buildAddMenu(context),
      ],
    );
  }

  Widget _buildThemeToggle(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, tp, _) => IconButton(
        icon: Icon(
          tp.isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          color: Colors.white70,
          size: 20,
        ),
        onPressed: () => tp.toggleTheme(),
        tooltip: 'Toggle Theme',
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
          ),
        ),
      ),
    );
  }

  Widget _buildNexusButton(BuildContext context) {
    return IconButton(
      icon: Icon(
        Icons.travel_explore_rounded,
        color: Colors.white70,
        size: 20,
      ),
      onPressed: () => context.goNamed('search'),
      tooltip: 'Nexus Global Search',
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
        ),
      ),
    );
  }

  Widget _buildAddMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
      ),
      onSelected: (val) => _onAddActionSelected(context, val),
      itemBuilder: (context) => [
        _menuItem('newMessage', Icons.chat_bubble_rounded, 'New Message'),
        _menuItem('buddy', Icons.person_add_rounded, 'Add Buddy'),
        _menuItem('group', Icons.group_add_rounded, 'Create/Join Group'),
        _menuItem('discover', Icons.explore_rounded, 'Discover Rooms'),
        _menuItem('invite', Icons.person_add_alt_rounded, 'Invite Friends'),
        _menuItem('connections', Icons.hub_rounded, 'Connections'),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  void _onAddActionSelected(BuildContext context, String val) {
    if (val == 'newMessage') {
      context.goNamed('newMessage');
      return;
    }
    if (val == 'buddy') chatProvider.setSidebarTab(1);
    if (val == 'group') _showJoinRoomDialog(context);
    if (val == 'discover') {
      chatProvider.setSidebarTab(3);
    }
    if (val == 'invite') {
      context.goNamed('invite');
    }
    if (val == 'connections') {
      context.goNamed('connections');
    }
  }

  void _showJoinRoomDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create/Join Group'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Room JID or Name',
            hintText: 'room@conference.example.com',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      onChanged: (val) => chatProvider.setSearchQuery(val),
      decoration: InputDecoration(
        hintText: 'Search...',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.2),
        contentPadding: const EdgeInsets.symmetric(vertical: 0),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: Colors.white60),
      ),
      style: const TextStyle(color: Colors.white),
    );
  }

  Widget _buildStatusRow(BuildContext context, bool isDark) {
    return GestureDetector(
      onTap: () => _showStatusPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _getStatusColor(authService.myStatus),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                authService.myStatusMessage ?? authService.myStatus.name.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(
              Icons.mode_edit_outline_outlined,
              color: Colors.white54,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(ContactStatus status) {
    switch (status) {
      case ContactStatus.online:
        return Colors.green;
      case ContactStatus.away:
        return Colors.yellow;
      case ContactStatus.dnd:
        return Colors.red;
      case ContactStatus.xa:
        return Colors.orange;
      case ContactStatus.offline:
        return Colors.grey;
    }
  }

  void _showStatusPicker(BuildContext context) {
    final statusCtrl = TextEditingController(text: authService.myStatusMessage);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          top: 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set Presence Status',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: statusCtrl,
              decoration: InputDecoration(
                hintText: "What's on your mind?",
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ...ContactStatus.values.map((status) {
              return ListTile(
                leading: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _getStatusColor(status),
                    shape: BoxShape.circle,
                  ),
                ),
                title: Text(
                  status.name.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                onTap: () {
                  authService.updatePresence(status, message: statusCtrl.text.trim());
                  Navigator.pop(ctx);
                },
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
