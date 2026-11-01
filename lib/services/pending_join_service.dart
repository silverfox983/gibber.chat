import 'package:flutter/foundation.dart';

import '../models/join_intent.dart';

/// Holds a join request made before authentication (e.g. from the landing
/// page's trending-rooms), so the chat shell can resume it post-login.
class PendingJoinService extends ChangeNotifier {
  PendingJoinService._();
  static final PendingJoinService instance = PendingJoinService._();

  JoinIntent? _pending;

  JoinIntent? get pending => _pending;

  void set(JoinIntent intent) {
    _pending = intent;
    notifyListeners();
  }

  JoinIntent? take() {
    final intent = _pending;
    _pending = null;
    return intent;
  }

  void clear() {
    _pending = null;
  }
}