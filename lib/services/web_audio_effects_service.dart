import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:web/web.dart' as web;
import 'audio_effects_service.dart';

class WebAudioEffectsService {
  static final WebAudioEffectsService instance = WebAudioEffectsService._();
  WebAudioEffectsService._();

  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _source;
  web.AudioWorkletNode? _worklet;
  web.MediaStreamAudioDestinationNode? _dest;
  web.GainNode? _injectGain;
  web.AudioBufferSourceNode? _injectSource;

  web.MediaStream? _originalStream;
  web.MediaStream? _processedStream;
  bool _initialized = false;

  VoiceEffectConfig _config = const VoiceEffectConfig();

  Future<bool> initialize() async {
    if (!kIsWeb) return false;
    try {
      _ctx = web.AudioContext();
      await _ctx!.audioWorklet.addModule('audio_worklet.js').toDart;
      _initialized = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  MediaStream processMediaStream(MediaStream stream) {
    if (!_initialized || _ctx == null) return stream;
    try {
      final dynamic streamImpl = stream;
      if (streamImpl is! MediaStreamWeb) return stream;
      final jsStream = streamImpl.jsStream;
      final processedJsStream = _processJsStream(jsStream);
      return MediaStreamWeb(processedJsStream, stream.ownerTag ?? 'local');
    } catch (e) {
      return stream;
    }
  }

  web.MediaStream _processJsStream(web.MediaStream jsStream) {
    _disconnect();

    _source = _ctx!.createMediaStreamSource(jsStream);
    _dest = _ctx!.createMediaStreamDestination();

    _worklet = web.AudioWorkletNode(_ctx!, 'voice-processor');
    _updateConfig();

    _source!.connect(_worklet!);
    _worklet!.connect(_dest!);

    _originalStream = jsStream;
    _processedStream = _dest!.stream;

    return _processedStream!;
  }

  void updateConfig(VoiceEffectConfig config) {
    _config = config;
    _updateConfig();
  }

  void _updateConfig() {
    if (_worklet == null) return;
    final pitchFactor = _config.effect == VoiceEffect.pitch || _config.effect == VoiceEffect.custom
        ? (_config.pitchSemitones != 0 ? _semitonesToFactor(_config.pitchSemitones) : 1.0)
        : 1.0;
    _worklet!.port.postMessage({
      'type': 'config',
      'pitch': pitchFactor,
      'robotDepth': _config.effect == VoiceEffect.robot || _config.effect == VoiceEffect.custom
          ? _config.robotDepth
          : 0.0,
      'robotFrequency': _config.robotFrequencyHz,
      'phoneEnabled': _config.phoneFilter || _config.effect == VoiceEffect.phone,
      'noiseGateEnabled': _config.noiseGate,
      'noiseGateThreshold': _config.noiseGateThresholdDb,
      'enabled': _config.enabled,
      'sampleRate': _ctx?.sampleRate.toDouble(),
    }.jsify());
  }

  double _semitonesToFactor(double semitones) {
    return math.pow(2.0, semitones / 12.0).toDouble();
  }

  Future<void> injectAudio(String url, {double volume = 0.7, bool looping = false}) async {
    if (!_initialized || _ctx == null || _dest == null) return;
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      final jsArrayBuffer = await response.arrayBuffer().toDart;
      final audioBuffer = await _ctx!.decodeAudioData(jsArrayBuffer).toDart;

      _injectSource?.stop();
      _injectSource?.disconnect();
      _injectGain ??= _ctx!.createGain();
      _injectGain!.gain.value = volume;
      _injectGain!.connect(_dest!);

      _injectSource = _ctx!.createBufferSource();
      _injectSource!.buffer = audioBuffer;
      _injectSource!.loop = looping;
      _injectSource!.connect(_injectGain!);
      _injectSource!.start();
    } catch (e) {
      // Audio injection failed silently
    }
  }

  void stopInjection() {
    try {
      _injectSource?.stop();
      _injectSource?.disconnect();
      _injectSource = null;
    } catch (_) {}
  }

  void setInjectionVolume(double volume) {
    _injectGain?.gain.value = volume;
  }

  void _disconnect() {
    try {
      _source?.disconnect();
      _worklet?.disconnect();
    } catch (_) {}
    _source = null;
    _worklet = null;
  }

  void dispose() {
    _disconnect();
    _injectSource?.stop();
    _injectSource?.disconnect();
    _injectSource = null;
    _injectGain?.disconnect();
    _injectGain = null;
    _ctx?.close();
    _ctx = null;
    _initialized = false;
  }
}