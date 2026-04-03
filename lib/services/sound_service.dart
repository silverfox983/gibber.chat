import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum SoundType { ringtone, ringback, message, notification }

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _player = AudioPlayer();

  Future<void> playRingtone() async {
    debugPrint('SoundService: Playing ringtone');
    await _play('sounds/ringtone.mp3', loop: true);
  }

  Future<void> playRingback() async {
    debugPrint('SoundService: Playing ringback');
    await _play('sounds/ringback.mp3', loop: true);
  }

  Future<void> playMessageSound() async {
    await _play('sounds/message.mp3', loop: false);
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('SoundService: Error stopping sound: $e');
    }
  }

  Future<void> _play(String assetPath, {bool loop = false}) async {
    try {
      await _player.stop();

      if (loop) {
        await _player.setReleaseMode(ReleaseMode.loop);
      } else {
        await _player.setReleaseMode(ReleaseMode.release);
      }

      await _player.play(AssetSource(assetPath), mode: PlayerMode.lowLatency);
    } catch (e) {
      debugPrint('SoundService: Failed to play $assetPath: $e');
    }
  }

  /// Sets the global audio context for calling
  /// NOTE: WebRTC audio is handled by AndroidNativeAudioManagement/AppleNativeAudioManagement
  /// in WebRTCManager.initLocalStream(). This method now just logs for debugging.
  Future<void> setCallAudioContext({bool isVideo = false}) async {
    debugPrint(
      'SoundService: setCallAudioContext called (WebRTC audio handled in WebRTCManager)',
    );
    // Audio routing for WebRTC calls is now configured in WebRTCManager.initLocalStream()
    // AudioPlayer.global.setAudioContext() is for audioplayers package, NOT for WebRTC
  }

  /// Resets the global audio context to default
  /// Called when call ends to restore normal audio behavior
  Future<void> resetAudioContext() async {
    debugPrint('SoundService: resetAudioContext called');
    // Cleanup is handled by WebRTCManager when stream is disposed
  }

  void dispose() {
    _player.dispose();
  }
}
