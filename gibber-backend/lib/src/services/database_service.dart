import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

class DatabaseService {
  final String dbPath;
  Database? _db;
  static const int _currentVersion = 3;

  DatabaseService(this.dbPath);

  Database get db {
    _db ??= sqlite3.open(dbPath);
    return _db!;
  }

  Future<void> initialize({bool reset = false}) async {
    if (reset) {
      try {
        db.execute('DROP TABLE IF EXISTS users');
        db.execute('DROP TABLE IF EXISTS miner_sessions');
        db.execute('DROP TABLE IF EXISTS entitlements');
        db.execute('DROP TABLE IF EXISTS redemption_codes');
        db.execute('DROP TABLE IF EXISTS gateway_authorizations');
        db.execute('DROP TABLE IF EXISTS subscriptions');
        db.execute('DROP TABLE IF EXISTS payments');
        db.execute('DROP TABLE IF EXISTS schema_version');
      } catch (_) {}
    }

    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA synchronous=NORMAL');

    _createTables();
    _createIndexes();
    _runMigrations();

    final version = _getSchemaVersion();
    _setSchemaVersion(_currentVersion);
    print('Database initialized (schema v$version, target v$_currentVersion)');
  }

  void _createTables() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        jid TEXT UNIQUE NOT NULL,
        password_hash TEXT,
        tier TEXT DEFAULT 'free',
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS miner_sessions (
        id TEXT PRIMARY KEY,
        jid TEXT NOT NULL,
        session_token TEXT UNIQUE NOT NULL,
        total_hashes REAL DEFAULT 0,
        cpu_cap REAL DEFAULT 0.3,
        active INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now')),
        last_heartbeat TEXT,
        FOREIGN KEY (jid) REFERENCES users(jid)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS entitlements (
        id TEXT PRIMARY KEY,
        jid TEXT UNIQUE NOT NULL,
        tier TEXT DEFAULT 'free',
        additional_protocols TEXT DEFAULT '',
        expires_at TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (jid) REFERENCES users(jid)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS redemption_codes (
        code TEXT PRIMARY KEY,
        tier TEXT NOT NULL,
        protocols TEXT DEFAULT '',
        duration_days INTEGER DEFAULT 30,
        used INTEGER DEFAULT 0,
        used_by TEXT,
        used_at TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS gateway_authorizations (
        id TEXT PRIMARY KEY,
        jid TEXT NOT NULL,
        protocol TEXT NOT NULL,
        authorized INTEGER DEFAULT 0,
        authorized_at TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(jid, protocol),
        FOREIGN KEY (jid) REFERENCES users(jid)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS subscriptions (
        id TEXT PRIMARY KEY,
        jid TEXT NOT NULL,
        tier TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        status TEXT DEFAULT 'active',
        current_period_start TEXT,
        current_period_end TEXT,
        cancel_at TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (jid) REFERENCES users(jid)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id TEXT PRIMARY KEY,
        jid TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_payment_id TEXT NOT NULL,
        tier TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL DEFAULT 'USD',
        status TEXT DEFAULT 'pending',
        created_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (jid) REFERENCES users(jid)
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER PRIMARY KEY,
        applied_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS push_subscriptions (
        id TEXT PRIMARY KEY,
        jid TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        p256dh TEXT,
        auth TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(jid)
      )
    ''');
  }

  void _createIndexes() {
    db.execute('CREATE INDEX IF NOT EXISTS idx_users_jid ON users(jid)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_miner_sessions_token ON miner_sessions(session_token)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_miner_sessions_jid ON miner_sessions(jid)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_entitlements_jid ON entitlements(jid)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_gateway_auth_jid_proto ON gateway_authorizations(jid, protocol)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_subscriptions_jid ON subscriptions(jid)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_subscriptions_provider_id ON subscriptions(provider_id)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_payments_jid ON payments(jid)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_payments_provider_payment_id ON payments(provider_payment_id)');
  }

  int _getSchemaVersion() {
    try {
      final result = db.select('SELECT MAX(version) as v FROM schema_version');
      if (result.isEmpty) return 0;
      return result.first['v'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  void _setSchemaVersion(int version) {
    db.execute('INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, datetime(\'now\'))', [version]);
  }

  void _runMigrations() {
    final currentVersion = _getSchemaVersion();

    if (currentVersion < 1) {
      print('Running migration v1: initial schema');
      _setSchemaVersion(1);
    }

    if (currentVersion < 2) {
      print('Running migration v2: add stale session cleanup');
      db.execute('CREATE INDEX IF NOT EXISTS idx_miner_sessions_active ON miner_sessions(active, last_heartbeat)');
      _setSchemaVersion(2);
    }

    if (currentVersion < 3) {
      print('Running migration v3: add user_gateways table');
      db.execute('''
        CREATE TABLE IF NOT EXISTS user_gateways (
          id TEXT PRIMARY KEY,
          jid TEXT NOT NULL,
          gateway_type TEXT NOT NULL,
          config TEXT NOT NULL DEFAULT '{}',
          enabled INTEGER DEFAULT 0,
          status TEXT DEFAULT 'disabled',
          component_jid TEXT,
          container_id TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          UNIQUE(jid, gateway_type),
          FOREIGN KEY (jid) REFERENCES users(jid)
        )
      ''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_user_gateways_jid ON user_gateways(jid)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_user_gateways_jid_type ON user_gateways(jid, gateway_type)');
      _setSchemaVersion(3);
    }

    if (currentVersion < 4) {
      print('Running migration v4: add push_subscriptions table');
      db.execute('''
        CREATE TABLE IF NOT EXISTS push_subscriptions (
          id TEXT PRIMARY KEY,
          jid TEXT NOT NULL,
          endpoint TEXT NOT NULL,
          p256dh TEXT,
          auth TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          UNIQUE(jid)
        )
      ''');
      _setSchemaVersion(4);
    }
  }

  void upsertPushSubscription(String jid, String endpoint, String? p256dh, String? auth) {
    db.execute('''
      INSERT INTO push_subscriptions (id, jid, endpoint, p256dh, auth)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(jid) DO UPDATE SET
        endpoint = excluded.endpoint,
        p256dh = excluded.p256dh,
        auth = excluded.auth
    ''', [const Uuid().v4(), jid, endpoint, p256dh, auth]);
  }

  Map<String, dynamic>? getPushSubscription(String jid) {
    final results = db.select(
      'SELECT endpoint, p256dh, auth FROM push_subscriptions WHERE jid = ?',
      [jid],
    );
    if (results.isEmpty) return null;
    return {
      'endpoint': results.first['endpoint'],
      'p256dh': results.first['p256dh'],
      'auth': results.first['auth'],
    };
  }

  void deletePushSubscription(String jid) {
    db.execute('DELETE FROM push_subscriptions WHERE jid = ?', [jid]);
  }

  List<Map<String, dynamic>> getAllPushSubscriptions() {
    return db.select('SELECT jid, endpoint, p256dh, auth FROM push_subscriptions').toList();
  }

  void dispose() {
    _db?.close();
  }
}