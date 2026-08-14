import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio_effects_service.dart';

class WebAudioEffectsService {
  static final WebAudioEffectsService instance = WebAudioEffectsService._();
  WebAudioEffectsService._();

  Future<bool> initialize() async => false;

  MediaStream processMediaStream(MediaStream stream) => stream;

  void updateConfig(VoiceEffectConfig config) {}

  Future<void> injectAudio(String url, {double volume = 0.7, bool looping = false}) async {}

  void stopInjection() {}

  void setInjectionVolume(double volume) {}

  void dispose() {}
}