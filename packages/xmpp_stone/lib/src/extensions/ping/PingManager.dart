import 'dart:async';

import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/logger/Log.dart';

class PingManager {

  static const String TAG = 'PingManager';
  final Connection _connection;

  static final Map<Connection, PingManager> _instances = {};

  late StreamSubscription<XmppConnectionState> _xmppConnectionStateSubscription;
  late StreamSubscription<AbstractStanza?> _abstractStanzaSubscription;

  Timer? _pingTimer;
  Duration _pingInterval = const Duration(seconds: 60);
  Duration _pingTimeout = const Duration(seconds: 30);
  int _pendingPings = 0;
  static const int _maxPendingPings = 3;

  PingManager(this._connection) {
    _xmppConnectionStateSubscription =
        _connection.connectionStateStream.listen(_connectionStateProcessor);
    _abstractStanzaSubscription =
        _connection.inStanzasStream.listen(_processStanza);
  }

  static PingManager getInstance(Connection connection) {
    var manager = _instances[connection];
    if (manager == null) {
      manager = PingManager(connection);
      _instances[connection] = manager;
    }
    return manager;
  }

  static void removeInstance(Connection connection) {
    _instances[connection]?._stopPingTimer();
    _instances[connection]?._abstractStanzaSubscription.cancel();
    _instances[connection]?._xmppConnectionStateSubscription.cancel();
    _instances.remove(connection);
  }

  void setPingInterval(Duration interval, {Duration? timeout}) {
    _pingInterval = interval;
    if (timeout != null) _pingTimeout = timeout;
    if (_pingTimer != null) {
      _stopPingTimer();
      _startPingTimer();
    }
  }

  void _connectionStateProcessor(XmppConnectionState event) {
    if (event == XmppConnectionState.Ready || event == XmppConnectionState.Resumed) {
      _startPingTimer();
    } else if (event == XmppConnectionState.Closed ||
        event == XmppConnectionState.ForcefullyClosed ||
        event == XmppConnectionState.Idle) {
      _stopPingTimer();
    }
  }

  void _startPingTimer() {
    _pingTimer ??= Timer.periodic(_pingInterval, (_) => _sendPing());
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pendingPings = 0;
  }

  void _sendPing() {
    if (_connection.state != XmppConnectionState.Ready &&
        _connection.state != XmppConnectionState.Resumed) {
      _stopPingTimer();
      return;
    }

    if (_pendingPings >= _maxPendingPings) {
      Log.w(TAG, '$_maxPendingPings unanswered pings — connection likely dead, forcing close');
      _stopPingTimer();
      _connection.close();
      return;
    }

    final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.GET);
    iq.fromJid = _connection.fullJid;
    iq.toJid = Jid.fromFullJid(_connection.fullJid.domain);
    final pingElement = XmppElement();
    pingElement.name = 'ping';
    pingElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:ping'));
    iq.addChild(pingElement);
    _connection.writeStanza(iq);
    _pendingPings++;
    Log.d(TAG, 'Sent keepalive ping (pending: $_pendingPings/$_maxPendingPings)');

    Timer(_pingTimeout, () {
      if (_pendingPings > 0) {
        _pendingPings--;
      }
    });
  }

  void _processStanza(AbstractStanza? stanza) {
    if (stanza is IqStanza) {
      if (stanza.type == IqStanzaType.GET) {
        var ping = stanza.getChild('ping');
        if (ping != null) {
          var iqStanza = IqStanza(stanza.id, IqStanzaType.RESULT);
          iqStanza.fromJid = _connection.fullJid;
          iqStanza.toJid = stanza.fromJid;
          _connection.writeStanza(iqStanza);
        }
      } else if (stanza.type == IqStanzaType.RESULT || stanza.type == IqStanzaType.ERROR) {
        if (_pendingPings > 0) {
          _pendingPings = 0;
          Log.d(TAG, 'Ping response received — connection alive');
        }
      }
    }
  }
}
