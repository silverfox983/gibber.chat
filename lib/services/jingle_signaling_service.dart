import 'dart:async';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
// Internal import required for XmppAttribute as it's not exported in the main file
// ignore: implementation_imports
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:flutter/foundation.dart';

enum JingleAction {
  sessionInitiate,
  sessionAccept,
  transportInfo,
  sessionTerminate,
  propose,
  ringing,
  proceed,
  contentModify,
  sessionInfo,
  roomTopicUpdate,
  chatMarker,
  retract,
  messageError,
}

class JingleEvent {
  final JingleAction action;
  final String sessionId;
  final String fromJid;
  final String? accountId;
  final String? sdp;
  final String? reason;
  final Map<String, dynamic>? candidate;

  JingleEvent({
    required this.action,
    required this.sessionId,
    required this.fromJid,
    this.accountId,
    this.sdp,
    this.reason,
    this.candidate,
    this.topic,
  });

  final String? topic;
}

class JingleSignalingService {
  final xmpp.Connection connection;
  final _eventController = StreamController<JingleEvent>.broadcast();
  Stream<JingleEvent> get events => _eventController.stream;

  // Track content names per session to map to SDP MIDs (index-based)
  final Map<String, List<String>> _sessionContentMap = {};

  // Track ufrag and pwd credentials for trickle ICE (transport-info)
  final Map<String, Map<String, String>> _sessionCredentials = {};

  // Track discovered setup roles and ice-lite status per session
  final Map<String, String> _sessionSetupRoles = {};
  final Map<String, bool> _sessionIsIceLite = {};

  // Track if we are the initiator to prevent state corruption with early media
  final Map<String, bool> _sessionIsWeInitiator = {};

  // Track pending XEP-0353 sessions (message-initiated)
  final Set<String> _messageInitiatedSessions = {};

  // Track pending outgoing sessions awaiting <proceed/> - stores SDP and metadata
  // Key format: "$sessionId:$toJid" to avoid collision in MUC group calls
  final Map<String, Map<String, dynamic>> _pendingProposeSessions = {};

  // Timers for XEP-0353 fallback (proceed timeout)
  final Map<String, Timer> _proceedTimers = {};

  // Timers for XEP-0353 fallbacks


  // Callback for when <proceed/> is received for an outgoing call
  Function(String sessionId, String sdp, String toJid)? onProceedReceived;

  // Track IQ IDs of outgoing session-initiate to wait for RESULT
  final Map<String, String> _iqToSessionId = {};
  final Map<String, String> _iqToRecipientJid = {};

  // Counter to ensure unique IQ IDs for rapid candidate flushing
  int _candidateCounter = 0;
  // Track which sessions have been acknowledged by the server/remote
  final Set<String> _acknowledgedSessions = {};
  // Queue candidates that arrive before the session is acknowledged
  final Map<String, List<Map<String, dynamic>>> _pendingOutgoingCandidates = {};

  StreamSubscription? _stanzaSubscription;

  JingleSignalingService(this.connection) {
    debugPrint('Jingle: Initialized for ${connection.fullJid.fullJid}');
  }

  bool _writeStanza(xmpp.AbstractStanza stanza) {
    if (connection.state != xmpp.XmppConnectionState.Ready) {
      debugPrint(
        'Jingle: WARNING - Attempted to send stanza while XMPP is not Ready (State: ${connection.state})',
      );
      return false;
    }
    connection.writeStanza(stanza);
    return true;
  }

  void dispose() {
    _stanzaSubscription?.cancel();
    _stanzaSubscription = null;

    if (!_eventController.isClosed) {
      _eventController.close();
    }
  }

  // AuthService handles dispatching to these public handlers

  void handleIncomingMessage(xmpp.MessageStanza stanza) {
    if (stanza.type == xmpp.MessageStanzaType.ERROR) {
      debugPrint('Jingle: Ignoring bounced Jingle message (type=error)');
      return;
    }

    // 1. Skip Jingle signaling from MAM (archived calls) or delayed messages
    final mamResult = stanza.getChild('result');
    final delay = stanza.getChild('delay');
    if ((mamResult != null &&
            mamResult.getAttribute('xmlns')?.value == 'urn:xmpp:mam:2') ||
        (delay != null &&
            delay.getAttribute('xmlns')?.value == 'urn:xmpp:delay')) {
      debugPrint(
        'Jingle: Ignoring historical Jingle Message (MAM or delayed).',
      );
      return;
    }

    // 2. Filter out self-sent messages (including reflected carbons)
    final fromJidStr = stanza.fromJid != null
        ? '${stanza.fromJid!.local}@${stanza.fromJid!.domain}'.toLowerCase()
        : '';
    final myJidStr = '${connection.fullJid.local}@${connection.fullJid.domain}'
        .toLowerCase();

    // We only filter if it's a Carbon-sent or we are sure it's us
    final isCarbonSent = stanza.getChild('sent') != null;
    if (isCarbonSent && fromJidStr == myJidStr) {
      debugPrint('Jingle: Ignoring self-echo Carbon message.');
      return;
    }

    // 2. Support XEP-0280 Carbons: Extract inner message if wrapped
    xmpp.XmppElement effectiveElement = stanza;
    final carbonSent = stanza.getChild('sent');
    final carbonReceived = stanza.getChild('received');
    final carbon = carbonSent ?? carbonReceived;
    if (carbon != null) {
      final fwd = carbon.getChild('forwarded');
      final msg = fwd?.getChild('message');
      if (msg != null) {
        effectiveElement = msg;
        debugPrint('Jingle: Processing signaling from Carbon-copied message');
      }
    }

    // 3. Look for XEP-0353 elements in the effective element
    for (var child in effectiveElement.children) {
      final ns = child.getAttribute('xmlns')?.value;
      final name = child.name;

      // Handle XEP-0353 elements (urn:xmpp:jingle-message:0/1 namespace)
      if (ns == 'urn:xmpp:jingle-message:0' ||
          ns == 'urn:xmpp:jingle-message:1') {
        debugPrint(
          'Jingle: Found XEP-0353 element: $name in NS: $ns from ${stanza.fromJid?.fullJid}',
        );
        _processJingleMessageElement(child, stanza);
        continue;
      } else if (name == 'ringing' || name == 'propose' || name == 'proceed') {
        debugPrint(
          'Jingle: Found potential Jingle Message element $name but NS is $ns',
        );
      }

      // Handle legacy Jingle in MESSAGE (some implementations send directly)
      if (name == 'jingle' && ns == 'urn:xmpp:jingle:1') {
        debugPrint(
          'Jingle: [LEGACY] Received Jingle via MESSAGE from ${stanza.fromJid?.fullJid}',
        );
        _processJingleElement(child, stanza);
      }
    }
  }

  void _processJingleMessageElement(
    xmpp.XmppElement element,
    xmpp.MessageStanza stanza,
  ) {
    final name = element.name;
    final sid = element.getAttribute('id')?.value;
    final fromJid = stanza.fromJid?.fullJid ?? '';

    debugPrint('Jingle: [XEP-0353] Received $name from $fromJid, sid: $sid');

    if (sid == null) {
      debugPrint('Jingle: [XEP-0353] Element missing id attribute, ignoring');
      return;
    }

    switch (name) {
      case 'proceed':
        _handleProceed(sid, fromJid);
        break;
      case 'reject':
        _handleReject(sid, fromJid, element);
        break;
      case 'ringing':
        debugPrint(
          'Jingle: [XEP-0353] Remote is ringing from $fromJid, sid: $sid',
        );

        // Cancel fallback timer since we know they support XEP-0353 and received the proposal


        // DYNAMIC JID UPDATE: If we were waiting on a bare JID, we now have a full JID
        final pending = _pendingProposeSessions[sid];
        if (pending != null &&
            !pending['toJid'].contains('/') &&
            fromJid.contains('/')) {
          debugPrint(
            'Jingle: [XEP-0353] Updating bare JID to full JID: $fromJid',
          );
          pending['toJid'] = fromJid;
        }

        _eventController.add(
          JingleEvent(
            action: JingleAction.ringing,
            sessionId: sid,
            fromJid: fromJid,
          ),
        );
        break;
      case 'propose':
        debugPrint('Jingle: [XEP-0353] Received inbound propose, sid: $sid');
        _handleInboundPropose(element, sid, fromJid, stanza);
        break;
      case 'retract':
        debugPrint('Jingle: [XEP-0353] Session retracted, sid: $sid');
        _eventController.add(
          JingleEvent(
            action: JingleAction.sessionTerminate,
            sessionId: sid,
            fromJid: fromJid,
            reason: 'retracted',
          ),
        );
        break;
      case 'finish':
        debugPrint('Jingle: [XEP-0353] Session finished, sid: $sid');
        _eventController.add(
          JingleEvent(
            action: JingleAction.sessionTerminate,
            sessionId: sid,
            fromJid: fromJid,
            reason: 'finished',
          ),
        );
        break;
      default:
        debugPrint('Jingle: [XEP-0353] Unknown element: $name');
    }
  }

