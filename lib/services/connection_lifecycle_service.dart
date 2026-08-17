import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class ConnectionLifecycleService extends WidgetsBindingObserver {
  static final ConnectionLifecycleService instance =
      ConnectionLifecycleService._internal();
  ConnectionLifecycleService._internal();

  bool _isInitialized = false;
  AppLifecycleState _lastState = AppLifecycleState.resumed;
  final Map<String, xmpp.Connection> _connections = {};

  void init() {
    if (_isInitialized) return;
    _isInitialized = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void registerConnection(String accountId, xmpp.Connection connection) {
    _connections[accountId] = connection;
  }

  void unregisterConnection(String accountId) {
    _connections.remove(accountId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previousState = _lastState;
    _lastState = state;

    if (previousState == AppLifecycleState.paused ||
        previousState == AppLifecycleState.hidden ||
        previousState == AppLifecycleState.inactive) {
      if (state == AppLifecycleState.resumed) {
        _onAppResumed();
      }
    }

    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _onAppPaused();
    }
  }

  void _onAppResumed() {
    debugPrint('Lifecycle: App resumed — checking XMPP connections');
    for (final entry in _connections.entries) {
      final id = entry.key;
      final conn = entry.value;
      final state = conn.state;
      if (state == xmpp.XmppConnectionState.ForcefullyClosed) {
        debugPrint('Lifecycle: Reconnecting account $id (forcefully closed)');
        conn.reconnect();
      } else if (state == xmpp.XmppConnectionState.Idle ||
          state == xmpp.XmppConnectionState.Closed) {
        debugPrint('Lifecycle: Reconnecting account $id (state: $state)');
        conn.connect();
      } else if (state == xmpp.XmppConnectionState.Ready ||
          state == xmpp.XmppConnectionState.Resumed) {
        debugPrint('Lifecycle: Account $id still connected, sending ping');
        _pingConnection(id, conn);
      } else {
        debugPrint('Lifecycle: Account $id in state $state, waiting');
      }
    }
  }

  void _onAppPaused() {
    debugPrint('Lifecycle: App paused — connections will rely on keepalive pings');
  }

  void _pingConnection(String id, xmpp.Connection conn) {
    try {
      final ping = xmpp.IqStanza(
        xmpp.AbstractStanza.getRandomId(),
        xmpp.IqStanzaType.GET,
      );
      ping.fromJid = conn.fullJid;
      ping.toJid = xmpp.Jid.fromFullJid(conn.fullJid.domain);
      final pingEl = xmpp.XmppElement();
      pingEl.name = 'ping';
      pingEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:ping'));
      ping.addChild(pingEl);
      conn.writeStanza(ping);
    } catch (e) {
      debugPrint('Lifecycle: Ping failed for $id: $e');
    }
  }

  void dispose() {
    if (_isInitialized) {
      WidgetsBinding.instance.removeObserver(this);
      _isInitialized = false;
    }
  }
}