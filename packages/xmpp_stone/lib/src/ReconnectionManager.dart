import 'dart:async';
import 'dart:math';
import 'package:xmpp_stone/src/Connection.dart';
import 'logger/Log.dart';

class ReconnectionManager {
  static const TAG = 'ReconnectionManager';

  late Connection _connection;
  bool isActive = false;
  int initialTimeout = 1000;
  int totalReconnections = 30;
  late int timeOutInMs;
  int counter = 0;
  Timer? timer;
  late StreamSubscription<XmppConnectionState> _xmppConnectionStateSubscription;
  final Random _random = Random();

  static const int _maxBackoffMs = 60000;
  static const double _jitterFactor = 0.25;

  ReconnectionManager(Connection connection) {
    _connection = connection;
    _xmppConnectionStateSubscription =
        _connection.connectionStateStream.listen(connectionStateHandler);
    initialTimeout = _connection.account.reconnectionTimeout;
    totalReconnections = _connection.account.totalReconnections;
    timeOutInMs = initialTimeout;
  }

  int _jitter(int baseMs) {
    final jitterRange = (baseMs * _jitterFactor).toInt();
    return baseMs + _random.nextInt(jitterRange * 2) - jitterRange;
  }

  void connectionStateHandler(XmppConnectionState state) {
    if (state == XmppConnectionState.ForcefullyClosed) {
      Log.d(TAG, 'Connection forcefully closed!');
      handleReconnection();
    } else if (state == XmppConnectionState.Closed) {
      Log.d(TAG, 'Connection closed');
      handleReconnection();
    } else if (state == XmppConnectionState.SocketOpening) {
      // connection is being opened, do nothing
    } else if (state == XmppConnectionState.AuthenticationFailure) {
      Log.d(TAG, 'Authentication failed - stopping reconnection');
      _resetState();
    } else if (state == XmppConnectionState.Ready ||
        state == XmppConnectionState.Resumed) {
      Log.d(TAG, 'Connected successfully - resetting reconnection state');
      _resetState();
    } else if (state != XmppConnectionState.Reconnecting) {
      isActive = false;
      _resetState();
    }
  }

  void _resetState() {
    isActive = false;
    timeOutInMs = initialTimeout;
    counter = 0;
    timer?.cancel();
    timer = null;
  }

  void handleReconnection() {
    timer?.cancel();
    if (counter < totalReconnections) {
      final delayMs = _jitter(timeOutInMs.clamp(initialTimeout, _maxBackoffMs));
      Log.d(TAG, 'Reconnecting in ${delayMs}ms (attempt ${counter + 1}/$totalReconnections)');
      timer = Timer(Duration(milliseconds: delayMs), _connection.reconnect);
      timeOutInMs = (timeOutInMs * 2).clamp(initialTimeout, _maxBackoffMs);
      counter++;
      isActive = true;
    } else {
      Log.d(TAG, 'Max reconnection attempts reached ($totalReconnections). Giving up.');
      _connection.close();
    }
  }

  void close() {
    timer?.cancel();
    timer = null;
    isActive = false;
    counter = 0;
    timeOutInMs = initialTimeout;
    _xmppConnectionStateSubscription.cancel();
  }
}