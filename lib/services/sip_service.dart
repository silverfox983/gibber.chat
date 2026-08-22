import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'web_audio_effects_stub.dart' if (dart.library.html) 'web_audio_effects_service.dart';

enum SipCallState { idle, connecting, ringing, active, ended }

class SipService implements SipUaHelperListener {
  SIPUAHelper? _helper;
  Call? _currentCall;

  final _callStateController = StreamController<SipCallState>.broadcast();
  Stream<SipCallState> get callStateStream => _callStateController.stream;

  SipCallState _state = SipCallState.idle;
  SipCallState get state => _state;

  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get remoteStream => _remoteStreamController.stream;

  MediaStream? _localStream;
  MediaStream? _remoteMediaStream;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteMediaStream => _remoteMediaStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  final _dtmfController = StreamController<String>.broadcast();
  Stream<String> get dtmfStream => _dtmfController.stream;

  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  String? _remoteNumber;
  String? get remoteNumber => _remoteNumber;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  String? _sipUri;
  String? _wsUrl;
  String? _password;
  String? _displayName;
  int _cheogramPortIndex = 0;
  final List<int> _cheogramPorts = [10443, 443, 8080];

  RegistrationState _registerState = RegistrationState();
  RegistrationState get registerState => _registerState;
  bool get isRegistered => _helper?.registered ?? false;

