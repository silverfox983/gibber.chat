import 'package:uuid/uuid.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/models/miner_session.dart';

class MinerPoolService {
  final DatabaseService db;
  final _uuid = const Uuid();

  MinerPoolService({required this.db});

  Future<MinerSession> register(String jid, {double cpuCap = 0.3}) async {
    _ensureUser(jid);
    final sessionToken = _generateToken();
    final id = _uuid.v4();

    db.db.execute(
      'INSERT INTO miner_sessions (id, jid, session_token, cpu_cap) VALUES (?, ?, ?, ?)',
      [id, jid, sessionToken, cpuCap],
    );

    return MinerSession(
      id: id,
      jid: jid,
      sessionToken: sessionToken,
      cpuCap: cpuCap,
    );
  }

  Future<MinerSession?> validateSession(String sessionToken) async {
    final rows = db.db.select(
      'SELECT * FROM miner_sessions WHERE session_token = ? AND active = 1',
      [sessionToken],
    );
    if (rows.isEmpty) return null;
    return MinerSession.fromRow(rows.first);
  }

  Future<void> submitHashes(String sessionToken, double hashes) async {
    final session = await validateSession(sessionToken);
    if (session == null) return;

    db.db.execute(
      'UPDATE miner_sessions SET total_hashes = total_hashes + ?, last_heartbeat = datetime(\'now\') WHERE session_token = ?',
      [hashes, sessionToken],
    );
  }

  Future<void> heartbeat(String sessionToken) async {
    db.db.execute(
      'UPDATE miner_sessions SET last_heartbeat = datetime(\'now\') WHERE session_token = ? AND active = 1',
      [sessionToken],
    );
  }

  Future<List<MinerSession>> getActiveSessions({String? jid}) async {
    final rows = jid != null
        ? db.db.select(
            'SELECT * FROM miner_sessions WHERE jid = ? AND active = 1 ORDER BY created_at DESC',
            [jid],
          )
        : db.db.select(
            'SELECT * FROM miner_sessions WHERE active = 1 ORDER BY created_at DESC',
          );
    return rows.map((r) => MinerSession.fromRow(r)).toList();
  }

  Future<double> getTotalHashes(String jid) async {
    final rows = db.db.select(
      'SELECT SUM(total_hashes) as total FROM miner_sessions WHERE jid = ?',
      [jid],
    );
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  Future<void> deactivateSession(String sessionToken) async {
    db.db.execute(
      'UPDATE miner_sessions SET active = 0 WHERE session_token = ?',
      [sessionToken],
    );
  }

  Future<void> deactivateStaleSessions({Duration threshold = const Duration(minutes: 5)}) async {
    db.db.execute(
      "UPDATE miner_sessions SET active = 0 WHERE active = 1 AND last_heartbeat < datetime('now', '-${threshold.inMinutes} minutes')",
    );
  }

  String _generateToken() {
    return _uuid.v4();
  }

  String _ensureUser(String jid) {
    final existing = db.db.select('SELECT id FROM users WHERE jid = ?', [jid]);
    if (existing.isEmpty) {
      final id = _uuid.v4();
      db.db.execute('INSERT INTO users (id, jid) VALUES (?, ?)', [id, jid]);
    }
    return jid;
  }
}