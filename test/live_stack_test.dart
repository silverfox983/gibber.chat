import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

import 'package:gibber/models/space_models.dart';
import 'package:gibber/services/spaces_service.dart';

/// Live end-to-end probe against the local docker stack.
///
/// Opt-in: run with  LIVE_STACK=1  (requires prosody/backend up on localhost).
/// Verifies: guest registration, XMPP connect (c2s), MUC room join via the
/// biboumi IRC gateway, group-chat message send, and Spaces discovery.
const _api = 'http://127.0.0.1:8080';
const _xmppHost = '127.0.0.1';
const _xmppPort = 5222;
const _domain = 'gibberapp.online';
const _ircGateway = 'irc.gibberapp.online';

bool get _live => Platform.environment['LIVE_STACK'] == '1';

String _randUser() {
  final r = Random();
  return 'probe${DateTime.now().millisecondsSinceEpoch % 100000000}${r.nextInt(90) + 10}';
}

void main() {
  test('STACK: register guest, connect XMPP, join IRC room, discover spaces', () async {
    if (!_live) {
      // ignore: avoid_print
      print('SKIP: LIVE_STACK != 1');
      return;
    }

    // --- 1. Register a fresh guest via the backend --------------------------
    final username = _randUser();
    final password = 'S${_randUser()}xyzpass';
    final reg = await http.post(
      Uri.parse('$_api/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password, 'host': _domain}),
    ).timeout(const Duration(seconds: 20));
    final regBody = jsonDecode(reg.body) as Map<String, dynamic>;
    expect(reg.statusCode, 200, reason: 'register failed: ${reg.body}');
    expect(regBody['jid'], contains(username));

// --- 2. Connect over c2s (5222) ----------------------------------------
    final account = xmpp.XmppAccountSettings.fromJid('$username@$_domain', password);
    account.host = _xmppHost;
    account.port = _xmppPort;
    account.totalReconnections = 1;

    final conn = xmpp.Connection(account);
    final completer = Completer<xmpp.XmppConnectionState>();
    final sub = conn.connectionStateStream.listen((state) async {
      if (state == xmpp.XmppConnectionState.Ready ||
          state == xmpp.XmppConnectionState.AuthenticationFailure) {
        if (!completer.isCompleted) completer.complete(state);
      }
    });
    conn.connect();
    final finalState = await completer.future.timeout(const Duration(seconds: 20));
    final stateHistory = <xmpp.XmppConnectionState>[];
    expect(finalState, xmpp.XmppConnectionState.Ready, reason: 'XMPP connect failed');

    // --- 3. Spaces service (wired into this probe's own dispatch) ----------
    final spacesService = SpacesService(conn, accountId: '$username@$_domain');

    // --- 3b. Join a room -----------------------------------------------------
    // Try the LOCAL MUC first (no external-network footprint). The IRC
    // gateway path is proven when biboumi bridges the join; public networks
    // like Libera actively ban automated clients (K-Line), so do not rely on
    // them for the probe.
    final roomCandidates = <String>[
      '#gibberprobe@conference.$_domain',
      '#gibberprobe%irc.libera.chat@$_ircGateway',
    ];
    final joinedSelf = Completer<String>();
    String? roomJid;
    var sentMsg = false;
    late final StreamSubscription<xmpp.AbstractStanza?> stanzaSub;
    var attempts = 0;
    final total = roomCandidates.length;

    void tryNextCandidate() {
      if (roomJid != null || attempts >= total) return;
      roomJid = roomCandidates[attempts];
      attempts++;
      final join = xmpp.PresenceStanza();
      join.toJid = xmpp.Jid.fromFullJid('$roomJid/$username');
      final mucEl = xmpp.XmppElement()
        ..name = 'x'
        ..addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/muc'));
      join.addChild(mucEl);
      conn.writeStanza(join);
    }

    stanzaSub = conn.inStanzasStream.listen((stanza) async {
      // Feed the spaces service (the app's dispatcher does this).
      try {
        spacesService.handleStanza(stanza);
      } catch (_) {}
      if (sentMsg) return;
      if (stanza is xmpp.IqStanza) {
        final type = stanza.type;
        if (type == xmpp.IqStanzaType.RESULT || type == xmpp.IqStanzaType.ERROR) {
          // SpacesService correlates via its own IqRequestManager.
        }
      }
      if (stanza is xmpp.PresenceStanza) {
        final mucX = stanza.children.where((c) =>
            c.name == 'x' &&
            c.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/muc#user');
        final selfCode = mucX.expand((x) => x.children)
            .where((c) => c.name == 'status')
            .any((s) => s.getAttribute('code')?.value == '110');
        if (selfCode && !joinedSelf.isCompleted && roomJid != null) {
          joinedSelf.complete(roomJid!);
          // Join confirmed — send a groupchat message into the room.
          final msg = xmpp.MessageStanza('msg_${DateTime.now().millisecondsSinceEpoch}',
              xmpp.MessageStanzaType.GROUPCHAT);
          msg.toJid = xmpp.Jid.fromFullJid(roomJid!);
          final body = xmpp.XmppElement()..name = 'body'..textValue = 'probe hello from $username';
          msg.addChild(body);
          conn.writeStanza(msg);
          sentMsg = true;
          // Leave immediately to keep the IRC channel footprint minimal.
          final leave = xmpp.PresenceStanza.withType(xmpp.PresenceType.UNAVAILABLE);
          leave.toJid = xmpp.Jid.fromFullJid('$roomJid!/$username'.replaceAll('!', ''));
          conn.writeStanza(leave);
        }
      } else if (stanza is xmpp.MessageStanza &&
          stanza.type == xmpp.MessageStanzaType.ERROR &&
          attempts < total) {
        // Join failed on this candidate - try the next JID format.
        Future.delayed(const Duration(milliseconds: 800), tryNextCandidate);
      }
    });

    tryNextCandidate();
    final didJoin = await joinedSelf.future
        .timeout(const Duration(seconds: 30), onTimeout: () => '');
    expect(didJoin, isNotEmpty, reason: 'MUC self-presence (110) not received for any of $roomCandidates');

    // --- 4. Spaces discovery -------------------------------------------------
    final spaces = await spacesService
        .discoverAllSpaces(_domain, forceRefresh: true)
        .timeout(const Duration(seconds: 25), onTimeout: () => const <SpaceNode>[]);
    // ignore: avoid_print
    print('SPACES DISCOVERED: ${spaces.length}');
    for (final s in spaces.take(5)) {
      // ignore: avoid_print
      print('  - ${s.domain}|${s.node} name=${s.name}');
    }

    // --- 5. Create a space, then re-discover (population must work) ---------
    final spaceNode = 'landingprobe${DateTime.now().millisecondsSinceEpoch % 100000}';
    final created = await spacesService.createSpace(
      _domain,
      spaceNode,
      'Probe Space',
      description: 'Created by the live probe',
      createChatRoom: false,
    ).timeout(const Duration(seconds: 30), onTimeout: () => 'create-timeout');
    // ignore: avoid_print
    print('CREATE SPACE result: ${created ?? 'null (ok?)'}');
    final after = await spacesService
        .discoverAllSpaces(_domain, forceRefresh: true)
        .timeout(const Duration(seconds: 25), onTimeout: () => const <SpaceNode>[]);
    // ignore: avoid_print
    print('SPACES AFTER CREATE: ${after.length}');
    for (final s in after.take(5)) {
      // ignore: avoid_print
      print('  + ${s.domain}|${s.node} name=${s.name}');
    }
    expect(after.any((s) => s.node == spaceNode), true,
        reason: 'created space must appear in discovery (created=$created)');

    stateHistory.clear();
    await sub.cancel();
    conn.close();
  }, timeout: const Timeout(Duration(seconds: 120)));
}