import 'dart:convert';
import 'dart:io';

class JanusClient {
  final String adminUrl;
  final String adminSecret;

  int? _sessionId;
  int? _videoRoomHandleId;

  JanusClient({
    String? adminUrl,
    String? adminSecret,
  })  : adminUrl = adminUrl ?? 'http://localhost:7088',
        adminSecret = adminSecret ?? 'janus-admin-secret-change-in-production';

  Future<Map<String, dynamic>> _sendRequest(Map<String, dynamic> request) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$adminUrl'));
      req.headers.set('Content-Type', 'application/json');
      req.write(jsonEncode(request));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw Exception('Janus admin API error: ${resp.statusCode} - $body');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  String _transactionId() => DateTime.now().millisecondsSinceEpoch.toString();

  Future<int> createSession() async {
    final response = await _sendRequest({
      'janus': 'create',
      'transaction': _transactionId(),
    });
    if (response['janus'] != 'success') {
      throw Exception('Failed to create Janus session: $response');
    }
    _sessionId = response['data']['id'] as int;
    return _sessionId!;
  }

  Future<int> attachVideoRoom() async {
    if (_sessionId == null) {
      throw Exception('No Janus session. Call createSession() first.');
    }
    final response = await _sendRequest({
      'janus': 'attach',
      'plugin': 'janus.plugin.videoroom',
      'transaction': _transactionId(),
      'session_id': _sessionId,
    });
    if (response['janus'] != 'success') {
      throw Exception('Failed to attach to videoroom plugin: $response');
    }
    _videoRoomHandleId = response['data']['id'] as int;
    return _videoRoomHandleId!;
  }

  Future<Map<String, dynamic>> createRoom({
    required String roomId,
    String? description,
    int maxPublishers = 6,
    int bitrate = 1280000,
  }) async {
    final handleId = _videoRoomHandleId ?? await attachVideoRoom();
    final response = await _sendRequest({
      'janus': 'message',
      'transaction': _transactionId(),
      'session_id': _sessionId,
      'handle_id': handleId,
      'body': {
        'request': 'create',
        'room': int.tryParse(roomId) ?? roomId.hashCode,
        'room_display_name': description ?? 'Gibber Conference',
        'max_publishers': maxPublishers,
        'bitrate': bitrate,
        'permanent': false,
      },
    });

    final janusResponse = response['plugindata']?['data'];
    if (janusResponse == null || janusResponse['videoroom'] != 'created') {
      throw Exception('Failed to create Janus room: $response');
    }

    return {
      'room': janusResponse['room'],
      'room_str': janusResponse['room'].toString(),
      'created': janusResponse['created'],
    };
  }

  Future<void> destroyRoom(String roomId, String secret) async {
    final handleId = _videoRoomHandleId;
    if (handleId == null || _sessionId == null) return;

    try {
      await _sendRequest({
        'janus': 'message',
        'transaction': _transactionId(),
        'session_id': _sessionId,
        'handle_id': handleId,
        'body': {
          'request': 'destroy',
          'room': int.tryParse(roomId) ?? roomId.hashCode,
          'secret': secret,
        },
      });
    } catch (_) {}
  }

  Future<void> closeSession() async {
    if (_sessionId == null) return;
    try {
      await _sendRequest({
        'janus': 'destroy',
        'transaction': _transactionId(),
        'session_id': _sessionId,
      });
    } catch (_) {}
    _sessionId = null;
    _videoRoomHandleId = null;
  }

  void dispose() {
    closeSession();
  }
}
