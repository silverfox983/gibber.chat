import 'dart:async';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

/// Shared request/response IQ correlation bookkeeping.
///
/// Many XMPP services track outgoing IQ ids and complete a Future when the
/// matching result stanza arrives. This class centralizes that plumbing.
/// Each service keeps its own stanza listening, retries and timeout policies.
class IqRequestManager {
  final Map<String, Completer<xmpp.IqStanza>> _pending = {};

  /// Number of requests awaiting a response.
  int get pendingCount => _pending.length;

  /// True if any request is pending.
  bool get hasPending => _pending.isNotEmpty;

  /// Raw pending-request map (services that route stanza ids across
  /// several managers in one stanza listener).
  Map<String, Completer<xmpp.IqStanza>> get pending => _pending;

  /// True if a request with [id] is registered.
  bool contains(String? id) => id != null && _pending.containsKey(id);

  /// Register [completer] as the response future for request [id].
  void register(String id, Completer<xmpp.IqStanza> completer) {
    _pending[id] = completer;
  }

  /// Complete the request registered as [id] with [response].
  /// Returns true if a matching pending request was found.
  bool complete(String? id, xmpp.IqStanza response) {
    if (id == null) return false;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
      return true;
    }
    return false;
  }

  /// Fail the request registered as [id].
  /// Returns true if a matching pending request was found.
  bool fail(String? id, Object error, [StackTrace? stackTrace]) {
    if (id == null) return false;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
      return true;
    }
    return false;
  }

  /// Forget a request without completing nor failing its future.
  /// Used on timeout paths where the future is completed via `.timeout()`.
  void forget(String? id) {
    if (id != null) _pending.remove(id);
  }

  /// Fail all pending requests. Used when the service/connection is torn down.
  void failAll(Object error, [StackTrace? stackTrace]) {
    final completers = List<Completer<xmpp.IqStanza>>.from(_pending.values);
    _pending.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }
}