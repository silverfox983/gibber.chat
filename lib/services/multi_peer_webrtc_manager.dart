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

  bool get isDisposed => _isDisposed;
  MediaStream? get localStream => _localStream;

  void setIceServers(List<Map<String, dynamic>> servers) {
    final allServers = <Map<String, dynamic>>[...servers];
    for (var fallback in _fallbackIceServers) {
      final urls = fallback['urls'] as String;
      if (!allServers.any((s) => s['urls'] == urls)) {
        allServers.add(fallback);
      }
    }
    _config['iceServers'] = allServers;
    debugPrint('MultiPeer: ICE servers updated (with fallbacks): ${allServers.length}');
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

  Future<void> addPeer(String peerId, {bool addLocalTracks = true}) async {
    if (_peerConnections.containsKey(peerId)) return;

    final pc = await createPeerConnection(_config, {
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': true,
      }
    });

    _peerConnections[peerId] = pc;
    _remoteCandidatesQueue[peerId] = [];

    // Only add local tracks if we have a local stream (mesh mode).
    // For SFU subscriber mode, there are no local tracks to add.
    if (addLocalTracks && _localStream != null) {
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
    // Auto-create peer if it doesn't exist (SFU subscriber flow).
    // We create it without local tracks since SFU subscribers don't send local media.
    if (!_peerConnections.containsKey(peerId)) {
      debugPrint('MultiPeer: Auto-creating peer $peerId for remote description (SFU flow)');
      await addPeer(peerId, addLocalTracks: false);
    }
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
      _remoteCandidatesQueue[peerId] ??= [];
      _remoteCandidatesQueue[peerId]!.add(candidate);
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

  Future<bool> replaceVideoTrack(MediaStreamTrack newTrack, {bool isStopping = false}) async {
    if (_localStream == null) return false;
    final pc = _peerConnections['publisher'];
    if (pc == null) return false;

    try {
      final senders = await pc.getSenders();
      for (var sender in senders) {
        if (sender.track?.kind == 'video') {
          MediaStreamTrack trackToUse;

          if (isStopping && _originalCameraTrack != null) {
            // Stopping screen share: restore original camera track
            trackToUse = _originalCameraTrack!;
            _originalCameraTrack = null;
          } else {
            // Starting screen share: save current camera, use new screen track
            trackToUse = newTrack;
            if (newTrack.kind == 'video' && _originalCameraTrack == null) {
              final currentVideo = _localStream!.getVideoTracks();
              if (currentVideo.isNotEmpty) {
                _originalCameraTrack = currentVideo.first;
              }
            }
          }

          await sender.replaceTrack(trackToUse);
          // Update local stream's video track
          final videoTracks = _localStream!.getVideoTracks();
          for (var track in videoTracks) {
            _localStream!.removeTrack(track);
            track.stop();
          }
          _localStream!.addTrack(trackToUse);
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('MultiPeer: replaceVideoTrack failed: $e');
      return false;
    }
  }

  Future<bool> replaceVideoTrackForAll(MediaStreamTrack newTrack, {bool isStopping = false}) async {
    if (_localStream == null) return false;
    try {
      MediaStreamTrack trackToUse;

      if (isStopping && _originalCameraTrack != null) {
        trackToUse = _originalCameraTrack!;
        _originalCameraTrack = null;
      } else {
        trackToUse = newTrack;
        if (newTrack.kind == 'video' && _originalCameraTrack == null) {
          final currentVideo = _localStream!.getVideoTracks();
          if (currentVideo.isNotEmpty) {
            _originalCameraTrack = currentVideo.first;
          }
        }
      }

      for (var entry in _peerConnections.entries) {
        final pc = entry.value;
        final senders = await pc.getSenders();
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(trackToUse);
          }
        }
      }
      // Update local stream
      final videoTracks = _localStream!.getVideoTracks();
      for (var track in videoTracks) {
        _localStream!.removeTrack(track);
        track.stop();
      }
      _localStream!.addTrack(trackToUse);
      return true;
    } catch (e) {
      debugPrint('MultiPeer: replaceVideoTrackForAll failed: $e');
      return false;
    }
  }

  MediaStream? _screenStream;
  MediaStreamTrack? _originalCameraTrack;

  Future<MediaStream?> getDisplayMedia() async {
    try {
      _screenStream = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      return _screenStream;
    } catch (e) {
      debugPrint('MultiPeer: getDisplayMedia failed: $e');
      return null;
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
