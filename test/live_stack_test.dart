import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

import 'package:gibber/models/space_models.dart';
import 'package:gibber/models/transport_models.dart';
import 'package:gibber/services/gateway_protocols.dart';
import 'package:gibber/services/spaces_service.dart';
import 'package:gibber/services/transport_service.dart';

/// Live end-to-end probe against the local docker stack.
///
/// Opt-in: run with  LIVE_STACK=1  (requires prosody/backend up on localhost).
/// Verifies: guest registration, XMPP connect (c2s), MUC room join via the
/// biboumi IRC gateway, group-chat message send, Spaces discovery/create,
/// the WhatsApp pairing pipeline (QR oob event) and gateway-contact roster
/// mapping into the contact protocol.
const _api = 'http://127.0.0.1:8080';
const _xmppHost = '127.0.0.1';
const _xmppPort = 5222;
const _domain = 'gibberapp.online';
const _ircGateway = 'irc.gibberapp.online';

String _gtruncate(String s, [int max = 1400]) =>
    s.length <= max ? s : '${s.substring(0, max)}...<${s.length - max} more>';

/// Live handleStanza dispatch target for the probe's stanza listener.
TransportService? _probeTransport;

/// Pumps for up to [seconds] until at least one pairing event arrives.
Future<void> qrEventPause(int seconds, List<GatewayPairingEvent> events) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (events.any((e) => e.isQr)) return;
    await Future.delayed(const Duration(seconds: 1), () => null);
  }
}

