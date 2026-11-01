import 'push_notification_stub.dart'
    if (dart.library.js_interop) 'push_notification_web.dart';

enum PushPermissionStatus { granted, denied, prompt, unsupported }

class PushSubscription {
  final String endpoint;
  final String? p256dh;
  final String? auth;

  PushSubscription({required this.endpoint, this.p256dh, this.auth});

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    if (p256dh != null) 'p256dh': p256dh,
    if (auth != null) 'auth': auth,
  };
}

abstract class PushNotificationService {
  static PushNotificationService? _instance;
  static PushNotificationService get instance => _instance ??= createPushNotificationService();

  Future<PushPermissionStatus> requestPermission();
  Future<PushPermissionStatus> getPermissionStatus();
  Future<PushSubscription?> getCurrentSubscription();
  Future<bool> subscribe(String accountJid);
  Future<void> unsubscribe();
  void dispose();
}