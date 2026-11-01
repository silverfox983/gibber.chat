import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'push_notification_service.dart'
    show PushPermissionStatus, PushNotificationService, PushSubscription;

@JS('Notification.permission')
external JSString get _notificationPermission;

@JS('Notification.requestPermission')
external JSPromise<JSString> _notificationRequestPermission();

@JS('window.pushManager')
external _PushManager? get _pushManager;

@JS()
@staticInterop
class _PushManager {}

extension _PushManagerExt on _PushManager {
  external JSPromise<JSObject?> getSubscription();
  external JSPromise<JSObject> subscribe(JSObject options);
}

@JS()
@staticInterop
class _PushSubscription {}

extension _PushSubscriptionExt on _PushSubscription {
  external JSString get endpoint;
  external JSObject? getKey(JSString name);
  external JSPromise<JSBoolean> unsubscribe();
}

PushNotificationService createPushNotificationService() => PushNotificationWeb();

class PushNotificationWeb implements PushNotificationService {
  static const _storageKey = 'gibber_push_subscription';
  static const _vapidKey = 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U';

  @override
  Future<PushPermissionStatus> requestPermission() async {
    try {
      final result = await _notificationRequestPermission().toDart;
      return _permissionToStatus(result.toDart);
    } catch (e) {
      debugPrint('Push permission request failed: $e');
      return PushPermissionStatus.denied;
    }
  }

  @override
  Future<PushPermissionStatus> getPermissionStatus() async {
    try {
      final result = _notificationPermission.toDart;
      return _permissionToStatus(result);
    } catch (e) {
      return PushPermissionStatus.unsupported;
    }
  }

  PushPermissionStatus _permissionToStatus(String state) {
    switch (state) {
      case 'granted': return PushPermissionStatus.granted;
      case 'denied': return PushPermissionStatus.denied;
      default: return PushPermissionStatus.prompt;
    }
  }

  @override
  Future<PushSubscription?> getCurrentSubscription() async {
    final pm = _pushManager;
    if (pm == null) return null;
    try {
      final sub = await pm.getSubscription().toDart;
      if (sub == null) return null;
      return _subToSubscription(sub as _PushSubscription);
    } catch (e) {
      debugPrint('Get push notification subscription failed: $e');
      return null;
    }
  }

  PushSubscription _subToSubscription(_PushSubscription sub) {
    final endpoint = sub.endpoint.toDart;
    final p256dhKey = sub.getKey('p256dh'.toJS);
    final authKey = sub.getKey('auth'.toJS);
    String? p256dh;
    String? auth;
    if (p256dhKey != null) {
      p256dh = base64Encode(_jsBufferToBytes(p256dhKey));
    }
    if (authKey != null) {
      auth = base64Encode(_jsBufferToBytes(authKey));
    }
    return PushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth);
  }

  List<int> _jsBufferToBytes(JSObject buffer) {
    final byteLength = (buffer as dynamic).byteLength as int;
    final result = List<int>.filled(byteLength, 0);
    for (var i = 0; i < byteLength; i++) {
      result[i] = (buffer as dynamic)[i] as int;
    }
    return result;
  }

  @override
  Future<bool> subscribe(String accountJid) async {
    final pm = _pushManager;
    if (pm == null) return false;
    try {
      final appServerKeyBytes = base64Decode(_vapidKey.replaceAll('-', '+').replaceAll('_', '/'));
      final options = {
        'userVisibleOnly': true,
        'applicationServerKey': appServerKeyBytes,
      }.jsify() as JSObject;
      final sub = await pm.subscribe(options).toDart;
      final subscription = _subToSubscription(sub as _PushSubscription);
      await _storeSubscription(accountJid, subscription);
      await _registerSubscriptionBackend(accountJid, subscription);
      return true;
    } catch (e) {
      debugPrint('Push subscription failed: $e');
      return false;
    }
  }

  Future<void> _storeSubscription(String jid, PushSubscription sub) async {
    final prefs = await SharedPreferences.getInstance();
    final all = prefs.getString(_storageKey) ?? '{}';
    final Map<String, dynamic> subs = jsonDecode(all);
    subs[jid] = sub.toJson();
    await prefs.setString(_storageKey, jsonEncode(subs));
  }

  Future<void> _registerSubscriptionBackend(String jid, PushSubscription sub) async {
    const apiUrl = 'https://gibberapp.online';
    try {
      final response = await http.post(
        Uri.parse('$apiUrl/push/subscribe'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'jid': jid, 'subscription': sub.toJson()}),
      );
      if (response.statusCode != 200) {
        debugPrint('Backend push registration failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Backend push registration error: $e');
    }
  }

  @override
  Future<void> unsubscribe() async {
    final pm = _pushManager;
    if (pm == null) return;
    try {
      final sub = await pm.getSubscription().toDart;
      if (sub != null) {
        await (sub as _PushSubscription).unsubscribe().toDart;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (e) {
      debugPrint('Push unsubscribe failed: $e');
    }
  }

  @override
  void dispose() {}
}