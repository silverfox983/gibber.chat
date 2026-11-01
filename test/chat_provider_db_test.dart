import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/providers/chat_provider.dart';
import 'package:gibber/services/database_service.dart';
import 'package:gibber/models/chat_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testPath = ':memory:';
    tmp = Directory.systemTemp.createTempSync('gibber_chat_provider_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // sqflite connections may still hold the files; OS cleans up temp dirs.
    }
  });

  group('ChatProvider with isolated test database', () {
    test('fresh provider starts with no conversations', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = ChatProvider(database: DatabaseService.forTest(tmp.path + '/fresh.db'));
      expect(provider.conversations, isEmpty);
    });

    test('addMessage persists through the injected database instance', () async {
      SharedPreferences.setMockInitialValues({});
      final db = DatabaseService.forTest(tmp.path + '/persist.db');
      final provider = ChatProvider(database: db);

      provider.addMessage(
        'alice@example.com',
        ChatMessage(
          id: 'm1',
          text: 'hello',
          timestamp: DateTime.now(),
          isSent: false,
          senderId: 'alice@example.com',
          senderName: 'Alice',
          conversationId: 'alice@example.com',
        ),
      );

      await Future.delayed(const Duration(milliseconds: 400));

      final stored = await db.getMessages('alice@example.com');
      expect(stored, hasLength(1));
      expect(stored.first.text, 'hello');
      expect(stored.first.id, 'm1');
    });

    test('two providers on separate isolated databases do not share rows', () async {
      SharedPreferences.setMockInitialValues({});
      final dbA = DatabaseService.forTest(tmp.path + '/a.db');
      final dbB = DatabaseService.forTest(tmp.path + '/b.db');
      final providerA = ChatProvider(database: dbA);
      final providerB = ChatProvider(database: dbB);

      providerA.addMessage(
        'alice@example.com',
        ChatMessage(
          id: 'mA',
          text: 'from A',
          timestamp: DateTime.now(),
          isSent: false,
          conversationId: 'alice@example.com',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 400));

      expect(await dbA.getMessages('alice@example.com'), hasLength(1));
      expect(await dbB.getMessages('alice@example.com'), isEmpty);
      expect(await (ChatProvider(database: dbB)).conversations, isEmpty);
    });
  });
}