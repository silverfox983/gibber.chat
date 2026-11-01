import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/models/chat_models.dart';

ChatMessage _msg({Map<String, List<String>>? reactions}) => ChatMessage(
      id: 'm1',
      text: 'hello',
      timestamp: DateTime.parse('2026-11-01T10:00:00.000Z'),
      isSent: false,
      senderId: 'alice@example.com',
      conversationId: 'alice@example.com',
      reactions: reactions,
    );

void main() {
  group('ChatMessage reactions serialization', () {
    test('toMap/fromMap round-trips reactions through reactions_json only', () {
      final msg = _msg(
        reactions: {
          '👍': ['bob@example.com', 'alice@example.com'],
          '🎉': ['carol@example.com'],
        },
      );
      final map = msg.toMap();

      // Single source of truth: no legacy dual write anymore.
      expect(map.containsKey('reactions'), isFalse,
          reason: 'reactions column is deprecated; reactions_json is canonical');
      expect(map['reactions_json'], isNotNull);

      final restored = ChatMessage.fromMap(map);
      expect(restored.reactions, msg.reactions);
    });

    test('dedupes repeated senders', () {
      final msg = _msg(
        reactions: {
          '👍': ['bob@example.com', 'bob@example.com', ' bob@example.com '],
        },
      );
      expect(msg.reactions['👍'], ['bob@example.com']);
    });

    test('fromMap falls back to legacy reactions column for old rows', () {
      final map = _msg(reactions: {'🎉': ['ann@example.com']}).toMap();
      // Simulate a pre-unification row: content lives ONLY in 'reactions'.
      final legacy = Map<String, dynamic>.from(map)
        ..['reactions_json'] = null
        ..['reactions'] = map['reactions_json'];
      final restored = ChatMessage.fromMap(legacy);
      expect(restored.reactions['🎉'], ['ann@example.com']);
    });

    test('empty and invalid reaction data decode to empty map', () {
      expect(ChatMessage.fromMap(_msg().toMap()).reactions, isEmpty);
      expect(ChatMessage.fromMap({'id': 'x', 'reactions_json': 'not-json'}).reactions, isEmpty);
    });
  });
}