import 'dart:io' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'auth_service.dart';

class AccountStatusNotificationService {
  AccountStatusNotificationService._();
  static final AccountStatusNotificationService instance =
      AccountStatusNotificationService._();

  static const String _channelId = 'gibber_connected_accounts';
  static const int _notificationId = 91101;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _isStarted = false;
  AuthService? _authService;

  Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings: initSettings);
    _initialized = true;
  }

  Future<void> start(AuthService authService) async {
    if (!Platform.isAndroid || _isStarted) return;
    await initialize();
    _authService = authService;
    _authService!.addListener(_onAuthChanged);
    _isStarted = true;
    await _refresh();
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (_isStarted && _authService != null) {
      _authService!.removeListener(_onAuthChanged);
    }
    _isStarted = false;
    _authService = null;
    if (_initialized) {
      await _plugin.cancel(id: _notificationId);
    }
  }

  Future<void> _onAuthChanged() async {
    await _refresh();
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid || !_initialized || _authService == null) return;
    final auth = _authService!;
    final lines = auth.getAccountsStatusLines();
    final connectedCount = lines
        .where((l) => l.contains('Online') || l.contains('Connecting'))
        .length;

    final title = connectedCount > 0
        ? 'Gibber: $connectedCount account(s) active'
        : 'Gibber: No active accounts';
    final body = lines.isEmpty
        ? 'No saved accounts'
        : lines.join('\n');

    final android = AndroidNotificationDetails(
      _channelId,
      'Connected Accounts Status',
      channelDescription: 'Shows connected chat account status in notification shade',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
      category: AndroidNotificationCategory.status,
      styleInformation: BigTextStyleInformation(body),
      visibility: NotificationVisibility.public,
      playSound: false,
      enableVibration: false,
      showWhen: false,
    );

    await _plugin.show(
      id: _notificationId,
      title: title,
      body: lines.isEmpty ? body : lines.first,
      notificationDetails: NotificationDetails(android: android),
    );
  }
  void refresh() {}
  }
