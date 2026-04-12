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
  });
}

class JingleSignalingService {
  final xmpp.Connection connection;
  final _eventController = StreamController<JingleEvent>.broadcast();
  Stream<JingleEvent> get events => _eventController.stream;

  // Track content names per session to map to SDP MIDs (index-based)
  final Map<String, List<String>> _sessionContentMap = {};

  // Track pending XEP-0353 sessions (message-initiated)
  final Set<String> _messageInitiatedSessions = {};

  // Track pending outgoing sessions awaiting <proceed/> - stores SDP and metadata
  final Map<String, Map<String, dynamic>> _pendingProposeSessions = {};

  // Callback for when <proceed/> is received for an outgoing call
  Function(String sessionId, String sdp, String toJid)? onProceedReceived;

  StreamSubscription? _stanzaSubscription;

  JingleSignalingService(this.connection) {
    _init();
  }

  void _init() {
    _stanzaSubscription = connection.inStanzasStream.listen((stanza) {
      _handleIncomingStanza(stanza);
    });
    debugPrint('Jingle: Listening for incoming stanzas');
  }

  void dispose() {
    _stanzaSubscription?.cancel();
    _eventController.close();
  }

  void _handleIncomingStanza(dynamic stanza) {
    // Handle Jingle in IQ stanzas (standard Jingle)
    if (stanza is xmpp.IqStanza) {
      handleIncomingIq(stanza);
    }
    // Handle Jingle in MESSAGE stanzas (XEP-0353)
    else if (stanza is xmpp.MessageStanza) {
      _processMessageStanza(stanza);
    }
  }

