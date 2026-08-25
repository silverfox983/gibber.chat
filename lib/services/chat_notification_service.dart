import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatNotificationService {
  static final ChatNotificationService _instance = ChatNotificationService._();
  static ChatNotificationService get instance => _instance;

  ChatNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final Map<String, int> _conversationNotificationIds = {};

  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(android: android, iOS: ios);

    await _plugin.initialize(settings: initSettings);
    _initialized = true;
  }

  int _getConversationNotificationId(String conversationId) {
    if (!_conversationNotificationIds.containsKey(conversationId)) {
      _conversationNotificationIds[conversationId] = DateTime.now().millisecondsSinceEpoch % 2147483647;
    }
    return _conversationNotificationIds[conversationId]!;
  }

  Future<void> showMessageNotification({
    required String conversationId,
    required String conversationName,
    required String senderName,
    required String body,
    required String? accountId,
    required bool isGroup,
    String? avatarUrl,
  }) async {
    if (!_initialized) return;
    if (kIsWeb) return;

    final prefs = await SharedPreferences.getInstance();
    final mutedKey = 'mute_notif_$conversationId';
    if (prefs.getBool(mutedKey) == true) return;

    final notificationId = _getConversationNotificationId(conversationId);

    final androidDetails = AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for incoming chat messages',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(body),
      groupKey: isGroup ? 'group_chats' : 'direct_chats',
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _plugin.show(
      id: notificationId,
      title: isGroup ? '$senderName in $conversationName' : senderName,
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> cancelConversationNotification(String conversationId) async {
    if (!_initialized) return;
    final id = _conversationNotificationIds[conversationId];
    if (id != null) {
      await _plugin.cancel(id: id);
    }
  }

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  Future<void> setMuted(String conversationId, bool muted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mute_notif_$conversationId', muted);
  }

  Future<bool> isMuted(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('mute_notif_$conversationId') ?? false;
  }
}