  void _handleProceed(String sid, String fromJid) {
    final pending = _pendingProposeSessions[sid];
    if (pending == null) {
      debugPrint(
        'Jingle: [XEP-0353] Received proceed for unknown session: $sid from $fromJid',
      );
      return;
    }

    _proceedTimers[sid]?.cancel();
    _proceedTimers.remove(sid);

    debugPrint(
      'Jingle: [XEP-0353] Received proceed for session $sid, sending IQ session-initiate',
    );

    final sdp = pending['sdp'] as String;
    final isVideo = pending['isVideo'] as bool? ?? false;

    _pendingProposeSessions.remove(sid);

    sendSessionInitiateIq(fromJid, sid, sdp, isVideo: isVideo);

    onProceedReceived?.call(sid, sdp, fromJid);
  }

  void _handleReject(String sid, String fromJid, xmpp.XmppElement element) {
    debugPrint('Jingle: [XEP-0353] Session rejected, sid: $sid');
    _proceedTimers[sid]?.cancel();
    _proceedTimers.remove(sid);

    _pendingProposeSessions.remove(sid);

    String? reason;
    final reasonEl = element.getChild('reason');
    if (reasonEl != null && reasonEl.children.isNotEmpty) {
      final condition = reasonEl.children.first.name;
      final text = reasonEl.getChild('text')?.textValue;
      reason = text != null && text.isNotEmpty
          ? '$condition: $text'
          : condition;
    }

    _eventController.add(
      JingleEvent(
        action: JingleAction.sessionTerminate,
        sessionId: sid,
        fromJid: fromJid,
        reason: reason ?? 'rejected',
      ),
    );
  }

  void _handleInboundPropose(
    xmpp.XmppElement element,
    String sid,
    String fromJid,
    xmpp.MessageStanza stanza,
  ) {
    // Extract media types from description elements
    final descriptions = <String>[];
    for (var child in element.children) {
      if (child.name == 'description') {
        final media = child.getAttribute('media')?.value ?? 'audio';
        descriptions.add(media);
      }
    }

    debugPrint(
      'Jingle: [XEP-0353] Inbound propose for $sid, media: $descriptions',
    );

    // Store content map for this session
    _sessionContentMap[sid] = descriptions;

    // Fire event to notify call provider
    _eventController.add(
      JingleEvent(
        action: JingleAction.propose,
        sessionId: sid,
        fromJid: fromJid,
      ),
    );
  }

