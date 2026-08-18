import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/group_call_models.dart';

typedef OnJanusConnected = void Function();
typedef OnJanusDisconnected = void Function(String? reason);
typedef OnJanusError = void Function(String error);
typedef OnParticipantJoined = void Function(JanusParticipant participant);
typedef OnParticipantLeft = void Function(String participantId);
typedef OnParticipantSpeaking = void Function(String participantId, bool speaking);
typedef OnParticipantAudioVideo = void Function(String participantId, bool audio, bool video);
typedef OnRoomDestroyed = void Function(String roomId);
typedef OnTrickleCandidate = void Function(String handleId, Map<String, dynamic> candidate);

class JanusService {
  WebSocketChannel? _ws;
  String? _sessionId;
  String? _serverUrl;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _transactionId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingTransactions = {};
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  String? _apiSecret;
  String? _token;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;

  OnJanusConnected? onConnected;
  OnJanusDisconnected? onDisconnected;
  OnJanusError? onError;
  OnParticipantJoined? onParticipantJoined;
  OnParticipantLeft? onParticipantLeft;
  OnRoomDestroyed? onRoomDestroyed;
  OnTrickleCandidate? onTrickleCandidate;

  final StreamController<Map<String, dynamic>> _remoteTrackController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, bool>> _speakingController =
      StreamController<Map<String, bool>>.broadcast();

  Stream<Map<String, dynamic>> get onRemoteTrack => _remoteTrackController.stream;
  Stream<Map<String, bool>> get onSpeaking => _speakingController.stream;

  bool get isConnected => _isConnected;
  String? get sessionId => _sessionId;

  Future<void> connect(String url, {String? apiSecret, String? token}) async {
    if (_isConnected || _isConnecting) return;
    _isConnecting = true;
    _serverUrl = url;
    _apiSecret = apiSecret;
    _token = token;

    try {
      final uri = Uri.parse(url);
      _ws = WebSocketChannel.connect(uri);
      _ws!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      final session = await _createSession();
      if (session != null) {
        _sessionId = session;
        _isConnected = true;
        _reconnectAttempts = 0;
        _startKeepalive();
        onConnected?.call();
        debugPrint('JANUS: Connected to $url, session=$_sessionId');
      } else {
        _isConnecting = false;
        onError?.call('Failed to create session');
      }
    } catch (e) {
      _isConnecting = false;
      onError?.call('Connection failed: $e');
    }
    _isConnecting = false;
  }

  void disconnect() {
    _keepaliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _ws?.sink.close();
    _ws = null;
    _sessionId = null;
    _isConnected = false;
    _pendingTransactions.clear();
    debugPrint('JANUS: Disconnected');
  }

  Future<String?> attachToVideoRoom() async {
    if (!_isConnected || _sessionId == null) return null;

    final response = await _sendRequest({
      'janus': 'attach',
      'plugin': 'janus.plugin.videoroom',
      'session_id': int.parse(_sessionId!),
    });

    if (response != null && response['janus'] == 'success') {
      final handleId = response['data']?['id']?.toString();
      debugPrint('JANUS: Attached to VideoRoom, handle=$handleId');
      return handleId;
    }
    return null;
  }

  Future<String?> joinRoom(String roomId, String displayName, {String? token}) async {
    if (!_isConnected || _sessionId == null) return null;

    final handleId = await attachToVideoRoom();
    if (handleId == null) return null;

    final response = await _sendRequest({
      'janus': 'message',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'body': {
        'request': 'join',
        'room': int.tryParse(roomId) ?? roomId.hashCode,
        'ptype': 'publisher',
        'display': displayName,
        if (token != null) 'token': token,
      },
    });

    if (response != null && response['janus'] == 'event') {
      final plugindata = response['plugindata'] as Map<String, dynamic>?;
      final data = plugindata?['data'] as Map<String, dynamic>?;
      final error = data?['error'];
      if (error != null) {
        debugPrint('JANUS: Failed to join room $roomId: $error');
        onError?.call('Failed to join room: $error');
        return null;
      }
      debugPrint('JANUS: Joined room $roomId as publisher, handle=$handleId');
      return handleId;
    }
    debugPrint('JANUS: joinRoom timed out or failed for room $roomId');
    return null;
  }