  final _incomingCallController = StreamController<Call>.broadcast();
  Stream<Call> get incomingCallStream => _incomingCallController.stream;

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    debugPrint('SipService: Renderers initialized');
  }

  void start({
    required String sipUri,
    required String wsUrl,
    required String password,
    String displayName = 'Flutter SIP',
  }) {
    if (_helper != null) return;

    _sipUri = sipUri;
    _wsUrl = wsUrl;
    _password = password;
    _displayName = displayName;

    _helper = SIPUAHelper();
    _helper!.addSipUaHelperListener(this);

    _register();
  }

  void _register() {
    if (_helper == null || _wsUrl == null || _sipUri == null) {
      debugPrint(
        'SipService: Cannot register - helper: ${_helper != null}, wsUrl: ${_wsUrl != null}, sipUri: ${_sipUri != null}',
      );
      return;
    }

    try {
      final uaSettings = UaSettings();
      uaSettings.webSocketUrl = _wsUrl!;
      // Extract username and domain from _sipUri (format: username@domain or just username)
      final parts = _sipUri!.contains('@') ? _sipUri!.split('@') : ['', ''];
      final username = parts[0];
      final domain = parts.length > 1 && parts[1].isNotEmpty
          ? parts[1]
          : 'cheogram.com';
      final fullSipUri = 'sip:$username@$domain';
      uaSettings.uri = fullSipUri;
      uaSettings.host = domain;
      uaSettings.contact_uri = fullSipUri;

      // Handle Cheogram Port Cycling
      if (domain == 'cheogram.com' && _wsUrl!.contains('cheogram.com')) {
        final port = _cheogramPorts[_cheogramPortIndex];
        uaSettings.webSocketUrl = 'wss://cheogram.com:$port';
        debugPrint('SipService: Cheogram Port-Cycling [Attempt ${_cheogramPortIndex + 1}/${_cheogramPorts.length}] -> $port');
      }

      final userPart = username;
      uaSettings.authorizationUser = userPart;
      uaSettings.password = _password ?? '';
      uaSettings.displayName = _displayName ?? 'Flutter SIP';
      uaSettings.userAgent = 'Gibber SIP Client/1.0';
      uaSettings.transportType = TransportType.WS;

      // WebSocket settings
      uaSettings.webSocketSettings.allowBadCertificate = true;
      uaSettings.tcpSocketSettings.allowBadCertificate = true;

      // Add ICE servers with TURN for NAT traversal
      uaSettings.iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun.ekiga.net'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ];
      uaSettings.iceTransportPolicy = IceTransportPolicy.ALL;

      debugPrint('SipService: Registering with WS=$_wsUrl');
      debugPrint('SipService: SIP URI: ${uaSettings.uri}');
      debugPrint('SipService: Host: ${uaSettings.host}');

      _helper!.start(uaSettings);
    } catch (e, stack) {
      debugPrint('SipService: Registration error: $e');
      debugPrint('SipService: Stack trace: $stack');
      _state = SipCallState.idle;
      _callStateController.add(_state);
    }
  }

  Future<void> register({
    required String sipUri,
    required String wsUrl,
    required String password,
    String displayName = 'Flutter SIP',
  }) async {
    _sipUri = sipUri;
    _wsUrl = wsUrl;
    _password = password;
    _displayName = displayName;

    try {
      if (_helper == null) {
        debugPrint('SipService: Creating new SIP UA helper');
        _helper = SIPUAHelper();
        _helper!.addSipUaHelperListener(this);
        // Wait for helper to fully initialize
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      _register();
    } catch (e, stack) {
      debugPrint('SipService: Registration error: $e');
      debugPrint('SipService: Stack: $stack');
    }
  }

  void unregister() {
    if (_helper == null) return;
    _helper!.unregister();
    debugPrint('SipService: Unregistered');
  }

  Future<bool> call(String phoneNumber, {bool video = false}) async {
    if (_helper == null) {
      debugPrint('SipService: SIP UA not initialized');
      return false;
    }

    _remoteNumber = phoneNumber;
    _state = SipCallState.connecting;
    _callStateController.add(_state);

    final cleanNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    final domain = _sipUri?.contains('@') == true ? _sipUri!.split('@').last : 'cheogram.com';
    final sipUri = 'sip:$cleanNumber@sip.$domain';

    debugPrint('SipService: Calling $sipUri (video: $video)');

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': video
            ? {
                'mandatory': <String, dynamic>{
                  'minWidth': '640',
                  'minHeight': '480',
                  'minFrameRate': '30',
                },
                'facingMode': 'user',
              }
            : false,
      };

      MediaStream mediaStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      // Web: Route audio through Web Audio effects processor
      if (kIsWeb) {
        try {
          mediaStream = WebAudioEffectsService.instance.processMediaStream(mediaStream);
        } catch (_) {}
      }

      _localStream = mediaStream;

      bool success = await _helper!.call(
        sipUri,
        voiceOnly: !video,
        mediaStream: mediaStream,
      );

      if (!success) {
        _state = SipCallState.idle;
        _callStateController.add(_state);
      }

      return success;
    } catch (e) {
      debugPrint('SipService: Call failed: $e');
      _state = SipCallState.idle;
      _callStateController.add(_state);
      return false;
    }
  }

  Future<bool> answer({bool video = false}) async {
    if (_currentCall == null) return false;

    debugPrint('SipService: Answering call (video: $video)');

    // Acquire local media if not already done (incoming calls need this before answering)
    if (_localStream == null) {
      debugPrint('SipService: Acquiring local media before answer...');
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': video,
      };
      try {
        _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
        debugPrint('SipService: Local media acquired for answer');
      } catch (e) {
        debugPrint('SipService: Failed to acquire local media: $e');
        // Continue anyway - the session may still work without explicit media stream
      }
    }

    try {
      final options = _helper!.buildCallOptions(video);
      _currentCall!.answer(options, mediaStream: _localStream);
      return true;
    } catch (e) {
      debugPrint('SipService: Answer failed: $e');
      return false;
    }
  }

  void hangup() {
    if (_currentCall == null) return;

    debugPrint('SipService: Hangup');
    _currentCall!.hangup({'status_code': 200});
    _cleanup();
  }

  void reject() {
    if (_currentCall == null) return;

    debugPrint('SipService: Rejecting call');
    _currentCall!.hangup({'status_code': 486});
    _cleanup();
  }

  void toggleMute() {
    if (_currentCall == null) return;

    _isMuted = !_isMuted;
    if (_isMuted) {
      _currentCall!.mute(true, false);
    } else {
      _currentCall!.unmute(true, false);
    }
    debugPrint('SipService: Mute: $_isMuted');
  }

  void toggleSpeaker(bool enabled) {
    _isSpeakerOn = enabled;
    Helper.setSpeakerphoneOn(enabled);
    debugPrint('SipService: Speaker: $enabled');
  }

  void sendDTMF(String tone) {
    if (_currentCall == null) return;

    _currentCall!.sendDTMF(tone);
    debugPrint('SipService: Sent DTMF: $tone');
    _dtmfController.add(tone);
  }

  bool _isOnHold = false;
  bool get isOnHold => _isOnHold;

  void hold() {
    if (_currentCall == null) return;
    _currentCall!.hold();
    _isOnHold = true;
    debugPrint('SipService: Call placed on hold');
  }

  void unhold() {
    if (_currentCall == null) return;
    _currentCall!.unhold();
    _isOnHold = false;
    debugPrint('SipService: Call resumed from hold');
  }

  void transfer(String targetUri) {
    if (_currentCall == null) return;
    _currentCall!.refer(targetUri);
    debugPrint('SipService: Transferring call to $targetUri');
  }

  void _cleanup() {
    _currentCall = null;

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      _localStream!.dispose();
      _localStream = null;
    }

    _remoteMediaStream = null;
    _remoteNumber = null;
    _isMuted = false;

    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;

    _state = SipCallState.idle;
    _callStateController.add(_state);
  }

  @override
  void callStateChanged(Call call, CallState callState) {
    debugPrint('SipService: Call state changed: ${callState.state}');

    _currentCall = call;

    switch (callState.state) {
      case CallStateEnum.CALL_INITIATION:
        if (call.direction == Direction.incoming) {
          _remoteNumber = call.remote_identity;
          debugPrint('SipService: Incoming call from $_remoteNumber');
          _state = SipCallState.ringing;
          _callStateController.add(_state);
        } else {
          _state = SipCallState.connecting;
          _callStateController.add(_state);
        }
        break;
      case CallStateEnum.CONNECTING:
        _state = SipCallState.connecting;
        _callStateController.add(_state);
        break;
      case CallStateEnum.PROGRESS:
        _state = SipCallState.ringing;
        _callStateController.add(_state);
        break;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        _state = SipCallState.active;
        _callStateController.add(_state);
        break;
      case CallStateEnum.STREAM:
        _handleStream(callState);
        break;
      case CallStateEnum.FAILED:
      case CallStateEnum.ENDED:
        _state = SipCallState.ended;
        _callStateController.add(_state);
        _cleanup();
        break;
      case CallStateEnum.MUTED:
        if (callState.audio == true) {
          _isMuted = true;
        }
        break;
      case CallStateEnum.UNMUTED:
        if (callState.audio == true) {
          _isMuted = false;
        }
        break;
      default:
        break;
    }
  }

  void _handleStream(CallState callState) {
    if (callState.stream == null) return;

    if (callState.originator == Originator.remote) {
      if (_remoteMediaStream != null) {
        _remoteMediaStream!.getTracks().forEach((track) => track.stop());
        _remoteMediaStream!.dispose();
      }
      _remoteMediaStream = callState.stream;
      remoteRenderer.srcObject = _remoteMediaStream;
      _remoteStreamController.add(_remoteMediaStream!);
      debugPrint('SipService: Remote stream received');
    }
  }

  @override
  void registrationStateChanged(RegistrationState state) {
    _registerState = state;
    debugPrint('SipService: === REGISTRATION STATE CHANGED ===');
    debugPrint(
      'SipService: Registration state: ${state.state?.name ?? "null"}',
    );
    if (state.state?.name == 'Registered') {
      debugPrint('SipService: === SIP REGISTERED SUCCESSFULLY ===');
      debugPrint(
        'SipService: Helper registered: ${_helper?.registered ?? false}',
      );
    }
  }

  @override
  void transportStateChanged(TransportState state) {
    debugPrint('SipService: Transport state: ${state.state.name}');

    // Auto-Retry Logic for Cheogram Port-Cycling
    if (state.state == TransportStateEnum.DISCONNECTED &&
        _wsUrl != null &&
        _wsUrl!.contains('cheogram.com')) {
      if (_cheogramPortIndex < _cheogramPorts.length - 1) {
        _cheogramPortIndex++;
        debugPrint(
          'SipService: Cheogram connection refused. Retrying with next port: ${_cheogramPorts[_cheogramPortIndex]}',
        );
        Future.delayed(const Duration(seconds: 2), () => _register());
      } else {
        debugPrint('SipService: All Cheogram ports exhausted. SIP registration failed.');
        _cheogramPortIndex = 0; // Reset for next manual attempt
      }
    } else if (state.state == TransportStateEnum.CONNECTED) {
      _cheogramPortIndex = 0; // Reset on success
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {
    debugPrint('SipService: New message received');
  }

  @override
  void onNewNotify(Notify ntf) {
    debugPrint('SipService: New notify received');
  }

  @override
  void onNewReinvite(ReInvite event) {
    debugPrint('SipService: New reinvite received');
  }

  void dispose() {
    _helper?.removeSipUaHelperListener(this);
    _helper?.stop();
    _helper = null;
    _cleanup();
    localRenderer.dispose();
    remoteRenderer.dispose();
    _callStateController.close();
    _remoteStreamController.close();
    _dtmfController.close();
    _incomingCallController.close();
    debugPrint('SipService: Disposed');
  }
}
