import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import '../services/webrtc_manager.dart';
import '../services/jingle_signaling_service.dart';
import '../services/sip_service.dart';
import '../services/auth_service.dart';
import '../services/call_history_service.dart';
import '../services/sound_service.dart';
import '../services/multi_peer_webrtc_manager.dart';
import '../services/audio_effects_service.dart';
import '../services/call_audio_playback_service.dart';
import '../services/resource_scheduler_service.dart';
import '../services/janus_service.dart';
import '../services/backend_config.dart';
import '../models/call_log.dart';
import '../models/group_call_models.dart';
import '../models/chat_models.dart' as chat;

bool isPhoneNumber(String input) {
  final cleaned = input.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  return RegExp(r'^\+?\d{7,15}$').hasMatch(cleaned);
}

enum CallState { idle, incoming, outgoing, active }

class CallProvider with ChangeNotifier, WidgetsBindingObserver {
  CallState _state = CallState.idle;
  String? _remoteJid;
  String? _sessionId;
  String? _incomingOfferSdp;
  String? _permissionError;
  bool _isVideo = true;
  bool _isMicMuted = false;
  bool _isCameraOff = false;
  bool _isSpeakerOn = false;
  DateTime? _callStartTime;
  AuthService? _authService;
  CallHistoryService? _historyService;
  ResourceSchedulerService? _scheduler;
  String? _callAccountId;
  bool _isRecording = false;
  String? _lastRecordingPath;
  String? _lastError;
  RTCIceConnectionState _iceState =
      RTCIceConnectionState.RTCIceConnectionStateNew;
  bool _isAccepted = false;
  bool _isAccepting = false;
  bool _isRinging = false;

  WebRTCManager _rtcManager = WebRTCManager();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final SoundService _soundService = SoundService();
  SipService? _sipService;
  StreamSubscription? _signalingSub;
  StreamSubscription? _statsSub;
  StreamSubscription? _proximitySub;
  StreamSubscription? _sipCallStateSub;
  StreamSubscription? _roomParticipantSub;
  StreamSubscription? _janusSpeakingSub;
  StreamSubscription? _janusRemoteTrackSub;
  Timer? _callTimeoutTimer;
  Timer? _iceDebugTimer;
  int _candidateSendCount = 0;
  DateTime? _iceCheckingStartTime;
  bool _isSipCall = false;
  bool _remoteAnswerProcessed = false;
  double _localVolume = 0.0;
  double _remoteVolume = 0.0;
  bool _isTalkingWhileMuted = false;
  
  bool _isGroupCall = false;
  final Map<String, RTCVideoRenderer> _groupRenderers = {};
  final Map<String, double> _groupAudioLevels = {};
  MultiPeerWebRTCManager? _multiPeerManager;

  JanusService? _janusService;
  GroupCallSession? _groupCallSession;
  BackendConfig? _backendConfig;

  final AudioEffectsService _audioEffects = AudioEffectsService.instance;
  final CallAudioPlaybackService _audioPlayback = CallAudioPlaybackService.instance;
  bool _audioEffectsInitialized = false;

  CallState get state => _state;
  String? get remoteJid => _remoteJid;
  String? get sessionId => _sessionId;
  bool get isVideo => _isVideo;
  bool get isMicMuted => _isMicMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isRecording => _isRecording;
  String? get lastRecordingPath => _lastRecordingPath;
  RTCVideoRenderer get localRenderer => _localRenderer;
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;
  String? get permissionError => _permissionError;
  String? get lastError => _lastError;
  RTCIceConnectionState get iceState => _iceState;
  bool get isAccepted => _isAccepted;
  bool get isRinging => _isRinging;
  double get localVolume => _localVolume;
  double get remoteVolume => _remoteVolume;
  bool get isTalkingWhileMuted => _isTalkingWhileMuted;
  bool get isSipCall => _isSipCall;
  bool get isSipRegistered => _sipService?.isRegistered ?? false;
  SipService? get sipService => _sipService;
  
  bool get isGroupCall => _isGroupCall;
  GroupCallSession? get groupCallSession => _groupCallSession;
  Map<String, RTCVideoRenderer> get groupRenderers => _groupRenderers;
  Map<String, double> get groupAudioLevels => _groupAudioLevels;
  AudioEffectsService get audioEffects => _audioEffects;
  CallAudioPlaybackService get audioPlayback => _audioPlayback;
  bool get isAudioEffectsAvailable => _audioEffectsInitialized && (kIsWeb || Platform.isAndroid);