  Future<bool> publishStream(String handleId, String sdpOffer) async {
    if (!_isConnected) return false;

    final response = await _sendRequest({
      'janus': 'message',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'body': {
        'request': 'publish',
      },
      'jsep': {
        'type': 'offer',
        'sdp': sdpOffer,
      },
    });

    if (response == null) {
      debugPrint('JANUS: publishStream timed out for handle=$handleId');
      return false;
    }
    if (response['janus'] == 'error') {
      final error = response['error'] ?? response['reason'];
      debugPrint('JANUS: publishStream error for handle=$handleId: $error');
      onError?.call('Failed to publish stream: $error');
      return false;
    }
    if (response['janus'] == 'event') {
      final plugindata = response['plugindata'] as Map<String, dynamic>?;
      final data = plugindata?['data'] as Map<String, dynamic>?;
      final error = data?['error'];
      if (error != null) {
        debugPrint('JANUS: publishStream error for handle=$handleId: $error');
        onError?.call('Failed to publish stream: $error');
        return false;
      }
      debugPrint('JANUS: Published stream on handle=$handleId');
      return true;
    }
    return false;
  }

  Future<bool> subscribeToParticipant(String roomId, String feedId, {String? token}) async {
    if (!_isConnected || _sessionId == null) return false;

    final handleId = await attachToVideoRoom();
    if (handleId == null) return false;

    final response = await _sendRequest({
      'janus': 'message',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'body': {
        'request': 'join',
        'room': int.tryParse(roomId) ?? roomId.hashCode,
        'ptype': 'subscriber',
        'feed': int.tryParse(feedId) ?? feedId.hashCode,
        if (token != null) 'token': token,
      },
    });

    if (response == null) {
      debugPrint('JANUS: subscribeToParticipant timed out for feed=$feedId');
      return false;
    }
    if (response['janus'] == 'error') {
      final error = response['error'] ?? response['reason'];
      debugPrint('JANUS: subscribeToParticipant error for feed=$feedId: $error');
      onError?.call('Failed to subscribe to participant: $error');
      return false;
    }
    if (response['janus'] == 'event') {
      final plugindata = response['plugindata'] as Map<String, dynamic>?;
      final data = plugindata?['data'] as Map<String, dynamic>?;
      final error = data?['error'];
      if (error != null) {
        debugPrint('JANUS: subscribeToParticipant error for feed=$feedId: $error');
        onError?.call('Failed to subscribe to participant: $error');
        return false;
      }
      debugPrint('JANUS: Subscribed to feed=$feedId, handle=$handleId');
      return true;
    }
    return false;
  }

  Future<bool> leaveRoom(String handleId) async {
    if (!_isConnected) return false;

    await _sendRequest({
      'janus': 'message',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'body': {
        'request': 'leave',
      },
    });

    debugPrint('JANUS: Left room, handle=$handleId');
    return true;
  }

  Future<bool> configurePublisher(String handleId, {bool? audio, bool? video}) async {
    if (!_isConnected) return false;

    await _sendRequest({
      'janus': 'message',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'body': {
        'request': 'configure',
        if (audio != null) 'audio': audio,
        if (video != null) 'video': video,
      },
    });

    return true;
  }

  Future<Map<String, dynamic>?> trickleCandidate(String handleId, Map<String, dynamic> candidate) async {
    if (!_isConnected) return null;

    return _sendRequest({
      'janus': 'trickle',
      'session_id': int.parse(_sessionId!),
      'handle_id': int.parse(handleId),
      'candidate': candidate,
    });
  }

  void _onMessage(dynamic message) {
    if (message is String) {
      try {
        final data = jsonDecode(message) as Map<String, dynamic>;
        _handleJanusMessage(data);
      } catch (e) {
        debugPrint('JANUS: Error parsing message: $e');
      }
    }
  }

  void _handleJanusMessage(Map<String, dynamic> data) {
    final type = data['janus'] as String?;
    final txn = data['transaction'] as String?;

    if (txn != null && _pendingTransactions.containsKey(txn)) {
      _pendingTransactions[txn]!.complete(data);
      _pendingTransactions.remove(txn);
      return;
    }

    switch (type) {
      case 'event':
        _handleEvent(data);
        break;
      case 'trickle':
        _handleTrickle(data);
        break;
      case 'ack':
        debugPrint('JANUS: Received ack for transaction $txn');
        break;
      case 'webrtcup':
        debugPrint('JANUS: WebRTC connection established');
        break;
      case 'media':
        final talking = data['type'] == 'audio';
        final handleId = data['sender']?.toString();
        if (handleId != null) {
          _speakingController.add({handleId: talking});
        }
        break;
      case 'slowlink':
        debugPrint('JANUS: Slow link detected');
        break;
      case 'hangup':
        debugPrint('JANUS: Peer hung up: ${data['reason'] ?? 'unknown'}');
        break;
      case 'detached':
        debugPrint('JANUS: Handle detached');
        break;
      case 'timeout':
        debugPrint('JANUS: Session timeout');
        _handleDisconnect('Session timeout');
        break;
      case 'keepalive':
        debugPrint('JANUS: Keepalive received');
        break;
    }
  }

