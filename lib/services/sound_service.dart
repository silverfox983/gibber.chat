import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SoundType { ringtone, ringback, message, notification }

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _player = AudioPlayer();

  Future<void> playRingtone() async {
    debugPrint('SoundService: Playing ringtone');
    try {
      final prefs = await SharedPreferences.getInstance();
      final customPath = prefs.getString('custom_ringtone_path');
      
      if (customPath != null && !kIsWeb && await File(customPath).exists()) {
        await _play(customPath, loop: true, isLocal: true);
        return;
      }
    } catch (e) {
      debugPrint('SoundService: Error checking custom ringtone: $e');
    }
    
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

  Future<void> _play(String path, {bool loop = false, bool isLocal = false}) async {
    try {
      await _player.stop();

      if (loop) {
        await _player.setReleaseMode(ReleaseMode.loop);
      } else {
        await _player.setReleaseMode(ReleaseMode.release);
      }

      final source = isLocal ? DeviceFileSource(path) : AssetSource(path);
      await _player.play(source, mode: PlayerMode.lowLatency);
    } catch (e) {
      debugPrint('SoundService: Failed to play $path: $e');
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
    try {
      // Force release the AudioPlayer to free up the MediaCodec buffer pool
      // This prevents AIBinder_linkToDeath aborts when the audio session is torn down.
      await _player.release();
    } catch (e) {
      debugPrint('SoundService: Error releasing audio player: $e');
    }
  }

  void dispose() {
    _player.dispose();
  }
}