  void _applyDefaultSpeakerRoute({required bool isVideo, String? source}) {
    // Voice calls should default to speakerphone so users can immediately hear audio.
    final speakerOn = !isVideo;
    _rtcManager.setSpeakerphone(speakerOn);
    _isSpeakerOn = speakerOn;
    if (source != null) {
      debugPrint(
        'CallProvider: [$source] Default speaker route -> ${speakerOn ? "speaker" : "earpiece"}',
      );
    }
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> initialize(
    AuthService authService,
    CallHistoryService historyService, {
    ResourceSchedulerService? scheduler,
  }) async {
    if (_authService != null) return;
    _authService = authService;
    _historyService = historyService;
    _scheduler = scheduler;
    _signalingSub = _authService!.jingleEvents.listen(_handleJingleEvent);

    // Set up XEP-0353 proceed callback
    _authService!.setJingleProceedCallback(_onJingleProceedReceived);

    await _initializeSipService();

    // ATTACH: Observe App Lifecycle to handle background leaks
    WidgetsBinding.instance.addObserver(this);

    // ATTACH: Initialize Proximity Sensor for automatic routing
    _setupProximitySensor();

    // ATTACH: Initialize Audio Effects (Android only)
    _audioEffects.initialize().then((ok) {
      _audioEffectsInitialized = ok;
      debugPrint('CallProvider: Audio effects initialized: $ok');
    });
    _audioPlayback.initialize().then((ok) {
      debugPrint('CallProvider: Audio playback initialized: $ok');
    });

    // ATTACH: Forward service notifications to UI
    _audioEffects.addListener(_onAudioEffectsChanged);
    _audioPlayback.addListener(_onAudioPlaybackChanged);
  }

  void setBackendConfig(BackendConfig config) {
    _backendConfig = config;
  }

  void _onAudioEffectsChanged() {
    notifyListeners();
  }

  void _onAudioPlaybackChanged() {
    notifyListeners();
  }

  void _onJingleProceedReceived(String sessionId, String sdp, String toJid) {
    debugPrint(
      'CallProvider: [XEP-0353] Proceed received for session $sessionId',
    );
    debugPrint(
      'CallProvider: [XEP-0353] IQ session-initiate sent automatically',
    );
    // Cancel timeout timer since we got a response
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
  }

  void _startCallTimeoutTimer() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_state == CallState.outgoing) {
        debugPrint('CallProvider: Call timeout - no response received');
        _lastError = 'Call timeout - no response from gateway';
        endCall();
      }
    });
  }

  Future<void> _initializeSipService() async {
    _sipService = SipService();
    await _sipService!.initialize();

    _sipCallStateSub?.cancel();
    _sipCallStateSub = _sipService!.callStateStream.listen((state) {
      debugPrint('CallProvider: SIP call state: $state');

      switch (state) {
        case SipCallState.ringing:
          if (_state == CallState.idle) {
            _state = CallState.incoming;
            _remoteJid = _sipService!.remoteNumber ?? 'Unknown';
            _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
            _log('Incoming SIP call from $_remoteJid', isSent: false);
            _playRingtone();
            notifyListeners();
          }
          break;
        case SipCallState.connecting:
          _state = CallState.outgoing;
          notifyListeners();
          break;
        case SipCallState.active:
          _callStartTime = DateTime.now();
          _state = CallState.active;
          _acquireSchedulerForCall();
          _stopAllSounds();
          _remoteRenderer.srcObject = _sipService!.remoteRenderer.srcObject;
          _localRenderer.srcObject = _sipService!.localRenderer.srcObject;
          notifyListeners();
          break;
        case SipCallState.ended:
          _cleanup(reason: 'terminated');
          break;
        case SipCallState.idle:
          break;
      }
    });

    debugPrint('CallProvider: SIP service initialized');
  }

  Future<void> _startXmppCall(
    String phoneNumber, {
    String? accountId,
    bool isVideo = false,
  }) async {
    debugPrint('CallProvider: === STARTING XMPP CALL FOR PHONE (forced) ===');
    final gatewayJid = '$phoneNumber@cheogram.com';
    // Route through XMPP Jingle directly, skipping SIP detection
    await _startXmppCallInternal(
      gatewayJid,
      accountId: accountId,
      isVideo: isVideo,
    );
  }

  Future<void> _startMucCall(
    String roomJid, {
    String? accountId,
    bool isVideo = true,
  }) async {
    debugPrint('CallProvider: === STARTING GROUP CALL (SFU) ===');

    final sfuUrl = _backendConfig?.derivedSfuUrl;
    if (sfuUrl == null || sfuUrl.isEmpty) {
      debugPrint('CallProvider: No SFU URL configured, falling back to mesh');
      await _startMucCallMesh(roomJid, accountId: accountId, isVideo: isVideo);
      return;
    }

    _state = CallState.outgoing;
    _remoteJid = roomJid;
    _isVideo = isVideo;
    _callAccountId = accountId;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _isGroupCall = true;
    _log('Outgoing group ${_isVideo ? "video" : "voice"} call started (SFU)', isSent: true);
    notifyListeners();

    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      if (isVideo) Permission.camera,
    ].request();
    if (statuses[Permission.microphone] != PermissionStatus.granted ||
        (isVideo && statuses[Permission.camera] != PermissionStatus.granted)) {
      _permissionError = 'Microphone/Camera permission denied';
      _state = CallState.idle;
      notifyListeners();
      return;
    }

    await _soundService.setCallAudioContext(isVideo: isVideo);
    _applyDefaultSpeakerRoute(isVideo: isVideo, source: 'start_sfu_call');

    for (var r in _groupRenderers.values) {
      r.srcObject = null;
      r.dispose();
    }
    _groupRenderers.clear();
    _groupAudioLevels.clear();

    _multiPeerManager?.dispose();
    _multiPeerManager = MultiPeerWebRTCManager();

    final iceServers = <Map<String, dynamic>>[];
    if (_backendConfig != null) {
      final configIce = _backendConfig!.iceServers;
      if (configIce.isNotEmpty) {
        iceServers.addAll(configIce);
      }
    }
    if (iceServers.isEmpty && _authService != null) {
      final fetched = await _authService!.fetchIceServers(accountId ?? '');
      iceServers.addAll(fetched);
    }
    if (iceServers.isNotEmpty) {
      _multiPeerManager!.setIceServers(iceServers);
    }

    await _multiPeerManager!.initLocalStream(isVideo: _isVideo);
    _localRenderer.srcObject = _multiPeerManager!.localStream;

    _janusService?.dispose();
    _janusService = JanusService();

    final sfuApiKey = _backendConfig?.sfuApiKey;
    try {
      await _janusService!.connect(sfuUrl, apiSecret: sfuApiKey);
      debugPrint('CallProvider: Connected to Janus SFU at $sfuUrl');
    } catch (e) {
      debugPrint('CallProvider: Failed to connect to Janus: $e');
      _lastError = 'Failed to connect to call server';
      _cleanup(reason: 'sfu_connect_failed');
      return;
    }

    final displayName = _authService?.activeAccountId?.split('@').first ?? 'User';
    final roomId = roomJid.split('@').first.hashCode.abs().toString();

    final handleId = await _janusService!.joinRoom(roomId, displayName);
    if (handleId == null) {
      _lastError = 'Failed to join call room';
      _cleanup(reason: 'sfu_join_failed');
      return;
    }

    _groupCallSession = GroupCallSession(
      roomId: roomId,
      roomJid: roomJid,
      accountId: accountId ?? _authService?.activeAccountId ?? '',
      janusSessionId: _janusService!.sessionId ?? '',
      publisherHandle: handleId,
      displayName: displayName,
      isAudioOnly: !isVideo,
      sfuUrl: sfuUrl,
    );

    _setupJanusListeners();

    final offer = await _multiPeerManager!.createOffer('publisher_$handleId');
    if (offer.sdp != null) {
      final published = await _janusService!.publishStream(handleId, offer.sdp!);
      if (!published) {
        debugPrint('CallProvider: Failed to publish stream to SFU');
      }
    }

    _callStartTime = DateTime.now();
    _state = CallState.active;
    _acquireSchedulerForCall();
    _stopAllSounds();
    notifyListeners();
  }

  void _setupJanusListeners() {
    _janusService?.onParticipantJoined = (participant) {
      debugPrint('CallProvider: SFU participant joined: ${participant.displayName}');
      _groupCallSession?.participants[participant.id] = participant;
      notifyListeners();

      _subscribeToSfuParticipant(participant.id);
    };

    _janusService?.onParticipantLeft = (participantId) {
      debugPrint('CallProvider: SFU participant left: $participantId');
      _groupCallSession?.participants.remove(participantId);
      final renderer = _groupRenderers.remove(participantId);
      if (renderer != null) {
        renderer.srcObject = null;
        renderer.dispose();
      }
      _groupAudioLevels.remove(participantId);
      notifyListeners();
    };

    _janusRemoteTrackSub?.cancel();
    _janusRemoteTrackSub = _janusService?.onRemoteTrack.listen((data) async {
      final handleId = data['handle_id'] as String?;
      final jsep = data['jsep'] as Map<String, dynamic>?;
      if (handleId == null || jsep == null) return;

      final sdp = jsep['sdp'] as String? ?? '';
      final type = jsep['type'] as String? ?? 'answer';

      if (_multiPeerManager != null) {
        try {
          await _multiPeerManager!.setRemoteDescription(
            handleId,
            RTCSessionDescription(sdp, type),
          );
        } catch (e) {
          debugPrint('CallProvider: Error setting SFU remote description: $e');
        }
      }
    });

    _janusService?.onRoomDestroyed = (roomId) {
      debugPrint('CallProvider: SFU room destroyed: $roomId');
      endCall();
    };

    _janusSpeakingSub?.cancel();
    _janusSpeakingSub = _janusService?.onSpeaking.listen((speakingMap) {
      for (var entry in speakingMap.entries) {
        _groupAudioLevels[entry.key] = entry.value ? 1.0 : 0.0;
      }
      notifyListeners();
    });
  }

  Future<void> _subscribeToSfuParticipant(String feedId) async {
    if (_janusService == null || _groupCallSession == null) return;

    final subscribed = await _janusService!.subscribeToParticipant(
      _groupCallSession!.roomId,
      feedId,
      feedId,
    );
    if (!subscribed) {
      debugPrint('CallProvider: Failed to subscribe to feed $feedId');
    }
  }

  Future<void> _startMucCallMesh(
    String roomJid, {
    String? accountId,
    bool isVideo = true,
  }) async {
    debugPrint('CallProvider: === STARTING MULTI-PEER MUC CALL ===');
    
    // For architectural placeholder, we notify the user that MUC calling requires SFU
    // But we dispatch the actual Jingle propose to test signaling to real participants!
    final occupants = _authService?.getRoomParticipants(roomJid) ?? [];
    // We no longer abort if occupants.isEmpty because we are building a dynamic mesh.
    // Late joiners will be handled by the roomParticipantsStream.

    _state = CallState.outgoing;
    _remoteJid = roomJid;
    _isVideo = isVideo;
    _callAccountId = accountId;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _isGroupCall = true;
    _log('Outgoing group ${_isVideo ? "video" : "voice"} call started (Full-Mesh)', isSent: true);
    _playRingback();
    notifyListeners();

    // Clean up existing renderers
    for (var r in _groupRenderers.values) {
      r.srcObject = null;
      r.dispose();
    }
    _groupRenderers.clear();
    _groupAudioLevels.clear();

    // Initialize MultiPeer WebRTC Manager
    _multiPeerManager?.dispose();
    _multiPeerManager = MultiPeerWebRTCManager();
    _multiPeerManager!.onRemoteStreamAdded = (peerId, stream) async {
      debugPrint('CallProvider: Remote stream added for $peerId in group call');
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = stream;
      _groupRenderers[peerId] = renderer;
      notifyListeners();
    };
    
    _multiPeerManager!.onRemoteStreamRemoved = (peerId) {
      debugPrint('CallProvider: Remote stream removed for $peerId in group call');
      final renderer = _groupRenderers.remove(peerId);
      if (renderer != null) {
        renderer.srcObject = null;
        renderer.dispose();
      }
      _groupAudioLevels.remove(peerId);
      notifyListeners();
    };

    await _multiPeerManager!.initLocalStream(isVideo: _isVideo);
    _localRenderer.srcObject = _multiPeerManager!.localStream;

    final signaling = _authService?.getJingleService(accountId ?? '') ?? _authService?.jingleSignaling;
    if (signaling == null) return;

    _multiPeerManager!.onIceCandidate = (peerId, candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        debugPrint('CallProvider: Local ICE Candidate gathered for $peerId: ${candidate.candidate}');
        signaling.sendIceCandidate(
          peerId,
          _sessionId!,
          candidate.toMap(),
          isVideo: _isVideo,
        );
      }
    };

    for (var occupant in occupants) {
      final targetFullJid = occupant.realJid ?? '$roomJid/${occupant.nickname}';
      // Do not call ourselves
      final myJid = _authService?.activeAccountId;
      if (myJid != null && targetFullJid.contains(myJid.split('@').first)) continue;

      debugPrint('CallProvider: Dispatching Full-Mesh propose to $targetFullJid');
      try {
        final offer = await _multiPeerManager!.createOffer(targetFullJid);
        signaling.sendSessionInitiateViaMessage(
          targetFullJid,
          _sessionId!,
          offer.sdp ?? '',
          isVideo: isVideo,
        );
      } catch (e) {
        debugPrint('CallProvider: Failed to create offer for $targetFullJid: $e');
      }
    }
    
    // Subscribe to dynamic presence updates to handle late-joiners
    _roomParticipantSub?.cancel();
    _roomParticipantSub = _authService!.roomParticipantsStream.listen((rooms) async {
      final updatedOccupants = rooms[roomJid] ?? [];
      for (var occupant in updatedOccupants) {
        final targetFullJid = occupant.realJid ?? '$roomJid/${occupant.nickname}';
        
        // Skip ourselves
        final myJid = _authService?.activeAccountId;
        if (myJid != null && targetFullJid.contains(myJid.split('@').first)) continue;

        // Skip existing connections
        if (_multiPeerManager!.hasPeer(targetFullJid)) continue;

        debugPrint('CallProvider: [LATE JOINER] Dispatching Full-Mesh propose to $targetFullJid');
        try {
          final offer = await _multiPeerManager!.createOffer(targetFullJid);
          signaling.sendSessionInitiateViaMessage(
            targetFullJid,
            _sessionId!,
            offer.sdp ?? '',
            isVideo: _isVideo,
          );
        } catch (e) {
          debugPrint('CallProvider: Failed to create offer for $targetFullJid: $e');
        }
      }

      // Handle part/offline (clean up disconnected peers)
      final currentJids = updatedOccupants.map((o) => o.realJid ?? '$roomJid/${o.nickname}').toSet();
      final activePeers = _multiPeerManager!.getActivePeerIds();
      for (var peer in activePeers) {
        if (!currentJids.contains(peer)) {
          debugPrint('CallProvider: [PEER LEFT] Removing disconnected peer $peer');
          _multiPeerManager!.removePeer(peer);
        }
      }
    });

    _startCallTimeoutTimer();
  }

  Future<void> _startXmppCallInternal(
    String toJid, {
    String? accountId,
    bool isVideo = true,
  }) async {
    debugPrint('CallProvider: === STARTING INTERNAL XMPP CALL ===');

    await _rtcManager.dispose();
    _rtcManager = WebRTCManager();

    final signaling =
        _authService?.getJingleService(accountId ?? '') ??
        _authService?.jingleSignaling;
    if (signaling == null) {
      debugPrint(
        'CallProvider: No Jingle service found for account $accountId',
      );
      return;
    }

    // Switch to Communication Context (DO THIS FIRST to ensure hardware is ready)
    await _soundService.setCallAudioContext(isVideo: isVideo);
    _applyDefaultSpeakerRoute(
      isVideo: isVideo,
      source: 'start_xmpp_call_internal',
    );

    _state = CallState.outgoing;
    _remoteJid = toJid;
    _isVideo = isVideo;
    _callAccountId = accountId;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _log('Outgoing ${_isVideo ? "video" : "voice"} call started', isSent: true);
    _playRingback();
    notifyListeners();

    try {
      final iceServers = await _authService!.fetchIceServers(accountId ?? '');
      _rtcManager.setIceServers(iceServers);

      await initRenderers();

      final bool videoSuccess = await _rtcManager.initLocalStream(
        isVideo: isVideo,
      );
      if (isVideo && !videoSuccess) {
        _isVideo = false;
      }
      _localRenderer.srcObject = _rtcManager.localStream;

      _setupRtcListeners(toJid, signaling);

      // MONITOR: Attach stats listener to expose volume to UI
      _statsSub?.cancel();
      _statsSub = _rtcManager.audioLevels.listen((levels) {
        debugPrint(
          'CallProvider: Audio levels - local: ${levels['local']}, remote: ${levels['remote']}',
        );
        _localVolume = levels['local'] ?? 0.0;
        _remoteVolume = levels['remote'] ?? 0.0;
        notifyListeners();
      });

      final offer = await _rtcManager.createOffer();
      debugPrint('CallProvider: Offer created');

      final isGateway = toJid.toLowerCase().contains('cheogram') || toJid.contains('+');
      debugPrint('CallProvider: [ROUTING] isGateway=$isGateway for $toJid');

      if (isGateway) {
        debugPrint('CallProvider: [PSTN] Direct IQ Protocol Forced');
        // HARDENING: Give ICE gathering 500ms to find srflx candidates before sending initiate
        debugPrint('CallProvider: Waiting 500ms for initial ICE gathering...');
        await Future.delayed(const Duration(milliseconds: 500));
        
        signaling.sendSessionInitiate(
          toJid,
          _sessionId!,
          offer.sdp!,
          isVideo: _isVideo,
        );
      } else {
        debugPrint('CallProvider: [CHAT] XEP-0353 Message Protocol Forced');
        signaling.sendSessionInitiateViaMessage(
          toJid,
          _sessionId!,
          offer.sdp!,
          isVideo: _isVideo,
        );
      }

      debugPrint('CallProvider: Session initiate sent');
      _startCallTimeoutTimer();
      notifyListeners();
    } catch (e) {
      debugPrint('CallProvider: Call failed: $e');
      _lastError = e.toString();
      _cleanup(reason: 'failed');
    }
  }

  void _setupProximitySensor() {
    if (kIsWeb) return;
    _proximitySub?.cancel();
    _proximitySub = ProximitySensor.events.listen((int event) {
      // 1 = near, 0 = far
      final bool isNear = event > 0;
      debugPrint(
        'CallProvider: Proximity sensor triggered: ${isNear ? "NEAR" : "FAR"}',
      );

      if (_state == CallState.active && !_isVideo) {
        // In voice-only active calls, holding to ear should switch to earpiece
        if (isNear) {
          _rtcManager.setSpeakerphone(false);
          _isSpeakerOn = false;
        } else {
          _rtcManager.setSpeakerphone(true);
          _isSpeakerOn = true;
        }
        notifyListeners();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('CallProvider: Lifecycle change to $state');
    // HARDENING: Only terminate on detached (app killed).
    // Allow 'paused' (backgrounding) to keep calls alive for background talking.
    if (_state != CallState.idle && state == AppLifecycleState.detached) {
      debugPrint(
        'CallProvider: Force cleaning up WebRTC resources due to app termination.',
      );
      endCall();
    }
  }

  void _handleJingleEvent(dynamic event) {
    debugPrint(
      'CallProvider: Received Jingle event ${event.action} on account ${event.accountId}',
    );
    switch (event.action) {
      case JingleAction.propose:
        // HARDENING: Ignore self-proposals (Carbons of our own outgoing calls)
        if (_state == CallState.outgoing && _sessionId == event.sessionId) {
          debugPrint('CallProvider: Ignoring self-echo propose for session ${event.sessionId}');
          break;
        }
        receiveCall(
          event.fromJid,
          event.sessionId,
          null, // Proposal doesn't have SDP yet
          accountId: event.accountId,
        );
        break;
      case JingleAction.ringing:
        if (_state == CallState.outgoing) {
          _isRinging = true;
          notifyListeners();
        }
        break;
      case JingleAction.proceed:
        if (_state == CallState.outgoing) {
          _isRinging = false;
          _log('Remote accepted proposal, connecting...', isSent: false);
          notifyListeners();
        }
        break;
      case JingleAction.sessionInitiate:
        if (event.sdp != null) {
          final wasAccepted = _isAccepted;
          receiveCall(
            event.fromJid,
            event.sessionId,
            event.sdp!,
            accountId: event.accountId,
          );
          if (wasAccepted) {
            debugPrint('CallProvider: Auto-accepting session-initiate as proposal was already accepted');
            acceptCall();
          }
        }
        break;
      case JingleAction.sessionAccept:
        if (event.sdp != null) {
          debugPrint(
            'CallProvider: Session accept received from ${event.fromJid}, SDP length: ${event.sdp!.length}',
          );
          _isRinging = false;
          if (_isGroupCall && _multiPeerManager != null) {
            _multiPeerManager!.setRemoteDescription(
              event.fromJid,
              RTCSessionDescription(event.sdp!, 'answer'),
            );
          } else {
            handleRemoteSdp(event.sdp!, 'answer');
          }
        }
        break;
      case JingleAction.transportInfo:
        if (event.candidate != null) {
          if (_isGroupCall && _multiPeerManager != null) {
            final candidateMap = event.candidate as Map<String, dynamic>;
            final candidateStr = candidateMap['candidate']?.toString() ?? '';
            if (candidateStr.isNotEmpty) {
              _multiPeerManager!.addCandidate(
                event.fromJid,
                RTCIceCandidate(
                  candidateStr,
                  candidateMap['sdpMid']?.toString() ?? '0',
                  int.tryParse(candidateMap['sdpMLineIndex']?.toString() ?? '0') ?? 0,
                ),
              );
            }
          } else {
            handleRemoteCandidate(event.candidate!);
          }
        }
        break;
      case JingleAction.sessionTerminate:
        debugPrint('CallProvider: Remote party ${event.fromJid} terminated the session');
        if (_isGroupCall && _multiPeerManager != null) {
          _multiPeerManager!.removePeer(event.fromJid);
          if (_groupRenderers.isEmpty) {
            endCall();
          }
        } else {
          endCall();
        }
        break;
    }
  }

  void _log(String text, {required bool isSent, String? filePath, chat.MessageType type = chat.MessageType.call}) {
    if (_remoteJid != null && _authService != null) {
      _authService!.logCallEvent(_remoteJid!, text, isSent, filePath: filePath, type: type);
    }
  }

  void receiveCall(
    String fromJid,
    String sessionId,
    String? offerSdp, {
    String? accountId,
  }) async {
    // HARDENING: Ignore calls from ourselves
    final myJid = _authService?.activeAccountId;
    if (myJid != null && fromJid.contains(myJid)) {
      debugPrint('CallProvider: Ignoring incoming call from ourselves ($fromJid)');
      return;
    }

    // BUSY CHECK: If we are already in a call, reject this one
    if (_state != CallState.idle && _sessionId != sessionId) {
      debugPrint('CallProvider: Already in a call, rejecting new incoming call from $fromJid');
      final signaling = _authService?.getJingleService(accountId ?? '') ?? _authService?.jingleSignaling;
      if (signaling != null) {
        final isGateway = fromJid.toLowerCase().contains('cheogram') || fromJid.contains('+');
        if (isGateway) {
          signaling.sendSessionTerminate(fromJid, sessionId, reason: 'busy');
        } else {
          signaling.sendRejectViaMessage(fromJid, sessionId);
        }
      }
      return;
    }

    // HARDENING: Clean up any stale sessions before accepting a new one, 
    // BUT preserve the manager if this is the same session transitioning from proposal to initiation.
    if (_sessionId != sessionId || _state == CallState.idle) {
      await _rtcManager.dispose();
      _rtcManager = WebRTCManager();
      _isAccepted = false;
      _isRinging = false;
    }

    _state = CallState.incoming;
    _remoteJid = fromJid;
    _sessionId = sessionId;
    _incomingOfferSdp = offerSdp;
    _callAccountId = accountId;
    
    // Basic detection of video in SDP (default to false for proposals)
    if (offerSdp != null) {
      _isVideo = offerSdp.contains('m=video');
    }

    // Play incoming ringtone
    _playRingtone();

    _log('Incoming ${_isVideo ? "video" : "voice"} call', isSent: false);
    notifyListeners();
  }

  void toggleMute() {
    if (_isSipCall) {
      _sipService?.toggleMute();
      _isMicMuted = _sipService?.isMuted ?? false;
      _log('Microphone ${_isMicMuted ? "Muted" : "Active"}', isSent: true);
      notifyListeners();
      return;
    }

    _isMicMuted = !_isMicMuted;
    _rtcManager.toggleMic(!_isMicMuted);
    _multiPeerManager?.toggleMic(!_isMicMuted);
    if (_isGroupCall && _janusService != null && _groupCallSession != null) {
      _janusService!.configurePublisher(
        _groupCallSession!.publisherHandle,
        audio: !_isMicMuted,
      );
    }
    _log('Microphone ${_isMicMuted ? "Muted" : "Active"}', isSent: true);
    notifyListeners();
  }

  void toggleSpeaker() {
    if (_isSipCall) {
      _isSpeakerOn = !_isSpeakerOn;
      _sipService?.toggleSpeaker(_isSpeakerOn);
      _log('Speakerphone ${_isSpeakerOn ? "On" : "Off"}', isSent: true);
      notifyListeners();
      return;
    }

    _isSpeakerOn = !_isSpeakerOn;
    _rtcManager.setSpeakerphone(_isSpeakerOn);
    _log('Speakerphone ${_isSpeakerOn ? "On" : "Off"}', isSent: true);
    notifyListeners();
  }

  Future<void> _playRingtone() async {
    await _soundService.playRingtone();
  }

  Future<void> _playRingback() async {
    await _soundService.playRingback();
  }

  Future<void> _stopAllSounds() async {
    await _soundService.stop();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    if (_isGroupCall && _janusService != null && _groupCallSession != null) {
      _janusService!.configurePublisher(
        _groupCallSession!.publisherHandle,
        video: !_isCameraOff,
      );
    }
    _rtcManager.toggleCamera(!_isCameraOff);
    _multiPeerManager?.toggleCamera(!_isCameraOff);
    _log('Camera ${_isCameraOff ? "Off" : "On"}', isSent: true);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    await _rtcManager.switchCamera();
    _log('Camera switched', isSent: true);
  }

  Future<void> startCall(
    String toJid, {
    String? accountId,
    bool isVideo = true,
    String? protocol,
  }) async {
    _lastError = null;
    final activeProtocol = protocol ?? 'XMPP';

    // IRC does not support voice/video calls in this client.
    if (activeProtocol == 'IRC') {
      _lastError = 'Voice and video calling are not supported for IRC chats.';
      _state = CallState.idle;
      notifyListeners();
      return;
    }



    // SIP PROTOCOL - route explicitly through SipService
    if (activeProtocol == 'SIP') {
      if (_sipService != null && _sipService!.isRegistered) {
        _isSipCall = true;
        _state = CallState.outgoing;
        _remoteJid = toJid;
        _callAccountId = accountId;
        _isVideo = isVideo;
        await _soundService.setCallAudioContext(isVideo: isVideo);
        _applyDefaultSpeakerRoute(
          isVideo: isVideo,
          source: 'start_call_sip',
        );
        _log(
          'Outgoing SIP ${isVideo ? "video" : "voice"} call started',
          isSent: true,
        );
        _playRingback();
        notifyListeners();
        final success = await _sipService!.call(toJid, video: isVideo);
        if (!success) {
          _lastError = 'SIP call failed to start.';
          _cleanup(reason: 'failed');
        }
      } else {
        _lastError = 'SIP service not available or not registered.';
        _state = CallState.idle;
        notifyListeners();
      }
      return;
    }

    // PHONE NUMBER DETECTION - Route through XMPP Jingle for phone calls (More stable than SIP)
    // Check if it looks like a phone number (contains digits, maybe with +)
    final cleanNumber = toJid.replaceAll(RegExp(r'[^\d+]'), '');
    if (isPhoneNumber(cleanNumber)) {
      debugPrint(
        'CallProvider: Phone number detected ($cleanNumber), routing through stable XMPP Jingle',
      );
      // Route through XMPP Jingle exactly like a normal chat call, let the gateway handle PSTN bridging
      await _startXmppCall(cleanNumber, accountId: accountId, isVideo: false);
      return;
    }

    // MUC DETECTION
    final isMuc = toJid.contains('@conference.') || toJid.contains('@muc.');
    if (isMuc) {
      debugPrint('CallProvider: MUC room detected. Initiating Multi-Peer Mesh Call...');
      await _startMucCall(toJid, accountId: accountId, isVideo: isVideo);
      return;
    }

    // HARDENING: Clean up any stale manager before starting a new call
    await _rtcManager.dispose();
    _rtcManager = WebRTCManager();

    final signaling =
        _authService?.getJingleService(accountId ?? '') ??
        _authService?.jingleSignaling;
    if (signaling == null) {
      debugPrint(
        'CallProvider: No Jingle service found for account $accountId',
      );
      return;
    }

    // Request permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      if (isVideo) Permission.camera,
    ].request();

    if (statuses[Permission.microphone] != PermissionStatus.granted ||
        (isVideo && statuses[Permission.camera] != PermissionStatus.granted)) {
      _permissionError =
          'Camera/Microphone permission denied. Please enable them in settings to make calls.';
      _state = CallState.idle;
      notifyListeners();
      return;
    }
    _permissionError = null;

    // Switch to Communication Context (DO THIS FIRST to ensure hardware is ready)
    await _soundService.setCallAudioContext(isVideo: isVideo);
    _applyDefaultSpeakerRoute(isVideo: isVideo, source: 'start_call');

    // JID NORMALIZATION: Ensure phone numbers have the gateway suffix
    String effectiveJid = toJid;
    if (effectiveJid.startsWith('+') || RegExp(r'^\d+$').hasMatch(effectiveJid)) {
      if (!effectiveJid.contains('@')) {
        effectiveJid = '$effectiveJid@cheogram.com';
        debugPrint('CallProvider: Normalized phone JID to $effectiveJid');
      }
    }

    _state = CallState.outgoing;
    _remoteJid = effectiveJid;
    _isVideo = isVideo;
    _callAccountId = accountId;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _log('Outgoing ${_isVideo ? "video" : "voice"} call started', isSent: true);

    // START RINGBACK
    _playRingback();

    notifyListeners();

    try {
      debugPrint('CallProvider: === STARTING OUTGOING CALL ===');
      debugPrint('CallProvider: Target JID: $toJid, isVideo: $isVideo');

      if (_authService != null && _callAccountId != null) {
        final iceServers = await _authService!.fetchIceServers(_callAccountId!);
        debugPrint('CallProvider: ICE servers fetched: ${iceServers.length}');
        _rtcManager.setIceServers(iceServers);
      }

      await initRenderers();
      debugPrint('CallProvider: Renderers initialized');

      final bool videoSuccess = await _rtcManager.initLocalStream(
        isVideo: isVideo,
      );
      debugPrint(
        'CallProvider: Local stream init result: videoSuccess=$videoSuccess',
      );

      // Check for audio configuration warnings
      if (_rtcManager.lastAudioWarning != null) {
        debugPrint(
          'CallProvider: AUDIO WARNING: ${_rtcManager.lastAudioWarning}',
        );
        _lastError = _rtcManager.lastAudioWarning;
      }

      if (isVideo && !videoSuccess) {
        _log('Camera unavailable - falling back to audio', isSent: false);
        _isVideo = false;
      }
      _localRenderer.srcObject = _rtcManager.localStream;
      debugPrint('CallProvider: Local renderer attached');

      // Attach listeners before creating offer to capture candidates
      _setupRtcListeners(effectiveJid, signaling);
      debugPrint('CallProvider: RTC listeners attached');

      // MONITOR: Attach stats listener to expose volume to UI
      _statsSub?.cancel();
      _statsSub = _rtcManager.audioLevels.listen((levels) {
        debugPrint(
          'CallProvider: Audio levels - local: ${levels['local']}, remote: ${levels['remote']}',
        );
        _localVolume = levels['local'] ?? 0.0;
        _remoteVolume = levels['remote'] ?? 0.0;

        // TALK-WHILE-MUTED DETECTION (Peak Energy > 0.3)
        final wasTalkingWhileMuted = _isTalkingWhileMuted;
        _isTalkingWhileMuted = _isMicMuted && _localVolume > 0.3;

        if (wasTalkingWhileMuted != _isTalkingWhileMuted) {
          notifyListeners();
        } else {
          notifyListeners(); // Still need to update volume for visualizer
        }
      });

      final offer = await _rtcManager.createOffer();
      debugPrint('CallProvider: Offer created');

      final isGateway = effectiveJid.toLowerCase().contains('cheogram') || effectiveJid.contains('+');
      
      if (isGateway) {
        debugPrint('CallProvider: === GATEWAY PROTOCOL ENFORCED (Direct Jingle IQ) ===');
        // HARDENING: Give ICE gathering 500ms to find srflx candidates before sending initiate
        debugPrint('CallProvider: Waiting 500ms for initial ICE gathering...');
        await Future.delayed(const Duration(milliseconds: 500));
        
        signaling.sendSessionInitiate(
          effectiveJid,
          _sessionId!,
          offer.sdp!,
          isVideo: isVideo,
        );
      } else {
        debugPrint('CallProvider: === CHAT PROTOCOL ENFORCED (XEP-0353 Message) ===');
        signaling.sendSessionInitiateViaMessage(
          effectiveJid,
          _sessionId!,
          offer.sdp!,
          isVideo: isVideo,
        );
      }
      debugPrint('CallProvider: Session initiate dispatched via ${isGateway ? "IQ" : "MESSAGE"}');

      _state = CallState.outgoing;
      _startCallTimeoutTimer();
      notifyListeners();
      debugPrint('CallProvider: === CALL INITIATED ===');
    } catch (e) {
      debugPrint('CallProvider: ERROR starting call: $e');
      _lastError = 'Failed to start call: $e';
      notifyListeners();
      _cleanup(reason: 'failed: $e');
    }
  }

  Future<void> acceptCall() async {
    debugPrint('CallProvider: === ACCEPTING INCOMING CALL ===');

    final signaling =
        _authService?.getJingleService(_callAccountId ?? '') ??
        _authService?.jingleSignaling;
    if (signaling == null) {
      debugPrint('CallProvider: ERROR - No signaling service');
      return;
    }
    if (_state != CallState.incoming || _isAccepting) {
      debugPrint(
        'CallProvider: Ignoring acceptCall - state=$_state, isAccepting=$_isAccepting',
      );
      return;
    }

    _isAccepting = true;
    notifyListeners();

    if (_incomingOfferSdp == null) {
      debugPrint('CallProvider: Accepting proposal for session $_sessionId');
      _isAccepted = true;
      _stopAllSounds();
      signaling.sendProceed(_remoteJid!, _sessionId!);
      _isAccepting = false;
      notifyListeners();
      return;
    }

    _stopAllSounds();
    debugPrint('CallProvider: Stopped all sounds');

    // Request permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      if (_isVideo) Permission.camera,
    ].request();

    if (statuses[Permission.microphone] != PermissionStatus.granted ||
        (_isVideo && statuses[Permission.camera] != PermissionStatus.granted)) {
      _permissionError =
          'Camera/Microphone permission denied. Please enable them in settings to accept calls.';
      debugPrint('CallProvider: Permission denied: $_permissionError');
      notifyListeners();
      endCall();
      return;
    }
    _permissionError = null;
    debugPrint('CallProvider: Permissions granted');

    // Switch to Communication Context (DO THIS FIRST to ensure hardware is ready)
    await _soundService.setCallAudioContext(isVideo: _isVideo);
    _applyDefaultSpeakerRoute(isVideo: _isVideo, source: 'accept_call');
    debugPrint('CallProvider: Audio context set, speakerphone: $_isSpeakerOn');

    try {
      if (_authService != null && _callAccountId != null) {
        final iceServers = await _authService!.fetchIceServers(_callAccountId!);
        debugPrint('CallProvider: ICE servers fetched: ${iceServers.length}');
        _rtcManager.setIceServers(iceServers);
      }

      debugPrint('CallProvider: Initializing local stream...');
      final bool videoSuccess = await _rtcManager.initLocalStream(
        isVideo: _isVideo,
      );
      debugPrint(
        'CallProvider: Local stream init result: videoSuccess=$videoSuccess',
      );

      // Check for audio configuration warnings
      if (_rtcManager.lastAudioWarning != null) {
        debugPrint(
          'CallProvider: AUDIO WARNING: ${_rtcManager.lastAudioWarning}',
        );
        _lastError = _rtcManager.lastAudioWarning;
        notifyListeners();
      }

      if (_isVideo && !videoSuccess) {
        _log('Camera unavailable - falling back to audio', isSent: false);
        _isVideo = false;
      }
      _localRenderer.srcObject = _rtcManager.localStream;
      debugPrint('CallProvider: Local renderer attached');

      // Attach listeners before creating answer
      _setupRtcListeners(_remoteJid!, signaling);
      debugPrint('CallProvider: RTC listeners attached');

      _statsSub?.cancel();
      _statsSub = _rtcManager.audioLevels.listen((levels) {
        debugPrint(
          'CallProvider: Audio levels - local: ${levels['local']}, remote: ${levels['remote']}',
        );
        _localVolume = levels['local'] ?? 0.0;
        _remoteVolume = levels['remote'] ?? 0.0;

        final wasTalkingWhileMuted = _isTalkingWhileMuted;
        _isTalkingWhileMuted = _isMicMuted && _localVolume > 0.3;

        if (wasTalkingWhileMuted != _isTalkingWhileMuted) {
          notifyListeners();
        } else {
          notifyListeners();
        }
      });

      debugPrint('CallProvider: Creating answer...');
      final answer = await _rtcManager.createAnswer(
        RTCSessionDescription(_incomingOfferSdp!, 'offer'),
      );
      debugPrint('CallProvider: Answer created');

      // CRITICAL: Start ICE connectivity check after creating answer
      // This triggers ICE to actually test candidate pairs
      debugPrint('CallProvider: Starting ICE connectivity check...');
      await _rtcManager.startIceConnectivityCheck();

      debugPrint('CallProvider: Sending session accept...');

      // Detect if caller is a gateway (phone number via cheogram, etc.)
      final isGateway = _remoteJid!.toLowerCase().contains('cheogram') || _remoteJid!.contains('+');
      if (isGateway) {
        debugPrint(
          'CallProvider: [PSTN] Direct IQ Protocol Forced (Session Accept)',
        );
        signaling.sendSessionAccept(
          _remoteJid!,
          _sessionId!,
          answer.sdp!,
          isVideo: _isVideo,
        );
      } else {
        signaling.sendSessionAcceptViaMessage(
          _remoteJid!,
          _sessionId!,
          answer.sdp!,
          isVideo: _isVideo,
        );
      }
      debugPrint('CallProvider: Session accept sent');

      // Set a timeout - if we don't get media in 20 seconds, fail the call
      // State stays as incoming until onTrack or ICE connected transitions to active
      debugPrint('CallProvider: Starting media timeout (20 seconds)...');
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = Timer(const Duration(seconds: 20), () {
        if (_state != CallState.active) {
          debugPrint('CallProvider: Media timeout - no remote track received');
          _lastError = 'Connection timeout - no media received';
          _cleanup(reason: 'media_timeout');
        }
      });

      _stopAllSounds();
      _log('Call accepted, waiting for media', isSent: true);

      notifyListeners();
    } catch (e) {
      debugPrint('Error accepting call: $e');
      _cleanup();
    } finally {
      _isAccepting = false;
      notifyListeners();
    }
  }

  void _setupRtcListeners(String toJid, JingleSignalingService signaling) {
    debugPrint('CallProvider: Setting up RTC listeners for $toJid');

    // Detect if target is a gateway
    final isGateway =
        toJid.contains('cheogram.com') &&
        (toJid.contains('+') || toJid.contains('/tel'));

    // Reset counters
    _candidateSendCount = 0;
    _iceCheckingStartTime = null;

    // Periodic ICE state logging timer
    _iceDebugTimer?.cancel();
    _iceDebugTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_state == CallState.idle) {
        _iceDebugTimer?.cancel();
        return;
      }
      debugPrint(
        'CallProvider: ICE Debug - state: $_iceState, candidates_sent: $_candidateSendCount',
      );

      // Check if ICE has been stuck in Checking for too long
      // BUT: Don't restart if call is already active (media is flowing!)
      if (_iceState == RTCIceConnectionState.RTCIceConnectionStateChecking &&
          _iceCheckingStartTime != null &&
          _state != CallState.active) {
        final stuckDuration = DateTime.now().difference(_iceCheckingStartTime!);
        debugPrint(
          'CallProvider: ICE stuck in Checking for ${stuckDuration.inSeconds} seconds',
        );
        if (stuckDuration.inSeconds >= 8) {
          debugPrint(
            'CallProvider: ICE stuck for too long, restarting ICE gathering...',
          );
          _rtcManager.restartIceGathering();
          _iceCheckingStartTime = DateTime.now(); // Reset timer after restart
        }
      } else if (_state == CallState.active) {
        debugPrint(
          'CallProvider: ICE still checking but call is active (media flowing) - NOT restarting ICE',
        );
      }
    });

    _rtcManager.onIceCandidate((candidate) {
      _candidateSendCount++;
      debugPrint(
        'CallProvider: ICE candidate generated (#$_candidateSendCount), sending to $toJid',
      );
      debugPrint(
        'CallProvider:   sdpMid: ${candidate.sdpMid}, type: ${_extractCandidateType(candidate.candidate ?? "")}',
      );
      if (isGateway) {
        signaling.sendIceCandidate(
          toJid,
          _sessionId!,
          candidate.toMap(),
          isVideo: _isVideo,
        );
      } else {
        signaling.sendIceCandidate(
          toJid,
          _sessionId!,
          candidate.toMap(),
          isVideo: _isVideo,
        );
      }
    });

    _rtcManager.onTrack((stream) {
      debugPrint('CallProvider: ========== CALL PROVIDER ON TRACK ==========');
      debugPrint('CallProvider: === REMOTE TRACK RECEIVED ===');
      debugPrint('CallProvider: Stream id: ${stream.id}');
      
      // CRITICAL: stream.active is NOT implemented on Android - do not access it!
      
      debugPrint(
        'CallProvider: Stream audio tracks: ${stream.getAudioTracks().length}',
      );
      debugPrint(
        'CallProvider: Stream video tracks: ${stream.getVideoTracks().length}',
      );

      // CRITICAL: Cancel ICE timeout timer - we have media!
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = null;
      debugPrint('CallProvider: ICE timeout cancelled - media received');

      // CRITICAL: Always set srcObject to ensure renderer has the stream
      _remoteRenderer.srcObject = stream;
      debugPrint(
        'CallProvider: Remote renderer srcObject set: ${_remoteRenderer.srcObject != null}',
      );

      // Force audio track enabled
      debugPrint('CallProvider: Enabling all audio tracks...');
      for (var track in stream.getAudioTracks()) {
        debugPrint(
          'CallProvider: Audio track before: enabled=${track.enabled}, muted=${track.muted}',
        );
        track.enabled = true;
        debugPrint(
          'CallProvider: Audio track after: enabled=${track.enabled}, label=${track.label}',
        );
      }

      _state = CallState.active;
      _acquireSchedulerForCall();
      _stopAllSounds();
      HapticFeedback.heavyImpact();
      _callStartTime ??= DateTime.now();
      _log('Call connected (media established)', isSent: false);

      // AUDIO PATH: Force speaker ON for voice calls with Android Route Force
      debugPrint('CallProvider: Configuring audio output...');
      if (!_isVideo) {
        debugPrint('CallProvider: Voice call - applying Android Speaker Route Force');
        
        // Android Speaker Force: toggling sometimes triggers the correct routing
        _rtcManager.setSpeakerphone(false); 
        Future.delayed(const Duration(milliseconds: 50), () {
          _rtcManager.setSpeakerphone(true);
          _isSpeakerOn = true;
          debugPrint('CallProvider: Speaker ON forced, _isSpeakerOn = true');
        });
      } else {
        debugPrint('CallProvider: Video call - using current speaker setting');
        _rtcManager.setSpeakerphone(_isSpeakerOn);
      }

      // Ensure audio is enabled on all tracks
      _rtcManager.ensureAudioEnabled();

      // Set remote volume to max
      _rtcManager.setRemoteAudioVolume(1.0);

      // AUDIO DELAYS: Multiple ensures for Android to properly configure audio
      debugPrint('CallProvider: Scheduling delayed audio fixes...');

      Future.delayed(const Duration(milliseconds: 200), () {
        debugPrint('CallProvider: [DELAY 200ms] Audio fix #1');
        _rtcManager.ensureAudioEnabled();
        if (!_isVideo) {
          _rtcManager.setSpeakerphone(true);
        }
      });


      Future.delayed(const Duration(milliseconds: 500), () {
        debugPrint('CallProvider: [DELAY 500ms] Audio fix #2');
        _rtcManager.ensureAudioEnabled();
        if (!_isVideo) {
          _rtcManager.setSpeakerphone(true);
        }
        debugPrint(
          'CallProvider: [DELAY 500ms] Verifying remoteRenderer.srcObject: ${_remoteRenderer.srcObject != null}',
        );
      });

      Future.delayed(const Duration(milliseconds: 1000), () {
        debugPrint('CallProvider: [DELAY 1000ms] Audio fix #3');
        if (!_isVideo) {
          _rtcManager.setSpeakerphone(true);
          debugPrint('CallProvider: [DELAY 1000ms] Final speaker ON');
        }
        // Verify stream is still attached
        if (_remoteRenderer.srcObject != null) {
          debugPrint(
            'CallProvider: [DELAY 1000ms] Stream still attached, audio should be playing',
          );
        } else {
          debugPrint('CallProvider: [DELAY 1000ms] WARNING - Stream detached!');
        }
      });

      Future.delayed(const Duration(milliseconds: 2000), () {
        debugPrint('CallProvider: [DELAY 2000ms] Final audio check');
        debugPrint(
          'CallProvider: Remote audio tracks: ${_remoteRenderer.srcObject?.getAudioTracks().length ?? 0}',
        );
      });

      notifyListeners();
      debugPrint('CallProvider: === CALL STATE: ACTIVE ===');
      debugPrint('CallProvider: ========== END ON TRACK ==========');
    });

    _rtcManager.onConnectionState((state) {
      debugPrint('CallProvider: Connection state changed: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        debugPrint('CallProvider: Connection failed/disconnected, ending call');
        endCall();
      }
    });

    _rtcManager.onIceConnectionState((state) {
      debugPrint('CallProvider: ICE connection state: $state');
      _iceState = state;
      notifyListeners();

      // Track when ICE entered Checking state for restart mechanism
      if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
        _iceCheckingStartTime = DateTime.now();
        debugPrint(
          'CallProvider: ICE entered Checking state at $_iceCheckingStartTime',
        );
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _iceCheckingStartTime = null;
        debugPrint('CallProvider: ICE CONNECTED - Data path established!');
        if (_state != CallState.active) {
          _state = CallState.active;
          _acquireSchedulerForCall();
          _callTimeoutTimer?.cancel();
          _callTimeoutTimer = null;
          _stopAllSounds();
          HapticFeedback.heavyImpact();
          _callStartTime ??= DateTime.now();
          _log('Call connected', isSent: false);
          notifyListeners();
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('CallProvider: ICE FAILED - Check network/NAT');
        _lastError = 'ICE connection failed';
        _iceCheckingStartTime = null;
        endCall();
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('CallProvider: ICE COMPLETED - Fully connected!');
        _iceCheckingStartTime = null;
      }
    });
  }

  Future<void> handleRemoteSdp(String sdp, String type) async {
    if (type == 'answer') {
      debugPrint('CallProvider: Setting remote answer, state: $_state');

      // Prevent duplicate processing of session-accept
      if (_remoteAnswerProcessed) {
        debugPrint(
          'CallProvider: Already processed remote answer, ignoring duplicate',
        );
        return;
      }

      if (_state == CallState.active) {
        debugPrint('CallProvider: Already active, ignoring duplicate answer');
        return;
      }

      debugPrint('CallProvider: Applying remote answer SDP...');
      _remoteAnswerProcessed = true;
      await _rtcManager.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      debugPrint('CallProvider: Remote answer applied successfully');

      // NOTE: Do NOT call restartIceGathering() here
      // ICE should automatically start checking once both descriptions are set
      // The peer connection will form candidate pairs and begin connectivity checks

      // Set a timeout - but only fail if we don't have media
      // Some gateways (like cheogram) don't provide TURN candidates, so ICE may never connect
      // but media can still flow through the gateway's SIP infrastructure
      debugPrint('CallProvider: Starting media timeout (20 seconds)...');
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = Timer(const Duration(seconds: 20), () {
        // Only fail if call is NOT active (no media received)
        // If we have a remote track, the call is active regardless of ICE state
        if (_state != CallState.active) {
          debugPrint('CallProvider: Media timeout - no remote track received');
          _lastError = 'Connection timeout - no media received';
          _cleanup(reason: 'media_timeout');
        } else {
          debugPrint('CallProvider: Call active despite ICE state: $_iceState');
        }
      });
    }
  }

  void handleRemoteCandidate(Map<String, dynamic> candidateMap) {
    debugPrint(
      'CallProvider: handleRemoteCandidate - sdpMid: ${candidateMap['sdpMid']}, mLineIndex: ${candidateMap['sdpMLineIndex']}',
    );
    final candidate = candidateMap['candidate']?.toString() ?? '';
    debugPrint('CallProvider: Candidate: $candidate');

    if (candidate.isEmpty) {
      debugPrint('CallProvider: WARNING - Empty candidate received!');
      return;
    }

    _rtcManager.addCandidate(
      RTCIceCandidate(
        candidate,
        candidateMap['sdpMid']?.toString() ?? '0',
        int.tryParse(candidateMap['sdpMLineIndex']?.toString() ?? '0') ?? 0,
      ),
    );
  }

  Future<void> sendDtmf(String tone) async {
    if (_state != CallState.active) return;
    
    if (_isSipCall) {
      _sipService?.sendDTMF(tone);
    } else {
      await _rtcManager.sendDtmf(tone);
    }
  }

  Future<void> toggleRecording() async {
    if (_state != CallState.active) return;

    if (_isRecording) {
      await _rtcManager.stopRecording();
      _isRecording = false;
      _log(
        'Call Recording',
        isSent: true,
        filePath: _lastRecordingPath,
        type: chat.MessageType.voice,
      );
      notifyListeners();
    } else {
      try {
        if (kIsWeb) {
          await _rtcManager.startRecording('web_call_recording');
        } else {
          final docsDir = await getApplicationDocumentsDirectory();
          final exportDir = Directory('${docsDir.path}/GibberExport/Calls');
          if (!await exportDir.exists()) {
            await exportDir.create(recursive: true);
          }
          
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          _lastRecordingPath =
              '${exportDir.path}/call_${_remoteJid?.split("@").first}_$timestamp.mp4';

          await _rtcManager.startRecording(_lastRecordingPath!);
        }
        _isRecording = true;
        _log(
          'Recording started',
          isSent: true,
        );
        notifyListeners();
      } catch (e) {
        debugPrint('Recording Error: $e');
      }
    }
  }

  Future<void> inviteParticipant(String targetJid) async {
    if (_state != CallState.active) {
      debugPrint('CallProvider: Cannot invite participant, call is not active.');
      return;
    }

    debugPrint('CallProvider: Inviting $targetJid to the active call...');
    
    // Architecturally, since Gibber is currently strictly P2P via WebRTC,
    // true multiparty calling requires either an MCU/SFU bridge or a mesh of PeerConnections.
    // For now, we will log the invite action. A future implementation would:
    // 1. Create a MUC room.
    // 2. Send XEP-0249 (Direct MUC Invitations) to the new participant and the current remote party.
    
    _log('Invited $targetJid to join the call', isSent: true);
    
    // We could potentially send a standard chat message containing a conference URI if we wanted to mock it.
    if (_authService != null && _callAccountId != null) {
      // final jingleService = _authService!.getJingleService(_callAccountId!);
      // For now, we just simulate sending an invite.
      // jingleService.sendConferenceInvite(targetJid, _sessionId!);
    }
  }

  Future<void> endCall() async {
    if (_isSipCall) {
      _sipService?.hangup();
      _isSipCall = false;
      _log('SIP Call ended', isSent: true);
      await _cleanup(reason: 'terminated');
      return;
    }

    final signaling =
        _authService?.getJingleService(_callAccountId ?? '') ??
        _authService?.jingleSignaling;
    
    // Capture state before cleanup
    final targetJid = _remoteJid;
    final sid = _sessionId;
    final wasActive = _state == CallState.active;
    final wasIncoming = _state == CallState.incoming;
    
    // 1. Force cleanup of WebRTC and Audio focus first
    await _cleanup(reason: 'terminated');

    // 2. Send termination signaling
    if (targetJid != null && sid != null) {
      final isGateway = targetJid.toLowerCase().contains('cheogram') || targetJid.contains('+');
      debugPrint('CallProvider: [TEARDOWN] isGateway=$isGateway for $targetJid');

      if (wasActive || isGateway) {
        debugPrint('CallProvider: Direct IQ Terminate');
        signaling?.sendSessionTerminate(targetJid, sid);
      } else {
        if (wasIncoming) {
          debugPrint('CallProvider: [CHAT] XEP-0353 Message Reject');
          signaling?.sendRejectViaMessage(targetJid, sid);
        } else {
          debugPrint('CallProvider: [CHAT] XEP-0353 Message Retract');
          signaling?.sendRetractViaMessage(targetJid, sid);
        }
      }
      _log('Call ended', isSent: true);
    }
  }

  Future<void> declineCall() async {
    final signaling =
        _authService?.getJingleService(_callAccountId ?? '') ??
        _authService?.jingleSignaling;
        
    // Capture state before cleanup
    final targetJid = _remoteJid;
    final sid = _sessionId;
    final wasActive = _state == CallState.active;
    final wasIncoming = _state == CallState.incoming;
    
    // 1. Force cleanup of WebRTC and Audio focus first
    await _cleanup(reason: 'declined');

    // 2. Send termination signaling
    if (targetJid != null && sid != null) {
      final isGateway = targetJid.toLowerCase().contains('cheogram') || targetJid.contains('+');
      debugPrint('CallProvider: [DECLINE] isGateway=$isGateway for $targetJid');

      if (wasActive || isGateway) {
        debugPrint('CallProvider: Direct IQ Decline');
        signaling?.sendSessionTerminate(targetJid, sid);
      } else {
        if (wasIncoming) {
          debugPrint('CallProvider: [CHAT] XEP-0353 Message Reject');
          signaling?.sendRejectViaMessage(targetJid, sid);
        } else {
          debugPrint('CallProvider: [CHAT] XEP-0353 Message Retract');
          signaling?.sendRetractViaMessage(targetJid, sid);
        }
      }
      _log('Call declined', isSent: true);
    }
  }

  Future<void> _cleanup({String? reason}) async {
    debugPrint('CallProvider: === CLEANUP STARTING ===');
    debugPrint('CallProvider: Cleanup reason: $reason');

    _releaseSchedulerForCall();

    _statsSub?.cancel();
    _roomParticipantSub?.cancel();
    _roomParticipantSub = null;
    _janusSpeakingSub?.cancel();
    _janusSpeakingSub = null;
    _janusRemoteTrackSub?.cancel();
    _janusRemoteTrackSub = null;
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _iceDebugTimer?.cancel();
    _iceDebugTimer = null;
    debugPrint('CallProvider: Stats subscription cancelled');

    String durationStr = '';
    if (_callStartTime != null) {
      final duration = DateTime.now().difference(_callStartTime!);
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      durationStr =
          ' (Duration: $minutes:${seconds.toString().padLeft(2, '0')})';
    }

    if (_state == CallState.active) {
      _log(
        'Call finished$durationStr${reason != null ? " ($reason)" : ""}',
        isSent: true,
      );
      if (_callStartTime != null) _saveCallLog(CallStatus.completed);
    } else if (_state == CallState.incoming) {
      _log('Missed call${reason != null ? " ($reason)" : ""}', isSent: false);
      _saveCallLog(CallStatus.missed);
    } else if (_state == CallState.outgoing) {
      _log('Call failed${reason != null ? " ($reason)" : ""}', isSent: true);
      _saveCallLog(CallStatus.failed);
    }

    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    debugPrint('CallProvider: Renderers cleared');

    for (var r in _groupRenderers.values) {
      r.srcObject = null;
    }
    _groupRenderers.clear();
    _groupAudioLevels.clear();
    await _multiPeerManager?.dispose();
    _multiPeerManager = null;
    _isGroupCall = false;
    _groupCallSession = null;

    _janusService?.disconnect();
    _janusService?.dispose();
    _janusService = null;

    _state = CallState.idle;
    notifyListeners(); // Immediate UI update to prevent race conditions during async dispose

    await _stopAllSounds();
    debugPrint('CallProvider: Sounds stopped');

    await _rtcManager.dispose();
    debugPrint('CallProvider: WebRTC manager disposed');

    // RESTORE: Default Audio Context
    await _soundService.resetAudioContext();
    debugPrint('CallProvider: Audio context reset');

    _lastError ??= reason;
    _remoteJid = null;
    _sessionId = null;
    _callAccountId = null;
    _isMicMuted = false;
    _isCameraOff = false;
    _callStartTime = null;
    _localVolume = 0.0;
    _remoteVolume = 0.0;
    _remoteAnswerProcessed = false;
    _iceCheckingStartTime = null;

    // Reset audio effects and stop playback on call end
    _audioEffects.reset();
    _audioPlayback.stop();

    notifyListeners();
    debugPrint('CallProvider: === CLEANUP COMPLETE ===');
  }

  void _saveCallLog(CallStatus status) {
    if (_remoteJid == null) return;

    final log = CallLog(
      jid: _remoteJid!,
      timestamp: DateTime.now(),
      duration: _callStartTime != null
          ? DateTime.now().difference(_callStartTime!)
          : null,
      isVideo: _isVideo,
      status: status,
      direction: _state == CallState.incoming
          ? CallDirection.incoming
          : CallDirection.outgoing,
    );

    _historyService?.addLog(log);
  }

  String _extractCandidateType(String candidate) {
    if (candidate.contains('typ host')) return 'host';
    if (candidate.contains('typ srflx')) return 'srflx';
    if (candidate.contains('typ relay')) return 'relay';
    if (candidate.contains('typ prflx')) return 'prflx';
    return 'unknown';
  }

  void _acquireSchedulerForCall() {
    _scheduler?.acquire(ResourceTask.webrtcCall);
  }

  void _releaseSchedulerForCall() {
    _scheduler?.release(ResourceTask.webrtcCall);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _signalingSub?.cancel();
    _proximitySub?.cancel();
    _sipCallStateSub?.cancel();
    _audioEffects.removeListener(_onAudioEffectsChanged);
    _audioPlayback.removeListener(_onAudioPlaybackChanged);
    _sipService?.dispose();
    _sipService = null;
    _janusSpeakingSub?.cancel();
    _janusRemoteTrackSub?.cancel();
    _cleanup(reason: 'provider disposed');
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    for (var r in _groupRenderers.values) {
      r.dispose();
    }
    _groupRenderers.clear();
    _multiPeerManager?.dispose();
    _janusService?.dispose();
    _janusService = null;
    super.dispose();
  }
}
