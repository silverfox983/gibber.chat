import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import 'database_service.dart';

class OfflineQueueService {
  static final OfflineQueueService _instance = OfflineQueueService._internal();
  factory OfflineQueueService() => _instance;
  OfflineQueueService._internal();

  static const int _maxQueueSize = 500;

  Future<Database> get _db async => DatabaseService().database;

  Future<void> initialize(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_messages (
        id TEXT PRIMARY KEY,
        target_jid TEXT NOT NULL,
        text TEXT NOT NULL,
        account_id TEXT NOT NULL,
        message_type INTEGER DEFAULT 0,
        file_path TEXT,
        file_name TEXT,
        reply_to_id TEXT,
        is_group INTEGER DEFAULT 0,
        encryption_type TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        retry_count INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_messages_account ON pending_messages(account_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_messages_created ON pending_messages(created_at)',
    );
  }

  Future<String> enqueue({
    required String targetJid,
    required String text,
    required String accountId,
    MessageType type = MessageType.text,
    String? filePath,
    String? fileName,
    String? replyToId,
    bool isGroup = false,
    String? encryptionType,
  }) async {
    final db = await _db;
    final id = 'pending_${DateTime.now().microsecondsSinceEpoch}';

    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM pending_messages WHERE account_id = ?', [accountId]),
    ) ?? 0;

    if (count >= _maxQueueSize) {
      await db.delete(
        'pending_messages',
        where: 'account_id = ? ORDER BY created_at ASC LIMIT 1',
        whereArgs: [accountId],
      );
    }

    await db.insert('pending_messages', {
      'id': id,
      'target_jid': targetJid,
      'text': text,
      'account_id': accountId,
      'message_type': type.index,
      'file_path': filePath,
      'file_name': fileName,
      'reply_to_id': replyToId,
      'is_group': isGroup ? 1 : 0,
      'encryption_type': encryptionType,
      'created_at': DateTime.now().toIso8601String(),
      'retry_count': 0,
    });

    debugPrint('OfflineQueue: Enqueued message $id for $targetJid (account: $accountId, queue depth: ${count + 1})');
    return id;
  }

  Future<List<Map<String, dynamic>>> getPendingForAccount(String accountId) async {
    final db = await _db;
    return db.query(
      'pending_messages',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'created_at ASC',
    );
  }

  Future<void> dequeue(String id) async {
    final db = await _db;
    await db.delete('pending_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementRetryCount(String id) async {
    final db = await _db;
    await db.rawUpdate(
      'UPDATE pending_messages SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> removeOldRetries({int maxRetries = 3}) async {
    final db = await _db;
    await db.delete(
      'pending_messages',
      where: 'retry_count >= ?',
      whereArgs: [maxRetries],
    );
  }

  Future<void> clearAllForAccount(String accountId) async {
    final db = await _db;
    await db.delete('pending_messages', where: 'account_id = ?', whereArgs: [accountId]);
  }

  Future<int> pendingCount(String accountId) async {
    final db = await _db;
    final result = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM pending_messages WHERE account_id = ?', [accountId]),
    );
    return result ?? 0;
  }
}