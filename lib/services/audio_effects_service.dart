import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'web_audio_effects_stub.dart' if (dart.library.html) 'web_audio_effects_service.dart';

enum VoiceEffect { none, pitch, robot, phone, noiseGate, custom }

class VoiceEffectConfig {
  final VoiceEffect effect;
  final double pitchSemitones;
  final double robotDepth;
  final double robotFrequencyHz;
  final bool phoneFilter;
  final bool noiseGate;
  final double noiseGateThresholdDb;
  final bool enabled;

  const VoiceEffectConfig({
    this.effect = VoiceEffect.none,
    this.pitchSemitones = 0.0,
    this.robotDepth = 0.5,
    this.robotFrequencyHz = 50.0,
    this.phoneFilter = false,
    this.noiseGate = false,
    this.noiseGateThresholdDb = -55.0,
    this.enabled = true,
  });

  VoiceEffectConfig copyWith({
    VoiceEffect? effect,
    double? pitchSemitones,
    double? robotDepth,
    double? robotFrequencyHz,
    bool? phoneFilter,
    bool? noiseGate,
    double? noiseGateThresholdDb,
    bool? enabled,
  }) {
    return VoiceEffectConfig(
      effect: effect ?? this.effect,
      pitchSemitones: pitchSemitones ?? this.pitchSemitones,
      robotDepth: robotDepth ?? this.robotDepth,
      robotFrequencyHz: robotFrequencyHz ?? this.robotFrequencyHz,
      phoneFilter: phoneFilter ?? this.phoneFilter,
      noiseGate: noiseGate ?? this.noiseGate,
      noiseGateThresholdDb: noiseGateThresholdDb ?? this.noiseGateThresholdDb,
      enabled: enabled ?? this.enabled,
    );
  }

  String get effectName => effect.name.toUpperCase();
}

class AudioEffectsService extends ChangeNotifier {
  static const _channel = MethodChannel('gibber.audio_effects');
  static final AudioEffectsService instance = AudioEffectsService._();

  AudioEffectsService._();

  bool _isAvailable = false;
  VoiceEffectConfig _config = const VoiceEffectConfig();

  bool get isAvailable => _isAvailable;
  VoiceEffectConfig get config => _config;

  Future<bool> initialize() async {
    if (kIsWeb) {
      final ok = await WebAudioEffectsService.instance.initialize();
      _isAvailable = ok;
      return ok;
    }
    if (!Platform.isAndroid) {
      _isAvailable = false;
      return false;
    }
    try {
      await _channel.invokeMethod('resetEffects');
      _isAvailable = true;
      _config = const VoiceEffectConfig();
      notifyListeners();
      return true;
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: initialize failed: $e');
      _isAvailable = false;
      return false;
    }
  }

  Future<void> setEffect(VoiceEffect effect) async {
    if (kIsWeb && _isAvailable) {
      _config = _config.copyWith(effect: effect);
      WebAudioEffectsService.instance.updateConfig(_config);
      notifyListeners();
      return;
    }
    if (!_isAvailable) return;
    try {
      await _channel.invokeMethod('setEffect', {'effect': effect.name.toUpperCase()});
      _config = _config.copyWith(effect: effect);
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setEffect failed: $e');
    }
  }

  Future<void> setPitchSemitones(double semitones) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(pitchSemitones: semitones);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setPitchSemitones', {'semitones': semitones});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setPitchSemitones failed: $e');
    }
  }

  Future<void> setRobotDepth(double depth) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(robotDepth: depth);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setRobotDepth', {'depth': depth});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setRobotDepth failed: $e');
    }
  }

  Future<void> setRobotFrequency(double frequencyHz) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(robotFrequencyHz: frequencyHz);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setRobotFrequency', {'frequency': frequencyHz});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setRobotFrequency failed: $e');
    }
  }

  Future<void> setPhoneFilter(bool enabled) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(phoneFilter: enabled);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setPhoneFilter', {'enabled': enabled});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setPhoneFilter failed: $e');
    }
  }

  Future<void> setNoiseGate(bool enabled) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(noiseGate: enabled);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setNoiseGate', {'enabled': enabled});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setNoiseGate failed: $e');
    }
  }

  Future<void> setNoiseGateThreshold(double thresholdDb) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(noiseGateThresholdDb: thresholdDb);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setNoiseGateThreshold', {'thresholdDb': thresholdDb});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setNoiseGateThreshold failed: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (!_isAvailable) return;
    _config = _config.copyWith(enabled: enabled);
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('setEffectEnabled', {'enabled': enabled});
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: setEnabled failed: $e');
    }
  }

  Future<void> reset() async {
    if (!_isAvailable) return;
    _config = const VoiceEffectConfig();
    if (kIsWeb) { WebAudioEffectsService.instance.updateConfig(_config); notifyListeners(); return; }
    try {
      await _channel.invokeMethod('resetEffects');
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('AudioEffectsService: reset failed: $e');
    }
  }

  Future<void> applyConfig(VoiceEffectConfig config) async {
    if (!_isAvailable) return;
    await setEffect(config.effect);
    if (config.effect == VoiceEffect.pitch || config.effect == VoiceEffect.custom) {
      await setPitchSemitones(config.pitchSemitones);
    }
    if (config.effect == VoiceEffect.robot || config.effect == VoiceEffect.custom) {
      await setRobotDepth(config.robotDepth);
      await setRobotFrequency(config.robotFrequencyHz);
    }
    await setPhoneFilter(config.phoneFilter);
    await setNoiseGate(config.noiseGate);
    if (config.noiseGate) {
      await setNoiseGateThreshold(config.noiseGateThresholdDb);
    }
    await setEnabled(config.enabled);
  }
}