import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'web_audio_effects_stub.dart' if (dart.library.html) 'web_audio_effects_service.dart';

enum PlaybackState { stopped, playing, paused }

class CallAudioPlaybackService extends ChangeNotifier {
  static const _channel = MethodChannel('gibber.audio_effects');
  static final CallAudioPlaybackService instance = CallAudioPlaybackService._();

  CallAudioPlaybackService._();

  bool _isAvailable = false;
  PlaybackState _state = PlaybackState.stopped;
  double _volume = 0.7;
  bool _looping = false;
  String? _currentSource;

  bool get isAvailable => _isAvailable;
  PlaybackState get state => _state;
  double get volume => _volume;
  bool get looping => _looping;
  String? get currentSource => _currentSource;

  Future<bool> initialize() async {
    if (kIsWeb) {
      _isAvailable = true;
      notifyListeners();
      return true;
    }
    if (!Platform.isAndroid) {
      _isAvailable = false;
      return false;
    }
    _isAvailable = true;
    notifyListeners();
    return true;
  }

  Future<void> playFile(String path, {bool looping = false, double volume = 0.7}) async {
    if (!_isAvailable) return;
    if (kIsWeb) return; // Local file paths not available on web
    try {
      await _channel.invokeMethod('playAudioOverCall', {
        'path': path,
        'isAsset': false,
        'isUrl': false,
        'looping': looping,
        'volume': volume,
      });
      _state = PlaybackState.playing;
      _volume = volume;
      _looping = looping;
      _currentSource = path;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: playFile failed: $e');
    }
  }

  Future<void> playAsset(String assetPath, {bool looping = false, double volume = 0.7}) async {
    if (!_isAvailable) return;
    if (kIsWeb) {
      try {
        await WebAudioEffectsService.instance.injectAudio(
          'assets/$assetPath',
          volume: volume,
          looping: looping,
        );
        _state = PlaybackState.playing;
        _volume = volume;
        _looping = looping;
        _currentSource = assetPath;
        notifyListeners();
      } catch (e) {
        debugPrint('CallAudioPlaybackService: playAsset (web) failed: $e');
      }
      return;
    }
    try {
      await _channel.invokeMethod('playAudioOverCall', {
        'path': assetPath,
        'isAsset': true,
        'isUrl': false,
        'looping': looping,
        'volume': volume,
      });
      _state = PlaybackState.playing;
      _volume = volume;
      _looping = looping;
      _currentSource = assetPath;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: playAsset failed: $e');
    }
  }

  Future<void> playUrl(String url, {bool looping = false, double volume = 0.7}) async {
    if (!_isAvailable) return;
    if (kIsWeb) {
      try {
        await WebAudioEffectsService.instance.injectAudio(url, volume: volume, looping: looping);
        _state = PlaybackState.playing;
        _volume = volume;
        _looping = looping;
        _currentSource = url;
        notifyListeners();
      } catch (e) {
        debugPrint('CallAudioPlaybackService: playUrl (web) failed: $e');
      }
      return;
    }
    try {
      await _channel.invokeMethod('playAudioOverCall', {
        'path': url,
        'isAsset': false,
        'isUrl': true,
        'looping': looping,
        'volume': volume,
      });
      _state = PlaybackState.playing;
      _volume = volume;
      _looping = looping;
      _currentSource = url;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: playUrl failed: $e');
    }
  }

  Future<void> pause() async {
    if (!_isAvailable) return;
    if (kIsWeb) { WebAudioEffectsService.instance.stopInjection(); _state = PlaybackState.paused; notifyListeners(); return; }
    try {
      await _channel.invokeMethod('pauseAudioOverCall');
      _state = PlaybackState.paused;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: pause failed: $e');
    }
  }

  Future<void> resume() async {
    if (!_isAvailable) return;
    if (kIsWeb) return; // Resume not supported on web (re-play instead)
    try {
      await _channel.invokeMethod('resumeAudioOverCall');
      _state = PlaybackState.playing;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: resume failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_isAvailable) return;
    if (kIsWeb) { WebAudioEffectsService.instance.stopInjection(); _state = PlaybackState.stopped; _currentSource = null; notifyListeners(); return; }
    try {
      await _channel.invokeMethod('stopAudioOverCall');
      _state = PlaybackState.stopped;
      _currentSource = null;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: stop failed: $e');
    }
  }

  Future<void> seek(double ratio) async {
    if (!_isAvailable) return;
    try {
      await _channel.invokeMethod('seekAudioOverCall', {'ratio': ratio});
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: seek failed: $e');
    }
  }

  Future<void> setVolume(double volume) async {
    if (!_isAvailable) return;
    if (kIsWeb) { WebAudioEffectsService.instance.setInjectionVolume(volume); _volume = volume; notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setAudioOverCallVolume', {'volume': volume});
      _volume = volume;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: setVolume failed: $e');
    }
  }

  Future<void> setLooping(bool looping) async {
    if (!_isAvailable) return;
    try {
      await _channel.invokeMethod('setAudioOverCallLooping', {'looping': looping});
      _looping = looping;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: setLooping failed: $e');
    }
  }

  Future<int> getDurationMs() async {
    if (!_isAvailable) return 0;
    try {
      final duration = await _channel.invokeMethod<int>('getAudioOverCallDuration');
      return duration ?? 0;
    } on PlatformException catch (e) {
      debugPrint('CallAudioPlaybackService: getDurationMs failed: $e');
      return 0;
    }
  }
}