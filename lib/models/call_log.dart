
enum CallStatus { completed, missed, rejected, failed }
enum CallDirection { incoming, outgoing }

class CallLog {
  final String jid;
  final DateTime timestamp;
  final Duration? duration;
  final bool isVideo;
  final CallStatus status;
  final CallDirection direction;

  CallLog({
    required this.jid,
    required this.timestamp,
    this.duration,
    required this.isVideo,
    required this.status,
    required this.direction,
  });

  Map<String, dynamic> toJson() => {
    'jid': jid,
    'timestamp': timestamp.toIso8601String(),
    'durationMs': duration?.inMilliseconds,
    'isVideo': isVideo,
    'status': status.index,
    'direction': direction.index,
  };

  factory CallLog.fromJson(Map<String, dynamic> json) => CallLog(
    jid: json['jid'],
    timestamp: DateTime.parse(json['timestamp']),
    duration: json['durationMs'] != null ? Duration(milliseconds: json['durationMs']) : null,
    isVideo: json['isVideo'],
    status: CallStatus.values[json['status']],
    direction: CallDirection.values[json['direction']],
  );
}
