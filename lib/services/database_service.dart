import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import '../models/space_models.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static String? testPath;
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path;
    if (kIsWeb) {
      path = 'pidgin_chat.db';
    } else {
      path = testPath ?? join(await getDatabasesPath(), 'pidgin_chat.db');
    }
    return await openDatabase(
      path,
      version: 15,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages(
            id TEXT PRIMARY KEY,
            text TEXT,
            timestamp TEXT,
            is_sent INTEGER,
            type INTEGER,
            file_path TEXT,
            file_name TEXT,
            sender_id TEXT,
            sender_name TEXT,
            account_id TEXT,
            protocol TEXT,
            conversation_id TEXT,
            is_group INTEGER DEFAULT 0,
            status INTEGER,
            reply_to_id TEXT,
            replaces_id TEXT,
            is_edited INTEGER DEFAULT 0,
            edit_timestamp TEXT,
            reactions TEXT,
            reactions_json TEXT,
            reply_preview TEXT,
            forwarded_from TEXT,
            encryption_type TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_conv ON messages(conversation_id)',
        );
        await db.execute('''
          CREATE TABLE conversations(
            id TEXT PRIMARY KEY,
            name TEXT,
            protocol TEXT,
            account_id TEXT,
            is_group INTEGER,
            unread_count INTEGER,
            last_message_id TEXT,
            wallpaper_path TEXT,
            wallpaper_color INTEGER
          )
        ''');

        // --- Spaces Table ---
        await db.execute('''
          CREATE TABLE spaces(
            domain TEXT,
            node TEXT,
            name TEXT,
            description TEXT,
            creator TEXT,
            avatar_url TEXT,
            cover_url TEXT,
            affiliation TEXT,
            member_count INTEGER,
            features TEXT,
            type TEXT,
            access_model TEXT,
            publish_model TEXT,
            num_subscribers INTEGER,
            owner_jid TEXT,
            is_subscribed INTEGER,
            notifications_enabled INTEGER,
            last_activity TEXT,
            post_count INTEGER,
            synced_at TEXT,
            is_joined INTEGER DEFAULT 0,
            PRIMARY KEY(domain, node)
          )
        ''');

        // --- OMEMO Tables ---
        await db.execute('''
          CREATE TABLE signal_sessions(
            address_name TEXT,
            device_id INTEGER,
            session_data BLOB,
            PRIMARY KEY(address_name, device_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE signal_identities(
            address_name TEXT,
            device_id INTEGER,
            identity_key_data BLOB,
            trust_level INTEGER DEFAULT 0,
            PRIMARY KEY(address_name, device_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE signal_pre_keys(
            pre_key_id INTEGER PRIMARY KEY,
            pre_key_data BLOB
          )
        ''');
        await db.execute('''
          CREATE TABLE signal_signed_pre_keys(
            signed_pre_key_id INTEGER PRIMARY KEY,
            signed_pre_key_data BLOB
          )
        ''');
        await db.execute('''
          CREATE TABLE signal_config(
            key TEXT PRIMARY KEY,
            value BLOB
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_messages(
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id)',
          );
        }
        if (oldVersion < 4) {
          await db.execute('''
              CREATE TABLE IF NOT EXISTS signal_sessions(
                address_name TEXT,
                device_id INTEGER,
                session_data BLOB,
                PRIMARY KEY(address_name, device_id)
              )
            ''');
          await db.execute('''
              CREATE TABLE IF NOT EXISTS signal_identities(
                address_name TEXT PRIMARY KEY,
                identity_key_data BLOB,
                trust_level INTEGER DEFAULT 0
              )
            ''');
          await db.execute('''
              CREATE TABLE IF NOT EXISTS signal_pre_keys(
                pre_key_id INTEGER PRIMARY KEY,
                pre_key_data BLOB
              )
            ''');
          await db.execute('''
              CREATE TABLE IF NOT EXISTS signal_signed_pre_keys(
                signed_pre_key_id INTEGER PRIMARY KEY,
                signed_pre_key_data BLOB
              )
            ''');
          await db.execute('''
              CREATE TABLE IF NOT EXISTS signal_config(
                key TEXT PRIMARY KEY,
                value BLOB
              )
            ''');
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN is_group INTEGER DEFAULT 0',
          );
        }
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE conversations ADD COLUMN wallpaper_path TEXT',
          );
          await db.execute(
            'ALTER TABLE conversations ADD COLUMN wallpaper_color INTEGER',
          );
        }
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN replaces_id TEXT');
        }
        if (oldVersion < 8) {
          await db.transaction((txn) async {
            await txn.execute(
              'ALTER TABLE signal_identities RENAME TO signal_identities_old',
            );
            await txn.execute('''
               CREATE TABLE signal_identities(
                 address_name TEXT,
                 device_id INTEGER,
                 identity_key_data BLOB,
                 trust_level INTEGER DEFAULT 0,
                 PRIMARY KEY(address_name, device_id)
               )
             ''');
            // We don't migrate old data as it lacks device_id info;
            // fresh exchange is safer for security state.
            await txn.execute('DROP TABLE signal_identities_old');
          });
        }
        if (oldVersion < 9) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN is_edited INTEGER DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN edit_timestamp TEXT',
          );
        }
        if (oldVersion < 10) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN reactions TEXT',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN reactions_json TEXT',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN reply_preview TEXT',
          );
        }
        if (oldVersion < 11) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN forwarded_from TEXT',
          );
        }
        if (oldVersion < 12) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN encryption_type TEXT',
          );
        }
        if (oldVersion < 13) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS spaces(
              domain TEXT,
              node TEXT,
              name TEXT,
              description TEXT,
              creator TEXT,
              avatar_url TEXT,
              cover_url TEXT,
              affiliation TEXT,
              member_count INTEGER,
              features TEXT,
              type TEXT,
              access_model TEXT,
              publish_model TEXT,
              num_subscribers INTEGER,
              owner_jid TEXT,
              is_subscribed INTEGER,
              notifications_enabled INTEGER,
              last_activity TEXT,
              post_count INTEGER,
              synced_at TEXT,
              is_joined INTEGER DEFAULT 0,
              PRIMARY KEY(domain, node)
            )
          ''');
        }
        if (oldVersion < 14) {
          try {
            await db.execute('ALTER TABLE spaces ADD COLUMN cover_url TEXT');
          } catch (e) {
            debugPrint('Column cover_url might already exist: $e');
          }
        }
        if (oldVersion < 15) {
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
      },
    );
  }

  // --- Message CRUD ---

  Future<void> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Auto-update conversation metadata
    await db.insert(
      'conversations',
      {
        'id': message.conversationId,
        'name': message.senderName ?? message.conversationId,
        'protocol': message.protocol,
        'account_id': message.accountId,
        'is_group': message.isGroup ? 1 : 0,
        'last_message_id': message.id,
      },
      conflictAlgorithm: ConflictAlgorithm
          .ignore, // Don't overwrite existing name/group status
    );

    await db.update(
      'conversations',
      {'last_message_id': message.id},
      where: 'LOWER(id) = LOWER(?)',
      whereArgs: [message.conversationId],
    );
  }

  Future<List<ChatMessage>> getMessages(
    String conversationId, {
    int limit = 100,
  }) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'LOWER(conversation_id) = ? OR LOWER(conversation_id) LIKE ?',
      whereArgs: [
        conversationId.toLowerCase(),
        '${conversationId.toLowerCase()}/%',
      ],
      orderBy: 'timestamp DESC',
      limit: limit,
    );

    final result = List.generate(maps.length, (i) {
      return ChatMessage.fromMap(maps[i]);
    });
    
    // Reverse the list so messages are returned in chronological order (oldest to newest)
    return result.reversed.toList();
  }

  Future<ChatMessage?> getMessageById(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return ChatMessage.fromMap(maps.first);
    }
    return null;
  }

  Future<List<ChatMessage>> searchMessages(
    String conversationId,
    String query,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'LOWER(conversation_id) = ? AND text LIKE ?',
      whereArgs: [conversationId.toLowerCase(), '%$query%'],
      orderBy: 'timestamp DESC',
    );

    return List.generate(maps.length, (i) {
      return ChatMessage.fromMap(maps[i]);
    });
  }

  Future<List<ChatMessage>> searchAllMessages(String query) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'text LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'timestamp DESC',
      limit: 200,
    );

    return List.generate(maps.length, (i) {
      return ChatMessage.fromMap(maps[i]);
    });
  }

  Future<List<ChatMessage>> getMessagesByStatus(MessageStatus status) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'status = ?',
      whereArgs: [status.index],
      orderBy: 'timestamp ASC',
    );

    return List.generate(maps.length, (i) {
      return ChatMessage.fromMap(maps[i]);
    });
  }

  Future<List<Conversation>> getConversations() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('conversations');

    List<Conversation> convs = [];
    for (var m in maps) {
      final convId = m['id'] ?? '';
      if (convId.isEmpty) continue; // Skip corrupted records

      convs.add(
        Conversation(
          id: convId,
          name: m['name'] ?? convId,
          messages: [], // messages are loaded on demand by ChatProvider
          protocol: m['protocol'] ?? 'XMPP',
          accountId: m['account_id'] ?? '',
          isGroup: m['is_group'] == 1,
          unreadCount: m['unread_count'] ?? 0,
          wallpaperPath: m['wallpaper_path'],
          wallpaperColor: m['wallpaper_color'] as int?,
        ),
      );
    }
    return convs;
  }

  Future<void> insertMessagesBatch(List<ChatMessage> messages) async {
    final db = await database;
    final batch = db.batch();
    for (var message in messages) {
      final msgId = message.id;
      final convId = message.conversationId ?? '';
      if (msgId.isEmpty || convId.isEmpty) {
        debugPrint('DatabaseService: Skipping batch item with empty ID/ConvID');
        continue;
      }

      batch.insert(
        'messages',
        message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Ensure conversation exists (Phase 16 Sync Restoration)
      batch.insert('conversations', {
        'id': convId,
        'name': message.senderName ?? convId,
        'protocol': message.protocol ?? 'XMPP',
        'account_id': message.accountId ?? '',
        'is_group': message.isGroup ? 1 : 0,
        'last_message_id': msgId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      batch.update(
        'conversations',
        {'last_message_id': msgId},
        where: 'LOWER(id) = LOWER(?)',
        whereArgs: [convId],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateMessage(
    String id,
    String newText, {
    bool isEdited = false,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{'text': newText};
    if (isEdited) {
      updates['is_edited'] = 1;
      updates['edit_timestamp'] = DateTime.now().toIso8601String();
    }
    await db.update('messages', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateMessageReactions(
    String id,
    Map<String, List<String>> reactions,
  ) async {
    final db = await database;
    await db.update(
      'messages',
      {'reactions_json': json.encode(reactions)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearConversationMessages(String conversationId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'LOWER(conversation_id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
  }

  Future<void> deleteConversation(String conversationId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'LOWER(conversation_id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
    await db.delete(
      'conversations',
      where: 'LOWER(id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('conversations');
  }

  // --- Utility Updates ---

  Future<void> updateMessageStatus(String msgId, MessageStatus status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [msgId],
    );
  }

  Future<void> updateConversationGroupStatus(
    String conversationId,
    bool isGroup,
  ) async {
    final db = await database;
    await db.update(
      'conversations',
      {'is_group': isGroup ? 1 : 0},
      where: 'LOWER(id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
  }

  Future<void> resetUnreadCount(String conversationId) async {
    final db = await database;
    await db.update(
      'conversations',
      {'unread_count': 0},
      where: 'LOWER(id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
  }

  Future<void> incrementUnreadCount(String conversationId) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE conversations 
      SET unread_count = COALESCE(unread_count, 0) + 1 
      WHERE LOWER(id) = LOWER(?)
    ''',
      [conversationId.toLowerCase()],
    );
  }

  Future<void> upsertConversation(Conversation conv) async {
    final db = await database;
    await db.insert('conversations', {
      'id': conv.id,
      'name': conv.name,
      'protocol': conv.protocol,
      'account_id': conv.accountId ?? '',
      'is_group': conv.isGroup ? 1 : 0,
      'unread_count': conv.unreadCount,
      'wallpaper_path': conv.wallpaperPath,
      'wallpaper_color': conv.wallpaperColor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateConversationWallpaper(
    String conversationId,
    String? path,
    int? color,
  ) async {
    final db = await database;
    await db.update(
      'conversations',
      {'wallpaper_path': path, 'wallpaper_color': color},
      where: 'LOWER(id) = LOWER(?)',
      whereArgs: [conversationId.toLowerCase()],
    );
  }

  // --- Export / Import ---

  Future<Map<String, List<Map<String, dynamic>>>> exportAllData() async {
    final db = await database;
    final Map<String, List<Map<String, dynamic>>> tables = {};

    final List<Map<String, dynamic>> tableRecords = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );

    for (var record in tableRecords) {
      final tableName = record['name'] as String;
      try {
        final rows = await db.query(tableName);
        tables[tableName] = rows;
      } catch (e) {
        tables[tableName] = [];
      }
    }
    return tables;
  }

  Future<void> importAllData(Map<String, dynamic> data) async {
    final db = await database;
    final batch = db.batch();

    // 1. Wipe current tables
    for (var tableName in data.keys) {
      batch.delete(tableName);
    }

    // 2. Insert new data
    for (var entry in data.entries) {
      final tableName = entry.key;
      final rows = entry.value as List<dynamic>;
      for (var row in rows) {
        batch.insert(tableName, row as Map<String, dynamic>);
      }
    }
    await batch.commit(noResult: true);
  }

  // --- Spaces CRUD ---

  Future<void> upsertSpace(SpaceNode space, {bool isJoined = false}) async {
    final db = await database;
    final map = space.toMap();
    map['is_joined'] = isJoined ? 1 : 0;
    await db.insert('spaces', map, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteSpace(String domain, String node) async {
    final db = await database;
    await db.delete('spaces', where: 'domain = ? AND node = ?', whereArgs: [domain, node]);
  }

  Future<List<SpaceNode>> getJoinedSpaces() async {
    final db = await database;
    final maps = await db.query('spaces', where: 'is_joined = 1');
    return maps.map((map) => SpaceNode.fromMap(map)).toList();
  }

  Future<List<SpaceNode>> getAllSpaces() async {
    final db = await database;
    final maps = await db.query('spaces');
    return maps.map((map) => SpaceNode.fromMap(map)).toList();
  }
}
