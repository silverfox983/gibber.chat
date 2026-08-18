import 'dart:async';
import 'llm_engine.dart';

class NativeLLMEngine implements LLMEngine {
  @override
  double get modelLoadProgress => 0.0;

  @override
  String get modelLoadStatus => 'Not available on mobile';

  @override
  bool get isInitialized => false;

  @override
  Future<bool> initialize() async => false;

  @override
  Future<String> generate(String query, String context) async {
    return 'AI assistant is only available on web. Please use a desktop browser.';
  }

  @override
  Stream<String> get onToken => const Stream.empty();

  @override
  Stream<double> get onModelLoadProgress => const Stream.empty();

  @override
  Stream<String> get onModelLoadStatus => const Stream.empty();

  @override
  void dispose() {}
}

LLMEngine createLLMEngine() => NativeLLMEngine();
