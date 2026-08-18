import 'dart:async';

abstract class LLMEngine {
  double get modelLoadProgress => 0.0;
  String get modelLoadStatus => '';
  bool get isInitialized => false;

  Future<bool> initialize();
  Future<String> generate(String query, String context);
  Stream<String> get onToken;
  Stream<double> get onModelLoadProgress;
  Stream<String> get onModelLoadStatus;
  void dispose();
}
