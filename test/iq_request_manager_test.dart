import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:gibber/services/iq_request_manager.dart';

xmpp.IqStanza _iq(String id) => xmpp.IqStanza(id, xmpp.IqStanzaType.RESULT);

void main() {
  group('IqRequestManager', () {
    test('register + complete resolves the awaiting future', () async {
      final mgr = IqRequestManager();
      final c = Completer<xmpp.IqStanza>();
      mgr.register('iq_1', c);

      expect(mgr.contains('iq_1'), isTrue);
      expect(mgr.hasPending, isTrue);

      final response = _iq('iq_1');
      mgr.complete('iq_1', response);
      final result = await c.future;
      expect(result, same(response));

      expect(mgr.contains('iq_1'), isFalse);
      expect(mgr.hasPending, isFalse);
      expect(mgr.pendingCount, 0);
    });

    test('complete with unknown id returns false and does not throw', () {
      final mgr = IqRequestManager();
      expect(mgr.complete('nope', _iq('nope')), isFalse);
      expect(mgr.complete(null, _iq('x')), isFalse);
    });

    test('complete with null id is a safe no-op', () {
      final mgr = IqRequestManager();
      expect(mgr.complete(null, _iq('x')), isFalse);
    });

    test('fail resolves the future with error', () async {
      final mgr = IqRequestManager();
      final c = Completer<xmpp.IqStanza>();
      mgr.register('iq_2', c);

      expect(mgr.fail('iq_2', TimeoutException('timed out')), isTrue);
      await expectLater(c.future, throwsA(isA<TimeoutException>()));
      expect(mgr.contains('iq_2'), isFalse);
    });

    test('forget drops entry without completing the future', () {
      final mgr = IqRequestManager();
      final c = Completer<xmpp.IqStanza>();
      mgr.register('iq_3', c);

      mgr.forget('iq_3');
      expect(mgr.contains('iq_3'), isFalse);
      expect(c.isCompleted, isFalse);
    });

    test('failAll fails every pending request and clears the map', () async {
      final mgr = IqRequestManager();
      final c1 = Completer<xmpp.IqStanza>();
      final c2 = Completer<xmpp.IqStanza>();
      mgr.register('a', c1);
      mgr.register('b', c2);

      mgr.failAll('Service disposed');

      await expectLater(c1.future, throwsA('Service disposed'));
      await expectLater(c2.future, throwsA('Service disposed'));
      expect(mgr.hasPending, isFalse);
    });

    test('failAll on already-completed completer does not throw', () async {
      final mgr = IqRequestManager();
      final c = Completer<xmpp.IqStanza>();
      mgr.register('a', c);
      c.complete(_iq('a'));

      mgr.failAll('Service disposed');
      expect(await c.future, isNotNull);
      expect(mgr.hasPending, isFalse);
    });

    test('exposed pending map completes correctly from outside', () async {
      final mgr = IqRequestManager();
      final c = Completer<xmpp.IqStanza>();
      mgr.register('routed', c);

      final c2 = Completer<xmpp.IqStanza>();
      mgr.register('routed', c2);

      expect(mgr.pendingCount, 1);
      expect(mgr.contains('routed'), isTrue);
      await expectLater(c.future, doesNotComplete);

      mgr.complete('routed', _iq('routed'));
      expect(await c2.future, isNotNull);
    });
  });
}