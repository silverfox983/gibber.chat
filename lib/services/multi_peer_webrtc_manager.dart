import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'web_audio_effects_stub.dart' if (dart.library.html) 'web_audio_effects_service.dart';

typedef OnLocalStream = void Function(MediaStream stream);
typedef OnRemoteStreamAdded = void Function(String peerId, MediaStream stream);
typedef OnRemoteStreamRemoved = void Function(String peerId);
typedef OnIceCandidate = void Function(String peerId, RTCIceCandidate candidate);
typedef OnConnectionState = void Function(String peerId, RTCPeerConnectionState state);
typedef OnIceConnectionState = void Function(String peerId, RTCIceConnectionState state);

/// MultiPeerWebRTCManager
/// Architected to handle Full-Mesh P2P connections for MUC rooms without an SFU.
/// Manages N PeerConnections, one for each participant in the MUC.
class MultiPeerWebRTCManager {
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, List<RTCIceCandidate>> _remoteCandidatesQueue = {};
  
  MediaStream? _localStream;
  bool _isDisposed = false;

  OnIceCandidate? onIceCandidate;
  OnRemoteStreamAdded? onRemoteStreamAdded;
  OnRemoteStreamRemoved? onRemoteStreamRemoved;
  OnConnectionState? onConnectionState;
  OnIceConnectionState? onIceConnectionState;

  final Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
    'iceTransportPolicy': 'all',
    'sdpSemantics': 'unified-plan',
  };

  bool get isDisposed => _isDisposed;
  MediaStream? get localStream => _localStream;

  void setIceServers(List<Map<String, dynamic>> servers) {
    _config['iceServers'] = servers;
  }

  Future<bool> initLocalStream({bool isVideo = true}) async {
    if (_isDisposed) return false;

    // HARDENING: Configure Native Audio for Voice Communication
    if (!kIsWeb) {
      try {
        debugPrint('MultiPeer: Configuring native audio for voice communication');

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
          debugPrint('MultiPeer: Android audio configured for voice communication');
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
          debugPrint('MultiPeer: iOS audio configured for voice communication');
        }
      } catch (e) {
        debugPrint('MultiPeer: Native audio config FAILED: $e');
      }
    }

    final mediaConstraints = {
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': isVideo ? {
        'mandatory': {
          'minWidth': '640',
          'minHeight': '480',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
      } : false,
    };

    debugPrint('MultiPeer: Requesting user media (isVideo: $isVideo)...');
    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      debugPrint('MultiPeer: User media obtained successfully! Tracks: ${_localStream!.getTracks().length}');

      // Web: Route audio through Web Audio effects processor
      if (kIsWeb) {
        try {
          _localStream = WebAudioEffectsService.instance.processMediaStream(_localStream!);
          debugPrint('MultiPeer: Audio stream processed through Web Audio effects');
        } catch (e) {
          debugPrint('MultiPeer: Web Audio effects processing failed: $e');
        }
      }

      return isVideo ? _localStream!.getVideoTracks().isNotEmpty : true;
    } catch (e) {
      debugPrint('MultiPeer: Failed to get local stream: $e');
      return false;
    }
  }

  bool hasPeer(String peerId) {
    return _peerConnections.containsKey(peerId);
  }

  Set<String> getActivePeerIds() {
    return _peerConnections.keys.toSet();
  }

  Future<void> addPeer(String peerId) async {
    if (_peerConnections.containsKey(peerId)) return;
    
    final pc = await createPeerConnection(_config, {
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': true,
      }
    });

    _peerConnections[peerId] = pc;
    _remoteCandidatesQueue[peerId] = [];

    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    pc.onIceCandidate = (candidate) {
      onIceCandidate?.call(peerId, candidate);
    };

    pc.onConnectionState = (state) {
      onConnectionState?.call(peerId, state);
    };

    pc.onIceConnectionState = (state) {
      onIceConnectionState?.call(peerId, state);
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStreams[peerId] = event.streams[0];
        onRemoteStreamAdded?.call(peerId, event.streams[0]);
      }
    };
  }

  Future<RTCSessionDescription> createOffer(String peerId) async {
    if (!_peerConnections.containsKey(peerId)) {
      await addPeer(peerId);
    }
    final pc = _peerConnections[peerId]!;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer(String peerId, RTCSessionDescription offer) async {
    if (!_peerConnections.containsKey(peerId)) {
      await addPeer(peerId);
    }
    final pc = _peerConnections[peerId]!;
    await pc.setRemoteDescription(offer);
    
    // Process queued candidates
    final queued = _remoteCandidatesQueue[peerId] ?? [];
    for (var candidate in queued) {
      await pc.addCandidate(candidate);
    }
    _remoteCandidatesQueue[peerId]!.clear();

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer;
  }

  Future<void> setRemoteDescription(String peerId, RTCSessionDescription description) async {
    if (!_peerConnections.containsKey(peerId)) return;
    await _peerConnections[peerId]!.setRemoteDescription(description);
    
    // Process queued candidates
    final queued = _remoteCandidatesQueue[peerId] ?? [];
    for (var candidate in queued) {
      await _peerConnections[peerId]!.addCandidate(candidate);
    }
    _remoteCandidatesQueue[peerId]!.clear();
  }

  Future<void> addCandidate(String peerId, RTCIceCandidate candidate) async {
    if (!_peerConnections.containsKey(peerId)) {
      _remoteCandidatesQueue[peerId] = [candidate];
      return;
    }
    
    final pc = _peerConnections[peerId]!;
    final remoteDesc = await pc.getRemoteDescription();
    
    if (remoteDesc != null) {
      await pc.addCandidate(candidate);
    } else {
      _remoteCandidatesQueue[peerId]?.add(candidate);
    }
  }

  Future<void> removePeer(String peerId) async {
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
    _remoteStreams.remove(peerId);
    _remoteCandidatesQueue.remove(peerId);
    onRemoteStreamRemoved?.call(peerId);
  }

  void toggleMic(bool enabled) {
    if (_localStream != null) {
      for (var track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  void toggleCamera(bool enabled) {
    if (_localStream != null) {
      for (var track in _localStream!.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;

    // 1. Forcefully stop all tracks first to release camera/mic hardware
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // 2. Dispose of peer connections
    for (var pc in _peerConnections.values) {
      await pc.close();
      await pc.dispose();
    }
    _peerConnections.clear();
    _remoteStreams.clear();
    _remoteCandidatesQueue.clear();
  }
}
