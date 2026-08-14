import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'auth_service.dart';
import 'persistent_notification_manager.dart';

/// Service to handle the System Tray icon and status indicator on Desktop (Windows/Linux)
class AppStatusTrayService with TrayListener, WindowListener {
  AppStatusTrayService._();
  static final AppStatusTrayService instance = AppStatusTrayService._();

  bool _initialized = false;
  AuthService? _authService;

  Future<void> init(AuthService authService) async {
    if (_initialized || kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;
    
    _authService = authService;
    _initialized = true;

    // 1. Initialize Tray Manager
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/logo.png' : 'assets/logo.png', 
      );
    } catch (e) {
      debugPrint('TrayManager: Failed to set icon: $e');
    }
    
    trayManager.addListener(this);

    // 2. Initialize Window Manager for background behavior
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // Prevent app from exiting on close - we want to hide it to tray
    await windowManager.setPreventClose(true);

    // 3. Listen to auth changes to update status
    _authService!.addListener(_updateStatus);
    await _updateStatus();
  }

  void stop() {
    if (_initialized && _authService != null) {
      _authService!.removeListener(_updateStatus);
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _initialized = false;
    _authService = null;
  }

  Future<void> refresh() async {
    await _updateStatus();
  }

  Future<void> _updateStatus() async {
    if (!_initialized) return;

    final lines = _authService!.getAccountsStatusLines();
    final connectedCount = lines
        .where((l) => l.contains('Online') || l.contains('Connecting'))
        .length;

    final tooltip = connectedCount > 0
        ? 'Gibber: $connectedCount Active Session(s)'
        : 'Gibber: Accounts Offline';

    await trayManager.setToolTip(tooltip);

    // Build Context Menu
    final List<MenuItem> menuItems = [
      MenuItem(
        key: 'show_window',
        label: 'Open Gibber',
      ),
      MenuItem.separator(),
    ];

    // Add account statuses to menu
    for (var line in lines) {
      menuItems.add(MenuItem(
        key: 'account_status_${line.hashCode}',
        label: line,
        disabled: true,
      ));
    }

    menuItems.addAll([
      MenuItem.separator(),
      MenuItem(
        key: 'exit_app',
        label: 'Exit Gibber',
      ),
    ]);

    // Add Recent Messages section
    final recentMsgs = PersistentNotificationManager.instance.recentMessages;
    if (recentMsgs.isNotEmpty) {
      menuItems.insertAll(2, [
        MenuItem(key: 'msg_header', label: 'Recent Messages:', disabled: true),
        ...recentMsgs.map((m) {
          final sender = m.senderName ?? m.senderId?.split('@').first ?? 'Unknown';
          return MenuItem(
            key: 'msg_${m.id}',
            label: '💬 $sender: ${m.text}',
          );
        }),
        MenuItem(key: 'clear_messages', label: 'Clear Recent Messages'),
        MenuItem.separator(),
      ]);
    }

    await trayManager.setContextMenu(Menu(items: menuItems));
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      _showWindow();
    } else if (menuItem.key == 'exit_app') {
      _exitApp();
    } else if (menuItem.key == 'clear_messages') {
      PersistentNotificationManager.instance.clearRecentMessages();
    } else if (menuItem.key?.startsWith('msg_') == true) {
      _showWindow();
    }
  }

  @override
  void onWindowClose() async {
    // When the user clicks the X, we hide to tray instead of exiting
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}