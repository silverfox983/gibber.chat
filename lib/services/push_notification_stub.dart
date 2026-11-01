import 'push_notification_service.dart'
    show PushPermissionStatus, PushNotificationService, PushSubscription;

PushNotificationService createPushNotificationService() => PushNotificationStub();

class PushNotificationStub implements PushNotificationService {
  @override Future<PushPermissionStatus> requestPermission() async => PushPermissionStatus.unsupported;
  @override Future<PushPermissionStatus> getPermissionStatus() async => PushPermissionStatus.unsupported;
  @override Future<PushSubscription?> getCurrentSubscription() async => null;
  @override Future<bool> subscribe(String accountJid) async => false;
  @override Future<void> unsubscribe() async {}
  @override void dispose() {}
}