import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/database_service.dart';
import 'package:gibber/models/chat_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testPath = ':memory:';
    SharedPreferences.setMockInitialValues({});
  });

  group('guest claim migrations', () {
    late DatabaseService db;

    setUp(() {
      db = DatabaseService();
    });

    test('reassignAccountIds moves messages and conversations, skips transports', () async {
      await db.insertMessage(ChatMessage(
        id: 'm1',
        text: 'hello from the guest',
        timestamp: DateTime.now(),
        isSent: true,
        senderId: 'guestabc@tld',
        senderName: 'guestabc',
        accountId: 'guestabc@tld',
        conversationId: 'friend@tld',
        type: MessageType.text,
      ));
      await db.upsertConversation(Conversation(
        id: 'friend@tld',
        name: 'Friend',
        messages: const [],
        protocol: 'XMPP',
        accountId: 'guestabc@tld',
      ));
      await db.saveRegisteredTransport(
        gatewayJid: 'whatsapp.tld',
        gatewayName: 'whatsapp',
        gatewayType: 'whatsapp',
        accountId: 'guestabc@tld',
      );

      final moved = await db.reassignAccountIds('guestabc@tld', 'realuser@tld');

      expect(moved, 2);
      final conversations = await db.getConversations();
      expect(conversations.single.accountId, 'realuser@tld');
      // The transport row must have been untouched (it is jid-bound and gets
      // deleted separately when the claim drops gateway registrations).
      final transports = await db.getRegisteredTransports();
      expect(transports.firstWhere((t) => t['gateway_jid'] == 'whatsapp.tld')['account_id'],
          'guestabc@tld');
    });

    test('deleteRegisteredTransportsForAccount drops only that account rows', () async {
      await db.saveRegisteredTransport(
        gatewayJid: 'discord.tld',
        gatewayName: 'discord',
        gatewayType: 'discord',
        accountId: 'guestabc@tld',
      );
      await db.saveRegisteredTransport(
        gatewayJid: 'telegram.tld',
        gatewayName: 'telegram',
        gatewayType: 'telegram',
        accountId: 'realuser@tld',
      );

      await db.deleteRegisteredTransportsForAccount('guestabc@tld');

      final left = await db.getRegisteredTransports();
      expect(left, hasLength(1));
      expect(left.single['gateway_jid'], 'telegram.tld');
    });
  });
}