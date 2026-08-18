import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'transcription_engine.dart';

class NativeTranscriptionEngine implements TranscriptionEngine {
  @override
  double get modelLoadProgress => 0.0;

  @override
  bool get isInitialized => false;

  @override
  Future<bool> initialize() async => false;

  @override
  void attachStreams(MediaStream localStream, MediaStream? remoteStream) {}

  @override
  void stop() {}

  @override
  void dispose() {}

  @override
  Stream<String> get onPartialResult => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onFinalResult => const Stream.empty();

  @override
  Stream<double> get onModelLoadProgress => const Stream.empty();
}

TranscriptionEngine createTranscriptionEngine() => NativeTranscriptionEngine();
