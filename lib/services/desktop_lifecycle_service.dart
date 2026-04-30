import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

class DesktopLifecycleService with WindowListener, TrayListener {
  static final DesktopLifecycleService instance = DesktopLifecycleService._internal();

  DesktopLifecycleService._internal();

  Future<void> init() async {
    if (kIsWeb) return;
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    trayManager.addListener(this);

    // Intercept the close button
    await windowManager.setPreventClose(true);

    // Setup tray icon and menu
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/logo.png' : 'assets/logo.png',
      );

      final Menu menu = Menu(
        items: [
          MenuItem(
            key: 'show_app',
            label: 'Show Gibber',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: 'Exit',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('Error initializing system tray: $e');
    }
  }

  @override
  void onWindowClose() async {
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      // Hide to system tray
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_app') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      await windowManager.setPreventClose(false);
      await windowManager.close();
      exit(0);
    }
  }
}