  void _processJingleElement(xmpp.XmppElement jingle, dynamic stanza) {
    final actionStr = jingle.getAttribute('action')?.value;
    final sid = jingle.getAttribute('sid')?.value;
    final fromJid = stanza.fromJid?.fullJid ?? '';

    if (sid == null || actionStr == null) return;

    debugPrint('Jingle: Processing action: $actionStr, sid: $sid');

    JingleAction? action;
    String? sdp;
    String? reason;
    Map<String, dynamic>? candidate;

    if (actionStr == 'session-initiate' || actionStr == 'session-accept') {
      action = actionStr == 'session-initiate'
          ? JingleAction.sessionInitiate
          : JingleAction.sessionAccept;
      final List<xmpp.XmppElement> contents = jingle.children
          .where((c) => c.name == 'content')
          .toList();

      if (contents.isNotEmpty) {
        final contentNames = contents
            .map((c) => c.getAttribute('name')?.value ?? '')
            .toList();
        debugPrint('Jingle: Content names: $contentNames');
        if (!_sessionContentMap.containsKey(sid)) {
          _sessionContentMap[sid] = contentNames;
        }
        final expectedOrder = _sessionContentMap[sid];

        // Try to find raw SDP
        for (var c in contents) {
          final s = c.getChild('description')?.textValue;
          if (s != null && s.isNotEmpty && s.contains('v=0')) {
            sdp = s;
            debugPrint('Jingle: Found raw SDP, length: ${sdp.length}');
            break;
          }
        }

        // Reconstruct SDP if needed
        if (sdp == null || sdp.isEmpty) {
          debugPrint('Jingle: Reconstructing SDP from Jingle');
          final initiator = jingle.getAttribute('initiator')?.value;
          final isWeInitiator =
              initiator != null && (initiator == connection.fullJid.fullJid);
          sdp = _reconstructMinimalSdp(
            contents,
            isWeInitiator,
            sid,
            actionStr == 'session-initiate',
            expectedOrder: expectedOrder,
          );
          debugPrint(
            'Jingle: Reconstructed SDP, length: ${sdp?.length}, has audio: ${sdp?.contains('m=audio')}',
          );
        }

        // Extract early candidates
        _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);
      }
    } else if (actionStr == 'transport-info') {
      action = JingleAction.transportInfo;
      final contentNames = _sessionContentMap[sid] ?? [];
      _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);
      return;
    } else if (actionStr == 'session-terminate') {
      action = JingleAction.sessionTerminate;
      final reasonEl = jingle.getChild('reason');
      if (reasonEl != null && reasonEl.children.isNotEmpty) {
        final condition = reasonEl.children.first.name;
        final text = reasonEl.getChild('text')?.textValue;
        reason = text != null && text.isNotEmpty
            ? '$condition: $text'
            : condition;
      }
    }

    if (action != null) {
      _eventController.add(
        JingleEvent(
          action: action,
          sessionId: sid,
          fromJid: fromJid,
          sdp: sdp,
          reason: reason,
          candidate: candidate,
        ),
      );
    }
  }

  /// XEP-0353: Send ` <propose/> ` via MESSAGE stanza
  /// Following XEP-0353: send propose first, wait for proceed, then send IQ
  void sendSessionInitiateViaMessage(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    // Step 1: Send <propose/> message (XEP-0353)
    final proposeMessage = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    proposeMessage.toJid = xmpp.Jid.fromFullJid(toJid);

    // Add store hint (required by XEP-0353)
    final storeHint = xmpp.XmppElement();
    storeHint.name = 'store';
    storeHint.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:hints'));
    proposeMessage.addChild(storeHint);

    // Create propose element
    final propose = xmpp.XmppElement();
    propose.name = 'propose';
    propose.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle-message:0'));
    propose.addAttribute(XmppAttribute('id', sessionId));

    // Add description elements for each media type
    final lines = sdp.split('\n');
    bool hasAudio = false;
    bool hasVideo = false;
    for (var line in lines) {
      if (line.trim().startsWith('m=audio')) hasAudio = true;
      if (line.trim().startsWith('m=video')) hasVideo = true;
    }

    if (hasAudio) {
      final descAudio = xmpp.XmppElement();
      descAudio.name = 'description';
      descAudio.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:rtp:1'),
      );
      descAudio.addAttribute(XmppAttribute('media', 'audio'));
      propose.addChild(descAudio);
    }
    if (hasVideo && isVideo) {
      final descVideo = xmpp.XmppElement();
      descVideo.name = 'description';
      descVideo.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:rtp:1'),
      );
      descVideo.addAttribute(XmppAttribute('media', 'video'));
      propose.addChild(descVideo);
    }

    proposeMessage.body = isVideo
        ? '📹 Incoming video call...'
        : '📞 Incoming audio call...';
    proposeMessage.addChild(propose);

    // Store SDP for when proceed is received
    _pendingProposeSessions[sessionId] = {
      'sdp': sdp,
      'toJid': toJid,
      'isVideo': isVideo,
      'timestamp': DateTime.now(),
    };

    // Set fallback timer (15 seconds to receive proceed)
    _proceedTimers[sessionId]?.cancel();
    _proceedTimers[sessionId] = Timer(const Duration(seconds: 15), () {
      debugPrint('Jingle: [XEP-0353] Proceed timeout for session $sessionId, falling back to direct IQ');
      _pendingProposeSessions.remove(sessionId);
      _proceedTimers.remove(sessionId);
      sendSessionInitiateIq(toJid, sessionId, sdp, isVideo: isVideo);
    });

    debugPrint(
      'Jingle: [XEP-0353] Sending <propose/> to $toJid, sid: $sessionId',
    );
    _writeStanza(proposeMessage);


  }

  /// Send actual Jingle session-initiate via IQ stanza
  /// Called after receiving ` <proceed/> ` from the remote party
  void sendSessionInitiateIq(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    _sessionIsWeInitiator[sessionId] = true;
    final iqId = 'jingle-$sessionId';
    _iqToSessionId[iqId] = sessionId;
    _iqToRecipientJid[iqId] = toJid;
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.addAttribute(XmppAttribute('to', toJid));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-initiate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    jingle.addAttribute(XmppAttribute('initiator', connection.fullJid.fullJid));

    final contents = _generateContentsFromSdp(sdp, 'initiator', sessionId);
    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    _messageInitiatedSessions.add(sessionId);

    debugPrint('Jingle: [INITIATE] Sending IQ to $toJid');
    _writeStanza(iq);
  }

  /// XEP-0353: Send session-accept (responds to session-initiate via IQ)
  void sendSessionAcceptViaMessage(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    _messageInitiatedSessions.add(sessionId);
    debugPrint('Jingle: [XEP-0353] Sending session-accept via IQ to $toJid');
    sendSessionAccept(toJid, sessionId, sdp, isVideo: isVideo);
  }

  /// XEP-0353: Send proceed message as a responder
  /// XEP-0353: Send <ringing/> to indicate the call is ringing
  void sendRinging(String toJid, String sessionId) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.addAttribute(XmppAttribute('to', toJid));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-info'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    final ringing = xmpp.XmppElement();
    ringing.name = 'ringing';
    ringing.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addChild(ringing);

    message.addChild(jingle);

    debugPrint(
      'Jingle: [XEP-0353] Sending <ringing/> to $toJid, sid: $sessionId',
    );
    _writeStanza(message);
  }

  void sendProceed(String toJid, String sessionId) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.addAttribute(XmppAttribute('to', toJid));

    final proceed = xmpp.XmppElement();
    proceed.name = 'proceed';
    proceed.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle-message:0'));
    proceed.addAttribute(XmppAttribute('id', sessionId));
    message.addChild(proceed);

    debugPrint(
      'Jingle: [XEP-0353] Sending <proceed/> to $toJid, sid: $sessionId',
    );
    _writeStanza(message);
  }

  /// XEP-0353: Send transport-info via MESSAGE stanza
  void sendTransportInfoViaMessage(
    String toJid,
    String sessionId,
    Map<String, dynamic> candidateMap, {
    bool isVideo = true,
  }) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.addAttribute(XmppAttribute('to', toJid));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'transport-info'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    final mid = candidateMap['sdpMid'] ?? '0';
    final contentNames =
        _sessionContentMap[sessionId] ??
        (isVideo ? ['audio', 'video'] : ['audio']);
    int midIdx = int.tryParse(mid) ?? 0;
    final contentName = (midIdx < contentNames.length)
        ? contentNames[midIdx]
        : (isVideo ? 'video' : 'audio');

    final content = xmpp.XmppElement();
    content.name = 'content';
    content.addAttribute(XmppAttribute('name', contentName));
    content.addAttribute(XmppAttribute('creator', 'initiator'));

    final transport = xmpp.XmppElement();
    transport.name = 'transport';
    transport.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:jingle:transports:ice-udp:1'),
    );

    final candidate = xmpp.XmppElement();
    candidate.name = 'candidate';
    candidate.addAttribute(XmppAttribute('id', mid));
    candidate.addAttribute(
      XmppAttribute('label', '${candidateMap['sdpMLineIndex'] ?? 0}'),
    );

    _addCandidateAttributes(candidate, candidateMap['candidate']);

    transport.addChild(candidate);
    content.addChild(transport);
    jingle.addChild(content);
    message.addChild(jingle);

    debugPrint(
      'Jingle: [XEP-0353] Sending transport-info via MESSAGE to $toJid',
    );
    _writeStanza(message);
  }

  /// XEP-0353: Send <retract/> via MESSAGE stanza (used by caller to cancel)
  void sendRetractViaMessage(String toJid, String sessionId) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.addAttribute(XmppAttribute('to', toJid));

    final retract = xmpp.XmppElement();
    retract.name = 'retract';
    retract.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle-message:0'));
    retract.addAttribute(XmppAttribute('id', sessionId));
    message.addChild(retract);
    message.body = '📞 Call cancelled.';

    debugPrint('Jingle: [XEP-0353] Sending <retract/> via MESSAGE to $toJid');
    _writeStanza(message);
  }

  /// XEP-0353: Send <reject/> via MESSAGE stanza (used by callee to decline)
  void sendRejectViaMessage(String toJid, String sessionId) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.addAttribute(XmppAttribute('to', toJid));

    final reject = xmpp.XmppElement();
    reject.name = 'reject';
    reject.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle-message:0'));
    reject.addAttribute(XmppAttribute('id', sessionId));
    message.addChild(reject);
    message.body = '📞 Call declined.';

    debugPrint('Jingle: [XEP-0353] Sending <reject/> via MESSAGE to $toJid');
    _writeStanza(message);
  }

  void sendSessionInitiate(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final iqId = 'jingle_${DateTime.now().millisecondsSinceEpoch}';
    _iqToSessionId[iqId] = sessionId;
    _iqToRecipientJid[iqId] = toJid;

    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    // CRITICAL: Force both 'to' and 'id' to ensure routing and tracking integrity
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-initiate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    jingle.addAttribute(XmppAttribute('initiator', connection.fullJid.fullJid));

    final contents = _generateContentsFromSdp(sdp, 'initiator', sessionId);

    // PRE-TRICKLE OPTIMIZATION: Include any candidates gathered during createOffer/setLocalDescription
    final pending = _pendingOutgoingCandidates.remove(sessionId);
    if (pending != null && pending.isNotEmpty) {
      debugPrint(
        'Jingle: Including ${pending.length} pre-gathered candidates in session-initiate',
      );
      for (var cand in pending) {
        final contentName = cand['sdpMid']?.toString() ?? '0';
        final content = contents.firstWhere(
          (c) => c.getAttribute('name')?.value == contentName,
          orElse: () => contents.first,
        );
        final transport = content.getChild('transport');
        if (transport != null) {
          final candEl = xmpp.XmppElement();
          candEl.name = 'candidate';
          final candStr = cand['candidate'];
          if (candStr is String && _addCandidateAttributes(candEl, candStr)) {
            transport.addChild(candEl);
          }
        }
      }
    }

    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    debugPrint(
      'Jingle: Sending session-initiate to $toJid with ${contents.length} contents (IQ: $iqId)',
    );
    _writeStanza(iq);
  }

  void sendSessionAccept(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final iqId = 'jingle_${DateTime.now().millisecondsSinceEpoch}';
    _iqToSessionId[iqId] = sessionId;
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    // CRITICAL: Force both 'to' and 'id' to ensure routing and tracking integrity
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    // CRITICAL: Mark session as acknowledged at the VERY START
    // This prevents candidates generated during the conversion from being queued
    _acknowledgedSessions.add(sessionId);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-accept'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    jingle.addAttribute(XmppAttribute('initiator', toJid));
    jingle.addAttribute(XmppAttribute('responder', connection.fullJid.fullJid));

    final expectedOrder = _sessionContentMap[sessionId];
    final contents = _generateContentsFromSdp(
      sdp,
      'initiator',
      sessionId,
      expectedOrder: expectedOrder,
    );

    // PRE-TRICKLE OPTIMIZATION: Include robust candidates in session-accept
    final key = sessionId.trim();
    final pending = _pendingOutgoingCandidates.remove(key) ?? [];
    final List<Map<String, dynamic>> toInclude = [];
    final List<Map<String, dynamic>> toPostpone = [];

    if (pending.isNotEmpty) {
      final sdpLower = sdp.toLowerCase();

      for (var cand in pending) {
        final candStr = cand['candidate']?.toString() ?? '';
        final type = cand['type']?.toString() ?? '';

        // Strategy: Include up to 10 host/srflx candidates in session-accept.
        // This supports non-trickle gateways and provides robust failover.
        bool shouldInclude = false;
        if (type == 'srflx' || type == 'host') {
          shouldInclude = true;
        }

        if (shouldInclude && toInclude.length >= 10) {
          shouldInclude = false;
        }

        if (shouldInclude) {
          // Deduplication: Only add if not already in the SDP (though unlikely for responder)
          final parts = candStr.split(' ');
          if (parts.length > 6) {
            final ipPort = '${parts[4]} ${parts[5]}';
            if (!sdpLower.contains(ipPort.toLowerCase())) {
              toInclude.add(cand);
              continue;
            }
          }
        }

        // If not included in the accept stanza, postpone for transport-info
        toPostpone.add(cand);
      }

      if (toInclude.isNotEmpty) {
        debugPrint(
          'Jingle: Including ${toInclude.length} pre-gathered candidates in session-accept',
        );
        for (var cand in toInclude) {
          final contentName = cand['sdpMid']?.toString() ?? '0';
          final content = contents.firstWhere(
            (c) => c.getAttribute('name')?.value == contentName,
            orElse: () => contents.first,
          );
          final transport = content.getChild('transport');
          if (transport != null) {
            final candEl = xmpp.XmppElement();
            candEl.name = 'candidate';
            final candStr = cand['candidate'];
            if (candStr is String && _addCandidateAttributes(candEl, candStr)) {
              transport.addChild(candEl);
            }
          }
        }
      }

      // Re-queue postponed candidates so they are flushed after the accept stanza is sent
      if (toPostpone.isNotEmpty) {
        _pendingOutgoingCandidates
            .putIfAbsent(key, () => [])
            .addAll(toPostpone);
      }
    }

    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);

    debugPrint(
      'Jingle: Sending session-accept to $toJid with ${contents.length} contents',
    );
    _writeStanza(iq);

    // FLUSH: Send all candidates that were postponed or arrived during preparation
    // This MUST happen after the session-accept stanza is sent.
    final acceptCandsRaw = toInclude
        .map((c) => c['candidate'] as String)
        .toSet();
    final queued = _pendingOutgoingCandidates.remove(key);

    if (queued != null && queued.isNotEmpty) {
      final sdpLower = sdp.toLowerCase();
      final remaining = queued.where((c) {
        final candStr = c['candidate'] as String;
        if (acceptCandsRaw.contains(candStr)) return false;

        // Deduplicate against candidates already in the SDP
        final parts = candStr.split(' ');
        if (parts.length > 5) {
          final ipPort = '${parts[4]} ${parts[5]}'.toLowerCase();
          if (sdpLower.contains(ipPort)) return false;
        }
        return true;
      }).toList();

      if (remaining.isNotEmpty) {
        debugPrint(
          'Jingle: [FLUSH] Sending ${remaining.length} additional candidates via transport-info',
        );
        for (var cand in remaining) {
          sendIceCandidate(toJid, sessionId, cand);
        }
      }
    }
  }

  void sendIceCandidate(
    String toJid,
    String sessionId,
    Map<String, dynamic> candidateMap, {
    bool isVideo = true,
  }) {
    // HARDENING: If session is not in our content map yet (e.g. candidates generated before session-initiate),
    // or not acknowledged, queue the candidate for flushing.
    if (!_sessionContentMap.containsKey(sessionId) ||
        !_acknowledgedSessions.contains(sessionId)) {
      debugPrint(
        'Jingle: Session $sessionId not ready for transport-info, queuing candidate',
      );
      _pendingOutgoingCandidates
          .putIfAbsent(sessionId, () => [])
          .add(candidateMap);
      return;
    }

    // CRITICAL: Use high-precision ID to avoid collisions when flushing multiple candidates
    final iqId =
        'cand_${DateTime.now().microsecondsSinceEpoch}_${candidateMap['sdpMid'] ?? 0}_${_candidateCounter++}';
    _iqToSessionId[iqId] = sessionId;
    _iqToRecipientJid[iqId] = toJid;
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'transport-info'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    // Map sdpMid to content name
    final mid = candidateMap['sdpMid'] ?? '0';

    final contentNames =
        _sessionContentMap[sessionId] ??
        (isVideo ? ['audio', 'video'] : ['audio']);
    int midIdx = int.tryParse(mid) ?? 0;
    final contentName = (midIdx < contentNames.length)
        ? contentNames[midIdx]
        : (isVideo ? 'video' : 'audio');

    final content = xmpp.XmppElement();
    content.name = 'content';
    content.addAttribute(XmppAttribute('name', contentName));
    content.addAttribute(XmppAttribute('creator', 'initiator'));

    final transport = xmpp.XmppElement();
    transport.name = 'transport';
    transport.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:jingle:transports:ice-udp:1'),
    );

    // XEP-0176: Including ufrag/pwd in transport-info for extra compatibility with picky gateways
    final credentials = _sessionCredentials[sessionId];
    if (credentials != null) {
      final sessionUfrag = credentials['ufrag'];
      final sessionPwd = credentials['pwd'];
      if (sessionUfrag != null) {
        transport.addAttribute(XmppAttribute('ufrag', sessionUfrag));
      }
      if (sessionPwd != null) {
        transport.addAttribute(XmppAttribute('pwd', sessionPwd));
      }
    }

    final candidate = candidateMap['candidate'];
    // Filter candidates: Only UDP Component 1 (RTP)
    if (candidate is String && candidate.startsWith('candidate:')) {
      final parts = candidate.split(' ');
      if (parts.length >= 3) {
        final component = parts[1]; // component 1=RTP, 2=RTCP
        final protocol = parts[2].toLowerCase();

        if (component != '1' || protocol != 'udp') {
          debugPrint(
            'Jingle: Skipping non-RTP/non-UDP candidate in transport-info: $candidate',
          );
          return;
        }
      }
    }

    final candidateEl = xmpp.XmppElement();
    candidateEl.name = 'candidate';

    // XEP-0176: Attempt to add attributes. Discard if invalid/loopback.
    if (!_addCandidateAttributes(candidateEl, candidateMap['candidate'])) {
      debugPrint(
        'Jingle: Discarding invalid/loopback candidate in transport-info: ${candidateMap['candidate']}',
      );
      return;
    }

    transport.addChild(candidateEl);
    content.addChild(transport);
    jingle.addChild(content);
    iq.addChild(jingle);

    debugPrint(
      'Jingle: Sending transport-info to $toJid for content $contentName',
    );
    _writeStanza(iq);
  }

  void _flushPendingCandidates(String sessionId, String toJid) {
    final pending = _pendingOutgoingCandidates.remove(sessionId);
    if (pending == null || pending.isEmpty) return;

    debugPrint(
      'Jingle: Flushing ${pending.length} pending candidates for session $sessionId',
    );
    for (var cand in pending) {
      // Re-call sendIceCandidate now that session is acknowledged
      sendIceCandidate(toJid, sessionId, cand);
    }
  }

  void sendSessionTerminate(String toJid, String sessionId, {String? reason}) {
    final iqId = 'jingle_${DateTime.now().millisecondsSinceEpoch}';
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-terminate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    if (reason != null) {
      final reasonEl = xmpp.XmppElement();
      reasonEl.name = 'reason';
      final cond = xmpp.XmppElement();
      cond.name = reason;
      reasonEl.addChild(cond);
      jingle.addChild(reasonEl);
    }

    iq.addChild(jingle);
    debugPrint('Jingle: Sending session-terminate to $toJid (reason: $reason)');
    _writeStanza(iq);

    // CLEANUP: Stop tracking this session immediately
    _cleanupSession(sessionId);
  }

  void sendTransferRequest(String toJid, String sessionId, String targetJid) {
    final iqId = 'jingle_${DateTime.now().millisecondsSinceEpoch}';
    _iqToSessionId[iqId] = sessionId;
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-info'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    final transfer = xmpp.XmppElement();
    transfer.name = 'transfer';
    transfer.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:transfer:0'));
    transfer.textValue = targetJid;

    jingle.addChild(transfer);
    iq.addChild(jingle);
    debugPrint('Jingle: Sending transfer request to $toJid for target $targetJid');
    _writeStanza(iq);
  }

  void sendContentModify(String toJid, String sessionId, String senders, {bool isAudio = true, bool isVideo = true}) {
    final iqId = 'jingle_${DateTime.now().millisecondsSinceEpoch}';
    _iqToSessionId[iqId] = sessionId;
    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    iq.addAttribute(XmppAttribute('to', toJid));
    iq.addAttribute(XmppAttribute('id', iqId));

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'content-modify'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    // Per XEP-0167, 'creator' indicates who created the content,
    // and 'senders' is an ATTRIBUTE on <content>, not a child element
    final isWeInitiator = _sessionIsWeInitiator[sessionId] ?? true;
    final creator = isWeInitiator ? 'initiator' : 'responder';

    final contentNames = _sessionContentMap[sessionId] ?? [];
    for (var contentName in contentNames) {
      final content = xmpp.XmppElement();
      content.name = 'content';
      content.addAttribute(XmppAttribute('name', contentName));
      content.addAttribute(XmppAttribute('creator', creator));
      content.addAttribute(XmppAttribute('senders', senders));

      final transport = xmpp.XmppElement();
      transport.name = 'transport';
      transport.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:transports:ice-udp:1'));

      content.addChild(transport);
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    debugPrint('Jingle: Sending content-modify (creator=$creator, senders=$senders) to $toJid');
    _writeStanza(iq);
  }

  void _cleanupSession(String sessionId) {
    debugPrint('Jingle: Cleaning up session state for $sessionId');
    _sessionContentMap.remove(sessionId);
    _sessionCredentials.remove(sessionId);
    _acknowledgedSessions.remove(sessionId);
    _pendingOutgoingCandidates.remove(sessionId);
    _messageInitiatedSessions.remove(sessionId);
    _pendingProposeSessions.remove(sessionId);
    _proceedTimers[sessionId]?.cancel();
    _proceedTimers.remove(sessionId);

    _iqToSessionId.removeWhere((key, value) => value == sessionId);
    _sessionSetupRoles.remove(sessionId);
    _sessionIsIceLite.remove(sessionId);
    _sessionIsWeInitiator.remove(sessionId);
  }

  void handleIncomingIq(xmpp.IqStanza stanza) {
    // Handle RESULT acknowledgement for our outgoing IQs (session-initiate, session-accept, etc.)
    if (stanza.type == xmpp.IqStanzaType.RESULT ||
        stanza.type == xmpp.IqStanzaType.ERROR) {
      final iqId = stanza.id;
      final sidForIq = _iqToSessionId.remove(iqId);
      final recipientJid = _iqToRecipientJid.remove(iqId);
      if (sidForIq != null) {
        debugPrint('Jingle: IQ $iqId acknowledged for SID: $sidForIq');
        _acknowledgedSessions.add(sidForIq);
        _flushPendingCandidates(
          sidForIq,
          stanza.fromJid?.fullJid ?? recipientJid ?? '',
        );

        if (stanza.type == xmpp.IqStanzaType.RESULT) return;
        
        // Handle IQ Error for a known session directly here!
        if (stanza.type == xmpp.IqStanzaType.ERROR) {
          final error = stanza.getChild('error');
          String reason = 'iq-error';
          if (error != null && error.children.isNotEmpty) {
            reason = error.children.first.name ?? 'unknown';
            final text = error.getChild('text')?.textValue;
            if (text != null && text.isNotEmpty) {
              reason = '$reason: $text';
            }
          }
          _cleanupSession(sidForIq);
          _eventController.add(
            JingleEvent(
              action: JingleAction.sessionTerminate,
              sessionId: sidForIq,
              fromJid: stanza.fromJid?.fullJid ?? recipientJid ?? '',
              reason: reason,
            ),
          );
          return;
        }
      }
    }

    final jingle = stanza.getChild('jingle');
    final sid = jingle?.getAttribute('sid')?.value;
    final actionStr = jingle?.getAttribute('action')?.value;
    final fromJid = stanza.fromJid?.fullJid ?? '';

    debugPrint(
      'Jingle: handleIncomingIq - id: ${stanza.id}, type: ${stanza.type}, from: $fromJid, action: $actionStr, sid: $sid',
    );

    if (jingle == null || sid == null || actionStr == null) return;

    // Always respond with a RESULT IQ for Jingle SET stanzas to avoid timeouts
    if (stanza.type == xmpp.IqStanzaType.SET) {
      final originalId = stanza.id ?? '';
      final result = xmpp.IqStanza(originalId, xmpp.IqStanzaType.RESULT);
      // CRITICAL: Force the 'id' attribute to match EXACTLY, bypassing internal generators
      result.addAttribute(XmppAttribute('id', originalId));
      // CRITICAL: Force the 'to' attribute using raw string
      if (stanza.fromJid != null) {
        result.addAttribute(XmppAttribute('to', stanza.fromJid!.fullJid));
      }
      _writeStanza(result);
    }

    JingleAction? action;
    String? sdp;
    String? reason;
    Map<String, dynamic>? candidate;

    if (stanza.type == xmpp.IqStanzaType.ERROR) {
      action = JingleAction.sessionTerminate;
      final error = stanza.getChild('error');
      if (error != null && error.children.isNotEmpty) {
        reason = error.children.first.name;
        final text = error.getChild('text')?.textValue;
        if (text != null && text.isNotEmpty) {
          reason = '$reason: $text';
        }
      } else {
        reason = 'iq-error';
      }
      // Treat IQ errors for Jingle stanzas as termination
      _cleanupSession(sid);
    } else if (actionStr == 'session-terminate') {
      action = JingleAction.sessionTerminate;
      final reasonEl = jingle.getChild('reason');
      if (reasonEl != null && reasonEl.children.isNotEmpty) {
        reason = reasonEl.children.first.name;
      }
      _cleanupSession(sid);
    } else if (actionStr == 'session-initiate' ||
        actionStr == 'session-accept') {
      action = actionStr == 'session-initiate'
          ? JingleAction.sessionInitiate
          : JingleAction.sessionAccept;
      final List<xmpp.XmppElement> contents = jingle.children
          .where((c) => c.name == 'content')
          .toList();

      if (contents.isNotEmpty) {
        // Store content order for MID mapping (ONLY if not already known, to preserve initiator's order)
        final contentNames = contents
            .map((c) => c.getAttribute('name')?.value ?? '')
            .toList();
        debugPrint('Jingle: Content names: $contentNames');
        // ALWAYS update the content map from session-initiate to establish the exact names (overwriting <propose> placeholders)
        _sessionContentMap[sid] = contentNames;
        final expectedOrder = _sessionContentMap[sid];

        if (actionStr == 'session-initiate') {
          _sessionIsWeInitiator[sid] = false;
        }

        // Attempt to find raw SDP first
        for (var c in contents) {
          final s = c.getChild('description')?.textValue;
          if (s != null && s.isNotEmpty && s.contains('v=0')) {
            sdp = s;
            debugPrint('Jingle: Found raw SDP, length: ${sdp.length}');
            break;
          }
        }

        // If no raw SDP, reconstruct
        if (sdp == null || sdp.isEmpty) {
          debugPrint('Jingle: Reconstructing SDP from Jingle');
          final initiator = jingle.getAttribute('initiator')?.value;
          final isWeInitiator =
              initiator != null && (initiator == connection.fullJid.fullJid);
          sdp = _reconstructMinimalSdp(
            contents,
            isWeInitiator,
            sid,
            actionStr == 'session-initiate',
            expectedOrder: expectedOrder,
          );
          debugPrint('Jingle: Reconstructed SDP:\n$sdp');
        }

        // IMPORTANT: Extract and fire early candidates found in the initiation/acceptance
        _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);
      }
    } else if (actionStr == 'transport-info') {
      action = JingleAction.transportInfo;
      final contentNames = _sessionContentMap[sid] ?? [];
      _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);

      // XEP-0167 Early Media: Reconstruct remote SDP if transport-info contains dtls fingerprint and ufrag
      // CRITICAL: Only synthesize early media if WE are the initiator. If we are the responder, we already received their full SDP.
      if (_sessionIsWeInitiator[sid] == true) {
        final contents = jingle.children
            .where((e) => e.name == 'content')
            .toList();
        if (contents.isNotEmpty) {
          final trans = contents.first.getChild('transport');
          if (trans != null &&
              trans.getAttribute('ufrag') != null &&
              trans.getChild('fingerprint') != null) {
            final earlySdp = _reconstructMinimalSdp(
              contents,
              false,
              sid,
              false,
              expectedOrder: contentNames,
            );
            if (earlySdp != null) {
              debugPrint(
                'Jingle: Synthesizing early-media SDP from transport-info',
              );
              _eventController.add(
                JingleEvent(
                  action: JingleAction.sessionAccept,
                  sessionId: sid,
                  fromJid: fromJid,
                  sdp: earlySdp,
                ),
              );
            }
          }
        }
      }
      return; // Handled by the helper
    } else if (actionStr == 'session-terminate') {
      action = JingleAction.sessionTerminate;
      final reasonEl = jingle.getChild('reason');
      if (reasonEl != null && reasonEl.children.isNotEmpty) {
        final condition = reasonEl.children.first.name;
        final text = reasonEl.getChild('text')?.textValue;
        reason = text != null && text.isNotEmpty
            ? '$condition: $text'
            : condition;
      }
    } else if (actionStr == 'session-info') {
      action = JingleAction.sessionInfo;
      // Extract reason/info from session-info (used for transfer response, etc.)
      final transferEl = jingle.getChild('transfer');
      if (transferEl != null) {
        reason = 'transfer';
      } else {
        final infoEl = jingle.getChild('info');
        reason = infoEl?.textValue ?? 'session-info';
      }
    } else if (actionStr == 'content-modify') {
      action = JingleAction.contentModify;
      // Extract senders attribute to determine hold/unhold
      final contentEl = jingle.getChild('content');
      if (contentEl != null) {
        final senders = contentEl.getAttribute('senders')?.value;
        reason = senders ?? 'inactive';
      }
    }

    if (action != null) {
      _eventController.add(
        JingleEvent(
          action: action,
          sessionId: sid,
          fromJid: fromJid,
          sdp: sdp,
          reason: reason,
          candidate: candidate,
        ),
      );
    }
  }

  String? _reconstructMinimalSdp(
    List<xmpp.XmppElement> contents,
    bool isWeInitiator,
    String sessionId,
    bool isOffer, {
    List<String>? expectedOrder,
  }) {
    if (contents.isEmpty) return null;

    final sb = StringBuffer();
    void writeSdpLine(String line) {
      sb.write('$line\r\n');
    }

    writeSdpLine('v=0');

    // Find a placeholder IP from any candidate to satisfy WebRTC engines that dislike 0.0.0.0
    String placeholderIp = '0.0.0.0';
    for (var content in contents) {
      final trans = content.getChild('transport');
      if (trans != null) {
        final cand = trans.getChild('candidate');
        if (cand != null) {
          placeholderIp = cand.getAttribute('ip')?.value ?? '0.0.0.0';
          if (placeholderIp != '0.0.0.0') break;
        }
      }
    }

    // Standard o line: <username> <sess-id> <sess-version> <nettype> <addrtype> <unicast-address>
    writeSdpLine(
      'o=- ${DateTime.now().millisecondsSinceEpoch} 2 IN IP4 $placeholderIp',
    );
    writeSdpLine('s=-');
    writeSdpLine('t=0 0');
    // msid-semantic: WMS should use a consistent ID with the m-line section msid
    final streamId = 'gibber_$sessionId';
    writeSdpLine('a=msid-semantic: WMS $streamId');

    // HARNESS: Strictly follow the expected order (Offer/Answer alignment)
    final List<xmpp.XmppElement?> orderedContents = [];
    if (expectedOrder != null && expectedOrder.isNotEmpty) {
      // Use a set of used contents to handle multiple streams of the same name correctly
      final List<xmpp.XmppElement> remainingContents = List.from(contents);
      for (var name in expectedOrder) {
        int idx = remainingContents.indexWhere(
          (c) => c.getAttribute('name')?.value == name,
        );
        if (idx != -1) {
          orderedContents.add(remainingContents.removeAt(idx));
        } else {
          // Media was offered but is missing in the answer (REJECTED section)
          orderedContents.add(null);
        }
      }
    } else {
      orderedContents.addAll(contents);
    }

    if (orderedContents.length > 1) {
      // Use numeric MIDs for BUNDLE (per WebRTC spec) - index matches a=mid: lines
      final mids = orderedContents
          .asMap()
          .entries
          .map((e) => '${e.key}')
          .toList();
      writeSdpLine('a=group:BUNDLE ${mids.join(' ')}');
    }

    for (int i = 0; i < orderedContents.length; i++) {
      final content = orderedContents[i];
      // Use numeric MID matching the BUNDLE group above
      final sectionMid = '$i';

      if (content == null) {
        // Generate a REJECTED media section to maintain m-line order (WebRTC requirement)
        // Infer media type from position: 0=audio, 1=video (matching expectedOrder convention)
        final mediaType = (expectedOrder != null && i < expectedOrder.length && expectedOrder[i].contains('video'))
            ? 'video'
            : 'audio';
        writeSdpLine('m=$mediaType 0 UDP/TLS/RTP/SAVPF 0');
        writeSdpLine('c=IN IP4 $placeholderIp');
        writeSdpLine('a=mid:$sectionMid');
        continue;
      }

      final description = content.getChild('description');
      final transport = content.getChild('transport');

      // XEP-0167: transport-info does not include <description>, but we need it for Early Media SDP.
      // Default to 'audio' and standard payload types if missing.
      final mediaType = description?.getAttribute('media')?.value ?? 'audio';
      final payloadTypes =
          description?.children
              .where((c) => c.name == 'payload-type')
              .toList() ??
          [];
      final List<String> ptIds = payloadTypes
          .map((pt) => pt.getAttribute('id')?.value)
          .whereType<String>()
          .toList();

      if (ptIds.isEmpty) {
        ptIds.addAll(
          mediaType == 'video' ? ['96', '102'] : ['111', '0', '8', '9', '101'],
        ); // Match exact rtpmap defaults below
      }

      // Extract the port from the first candidate if available
      String port = '49152';
      final candidates =
          transport?.children.where((c) => c.name == 'candidate').toList() ??
          [];
      if (candidates.isNotEmpty) {
        port = candidates.first.getAttribute('port')?.value ?? '49152';
      }

      writeSdpLine('m=$mediaType $port UDP/TLS/RTP/SAVPF ${ptIds.join(' ')}');
      writeSdpLine('c=IN IP4 $placeholderIp');
      writeSdpLine('a=mid:$sectionMid');
      // Fix: msid should lead with the per-session streamId defined above
      writeSdpLine('a=msid:gibber_$sessionId gibber-$mediaType-$sectionMid');

      // Map Jingle senders to SDP direction
      final senders = content.getAttribute('senders')?.value ?? 'both';
      if (senders == 'both') {
        writeSdpLine('a=sendrecv');
        writeSdpLine('a=rtcp-mux');
      } else if (senders == 'initiator') {
        writeSdpLine(isWeInitiator ? 'a=sendonly' : 'a=recvonly');
      } else if (senders == 'responder') {
        writeSdpLine(isWeInitiator ? 'a=recvonly' : 'a=sendonly');
      } else {
        writeSdpLine('a=inactive');
      }

      if (transport != null) {
        // STRIP INITIAL CANDIDATES: Force "Pure Trickle" ICE mode.
        // Candidates will be supplied to WebRTC exclusively via addIceCandidate
        // to prevent premature nomination deadlocks.

        final ufrag = transport.getAttribute('ufrag')?.value;
        final pwd = transport.getAttribute('pwd')?.value;
        if (ufrag != null) writeSdpLine('a=ice-ufrag:$ufrag');
        if (pwd != null) writeSdpLine('a=ice-pwd:$pwd');

        final fingerprints = transport.children
            .where((c) => c.name == 'fingerprint')
            .toList();
        String? setupRole;
        // XEP-0320: Check both <setup/> and fingerprint-level setup (legacy)
        setupRole = transport.getChild('setup')?.textValue;
        for (var f in fingerprints) {
          final hash =
              f.getAttribute('hash')?.value?.toUpperCase() ?? 'SHA-256';
          setupRole ??= f.getAttribute('setup')?.value;
          writeSdpLine('a=fingerprint:$hash ${f.textValue?.trim() ?? ""}');
        }

        // SMART SETUP: Respect remote's provided setup role if it exists.
        // If it's 'actpass' (typical for initiators), we pick 'passive' for them so we can be 'active'.
        // This ensures compatibility with both standard clients and ICE-Lite gateways.
        if (setupRole != null && setupRole != 'actpass') {
          writeSdpLine('a=setup:$setupRole');
        } else {
          writeSdpLine('a=setup:passive');
        }

        if (_sessionIsIceLite[sessionId] == true) {
          writeSdpLine('a=ice-lite');
        }
        writeSdpLine('a=ice-options:trickle');
      }

      // Codecs & Parameters (rtpmap & fmtp)
      if (payloadTypes.isNotEmpty) {
        for (var pt in payloadTypes) {
          final id = pt.getAttribute('id')?.value;
          final name = pt.getAttribute('name')?.value;
          final rate = pt.getAttribute('clockrate')?.value;
          if (id != null && name != null) {
            writeSdpLine('a=rtpmap:$id $name/${rate ?? "8000"}');

            // Build fmtp from <parameter> tags
            final params = pt.children
                .where((c) => c.name == 'parameter')
                .toList();
            if (params.isNotEmpty) {
              final fmtp = params
                  .map(
                    (p) =>
                        '${p.getAttribute('name')?.value}=${p.getAttribute('value')?.value}',
                  )
                  .join(';');
              writeSdpLine('a=fmtp:$id $fmtp');
            }

            final ptime = pt.getAttribute('ptime')?.value;
            if (ptime != null) writeSdpLine('a=ptime:$ptime');
          }
        }
      } else {
        if (mediaType == 'video') {
          writeSdpLine('a=rtpmap:96 VP8/90000');
          writeSdpLine('a=rtpmap:102 H264/90000');
          writeSdpLine(
            'a=fmtp:102 profile-level-id=42e01f;packetization-mode=1',
          );
        } else {
          writeSdpLine('a=rtpmap:111 opus/48000/2');
          writeSdpLine(
            'a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1;usedtx=1',
          );
          writeSdpLine('a=rtpmap:0 PCMU/8000');
          writeSdpLine('a=rtpmap:8 PCMA/8000');
          writeSdpLine('a=rtpmap:9 G722/8000');
          writeSdpLine('a=rtpmap:101 telephone-event/8000');
          writeSdpLine('a=fmtp:101 0-16');
        }
      }
    }

    return sb.toString();
  }

  List<xmpp.XmppElement> _generateContentsFromSdp(
    String sdp,
    String creator,
    String sessionId, {
    List<String>? expectedOrder,
  }) {
    final List<xmpp.XmppElement> contents = [];
    final List<String> contentNames = [];

    // Split SDP into media sections (separated by m=)
    final lines = sdp.split('\n');
    int currentContentIdx = -1;
    final List<List<String>> mediaSections = [];
    List<String> commonLines = [];

    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('m=')) {
        currentContentIdx++;
        mediaSections.add([trimmed]);
      } else if (currentContentIdx == -1) {
        commonLines.add(trimmed);
      } else {
        mediaSections[currentContentIdx].add(trimmed);
      }
    }

    String? sessionUfrag;
    String? sessionPwd;
    String? sessionSetup;
    final List<Map<String, String>> sessionFingerprints = [];

    for (var l in commonLines) {
      if (l.startsWith('a=ice-ufrag:')) sessionUfrag = l.substring(12);
      if (l.startsWith('a=ice-pwd:')) sessionPwd = l.substring(10).trim();
      if (l.startsWith('a=setup:')) {
        sessionSetup = l.substring(8).trim();
        debugPrint('Jingle: Found session-level setup: $sessionSetup');
      }
      if (l.startsWith('a=fingerprint:')) {
        final parts = l.substring(14).split(' ');
        if (parts.length == 2) {
          sessionFingerprints.add({'hash': parts[0], 'value': parts[1]});
        }
      }
    }

    for (int i = 0; i < mediaSections.length; i++) {
      final section = mediaSections[i];
      final mLine = section[0];
      final parts = mLine.split(' ');
      if (parts.length < 4) continue;

      final mediaType = parts[0].substring(2); // audio, video
      final payloads = parts.sublist(3);

      // Extract MID if present, fallback to mediaType
      String? sdpMid;
      for (var l in section) {
        if (l.startsWith('a=mid:')) {
          sdpMid = l.substring(6).trim();
          break;
        }
      }
      // HARDENING: Always use the exact sdpMid if present to ensure WebRTC mapping parity.
      // If we are responding, we MUST use the name the initiator provided (expectedOrder).
      final contentName = (expectedOrder != null && i < expectedOrder.length)
          ? expectedOrder[i]
          : (sdpMid ?? mediaType);
      contentNames.add(contentName);

      final content = xmpp.XmppElement();
      content.name = 'content';
      content.addAttribute(XmppAttribute('name', contentName));
      content.addAttribute(XmppAttribute('creator', creator));

      final description = xmpp.XmppElement();
      description.name = 'description';
      description.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:rtp:1'),
      );
      description.addAttribute(XmppAttribute('media', mediaType));

      final transport = xmpp.XmppElement();
      transport.name = 'transport';
      transport.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:jingle:transports:ice-udp:1'),
      );

      // Parse rtpmap and fmtp into payload-type elements
      final Map<String, xmpp.XmppElement> ptMap = {};
      for (var l in section) {
        if (l.startsWith('a=rtpmap:')) {
          final ptParts = l.substring(9).split(' ');
          final ptId = ptParts[0];

          // Only include if mentioned in m= line
          if (!payloads.contains(ptId)) continue;

          final codecParts = ptParts[1].split('/');
          final pt = xmpp.XmppElement();
          pt.name = 'payload-type';
          pt.addAttribute(XmppAttribute('id', ptId));
          pt.addAttribute(XmppAttribute('name', codecParts[0]));
          pt.addAttribute(
            XmppAttribute(
              'clockrate',
              codecParts.length > 1 ? codecParts[1] : '8000',
            ),
          );
          if (codecParts.length > 2) {
            pt.addAttribute(XmppAttribute('channels', codecParts[2]));
          }
          ptMap[ptId] = pt;
        }
      }

      // Add static payloads if missing but mentioned in m= line
      for (var ptId in payloads) {
        if (!ptMap.containsKey(ptId)) {
          if (ptId == '0') {
            final pt = xmpp.XmppElement();
            pt.name = 'payload-type';
            pt.addAttribute(XmppAttribute('id', '0'));
            pt.addAttribute(XmppAttribute('name', 'PCMU'));
            pt.addAttribute(XmppAttribute('clockrate', '8000'));
            ptMap['0'] = pt;
          } else if (ptId == '8') {
            final pt = xmpp.XmppElement();
            pt.name = 'payload-type';
            pt.addAttribute(XmppAttribute('id', '8'));
            pt.addAttribute(XmppAttribute('name', 'PCMA'));
            pt.addAttribute(XmppAttribute('clockrate', '8000'));
            ptMap['8'] = pt;
          } else if (ptId == '9') {
            final pt = xmpp.XmppElement();
            pt.name = 'payload-type';
            pt.addAttribute(XmppAttribute('id', '9'));
            pt.addAttribute(XmppAttribute('name', 'G722'));
            pt.addAttribute(XmppAttribute('clockrate', '8000'));
            ptMap['9'] = pt;
          } else if (ptId == '101') {
            final pt = xmpp.XmppElement();
            pt.name = 'payload-type';
            pt.addAttribute(XmppAttribute('id', '101'));
            pt.addAttribute(XmppAttribute('name', 'telephone-event'));
            pt.addAttribute(XmppAttribute('clockrate', '8000'));
            final param = xmpp.XmppElement();
            param.name = 'parameter';
            param.addAttribute(XmppAttribute('name', '0-15'));
            pt.addChild(param);
            ptMap['101'] = pt;
          }
        }
      }

      String? mediaUfrag;
      String? mediaPwd;
      String? mediaSetup;
      final List<Map<String, String>> mediaFingerprints = [];
      final List<String> rawCandidates = [];

      for (var l in section) {
        if (l.startsWith('a=fmtp:')) {
          final fmtpParts = l.substring(7).split(' ');
          final ptId = fmtpParts[0];
          final pt = ptMap[ptId];

          if (pt != null) {
            final params = fmtpParts[1].split(';');
            for (var p in params) {
              final kv = p.split('=');
              final param = xmpp.XmppElement();
              param.name = 'parameter';
              if (kv.length == 2) {
                param.addAttribute(XmppAttribute('name', kv[0]));
                param.addAttribute(XmppAttribute('value', kv[1]));
              } else {
                if (p == '0-15') {
                  param.addAttribute(XmppAttribute('name', 'events'));
                  param.addAttribute(XmppAttribute('value', '0-15'));
                } else {
                  // XEP-0167: If there's no value, some strict XML parses require both name/value.
                  // However, adding an empty value causes invalid SIP SDP (e.g., 111/111=).
                  // For WebRTC RED/RTX payloads, it's safer to just set the value to the name
                  // or use a safe default to satisfy XEP-0167 without breaking SIP parsing.
                  param.addAttribute(XmppAttribute('name', p));
                  param.addAttribute(XmppAttribute('value', p));
                }
              }
              pt.addChild(param);
            }
          }
        } else if (l.startsWith('a=ice-ufrag:')) {
          mediaUfrag = l.substring(12);
        } else if (l.startsWith('a=ice-pwd:')) {
          mediaPwd = l.substring(10);
        } else if (l.startsWith('a=fingerprint:')) {
          final fpParts = l.substring(14).split(' ');
          if (fpParts.length == 2) {
            mediaFingerprints.add({'hash': fpParts[0], 'value': fpParts[1]});
          }
        } else if (l.startsWith('a=setup:')) {
          mediaSetup = l.substring(8).trim();
          debugPrint('Jingle: Found media-level setup: $mediaSetup');
        } else if (l.startsWith('a=candidate:')) {
          rawCandidates.add(l.substring(2));
        }
      }

      // Apply transport attributes (prefer media-level, then session-level)
      final ufrag = mediaUfrag ?? sessionUfrag;
      final pwd = mediaPwd ?? sessionPwd;
      final setup = mediaSetup ?? sessionSetup;
      final fingerprints = mediaFingerprints.isNotEmpty
          ? mediaFingerprints
          : sessionFingerprints;

      // Store credentials for transport-info redundancy
      if (ufrag != null && pwd != null) {
        _sessionCredentials[sessionId] = {'ufrag': ufrag, 'pwd': pwd};
      }

      if (ufrag != null) transport.addAttribute(XmppAttribute('ufrag', ufrag));
      if (pwd != null) transport.addAttribute(XmppAttribute('pwd', pwd));

      for (var fp in fingerprints) {
        final f = xmpp.XmppElement();
        f.name = 'fingerprint';
        f.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:dtls:0'));
        f.addAttribute(XmppAttribute('hash', fp['hash']!.toLowerCase()));

        // XEP-0320: The 'setup' attribute MUST be included on the <fingerprint/> element.
        if (setup != null) {
          f.addAttribute(XmppAttribute('setup', setup));
          debugPrint('Jingle: Reporting setup on fingerprint: $setup');
        }

        // RFC 4572: Use uppercase hex string with colons
        f.textValue = fp['value']!.toUpperCase();
        transport.addChild(f);
      }

      // ALSO add a top-level <setup/> element for better client compatibility
      if (setup != null) {
        final setupEl = xmpp.XmppElement();
        setupEl.name = 'setup';
        setupEl.addAttribute(
          xmpp.XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:dtls:0'),
        );
        setupEl.textValue = setup;
        transport.addChild(setupEl);
      }

      int candCount = 0;
      for (var rawCand in rawCandidates) {
        // HARD LIMIT: Send up to 5 candidates in initial session-accept/initiate.
        // This usually includes host, srflx and relay.
        if (candCount >= 5) break;

        final candEl = xmpp.XmppElement();
        candEl.name = 'candidate';
        if (_addCandidateAttributes(candEl, rawCand)) {
          transport.addChild(candEl);
          candCount++;
        } else {
          debugPrint('Jingle: Skipping loopback/invalid candidate: $rawCand');
        }
      }

      for (var pt in ptMap.values) {
        description.addChild(pt);
      }

      // XEP-0167: Include rtcp-mux ONLY if it was in the source SDP
      // This is essential for compatibility with gateways that might NOT support it
      if (section.any((l) => l.contains('a=rtcp-mux'))) {
        final rtcpMux = xmpp.XmppElement();
        rtcpMux.name = 'rtcp-mux';
        description.addChild(rtcpMux);

        // Add rtcp-rsize for optimized feedback
        final rtcpRsize = xmpp.XmppElement();
        rtcpRsize.name = 'rtcp-rsize';
        description.addChild(rtcpRsize);
      }

      content.addChild(description);
      content.addChild(transport);
      contents.add(content);
    }

    // Store content order for candidate mapping
    _sessionContentMap[sessionId] = contentNames;
    return contents;
  }

  void _extractAndFireCandidates(
    xmpp.XmppElement jingle,
    String sid,
    xmpp.Jid? fromJid,
    List<String> contentNames,
  ) {
    debugPrint('Jingle: _extractAndFireCandidates for sid=$sid');
    debugPrint('Jingle: Expected content names: $contentNames');

    final iceLiteEl = jingle.getChild('ice-lite');
    final isIceLite =
        iceLiteEl != null || jingle.getAttribute('ice-lite')?.value == 'true';
    if (isIceLite) {
      _sessionIsIceLite[sid] = true;
    }

    for (var content in jingle.children) {
      if (content.name == 'content') {
        final contentName = content.getAttribute('name')?.value;
        var midIndex = contentNames.indexOf(contentName ?? '');

        if (midIndex == -1 && contentName != null) {
          // Try parsing as number
          final numericIndex = int.tryParse(contentName);
          if (numericIndex != null && numericIndex < contentNames.length) {
            midIndex = numericIndex;
            debugPrint(
              'Jingle: Using numeric content index $midIndex for "$contentName"',
            );
          } else {
            // Fallback to first content (usually audio)
            midIndex = 0;
            debugPrint(
              'Jingle: Content "$contentName" not in list, falling back to index 0',
            );
          }
        }

        final transport = content.getChild('transport');
        if (transport == null) {
          debugPrint('Jingle: No transport in content "$contentName"');
          continue;
        }

        // Extract setup role if present
        final setup =
            transport.getChild('setup')?.textValue ??
            transport.getChild('fingerprint')?.getAttribute('setup')?.value;
        if (setup != null) {
          _sessionSetupRoles[sid] = setup;
          debugPrint('Jingle: Discovered setup role: $setup for session $sid');
        }

        if (midIndex == -1) {
          debugPrint(
            'Jingle: Skipping candidates for unknown content "$contentName"',
          );
          continue;
        }

        debugPrint(
          'Jingle: Found ${transport.children.where((c) => c.name == 'candidate').length} candidates for content "$contentName"',
        );

        for (var cand in transport.children) {
          if (cand.name == 'candidate') {
            String rawCandidate = cand.textValue ?? '';
            if (rawCandidate.isEmpty || !rawCandidate.contains('candidate:')) {
              // Try to reconstruct from attributes (XEP-0176)
              final foundation = cand.getAttribute('foundation')?.value ?? '1';
              final component = cand.getAttribute('component')?.value ?? '1';
              final protocol = cand.getAttribute('protocol')?.value ?? 'udp';
              final priority =
                  cand.getAttribute('priority')?.value ?? '2113937151';
              final ip = cand.getAttribute('ip')?.value ?? '0.0.0.0';
              final port = cand.getAttribute('port')?.value ?? '9';
              final type = cand.getAttribute('type')?.value ?? 'host';

              rawCandidate =
                  'candidate:$foundation $component $protocol $priority $ip $port typ $type';

              final relAddr = cand.getAttribute('rel-addr')?.value;
              final relPort = cand.getAttribute('rel-port')?.value;
              if (relAddr != null && relPort != null) {
                rawCandidate += ' raddr $relAddr rport $relPort';
              }
            }
            debugPrint('Jingle: Extracted candidate: $rawCandidate');

            // CRITICAL: Filter remote candidates. Only Component 1 (RTP) UDP.
            // This prevents the local engine from creating redundant pairs that
            // cause 'Checking' stalls with legacy PSTN gateways.
            final parts = rawCandidate.split(' ');
            bool shouldAdd = true;
            if (parts.length >= 3) {
              final component = parts[1]; // component 1=RTP, 2=RTCP
              final protocol = parts[2].toLowerCase();
              if (component != '1' || protocol != 'udp') {
                shouldAdd = false;
              }
            }

            if (shouldAdd) {
              _eventController.add(
                JingleEvent(
                  action: JingleAction.transportInfo,
                  sessionId: sid,
                  fromJid: fromJid?.fullJid ?? '',
                  candidate: {
                    'candidate': rawCandidate,
                    'sdpMid': contentName ?? '$midIndex',
                    'sdpMLineIndex': midIndex,
                  },
                ),
              );
            } else {
              debugPrint(
                'Jingle: Skipping remote redundant/TCP candidate: $rawCandidate',
              );
            }
          }
        }
      }
    }
  }

  bool _addCandidateAttributes(xmpp.XmppElement element, String rawCandidate) {
    try {
      final s = rawCandidate.replaceFirst('candidate:', '').trim();
      final parts = s.split(RegExp(r'\s+'));
      if (parts.length >= 7) {
        final ip = parts[4];
        // CRITICAL: Strip loopback candidates to avoid confusing remote gateways
        if (ip == '127.0.0.1' || ip == '::1' || ip == '0.0.0.0') {
          return false;
        }

        final componentAttr = parts[1];
        String priority = parts[3];
        // type was unused, removed.

        // CONSISTENCY: We no longer artificially munge the srflx priority.
        // Doing so causes a mismatch with the authoritative WebRTC engine
        // state, causing strict PSTN gateways to drop our STUN binding requests.

        element.addAttribute(XmppAttribute('foundation', parts[0]));
        element.addAttribute(XmppAttribute('component', componentAttr));
        element.addAttribute(XmppAttribute('protocol', parts[2]));
        element.addAttribute(XmppAttribute('priority', priority));
        element.addAttribute(XmppAttribute('ip', ip));
        // COMPATIBILITY: Some gateways expect 'address' instead of 'ip'
        element.addAttribute(XmppAttribute('address', ip));
        element.addAttribute(XmppAttribute('port', parts[5]));
        // XEP-0176: 'generation' is REQUIRED
        element.addAttribute(XmppAttribute('generation', '0'));
        // Optional but recommended for some gateways
        element.addAttribute(XmppAttribute('network', '1'));

        if (parts.length > 7) {
          element.addAttribute(XmppAttribute('type', parts[7]));
        }

        for (int i = 8; i < parts.length - 1; i++) {
          if (parts[i] == 'raddr') {
            final raddr = parts[i + 1];
            if (raddr != '0.0.0.0' && raddr.isNotEmpty) {
              element.addAttribute(XmppAttribute('rel-addr', raddr));
            }
          }
          if (parts[i] == 'rport') {
            final rport = parts[i + 1];
            if (rport != '0' && rport.isNotEmpty) {
              element.addAttribute(XmppAttribute('rel-port', rport));
            }
          }
        }

        // Mandatory XEP-0176 attributes
        // Hardening: Include part of IP/Port hash in ID to ensure uniqueness
        final candHash = (ip.hashCode ^ parts[5].hashCode)
            .toUnsigned(16)
            .toRadixString(16);
        final candId = 'cand_${priority}_${componentAttr}_$candHash';
        element.addAttribute(XmppAttribute('id', candId));
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Jingle: Error parsing candidate attributes: $e');
      return false;
    }
  }
}