  void _processMessageStanza(xmpp.MessageStanza stanza) {
    // Look for XEP-0353 elements in MESSAGE stanzas
    for (var child in stanza.children) {
      final ns = child.getAttribute('xmlns')?.value;
      final name = child.name;

      // Handle XEP-0353 elements (urn:xmpp:jingle-message:0 namespace)
      if (ns == 'urn:xmpp:jingle-message:0') {
        _processJingleMessageElement(child, stanza);
        continue;
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
        debugPrint('Jingle: [XEP-0353] Remote is ringing, sid: $sid');
        _eventController.add(
          JingleEvent(
            action: JingleAction.sessionInitiate, // Reuse for signaling
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
        'Jingle: [XEP-0353] Received proceed for unknown session: $sid',
      );
      return;
    }

    debugPrint(
      'Jingle: [XEP-0353] Received proceed for session $sid, sending IQ session-initiate',
    );

    final sdp = pending['sdp'] as String;
    final toJid = pending['toJid'] as String;
    final isVideo = pending['isVideo'] as bool? ?? false;

    // Remove from pending
    _pendingProposeSessions.remove(sid);

    // Now send the actual Jingle IQ with session-initiate
    sendSessionInitiateIq(toJid, sid, sdp, isVideo: isVideo);

    // Notify caller via callback
    onProceedReceived?.call(sid, sdp, toJid);
  }

  void _handleReject(String sid, String fromJid, xmpp.XmppElement element) {
    debugPrint('Jingle: [XEP-0353] Session rejected, sid: $sid');
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
        action: JingleAction.sessionInitiate,
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

    proposeMessage.addChild(propose);

    // Store SDP for when proceed is received
    _pendingProposeSessions[sessionId] = {
      'sdp': sdp,
      'toJid': toJid,
      'isVideo': isVideo,
      'timestamp': DateTime.now(),
    };

    debugPrint(
      'Jingle: [XEP-0353] Sending <propose/> to $toJid, sid: $sessionId',
    );
    connection.writeStanza(proposeMessage);
  }

  /// Send actual Jingle session-initiate via IQ stanza
  /// Called after receiving ` <proceed/> ` from the remote party
  void sendSessionInitiateIq(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final iq = xmpp.IqStanza('jingle-$sessionId', xmpp.IqStanzaType.SET);
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-initiate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    // initiator attribute removed for domain transparency (XEP-0166)

    final contents = _generateContentsFromSdp(sdp, 'initiator', sessionId);
    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    _messageInitiatedSessions.add(sessionId);

    debugPrint(
      'Jingle: [XEP-0353] Sending <iq> with session-initiate to $toJid with ${contents.length} contents',
    );
    connection.writeStanza(iq);
  }

  /// XEP-0353: Send session-accept via MESSAGE stanza
  void sendSessionAcceptViaMessage(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-accept'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    // responder attribute removed for domain transparency (XEP-0166)

    final contents = _generateContentsFromSdp(sdp, 'responder', sessionId);
    for (var content in contents) {
      jingle.addChild(content);
    }

    message.addChild(jingle);
    _messageInitiatedSessions.add(sessionId);

    debugPrint(
      'Jingle: [XEP-0353] Sending session-accept via MESSAGE to $toJid',
    );
    connection.writeStanza(message);
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
    message.toJid = xmpp.Jid.fromFullJid(toJid);

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
    connection.writeStanza(message);
  }

  /// XEP-0353: Send session-terminate via MESSAGE stanza
  void sendSessionTerminateViaMessage(
    String toJid,
    String sessionId, {
    String reason = 'success',
  }) {
    final message = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    message.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-terminate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    final reasonEl = xmpp.XmppElement();
    reasonEl.name = reason;
    jingle.addChild(reasonEl);

    message.addChild(jingle);

    debugPrint(
      'Jingle: [XEP-0353] Sending session-terminate via MESSAGE to $toJid',
    );
    connection.writeStanza(message);
  }

  void sendSessionInitiate(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-initiate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    // initiator attribute removed for domain transparency (XEP-0166)

    final contents = _generateContentsFromSdp(sdp, 'initiator', sessionId);
    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    debugPrint(
      'Jingle: Sending session-initiate to $toJid with ${contents.length} contents',
    );
    connection.writeStanza(iq);
  }

  void sendSessionAccept(
    String toJid,
    String sessionId,
    String sdp, {
    bool isVideo = true,
  }) {
    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-accept'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));
    // responder attribute removed for domain transparency (XEP-0166)

    final contents = _generateContentsFromSdp(sdp, 'responder', sessionId);
    for (var content in contents) {
      jingle.addChild(content);
    }

    iq.addChild(jingle);
    debugPrint(
      'Jingle: Sending session-accept to $toJid with ${contents.length} contents',
    );
    connection.writeStanza(iq);
  }

  void sendIceCandidate(
    String toJid,
    String sessionId,
    Map<String, dynamic> candidateMap, {
    bool isVideo = true,
  }) {
    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

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
    iq.addChild(jingle);

    debugPrint(
      'Jingle: Sending transport-info to $toJid for content $contentName',
    );
    connection.writeStanza(iq);
  }

  void sendSessionTerminate(String toJid, String sessionId) {
    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

    final jingle = xmpp.XmppElement();
    jingle.name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:jingle:1'));
    jingle.addAttribute(XmppAttribute('action', 'session-terminate'));
    jingle.addAttribute(XmppAttribute('sid', sessionId));

    iq.addChild(jingle);
    debugPrint('Jingle: Sending session-terminate to $toJid');
    connection.writeStanza(iq);
  }

  void handleIncomingIq(xmpp.IqStanza stanza) {
    final jingle = stanza.getChild('jingle');
    if (jingle == null) return;

    final actionStr = jingle.getAttribute('action')?.value;
    final sid = jingle.getAttribute('sid')?.value;
    final fromJid = stanza.fromJid?.fullJid ?? '';

    debugPrint('Jingle: Received $actionStr from $fromJid (SID: $sid)');

    // Always respond with a RESULT IQ for Jingle SET stanzas to avoid timeouts
    if (stanza.type == xmpp.IqStanzaType.SET) {
      final result = xmpp.IqStanza(stanza.id ?? '', xmpp.IqStanzaType.RESULT);
      result.toJid = stanza.fromJid;
      connection.writeStanza(result);
    }

    if (sid == null || actionStr == null) return;

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
        if (!_sessionContentMap.containsKey(sid)) {
          _sessionContentMap[sid] = contentNames;
        }
        final expectedOrder = _sessionContentMap[sid];

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
          debugPrint(
            'Jingle: Reconstructed SDP, length: ${sdp?.length}, has audio: ${sdp?.contains('m=audio')}',
          );
        }

        // IMPORTANT: Extract and fire early candidates found in the initiation/acceptance
        _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);
      }
    } else if (actionStr == 'transport-info') {
      action = JingleAction.transportInfo;
      final contentNames = _sessionContentMap[sid] ?? [];
      _extractAndFireCandidates(jingle, sid, stanza.fromJid, contentNames);
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
    sb.writeln('v=0');
    // Standard o line: <username> <sess-id> <sess-version> <nettype> <addrtype> <unicast-address>
    sb.writeln('o=- ${DateTime.now().millisecondsSinceEpoch} 2 IN IP4 0.0.0.0');
    sb.writeln('s=-');
    sb.writeln('t=0 0');
    // msid-semantic: WMS should use a consistent ID with the m-line section msid
    final streamId = 'gibber_$sessionId';
    sb.writeln('a=msid-semantic: WMS $streamId');

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
      final mids = orderedContents
          .asMap()
          .entries
          .map(
            (e) =>
                e.value?.getAttribute('name')?.value ??
                (expectedOrder != null && e.key < expectedOrder.length
                    ? expectedOrder[e.key]
                    : '${e.key}'),
          )
          .toList();
      sb.writeln('a=group:BUNDLE ${mids.join(' ')}');
    }

    for (int i = 0; i < orderedContents.length; i++) {
      final content = orderedContents[i];
      final sectionMid = expectedOrder != null && i < expectedOrder.length
          ? expectedOrder[i]
          : '$i';

      if (content == null) {
        // Generate a REJECTED media section to maintain m-line order (WebRTC requirement)
        final mediaType = sectionMid.contains('video') ? 'video' : 'audio';
        sb.writeln('m=$mediaType 0 UDP/TLS/RTP/SAVPF 0');
        sb.writeln('c=IN IP4 0.0.0.0');
        sb.writeln('a=mid:$sectionMid');
        continue;
      }

      final description = content.getChild('description');
      final transport = content.getChild('transport');
      if (description == null) continue;

      final mediaType = description.getAttribute('media')?.value ?? 'audio';
      final payloadTypes = description.children
          .where((c) => c.name == 'payload-type')
          .toList();
      final List<String> ptIds = payloadTypes
          .map((pt) => pt.getAttribute('id')?.value)
          .whereType<String>()
          .toList();

      if (ptIds.isEmpty) {
        ptIds.addAll(mediaType == 'video' ? ['96', '97'] : ['0', '8', '111']);
      }

      sb.writeln('m=$mediaType 9 UDP/TLS/RTP/SAVPF ${ptIds.join(' ')}');
      sb.writeln('c=IN IP4 0.0.0.0');
      sb.writeln('a=rtcp:9 IN IP4 0.0.0.0');
      sb.writeln('a=mid:$sectionMid');
      // Fix: msid should lead with the per-session streamId defined above
      sb.writeln('a=msid:gibber_$sessionId gibber-$mediaType-$sectionMid');

      // Map Jingle senders to SDP direction
      final senders = content.getAttribute('senders')?.value ?? 'both';
      if (senders == 'both') {
        sb.writeln('a=sendrecv');
      } else if (senders == 'initiator') {
        sb.writeln(isWeInitiator ? 'a=sendonly' : 'a=recvonly');
      } else if (senders == 'responder') {
        sb.writeln(isWeInitiator ? 'a=recvonly' : 'a=sendonly');
      } else {
        sb.writeln('a=inactive');
      }

      sb.writeln('a=rtcp-mux');

      if (transport != null) {
        final ufrag = transport.getAttribute('ufrag')?.value;
        final pwd = transport.getAttribute('pwd')?.value;
        if (ufrag != null) sb.writeln('a=ice-ufrag:$ufrag');
        if (pwd != null) sb.writeln('a=ice-pwd:$pwd');

        final fingerprints = transport.children
            .where((c) => c.name == 'fingerprint')
            .toList();
        for (var f in fingerprints) {
          final hash = f.getAttribute('hash')?.value ?? 'sha-256';
          sb.writeln('a=fingerprint:$hash ${f.textValue}');
        }
      }

      // Important: WebRTC needs correct 'setup' role for DTLS handshakes.
      // - Remote Offers must be 'actpass' (letting us choose).
      // - Remote Answers (responses to our offers) must be 'active' or 'passive'.
      if (isOffer) {
        sb.writeln('a=setup:actpass');
      } else {
        // This is a session-accept (remote answer)
        sb.writeln('a=setup:active');
      }

      // Codecs & Parameters (rtpmap & fmtp)
      if (payloadTypes.isNotEmpty) {
        for (var pt in payloadTypes) {
          final id = pt.getAttribute('id')?.value;
          final name = pt.getAttribute('name')?.value;
          final rate = pt.getAttribute('clockrate')?.value;
          if (id != null && name != null) {
            sb.writeln('a=rtpmap:$id $name/${rate ?? "8000"}');

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
              sb.writeln('a=fmtp:$id $fmtp');
            }

            final ptime = pt.getAttribute('ptime')?.value;
            if (ptime != null) sb.writeln('a=ptime:$ptime');
          }
        }
      } else {
        if (mediaType == 'video') {
          sb.writeln('a=rtpmap:96 VP8/90000');
          sb.writeln('a=rtpmap:102 H264/90000');
          sb.writeln('a=fmtp:102 profile-level-id=42e01f;packetization-mode=1');
        } else {
          sb.writeln('a=rtpmap:111 opus/48000/2');
          sb.writeln(
            'a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1;usedtx=1',
          );
        }
      }
    }

    return sb.toString();
  }

  List<xmpp.XmppElement> _generateContentsFromSdp(
    String sdp,
    String creator,
    String sessionId,
  ) {
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
    final List<Map<String, String>> sessionFingerprints = [];

    for (var l in commonLines) {
      if (l.startsWith('a=ice-ufrag:')) sessionUfrag = l.substring(12);
      if (l.startsWith('a=ice-pwd:')) sessionPwd = l.substring(10);
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
      final mediaType = parts[0].substring(2); // audio, video

      // Extract MID (preferred for content name)
      String? mid;
      for (var l in section) {
        if (l.startsWith('a=mid:')) {
          mid = l.substring(6).trim();
          break;
        }
      }

      final contentName = mid ?? mediaType;
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

      String? mediaUfrag;
      String? mediaPwd;
      final List<Map<String, String>> mediaFingerprints = [];

      for (var l in section) {
        if (l.startsWith('a=fmtp:')) {
          final fmtpParts = l.substring(7).split(' ');
          final ptId = fmtpParts[0];
          final pt = ptMap[ptId];
          if (pt != null) {
            final params = fmtpParts[1].split(';');
            for (var p in params) {
              final kv = p.split('=');
              if (kv.length == 2) {
                final param = xmpp.XmppElement();
                param.name = 'parameter';
                param.addAttribute(XmppAttribute('name', kv[0]));
                param.addAttribute(XmppAttribute('value', kv[1]));
                pt.addChild(param);
              }
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
        }
      }

      // Apply transport attributes (prefer media-level, then session-level)
      final ufrag = mediaUfrag ?? sessionUfrag;
      final pwd = mediaPwd ?? sessionPwd;
      final fingerprints = mediaFingerprints.isNotEmpty
          ? mediaFingerprints
          : sessionFingerprints;

      if (ufrag != null) transport.addAttribute(XmppAttribute('ufrag', ufrag));
      if (pwd != null) transport.addAttribute(XmppAttribute('pwd', pwd));
      for (var fp in fingerprints) {
        final f = xmpp.XmppElement();
        f.name = 'fingerprint';
        f.addAttribute(XmppAttribute('hash', fp['hash']!));
        f.textValue = fp['value']!;
        transport.addChild(f);
      }

      for (var pt in ptMap.values) {
        description.addChild(pt);
      }

      content.addChild(description);
      content.addChild(transport);
      contents.add(content);
    }

    // Store content order for candidate mapping
    _sessionContentMap[sessionId] = contentNames;
    return contents;
  }

  /// Pure Jingle IQ: Send transport-info (ICE candidates)
  void sendTransportInfo(
    String toJid,
    String sessionId,
    Map<String, dynamic> candidateMap, {
    bool isVideo = true,
  }) {
    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(toJid);

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
    iq.addChild(jingle);

    debugPrint(
      'Jingle: Sending transport-info (IQ) to $toJid',
    );
    connection.writeStanza(iq);
  }

  void _extractAndFireCandidates(
    xmpp.XmppElement jingle,
    String sid,
    xmpp.Jid? fromJid,
    List<String> contentNames,
  ) {
    debugPrint('Jingle: _extractAndFireCandidates for sid=$sid');
    debugPrint('Jingle: Expected content names: $contentNames');

    for (var content in jingle.children) {
      if (content.name == 'content') {
        final contentName = content.getAttribute('name')?.value;
        var midIndex = contentNames.indexOf(contentName ?? '');

        // If content name not found, try to use numeric index or default
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
          }
        }
      }
    }
  }

  void _addCandidateAttributes(xmpp.XmppElement element, String rawCandidate) {
    // candidate:427053987 1 udp 2113937151 192.168.1.100 56789 typ host
    try {
      final s = rawCandidate.replaceFirst('candidate:', '').trim();
      final parts = s.split(RegExp(r'\s+'));
      if (parts.length >= 7) {
        element.addAttribute(XmppAttribute('foundation', parts[0]));
        element.addAttribute(XmppAttribute('component', parts[1]));
        element.addAttribute(XmppAttribute('protocol', parts[2]));
        element.addAttribute(XmppAttribute('priority', parts[3]));
        element.addAttribute(XmppAttribute('ip', parts[4]));
        element.addAttribute(XmppAttribute('port', parts[5]));
        // parts[6] should be 'typ'
        if (parts.length > 7) {
          element.addAttribute(XmppAttribute('type', parts[7]));
        }

        // Optional raddr/rport
        for (int i = 8; i < parts.length - 1; i++) {
          if (parts[i] == 'raddr') {
            element.addAttribute(XmppAttribute('rel-addr', parts[i + 1]));
          }
          if (parts[i] == 'rport') {
            element.addAttribute(XmppAttribute('rel-port', parts[i + 1]));
          }
        }

        // Mandatory XEP-0176 attributes
        element.addAttribute(XmppAttribute('generation', '0'));
        element.addAttribute(XmppAttribute('network', '0'));
        element.addAttribute(
          XmppAttribute('id', 'cand_${parts[0]}_${parts[1]}'),
        );
      }
    } catch (e) {
      debugPrint('Error parsing candidate attributes: $e');
    }
  }
}
