class MinerSession {
  final String id;
  final String jid;
  final String sessionToken;
  final double creditsEarned;
  final double totalHashes;
  final double cpuCap;
  final DateTime createdAt;
  final DateTime? lastHeartbeat;
  final bool active;

  MinerSession({
    required this.id,
    required this.jid,
    required this.sessionToken,
    this.creditsEarned = 0,
    this.totalHashes = 0,
    this.cpuCap = 0.3,
    DateTime? createdAt,
    this.lastHeartbeat,
    this.active = true,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'jid': jid,
        'sessionToken': sessionToken,
        'creditsEarned': creditsEarned,
        'totalHashes': totalHashes,
        'cpuCap': cpuCap,
        'createdAt': createdAt.toIso8601String(),
        'lastHeartbeat': lastHeartbeat?.toIso8601String(),
        'active': active,
      };

  factory MinerSession.fromRow(Map<String, dynamic> row) => MinerSession(
        id: row['id'] as String,
        jid: row['jid'] as String,
        sessionToken: row['session_token'] as String,
        creditsEarned: (row['credits_earned'] as num?)?.toDouble() ?? 0,
        totalHashes: (row['total_hashes'] as num?)?.toDouble() ?? 0,
        cpuCap: (row['cpu_cap'] as num?)?.toDouble() ?? 0.3,
        createdAt: DateTime.parse(row['created_at'] as String),
        lastHeartbeat: row['last_heartbeat'] != null
            ? DateTime.parse(row['last_heartbeat'] as String)
            : null,
        active: (row['active'] as int?) == 1,
      );
}