import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';

abstract class TranscriptionEngine {
  double get modelLoadProgress => 0.0;
  bool get isInitialized => false;

  Future<bool> initialize();
  void attachStreams(MediaStream localStream, MediaStream? remoteStream);
  void stop();
  void dispose();

  Stream<String> get onPartialResult;
  Stream<Map<String, dynamic>> get onFinalResult;
  Stream<double> get onModelLoadProgress;
}
