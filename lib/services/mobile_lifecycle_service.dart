import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundKeepAliveTaskHandler());
}

class BackgroundKeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('Foreground Service Started to keep process alive.');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Keep alive heartbeat
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('Foreground Service Destroyed. Timeout: $isTimeout');
  }
}

class MobileLifecycleService extends WidgetsBindingObserver {
  static final MobileLifecycleService instance =
      MobileLifecycleService._internal();
  MobileLifecycleService._internal();

  bool _isInitialized = false;

  Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'gibber_background_service',
        channelName: 'Background Service',
        channelDescription:
            'Keeps Gibber connected to receive messages and calls.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true, // App starts on device boot
        allowWakeLock: true, // Keep CPU active for XMPP
        allowWifiLock: true, // Keep WiFi active for XMPP
      ),
    );

    _isInitialized = true;
    WidgetsBinding.instance.addObserver(this);

    // Request permissions required for foreground service
    await FlutterForegroundTask.requestNotificationPermission();

    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations == false) {
      // Suggest user to disable battery optimizations for background reliability
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // We keep the service running even when resumed to ensure connection stability
    // but we can adjust priorities here if needed.
    if (!_isInitialized || kIsWeb || !Platform.isAndroid) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Ensure it's definitely running when we leave foreground
      _startBackgroundService();
    }
  }

  /// Syncs the foreground service state based on whether the user is logged in
  Future<void> syncServiceState(bool isAuthenticated) async {
    if (kIsWeb || !Platform.isAndroid || !_isInitialized) return;

    if (isAuthenticated) {
      await _startBackgroundService();
    } else {
      await _stopBackgroundService();
    }
  }

  Future<void> _startBackgroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;

    // Ensure we have permissions before starting
    final isIgnoringBattery =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;

    await FlutterForegroundTask.startService(
      notificationTitle: 'Gibber Connected',
      notificationText: 'Running in background to receive messages',
      callback: startCallback,
    );
  }

  Future<void> _stopBackgroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
