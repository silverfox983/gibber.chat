import 'package:sqlite3/sqlite3.dart';

class DatabaseService {
  final String dbPath;
  Database? _db;

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
      } catch (_) {}
    }

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

  void dispose() {
    _db?.dispose();
  }
}