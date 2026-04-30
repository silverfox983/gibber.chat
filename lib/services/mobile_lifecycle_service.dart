import 'dart:io';
import 'dart:isolate';
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
  static final MobileLifecycleService instance = MobileLifecycleService._internal();
  MobileLifecycleService._internal();

  bool _isInitialized = false;

  Future<void> init() async {
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'gibber_background_service',
        channelName: 'Background Service',
        channelDescription: 'Keeps Gibber connected to receive messages and calls.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
    WidgetsBinding.instance.addObserver(this);

    // Request permissions required for foreground service
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations == false) {
      // Optional: Suggest user to disable battery optimizations
    }
    
    // Android 13+ requires notification permissions
    await FlutterForegroundTask.requestNotificationPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isInitialized || !Platform.isAndroid) return;

    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _startBackgroundService();
    } else if (state == AppLifecycleState.resumed) {
      _stopBackgroundService();
    }
  }

  Future<void> _startBackgroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    
    // Ensure we have permissions before starting
    final isIgnoringBattery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    
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