  void _handleEvent(Map<String, dynamic> data) {
    final plugindata = data['plugindata'] as Map<String, dynamic>?;
    if (plugindata == null) return;

    final pluginData = plugindata['data'] as Map<String, dynamic>?;
    if (pluginData == null) return;

    final videoroom = pluginData['videoroom'] as String?;
    if (videoroom == null) return;

    switch (videoroom) {
      case 'joined':
        debugPrint('JANUS: Publisher joined room');
        break;
      case 'event':
        final event = pluginData;
        if (event.containsKey('publishers')) {
          final publishers = event['publishers'] as List<dynamic>;
          for (var pub in publishers) {
            final p = pub as Map<String, dynamic>;
            final participant = JanusParticipant(
              id: p['id']?.toString() ?? '',
              displayName: p['display']?.toString() ?? '',
              jid: p['display']?.toString() ?? '',
            );
            onParticipantJoined?.call(participant);
          }
        }
        if (event.containsKey('leaving')) {
          onParticipantLeft?.call(event['leaving'].toString());
        }
        if (event.containsKey('unpublished')) {
          onParticipantLeft?.call(event['unpublished'].toString());
        }
        if (event.containsKey('error')) {
          onError?.call(event['error'].toString());
        }
        break;
      case 'destroyed':
        final roomId = pluginData['room']?.toString();
        if (roomId != null) {
          onRoomDestroyed?.call(roomId);
        }
        break;
    }

    if (data.containsKey('jsep')) {
      _remoteTrackController.add({
        'handle_id': data['sender']?.toString(),
        'jsep': data['jsep'],
      });
    }
  }

  void _handleTrickle(Map<String, dynamic> data) {
    final candidate = data['candidate'] as Map<String, dynamic>?;
    if (candidate == null) return;

    final handleId = data['sender']?.toString();
    if (handleId == null) return;

    if (candidate.containsKey('completed') && candidate['completed'] == true) {
      debugPrint('JANUS: ICE candidate gathering complete for handle=$handleId');
      onTrickleCandidate?.call(handleId, {'completed': true});
      return;
    }

    debugPrint('JANUS: Received trickle candidate for handle=$handleId');
    onTrickleCandidate?.call(handleId, candidate);
  }

  void _onError(dynamic error) {
    debugPrint('JANUS: WebSocket error: $error');
    _handleDisconnect(error.toString());
  }

  void _onDone() {
    debugPrint('JANUS: WebSocket connection closed');
    _handleDisconnect('Connection closed');
  }

  void _handleDisconnect(String reason) {
    final wasConnected = _isConnected;
    _isConnected = false;
    _keepaliveTimer?.cancel();

    final shouldReconnect = wasConnected
        ? _reconnectAttempts < _maxReconnectAttempts
        : (_serverUrl != null && _sessionId == null && _reconnectAttempts < 2);

    if (shouldReconnect) {
      _reconnectAttempts++;
      final delay = Duration(seconds: 1 << (_reconnectAttempts - 1));
      debugPrint('JANUS: Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)');
      _reconnectTimer = Timer(delay, () {
        if (_serverUrl != null) {
          _isConnecting = false;
          connect(_serverUrl!, apiSecret: _apiSecret, token: _token);
        }
      });
    } else {
      onDisconnected?.call(reason);
    }
  }

  Future<String?> _createSession() async {
    final response = await _sendRequest({
      'janus': 'create',
    });

    if (response != null && response['janus'] == 'success') {
      return response['data']?['id']?.toString();
    }
    return null;
  }

  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_isConnected && _sessionId != null) {
        _sendRaw({
          'janus': 'keepalive',
          'session_id': int.parse(_sessionId!),
        });
      }
    });
  }

  Future<Map<String, dynamic>?> _sendRequest(Map<String, dynamic> request) async {
    if (_ws == null) return null;

    final txn = 'txn_${_transactionId++}';
    request['transaction'] = txn;

    final completer = Completer<Map<String, dynamic>>();
    _pendingTransactions[txn] = completer;

    try {
      _sendRaw(request);
      return await completer.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _pendingTransactions.remove(txn);
      debugPrint('JANUS: Request timed out or failed, transaction=$txn, error=$e');
      return null;
    }
  }

  void _sendRaw(Map<String, dynamic> data) {
    if (_apiSecret != null) {
      data['apisecret'] = _apiSecret;
    }
    if (_token != null) {
      data['token'] = _token;
    }
    _ws?.sink.add(jsonEncode(data));
  }

  void dispose() {
    disconnect();
    _remoteTrackController.close();
    _speakingController.close();
  }
}