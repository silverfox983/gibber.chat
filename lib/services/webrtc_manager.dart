import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef OnLocalStream = void Function(MediaStream stream);
typedef OnRemoteStream = void Function(MediaStream stream);
typedef OnIceCandidate = void Function(RTCIceCandidate candidate);
typedef OnConnectionState = void Function(RTCPeerConnectionState state);
typedef OnIceConnectionState = void Function(RTCIceConnectionState state);

class WebRTCManager {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaRecorder? _mediaRecorder;
  MediaStream? _recordingStream;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _remoteCandidatesQueue = [];
  Timer? _statsTimer;
  final _audioLevelController =
      StreamController<Map<String, double>>.broadcast();
  Stream<Map<String, double>> get audioLevels => _audioLevelController.stream;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  final Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
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
    ],
    'iceTransportPolicy': 'all',
    'sdpSemantics': 'unified-plan',
    'iceCandidatePoolSize': 10,
  };

  Map<String, dynamic>? _customIceConfig;
  bool _currentIsVideo = true;

  static const _fallbackIceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
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

  void setIceServers(List<Map<String, dynamic>> servers) {
    final allServers = <Map<String, dynamic>>[...servers];

    for (var fallback in _fallbackIceServers) {
      final urls = fallback['urls'] as String;
      if (!allServers.any((s) => s['urls'] == urls)) {
        allServers.add(fallback);
      }
    }

    _customIceConfig = {'iceServers': allServers};
    debugPrint(
      'WebRTC: Using ICE servers (with fallbacks): ${allServers.length}',
    );
    for (var server in allServers) {
      debugPrint('WebRTC:   - ${server['urls']}');
    }
  }

  OnIceCandidate? _iceCandidateCallback;
  OnRemoteStream? _remoteStreamCallback;
  OnConnectionState? _connectionStateCallback;
  OnIceConnectionState? _iceConnectionStateCallback;

  String? _lastAudioWarning;

  String? get lastAudioWarning => _lastAudioWarning;

  Future<bool> initLocalStream({bool isVideo = true}) async {
    if (_isDisposed) return false;

    // Configure native audio for proper Android/iOS audio routing
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        debugPrint('WebRTC: Configuring native audio for voice communication');

        if (Platform.isAndroid) {
          // Android: Use AndroidNativeAudioManagement for voice communication
          await AndroidNativeAudioManagement.setAndroidAudioConfiguration(
            AndroidAudioConfiguration(
              androidAudioMode: AndroidAudioMode.inCommunication,
              androidAudioFocusMode: AndroidAudioFocusMode.gain,
              androidAudioStreamType: AndroidAudioStreamType.voiceCall,
              androidAudioAttributesUsageType:
                  AndroidAudioAttributesUsageType.voiceCommunication,
              androidAudioAttributesContentType:
                  AndroidAudioAttributesContentType.speech,
              manageAudioFocus: true,
              forceHandleAudioRouting: true,
            ),
          );
          debugPrint(
            'WebRTC: Android audio configured for voice communication',
          );
        } else if (Platform.isIOS) {
          // iOS: Use AppleNativeAudioManagement for voice communication
          await AppleNativeAudioManagement.setAppleAudioConfiguration(
            AppleAudioConfiguration(
              appleAudioCategory: AppleAudioCategory.playAndRecord,
              appleAudioCategoryOptions: {
                AppleAudioCategoryOption.defaultToSpeaker,
                AppleAudioCategoryOption.allowBluetooth,
                AppleAudioCategoryOption.allowBluetoothA2DP,
              },
              appleAudioMode: AppleAudioMode.voiceChat,
            ),
          );
          debugPrint('WebRTC: iOS audio configured for voice communication');
        }

        debugPrint('WebRTC: Native audio configuration successful');
      } catch (e) {
        debugPrint('WebRTC: Native audio config FAILED: $e');
        _lastAudioWarning = 'Native audio configuration failed: $e';
      }
    }

    final Map<String, dynamic> mediaConstraints = {
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'googHighpassFilter': true,
      },
      'video': isVideo ? {
        'mandatory': {
          'minWidth': '1280',
          'minHeight': '720',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
      } : false,
    };

    debugPrint(
      'WebRTC: Media constraints: audio=${mediaConstraints['audio']}, video=$isVideo',
    );

    // LEAK PREVENTION: Fully dispose existing local stream before re-initializing
    if (_localStream != null) {
      debugPrint('WebRTC: Disposing existing local stream before re-init');
      _stopStreamTracks(_localStream);
      await _localStream!.dispose();
      _localStream = null;
    }

    try {
      debugPrint('WebRTC: Requesting user media...');
      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      debugPrint('WebRTC: User media obtained successfully');
      debugPrint('WebRTC: Local stream id: ${_localStream!.id}');
      debugPrint(
        'WebRTC: Local stream has ${_localStream!.getTracks().length} tracks total',
      );

      // HARDENING: Ensure audio tracks are explicitly started
      final audioTracks = _localStream!.getAudioTracks();
      debugPrint('WebRTC: Found ${audioTracks.length} audio track(s)');
      for (var track in audioTracks) {
        track.enabled = true;
        debugPrint(
          'WebRTC: Audio track - id: ${track.id}, label: ${track.label}, enabled: ${track.enabled}',
        );
      }

      // HAL SYNC: Short delay for Android 13+ AIDL mapping to complete before routing change
      // Only 500ms needed for modern drivers
      await Future.delayed(const Duration(milliseconds: 500));

      // HARDENING: Use standard Helper for hardware routing to avoid session-level conflicts
      // HARDENING: Only attempt native speakerphone routing on supported mobile platforms
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        try {
          Helper.setSpeakerphoneOn(isVideo);
        } catch (e) {
          debugPrint('WebRTC: Non-fatal speakerphone error: $e');
        }
      }

      return isVideo ? _localStream!.getVideoTracks().isNotEmpty : true;
    } catch (e) {
      if (isVideo) {
        debugPrint(
          'WebRTC: Video capture failed, attempting audio-only fallback: $e',
        );
        try {
          _localStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
          return false;
        } catch (e2) {
          debugPrint('WebRTC: Total media failure: $e2');
          rethrow;
        }
      } else {
        rethrow;
      }
    }
  }

  void toggleMic(bool enabled) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = enabled;
      debugPrint('WebRTC: Microphone ${enabled ? 'enabled' : 'disabled'}');
    });
  }

  void setSpeakerphone(bool enabled) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        Helper.setSpeakerphoneOn(enabled);
        debugPrint('WebRTC: Speakerphone ${enabled ? 'enabled' : 'disabled'}');
      } catch (e) {
        debugPrint('WebRTC: Non-fatal speakerphone error: $e');
      }
    }
  }

  void ensureAudioEnabled() {
    debugPrint('WebRTC: === ENSURING AUDIO ENABLED ===');

    // Ensure local audio tracks are enabled
    _localStream?.getAudioTracks().forEach((track) {
      if (!track.enabled) {
        track.enabled = true;
        debugPrint('WebRTC: Re-enabled local audio track: ${track.id}');
      }
    });

    // Ensure remote audio tracks are enabled
    _remoteStream?.getAudioTracks().forEach((track) {
      if (!track.enabled) {
        track.enabled = true;
        debugPrint('WebRTC: Re-enabled remote audio track: ${track.id}');
      }
    });

    debugPrint('WebRTC: === AUDIO ENABLED CHECK COMPLETE ===');
  }

  Future<void> ensureAudioEnabledWithDelay(int delayMs) async {
    await Future.delayed(Duration(milliseconds: delayMs));
    ensureAudioEnabled();
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        Helper.setSpeakerphoneOn(true);
        debugPrint('WebRTC: Force-enabled speakerphone after delay');
      } catch (e) {
        debugPrint('WebRTC: Speaker toggle error: $e');
      }
    }
  }

  void setRemoteAudioVolume(double volume) {
    debugPrint('WebRTC: Setting remote audio volume to $volume');
    _remoteStream?.getAudioTracks().forEach((track) {
      try {
        // The MediaStreamTrack doesn't have setVolume directly in Flutter WebRTC
        // But we can enable/disable and let the renderer handle volume
        track.enabled = volume > 0;
        debugPrint('WebRTC: Audio track ${track.id} enabled: ${track.enabled}');
      } catch (e) {
        debugPrint('WebRTC: Error setting audio volume: $e');
      }
    });
  }

  void toggleCamera(bool enabled) {
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = enabled;
    });
  }

  Future<void> switchCamera() async {
    if (_localStream == null) return;
    for (var track in _localStream!.getVideoTracks()) {
      await Helper.switchCamera(track);
    }
  }

  Future<void> _disposePeerConnection() async {
    if (_peerConnection != null) {
      debugPrint('WebRTC: Disposing existing peer connection');
      await _peerConnection!.close();
      await _peerConnection!.dispose();
      _peerConnection = null;
    }
    _remoteStream = null;
    _remoteDescriptionSet = false;
    _remoteCandidatesQueue.clear();
    debugPrint('WebRTC: Peer connection disposed');
  }

  Future<RTCSessionDescription> createOffer() async {
    if (_isDisposed) throw Exception('WebRTC: Engine Disposed');

    debugPrint('WebRTC: === CREATE OFFER START ===');

    // Determine if this is a video call based on local stream
    _currentIsVideo = _localStream?.getVideoTracks().isNotEmpty ?? false;
    debugPrint(
      'WebRTC: This is a ${_currentIsVideo ? "video" : "audio-only"} call',
    );

    // CRITICAL: Dispose and recreate peer connection for fresh state
    await _disposePeerConnection();
    await _initPeerConnection();

    if (_isDisposed || _peerConnection == null) {
      throw Exception('WebRTC: Engine Disposed during init');
    }

    // CRITICAL: Only add audio tracks for audio-only calls
    // This ensures the offer doesn't include video m-line
    if (_localStream != null) {
      if (_currentIsVideo) {
        // Video call: add all tracks
        debugPrint(
          'WebRTC: Adding ${_localStream!.getTracks().length} tracks to peer connection',
        );
        for (var track in _localStream!.getTracks()) {
          debugPrint('WebRTC: Adding ${track.kind} track: ${track.id}');
          await _peerConnection!.addTrack(track, _localStream!);
        }
      } else {
        // Audio-only: add only audio tracks from the existing local stream
        debugPrint('WebRTC: Audio-only mode: adding audio tracks from local stream');
        // Audio-only: reuse the already-initialized local stream.
        // Creating/discarding a temporary stream here can end tracks prematurely.
        final audioTracks = _localStream!.getAudioTracks();
        debugPrint(
          'WebRTC: Audio-only mode: adding ${audioTracks.length} local audio track(s)',
        );
        if (audioTracks.isEmpty) {
          throw Exception('WebRTC: No local audio track available for offer');
        }
        for (var track in audioTracks) {
          debugPrint('WebRTC: Adding audio track: ${track.id}');
          await _peerConnection!.addTrack(track, _localStream!);
        }
      }

      // Log audio track status
      final audioTracks = _localStream!.getAudioTracks();
      debugPrint(
        'WebRTC: Local stream has ${audioTracks.length} audio track(s)',
      );
      for (var track in audioTracks) {
        debugPrint(
          'WebRTC: Local audio track - id: ${track.id}, enabled: ${track.enabled}',
        );
      }
    } else {
      debugPrint('WebRTC: WARNING - Local stream is null!');
    }

    debugPrint('WebRTC: Creating offer...');

    // Use offer options to explicitly control SDP content
    final offerOptions = <String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _currentIsVideo,
      'voiceActivityDetection': true,
    };

    RTCSessionDescription offer = await _peerConnection!.createOffer(
      offerOptions,
    );
    debugPrint('WebRTC: Offer created, SDP length: ${offer.sdp?.length ?? 0}');

    // Verify audio is in SDP
    if (offer.sdp != null) {
      final hasAudio = offer.sdp!.contains('m=audio');
      final hasVideo = offer.sdp!.contains('m=video');
      debugPrint('WebRTC: SDP contains audio: $hasAudio, video: $hasVideo');
      debugPrint(
        'WebRTC: SDP preview: ${offer.sdp!.substring(0, offer.sdp!.length > 800 ? 800 : offer.sdp!.length)}',
      );
      if (!hasAudio) {
        debugPrint('WebRTC: WARNING - Audio NOT found in SDP!');
      }
    }

    await _peerConnection!.setLocalDescription(offer);
    debugPrint('WebRTC: === CREATE OFFER COMPLETE ===');

    return offer;
  }

  Future<RTCSessionDescription> createAnswer(
    RTCSessionDescription offer,
  ) async {
    if (_isDisposed) throw Exception('WebRTC: Engine Disposed');

    debugPrint('WebRTC: === CREATE ANSWER START ===');
    debugPrint('WebRTC: Offer SDP length: ${offer.sdp?.length}');
    _currentIsVideo = offer.sdp?.contains('m=video') ?? false;
    debugPrint('WebRTC: Offer has video: $_currentIsVideo');

    // Save pending candidates that arrived early via trickle ICE before they are wiped
    final pendingCandidates = List<RTCIceCandidate>.from(_remoteCandidatesQueue);

    // CRITICAL: Dispose and recreate peer connection for fresh state
    await _disposePeerConnection();
    await _initPeerConnection();

    // Restore pending candidates
    if (pendingCandidates.isNotEmpty) {
      debugPrint('WebRTC: Restored ${pendingCandidates.length} early remote candidates');
      _remoteCandidatesQueue.addAll(pendingCandidates);
    }

    if (_isDisposed || _peerConnection == null) {
      throw Exception('WebRTC: Engine Disposed during init');
    }

    // CRITICAL: Set remote description FIRST - this is REQUIRED for createAnswer() to work
    // Remote candidates that arrive before this are queued and will be added here
    await setRemoteDescription(offer);
    debugPrint('WebRTC: Remote description set');

    // CRITICAL: Add tracks AFTER setting remote description
    if (_localStream != null) {
      debugPrint(
        'WebRTC: Adding ${_localStream!.getTracks().length} tracks to peer connection',
      );
      for (var track in _localStream!.getTracks()) {
        debugPrint('WebRTC: Adding ${track.kind} track: ${track.id}');
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // Log audio track status
      final audioTracks = _localStream!.getAudioTracks();
      debugPrint(
        'WebRTC: Local stream has ${audioTracks.length} audio track(s)',
      );
      for (var track in audioTracks) {
        debugPrint(
          'WebRTC: Local audio track - id: ${track.id}, enabled: ${track.enabled}',
        );
      }
    } else {
      debugPrint('WebRTC: WARNING - Local stream is null!');
    }

    debugPrint('WebRTC: Creating answer...');
    RTCSessionDescription answer = await _peerConnection!.createAnswer();
    debugPrint(
      'WebRTC: Answer created, SDP length: ${answer.sdp?.length ?? 0}',
    );

    // Verify audio is in SDP
    if (answer.sdp != null) {
      final hasAudio = answer.sdp!.contains('m=audio');
      final hasVideo = answer.sdp!.contains('m=video');
      debugPrint(
        'WebRTC: Answer SDP contains audio: $hasAudio, video: $hasVideo',
      );

      // Log first 500 chars of SDP for debugging
      debugPrint(
        'WebRTC: Answer SDP preview: ${answer.sdp!.substring(0, answer.sdp!.length > 500 ? 500 : answer.sdp!.length)}',
      );

      if (!hasAudio) {
        debugPrint('WebRTC: WARNING - Audio NOT found in answer SDP!');
      }
    }

    // CRITICAL: Set local description to complete the answer exchange
    // This starts ICE gathering for our side
    await _peerConnection!.setLocalDescription(answer);
    debugPrint('WebRTC: Local description set - ICE gathering active');

    debugPrint('WebRTC: === CREATE ANSWER COMPLETE ===');

    return answer;
  }

  Future<void> _initPeerConnection() async {
    if (_isDisposed) return;
    if (_peerConnection != null) {
      debugPrint('WebRTC: Peer connection already exists, reusing');
      return;
    }

    debugPrint('WebRTC: === INIT PEER CONNECTION ===');

    // Build constraints dynamically based on call type
    // Only offer video if _currentIsVideo is true (local stream has video)
    final constraints = {
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': _currentIsVideo,
        'VoiceActivityDetection': true,
      },
      'optional': [
        {'googEchoCancellation': true},
        {'googAutoGainControl': true},
        {'googNoiseSuppression': true},
        {'googHighpassFilter': true},
        {'googNoiseReduction': true},
      ],
    };

    // Merge custom ICE servers with standards if provided
    final config = Map<String, dynamic>.from(_customIceConfig ?? _config);
    debugPrint('WebRTC: ICE servers: ${config['iceServers']}');
    debugPrint('WebRTC: Constraints - OfferToReceiveVideo: $_currentIsVideo');

    _peerConnection = await createPeerConnection(config, constraints);
    debugPrint('WebRTC: Peer connection created successfully');

    _peerConnection!.onIceCandidate = (candidate) {
      final candidateStr = candidate.candidate ?? '';
      debugPrint('WebRTC: ICE candidate generated: ${candidate.sdpMid}');
      debugPrint('WebRTC:   Full candidate: $candidateStr');
      debugPrint(
        'WebRTC:   Candidate type: ${_extractCandidateType(candidateStr)}',
      );
      _iceCandidateCallback?.call(candidate);
    };

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('WebRTC: ICE gathering state: $state');
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('WebRTC: Connection state: ${state.name}');
      _connectionStateCallback?.call(state);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        debugPrint('WebRTC: === PEER CONNECTION CONNECTED ===');
      }
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('WebRTC: ICE Connection State changed to ${state.name}');
      _iceConnectionStateCallback?.call(state);

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _startStatsLoop();
        debugPrint('WebRTC: === ICE CONNECTED - Audio path ready ===');
        _logSelectedCandidatePair();
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('WebRTC: === ICE COMPLETED - Fully connected ===');
        _logSelectedCandidatePair();
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _stopStatsLoop();
        debugPrint('WebRTC: ICE connection ended: ${state.name}');
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('WebRTC: ========== REMOTE TRACK EVENT ==========');
      debugPrint(
        'WebRTC: Track received - kind: ${event.track.kind}, id: ${event.track.id}',
      );
      debugPrint('WebRTC: Track enabled: ${event.track.enabled}');
      debugPrint('WebRTC: Track muted: ${event.track.muted}');
      debugPrint('WebRTC: Number of streams: ${event.streams.length}');

      if (event.streams.isNotEmpty) {
        debugPrint('WebRTC: Stream id: ${event.streams[0].id}');
        // NOTE: stream.active is NOT implemented on Android - do not access it!
        // Accessing stream.active will throw UnimplementedError
        _remoteStream = event.streams[0];

        final audioTracks = _remoteStream!.getAudioTracks();
        final videoTracks = _remoteStream!.getVideoTracks();
        debugPrint(
          'WebRTC: Stream has $audioTracks audio tracks, $videoTracks video tracks',
        );

        for (var track in audioTracks) {
          debugPrint(
            'WebRTC: AUDIO TRACK - id: ${track.id}, label: ${track.label}',
          );
          debugPrint(
            'WebRTC: AUDIO TRACK - enabled: ${track.enabled}, muted: ${track.muted}',
          );
          track.enabled = true;
          debugPrint('WebRTC: Set audio track enabled = true');
        }

        for (var track in _remoteStream!.getVideoTracks()) {
          debugPrint(
            'WebRTC: Remote video track: ${track.id}, enabled: ${track.enabled}',
          );
        }

        // CRITICAL: Log when we're about to call the callback
        debugPrint('WebRTC: Calling remote stream callback...');
        _remoteStreamCallback?.call(_remoteStream!);
        debugPrint('WebRTC: Remote stream callback completed');
      } else {
        debugPrint('WebRTC: WARNING - No streams in track event!');
      }
      debugPrint('WebRTC: ========== END REMOTE TRACK ==========');
    };
  }

  Future<void> _logSelectedCandidatePair() async {
    if (_peerConnection == null) return;

    try {
      final stats = await _peerConnection!.getStats();
      for (var report in stats) {
        if (report.type == 'candidate-pair' &&
            report.values['state'] == 'succeeded') {
          final localId = report.values['localCandidateId']?.toString() ?? '';
          final remoteId = report.values['remoteCandidateId']?.toString() ?? '';

          for (var r in stats) {
            if (r.id == localId) {
              debugPrint('WebRTC: Selected LOCAL candidate:');
              debugPrint('WebRTC:   ${r.values}');
            }
            if (r.id == remoteId) {
              debugPrint('WebRTC: Selected REMOTE candidate:');
              debugPrint('WebRTC:   ${r.values}');
            }
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('WebRTC: Error logging candidate pair: $e');
    }
  }

  String _extractCandidateType(String candidate) {
    if (candidate.contains('typ host')) return 'host';
    if (candidate.contains('typ srflx')) return 'srflx';
    if (candidate.contains('typ relay')) return 'relay';
    if (candidate.contains('typ prflx')) return 'prflx';
    return 'unknown';
  }

  void _startStatsLoop() {
    _statsTimer?.cancel();
    int tickCount = 0;
    _statsTimer = Timer.periodic(const Duration(milliseconds: 200), (
      timer,
    ) async {
      if (_peerConnection == null || _isDisposed) {
        _stopStatsLoop();
        return;
      }

      try {
        final stats = await _peerConnection!.getStats();
        if (_isDisposed) return;
        double localLevel = 0.0;
        double remoteLevel = 0.0;
        int? packetsReceived;
        bool hasInboundAudio = false;
        int iceCandidatePairs = 0;
        int connectedPairs = 0;
        String? selectedPairState;

        for (var report in stats) {
          // Standard 'media-source' or 'inbound-rtp' stats per WebRTC spec
          if (report.type == 'media-source' &&
              report.values['kind'] == 'audio') {
            double level =
                double.tryParse(
                  report.values['audioLevel']?.toString() ?? '0',
                ) ??
                0.0;
            localLevel = math.sqrt(level); // Perceived loudness scale
          }
          if (report.type == 'inbound-rtp' &&
              report.values['kind'] == 'audio') {
            hasInboundAudio = true;
            // totalAudioEnergy / totalSamplesDuration is sometimes used, but 'audioLevel' is more direct
            double level =
                double.tryParse(
                  report.values['audioLevel']?.toString() ?? '0',
                ) ??
                0.0;
            // LOGARITHMIC SCALING: Standard WebRTC levels are often linear energy,
            // we want something that mirrors human perceived volume (DB-ish) for the visualizer.
            remoteLevel = math.sqrt(level);
            packetsReceived = report.values['packetsReceived'] as int?;
          }

          // Track ICE candidate pairs
          if (report.type == 'candidate-pair') {
            iceCandidatePairs++;
            final state = report.values['state']?.toString() ?? '';
            if (state == 'succeeded') {
              connectedPairs++;
              selectedPairState = state;
            }
          }
        }

        _audioLevelController.add({'local': localLevel, 'remote': remoteLevel});

        // Log ICE stats every 5 seconds (25 ticks)
        tickCount++;
        if (tickCount % 25 == 0) {
          debugPrint(
            'WebRTC: ICE Stats - candidatePairs: $iceCandidatePairs, connected: $connectedPairs, selectedState: $selectedPairState',
          );
          debugPrint(
            'WebRTC: Audio stats - hasInbound: $hasInboundAudio, packets: $packetsReceived, remoteLevel: ${remoteLevel.toStringAsFixed(3)}',
          );
        }

        // REINFORCEMENT: Heartbeat check for tracks
        _localStream?.getAudioTracks().forEach((t) {
          if (!t.enabled) {
            debugPrint(
              'WebRTC: Local audio track found disabled, re-enabling via heartbeat',
            );
            t.enabled = true;
          }
        });
      } catch (e) {
        debugPrint('WebRTC: Stats error: $e');
      }
    });
  }

  void _stopStatsLoop() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    if (_isDisposed || _peerConnection == null) return;

    debugPrint('WebRTC: === SET REMOTE DESCRIPTION ===');
    debugPrint('WebRTC: SDP type: ${description.type}');
    debugPrint('WebRTC: SDP length: ${description.sdp?.length ?? 0}');

    String sdpText = description.sdp ?? '';
    if (sdpText.isNotEmpty) {
      // Check for actual m=audio and m=video lines (not just anywhere in SDP)
      final hasAudio = RegExp(r'^m=audio\s', multiLine: true).hasMatch(sdpText);
      final hasVideo = RegExp(r'^m=video\s', multiLine: true).hasMatch(sdpText);
      debugPrint('WebRTC: SDP has audio: $hasAudio, has video: $hasVideo');

      // Fix for remote answers that have video in BUNDLE but no actual m=video line
      // This is common with gateways that reject video but keep BUNDLE reference
      if (sdpText.contains('a=group:BUNDLE')) {
        final bundleMatch = RegExp(
          r'a=group:BUNDLE\s+([^\s\n]+)',
        ).firstMatch(sdpText);
        if (bundleMatch != null) {
          final bundleValue = bundleMatch.group(1) ?? '';
          final bundleMids = bundleValue.split(' ');

          // Check if BUNDLE references video (MID "1") but no m=video exists
          final hasVideoInBundle = bundleMids.any((m) => m == '1');

          if (hasVideoInBundle && !hasVideo) {
            debugPrint(
              'WebRTC: Fixing SDP - BUNDLE has video MID but no m=video line',
            );

            // Fix BUNDLE to only include audio
            sdpText = sdpText.replaceFirst(
              RegExp(r'a=group:BUNDLE\s+[^\s\n]+'),
              'a=group:BUNDLE 0',
            );
            debugPrint('WebRTC: Fixed BUNDLE to "a=group:BUNDLE 0"');
          }
        }
      }
    }

    final fixedDescription = RTCSessionDescription(sdpText, description.type);
    try {
      await _peerConnection!.setRemoteDescription(fixedDescription);
      _remoteDescriptionSet = true;
      debugPrint('WebRTC: Remote description set');
    } catch (e) {
      debugPrint('WebRTC: setRemoteDescription failed: $e');
      debugPrint('WebRTC: Trying with original SDP...');
      await _peerConnection!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      debugPrint('WebRTC: Remote description set (original)');
    }

    // CRITICAL: Add queued candidates immediately for gateway compatibility
    // Gateways like cheogram.com expect quick ICE negotiation
    if (_remoteCandidatesQueue.isNotEmpty) {
      debugPrint(
        'WebRTC: Adding ${_remoteCandidatesQueue.length} queued candidates immediately',
      );

      for (var candidate in _remoteCandidatesQueue) {
        if (_isDisposed || _peerConnection == null) break;
        debugPrint('WebRTC: Adding queued candidate: ${candidate.sdpMid}');
        try {
          await _peerConnection!.addCandidate(candidate);
        } catch (e) {
          debugPrint('WebRTC: Error adding candidate: $e');
        }
      }
      _remoteCandidatesQueue.clear();
    }
    debugPrint('WebRTC: === REMOTE DESCRIPTION COMPLETE ===');
  }

  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (_isDisposed) return;
    debugPrint(
      'WebRTC: addCandidate called - sdpMid: ${candidate.sdpMid}, index: ${candidate.sdpMLineIndex}',
    );
    debugPrint('WebRTC:   Candidate: ${candidate.candidate ?? "empty"}');
    debugPrint(
      'WebRTC:   Remote desc set: $_remoteDescriptionSet, Queue size: ${_remoteCandidatesQueue.length}',
    );

    if (_remoteDescriptionSet) {
      if (_peerConnection == null) {
        debugPrint('WebRTC: Cannot add candidate - no peer connection');
        return;
      }
      debugPrint('WebRTC: Adding candidate immediately');
      try {
        await _peerConnection!.addCandidate(candidate);
        debugPrint('WebRTC: Candidate added successfully');
      } catch (e) {
        debugPrint('WebRTC: Error adding candidate immediately: $e');
      }
    } else {
      debugPrint('WebRTC: Queuing candidate (remote desc not set yet)');
      _remoteCandidatesQueue.add(candidate);
      debugPrint(
        'WebRTC: Queue now has ${_remoteCandidatesQueue.length} candidates',
      );
    }
  }

  void onIceCandidate(OnIceCandidate callback) {
    _iceCandidateCallback = callback;
  }

  void onTrack(OnRemoteStream callback) {
    _remoteStreamCallback = callback;
  }

  void onConnectionState(OnConnectionState callback) {
    _connectionStateCallback = callback;
  }

  void onIceConnectionState(OnIceConnectionState callback) {
    _iceConnectionStateCallback = callback;
  }

  void restartIceGathering() {
    if (_peerConnection == null || _isDisposed) {
      debugPrint('WebRTC: Cannot restart ICE gathering - no peer connection');
      return;
    }
    debugPrint('WebRTC: === RESTARTING ICE GATHERING ===');
    _peerConnection!.restartIce();
  }

  Future<void> startIceConnectivityCheck() async {
    if (_peerConnection == null || _isDisposed) {
      debugPrint('WebRTC: Cannot start ICE check - no peer connection');
      return;
    }

    debugPrint('WebRTC: === STARTING ICE CONNECTIVITY CHECK ===');

    // CRITICAL: First, add any queued remote candidates
    if (_remoteCandidatesQueue.isNotEmpty) {
      debugPrint(
        'WebRTC: Adding ${_remoteCandidatesQueue.length} queued remote candidates',
      );
      for (var candidate in _remoteCandidatesQueue) {
        if (_isDisposed || _peerConnection == null) break;
        try {
          await _peerConnection!.addCandidate(candidate);
          debugPrint('WebRTC: Added queued candidate: ${candidate.sdpMid}');
        } catch (e) {
          debugPrint('WebRTC: Error adding queued candidate: $e');
        }
      }
      _remoteCandidatesQueue.clear();
      debugPrint('WebRTC: Queued candidates cleared');
    }

    try {
      final localDesc = await _peerConnection!.getLocalDescription();
      final remoteDesc = await _peerConnection!.getRemoteDescription();
      debugPrint('WebRTC: Local desc: ${localDesc != null ? "set" : "null"}');
      debugPrint('WebRTC: Remote desc: ${remoteDesc != null ? "set" : "null"}');

      if (localDesc == null || remoteDesc == null) {
        debugPrint('WebRTC: Cannot start ICE - missing descriptions');
        return;
      }

      // NOTE: Do NOT call restartIce() here - it can interfere with ICE connectivity
      // ICE should automatically start checking once both descriptions are set
      // The ICE agent will form candidate pairs and begin connectivity checks

      // Log current stats to see candidate pairs
      final stats = await _peerConnection!.getStats();
      int candidatePairCount = 0;
      int activePairCount = 0;
      for (var report in stats) {
        if (report.type == 'candidate-pair') {
          candidatePairCount++;
          final state = report.values['state']?.toString() ?? '';
          if (state == 'succeeded' || state == 'in-progress') {
            activePairCount++;
          }
          debugPrint('WebRTC: Candidate pair state: $state');
        }
      }
      debugPrint(
        'WebRTC: Total candidate pairs: $candidatePairCount, active: $activePairCount',
      );
    } catch (e) {
      debugPrint('WebRTC: Error starting ICE check: $e');
    }
  }

  void forceIceRenegotiation() {
    if (_peerConnection == null || _isDisposed) {
      debugPrint('WebRTC: Cannot force renegotiation - no peer connection');
      return;
    }
    debugPrint('WebRTC: === FORCING ICE RENEGOTIATION ===');
    _peerConnection!.restartIce();
  }

  Future<Map<String, dynamic>> getIceCandidatePairStats() async {
    if (_peerConnection == null) {
      return {'state': 'no_connection', 'error': 'No peer connection'};
    }

    try {
      final stats = await _peerConnection!.getStats();
      String selectedPair = '';
      String pairState = '';
      String localCandidate = '';
      String remoteCandidate = '';

      for (var report in stats) {
        if (report.type == 'candidate-pair' &&
            report.values['state'] == 'succeeded') {
          selectedPair = report.id;
          pairState = report.values['state']?.toString() ?? '';
          final localId = report.values['localCandidateId']?.toString() ?? '';
          final remoteId = report.values['remoteCandidateId']?.toString() ?? '';

          for (var r in stats) {
            if (r.id == localId) {
              localCandidate = r.values.toString();
            }
            if (r.id == remoteId) {
              remoteCandidate = r.values.toString();
            }
          }
          break;
        }
      }

      return {
        'selectedPair': selectedPair,
        'pairState': pairState,
        'localCandidate': localCandidate,
        'remoteCandidate': remoteCandidate,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  Future<void> startRecording(String path) async {
    if (_mediaRecorder != null) return;

    _mediaRecorder = MediaRecorder();
    _recordingStream = await createLocalMediaStream('recording_stream');

    // Mix local and remote audio
    _localStream?.getAudioTracks().forEach(
      (track) => _recordingStream!.addTrack(track),
    );
    _remoteStream?.getAudioTracks().forEach(
      (track) => _recordingStream!.addTrack(track),
    );

    // Add remote video as the recording visual (typically what you want to record)
    _remoteStream?.getVideoTracks().forEach(
      (track) => _recordingStream!.addTrack(track),
    );

    await _mediaRecorder!.start(
      path,
      videoTrack: _recordingStream!.getVideoTracks().isNotEmpty
          ? _recordingStream!.getVideoTracks().first
          : null,
      audioChannel: _recordingStream!.getAudioTracks().isNotEmpty
          ? RecorderAudioChannel.INPUT
          : null,
    );
  }

  Future<void> stopRecording() async {
    if (_mediaRecorder == null) return;
    await _mediaRecorder!.stop();
    _mediaRecorder = null;
    // Don't call _stopStreamTracks(_recordingStream) here, as these tracks are shared
    // with the active call. Killing them here would end the call's audio/video.
    try {
      await _recordingStream?.dispose().timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('WebRTC: Error disposing recording stream: $e');
    }
    _recordingStream = null;
  }
  
  Future<void> sendDtmf(String tone) async {
    if (_peerConnection == null) return;
    try {
      final senders = await _peerConnection!.getSenders();
      for (var sender in senders) {
        if (sender.track?.kind == 'audio') {
          final dtmfSender = sender.dtmfSender;
          await dtmfSender.insertDTMF(tone);
          debugPrint('WebRTC: Sent DTMF tone: $tone');
          return;
        }
      }
      debugPrint('WebRTC: No audio sender found for DTMF');
    } catch (e) {
      debugPrint('WebRTC: Error sending DTMF: $e');
    }
  }

  void _stopStreamTracks(MediaStream? stream) {
    if (stream == null) return;
    try {
      for (var track in stream.getTracks()) {
        try {
          track.stop();
        } catch (e) {
          debugPrint('WebRTC: Error stopping track: $e');
        }
      }
    } catch (e) {
      debugPrint('WebRTC: Error accessing tracks for stop: $e');
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    debugPrint('WebRTC: Forceful disposal starting...');
    _isDisposed = true; // Synchronous block
    _stopStatsLoop();
    _audioLevelController.close();
    await stopRecording();

    // SEQUENTIAL SHUTDOWN: tracks first, then streams, then connection
    if (_localStream != null) {
      debugPrint('WebRTC: Stopping local tracks');
      _stopStreamTracks(_localStream);
      try {
        await _localStream!.dispose().timeout(const Duration(seconds: 1));
      } catch (e) {
        debugPrint('WebRTC: Error disposing local stream (already gone?): $e');
      }
      _localStream = null;
    }

    if (_remoteStream != null) {
      debugPrint('WebRTC: Stopping remote tracks');
      _stopStreamTracks(_remoteStream);
      try {
        await _remoteStream!.dispose().timeout(const Duration(seconds: 1));
      } catch (e) {
        debugPrint('WebRTC: Error disposing remote stream (already gone?): $e');
      }
      _remoteStream = null;
    }

    if (_peerConnection != null) {
      debugPrint('WebRTC: Closing PeerConnection');
      // DETACH: remove all tracks from PC to allow native GC
      final senders = await _peerConnection!.getSenders();
      for (var s in senders) {
        try {
          await _peerConnection!.removeTrack(s);
          await s.dispose();
        } catch (e) {
          debugPrint('WebRTC: Error removing track from PC: $e');
        }
      }

      await _peerConnection!.dispose();
      _peerConnection = null;
    }

    _remoteDescriptionSet = false;
    _remoteCandidatesQueue.clear();

    // GC SYNC: Short delay to allow asynchronous native unregistration to finish
    await Future.delayed(const Duration(milliseconds: 300));
    debugPrint('WebRTC: Disposal complete');
  }
}