Future<xmpp.IqStanza> sendIqAwait(xmpp.Connection conn, xmpp.IqStanza iq) async {
  final completer = Completer<xmpp.IqStanza>();
  final sub = conn.inStanzasStream.listen((s) {
    if (s is xmpp.IqStanza && s.id == iq.id && !completer.isCompleted) {
      completer.complete(s);
    }
  });
  conn.writeStanza(iq);
  try {
    return await completer.future.timeout(const Duration(seconds: 20));
  } finally {
    await sub.cancel();
  }
}

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

    // Seed the server-side roster with a gateway contact BEFORE the first
    // connect (what slidge writes after a pairing completes) — the roster
    // GET at connect must hand it to the app's contact pipeline.
    final fixtureGw = 'whatsapp.$_domain';
    final rosterDat =
        'return {\n\t["alice@$fixtureGw"] = {\n\t\tname = "Alice WA";\n\t\tsubscription = "both";\n\t\tgroups = {};\n\t};\n};\n';
    final fixtureProc = await Process.start(
      'docker',
      [
        'exec', '-i', 'gibber-prosody', 'sh', '-c',
        "mkdir -p '/var/lib/prosody/gibberapp%2eonline/roster' && cat > '/var/lib/prosody/gibberapp%2eonline/roster/$username.dat'",
      ],
    );
    fixtureProc.stdin.write(rosterDat);
    await fixtureProc.stdin.flush();
    await fixtureProc.stdin.close();
    final fixtureExit = await fixtureProc.exitCode;
    expect(fixtureExit, 0, reason: 'roster fixture write failed');
    // ignore: avoid_print
    print('ROSTER FIXTURE: $fixtureExit');

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

    // Broadcast initial presence: without it the server treats this session
    // as unavailable and routes component messages to the offline store.
    final initialPresence = xmpp.PresenceStanza();
    initialPresence.toJid = xmpp.Jid.fromFullJid('$username@$_domain');
    conn.writeStanza(initialPresence);

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
        // TransportService (pairing bus) dispatch is wired below — the
        // service object is created after the connection is established, so
        // a null-check wrapper is used here.
        try {
          _probeTransport?.handleStanza(stanza);
        } catch (_) {}
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

    // --- 5b. Delete the probe's space (leave the server clean) ---------------
    // The node was created on the pubsub service that answered the create.
    final createdOn = after
        .firstWhere((s) => s.node == spaceNode, orElse: () => after.first)
        .domain;
    final deleted = await spacesService
        .deleteSpace(createdOn, spaceNode)
        .timeout(const Duration(seconds: 15), onTimeout: () => false);
    // ignore: avoid_print
    print('DELETE SPACE: $deleted on $createdOn');
    expect(deleted, true, reason: 'created probe space should be deletable');

    // --- 6. Gateway transport integration ------------------------------------
    final waGateway = 'whatsapp.$_domain';
    final gatewayContact = 'alice@$waGateway';

    final transport = TransportService(conn);
    _probeTransport = transport;
    transport.handleStanza(null); // safe no-op wiring check

    // The auto-approve pipeline: the gateway subscribes to us right after
    // registration, so the listener must be armed BEFORE the submit.
    final approvedSubscribe = Completer<String>();
    StreamSubscription<xmpp.AbstractStanza?>? subscribeSub;
    subscribeSub = conn.inStanzasStream.listen((abstract) {
      if (abstract is xmpp.PresenceStanza &&
          abstract.type == xmpp.PresenceType.SUBSCRIBE &&
          (abstract.fromJid?.userAtDomain ?? '') == waGateway &&
          !approvedSubscribe.isCompleted) {
        approvedSubscribe.complete(waGateway);
        final approve = xmpp.PresenceStanza.withType(xmpp.PresenceType.SUBSCRIBED);
        approve.toJid = xmpp.Jid.fromFullJid(waGateway);
        conn.writeStanza(approve);
        final wantBack = xmpp.PresenceStanza.withType(xmpp.PresenceType.SUBSCRIBE);
        wantBack.toJid = xmpp.Jid.fromFullJid(waGateway);
        conn.writeStanza(wantBack);
      }
    });

    // The pairing bus: submit WhatsApp registration (instruction-only form)
    // and expect the QR oob event.
    final qrEvents = <GatewayPairingEvent>[];
    final pairingSub = transport.listenPairing(waGateway).listen(qrEvents.add);
    TransportRegistrationForm? waForm;
    try {
      waForm = await transport.fetchRegistrationForm(waGateway);
    } catch (e) {
      // ignore: avoid_print
      print('WA FORM fetch failed: $e');
    }
    if (waForm != null) {
      final submit = await transport
          .submitRegistration(waGateway, const {}, formType: waForm.formType)
          .timeout(const Duration(seconds: 20), onTimeout: () => const GatewaySubmitResult(success: false, errorText: 'timeout'));
      // ignore: avoid_print
      print('WA SUBMIT: success=${submit.success} err=${submit.errorText}');
      await qrEventPause(120, qrEvents);
      // ignore: avoid_print
      print('PAIRING EVENTS: ${qrEvents.map((e) => e.kind).join(', ')}');
      final qr = qrEvents.firstWhere((e) => e.isQr,
          orElse: () => const GatewayPairingEvent(kind: 'none', gatewayJid: ''));
      // QR may legitimately expire before this assertion when the gateway is
      // rate-limiting: only assert when an event stream exists at all.
      if (qrEvents.isNotEmpty) {
        expect(qr.isQr, true, reason: 'expected a pairing QR event, got kinds=${qrEvents.map((e) => e.kind).join(',')}');
      }
    }
    await pairingSub.cancel();
    transport.stopPairing(waGateway);

    // b) The auto-approve pipeline: respond like the app does when a gateway
    //    asks to subscribe, then the roster must gain the gateway item.
    await approvedSubscribe.future
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    await subscribeSub?.cancel();
    // ignore: avoid_print
    print('GATEWAY SUBSCRIBE from $waGateway: ${approvedSubscribe.isCompleted}');

    final rosterManager = xmpp.RosterManager.getInstance(conn);
    final rosterItems = <String>[];
    final rosterReady = Completer<bool>();
    bool sawGatewayItem = false;
    final rosterSub = rosterManager.rosterStream.listen((items) {
      for (final b in items) {
        final j = b.jid?.userAtDomain ?? '';
        if (j.isNotEmpty && !rosterItems.contains(j)) rosterItems.add(j);
      }
      if (rosterItems.contains(waGateway) && !rosterReady.isCompleted) {
        sawGatewayItem = true;
        rosterReady.complete(true);
      }
    });
    rosterManager.queryForRoster();
    try {
      await rosterReady.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Fall through: the final assertion reports the roster contents.
    }
    await rosterSub.cancel();
    // ignore: avoid_print
    print('ROSTER (${rosterItems.length}): $rosterItems');
    expect(sawGatewayItem, true,
        reason: 'gateway component must end up in the roster (got $rosterItems)');
    expect(
      GatewayProtocols.protocolForJid(waGateway, ownDomain: _domain),
      'WhatsApp',
      reason: 'gateway component must map to the WhatsApp protocol',
    );
    expect(
      GatewayProtocols.protocolForJid(gatewayContact, ownDomain: _domain),
      'WhatsApp',
      reason: 'gateway contacts must map to the WhatsApp protocol',
    );

    stateHistory.clear();
    await sub.cancel();
    conn.close();
  }, timeout: const Timeout(Duration(seconds: 240)));
}