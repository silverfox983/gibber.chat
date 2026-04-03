import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/call_log.dart';

class CallHistoryService with ChangeNotifier {
  static const String _key = 'call_history_logs';
  List<CallLog> _logs = [];
  List<CallLog> get logs => List.unmodifiable(_logs);

  CallHistoryService() {
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_key) ?? [];
    _logs = data
        .map((e) => CallLog.fromJson(jsonDecode(e)))
        .toList();
    notifyListeners();
  }

  Future<void> addLog(CallLog log) async {
    final prefs = await SharedPreferences.getInstance();
    _logs = [log, ..._logs].take(100).toList();
    final data = _logs.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList(_key, data);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    _logs = [];
    notifyListeners();
  }
}
