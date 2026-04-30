import 'dart:convert';
import 'dart:collection';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import './account_status_notification_service.dart';
import './app_status_tray_service.dart';

/// A central manager that coordinates the persistent "always running" 
/// status notification across Android (status bar) and Desktop (System Tray).
class PersistentNotificationManager {
  PersistentNotificationManager._();
  static final PersistentNotificationManager instance = PersistentNotificationManager._();

  final List<ChatMessage> _recentMessages = [];
  static const int _maxRecent = 5;
  static const String _cacheKey = 'prefs_recent_messages_cache';

  List<ChatMessage> get recentMessages => UnmodifiableListView(_recentMessages);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getStringList(_cacheKey);
      
      if (cachedJson != null && cachedJson.isNotEmpty) {
        _recentMessages.clear();
        for (final msgStr in cachedJson) {
          try {
            final map = json.decode(msgStr) as Map<String, dynamic>;
            _recentMessages.add(ChatMessage.fromMap(map));
          } catch (e) {
            debugPrint('Failed to deserialize cached message: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('PersistentNotificationManager init error: $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encodedList = _recentMessages.map((msg) => json.encode(msg.toMap())).toList();
      await prefs.setStringList(_cacheKey, encodedList);
    } catch (e) {
      debugPrint('PersistentNotificationManager save error: $e');
    }
  }

  void addRecentMessage(ChatMessage message) {
    // Only add incoming non-system messages
    if (message.isSent || message.type == MessageType.system) return;

    // Deduplicate by ID
    if (_recentMessages.any((m) => m.id == message.id)) return;

    _recentMessages.insert(0, message);
    if (_recentMessages.length > _maxRecent) {
      _recentMessages.removeLast();
    }
    
    _saveCache();
    _triggerRefresh();
  }

  void clearRecentMessages() {
    _recentMessages.clear();
    _saveCache();
    _triggerRefresh();
  }

  void _triggerRefresh() {
    // Refresh Android Notification
    AccountStatusNotificationService.instance.refresh();
    
    // Refresh Desktop Tray
    AppStatusTrayService.instance.refresh();
  }
}