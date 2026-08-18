import 'dart:async';
import 'dart:js_interop';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web/web.dart' as web;
import 'llm_engine.dart';

class WebLLMEngine implements LLMEngine {
  web.Worker? _llmWorker;
  bool _initialized = false;
  double _modelLoadProgress = 0.0;
  String _modelLoadStatus = 'Initializing...';

  final _tokenController = StreamController<String>.broadcast();
  final _progressController = StreamController<double>.broadcast();
  final _statusController = StreamController<String>.broadcast();

  @override
  double get modelLoadProgress => _modelLoadProgress;

  @override
  String get modelLoadStatus => _modelLoadStatus;

  @override
  bool get isInitialized => _initialized;

  @override
  Stream<String> get onToken => _tokenController.stream;

  @override
  Stream<double> get onModelLoadProgress => _progressController.stream;

  @override
  Stream<String> get onModelLoadStatus => _statusController.stream;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      _llmWorker = web.Worker('llm_worker.js'.toJS);
      _llmWorker!.onmessage = ((web.MessageEvent e) {
        _handleMessage(e.data);
      }).toJS;

      return true;
    } catch (e) {
      debugPrint('WebLLMEngine: init failed: $e');
      return false;
    }
  }

  void _handleMessage(JSAny? data) {
    if (data == null) return;
    final str = data.toString();
    try {
      if (!str.startsWith('{')) return;
      final json = _parseJson(str);
      if (json == null) return;
      final type = json['type'] as String?;

      switch (type) {
        case 'progress':
          final progress = (json['progress'] as num?)?.toDouble() ?? 0.0;
          final text = json['text'] as String? ?? 'Loading...';
          _modelLoadProgress = progress.clamp(0.0, 1.0);
          _modelLoadStatus = text;
          _progressController.add(_modelLoadProgress);
          _statusController.add(_modelLoadStatus);
          break;
        case 'ready':
          _modelLoadProgress = 1.0;
          _modelLoadStatus = 'Ready';
          _initialized = true;
          _progressController.add(1.0);
          _statusController.add('Ready');
          break;
        case 'token':
          final text = json['text'] as String? ?? '';
          _tokenController.add(text);
          break;
        case 'done':
          _tokenController.add('[DONE]');
          break;
        case 'error':
          debugPrint('WebLLMEngine: worker error: ${json['error']}');
          break;
      }
    } catch (e) {
      debugPrint('WebLLMEngine: parse error: $e');
    }
  }

  Map<String, dynamic>? _parseJson(String str) {
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> generate(String query, String context) async {
    if (_llmWorker == null) {
      return 'AI assistant not initialized.';
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();

    void handleToken(String token) {
      if (token == '[DONE]') {
        _llmWorker!.onmessage = ((web.MessageEvent e) {
          _handleMessage(e.data);
        }).toJS;
        if (!completer.isCompleted) {
          completer.complete(buffer.toString());
        }
      } else {
        buffer.write(token);
      }
    }

    _llmWorker!.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data == null) return;
      final str = data.toString();
      if (!str.startsWith('{')) return;
      final json = _parseJson(str);
      if (json == null) return;
      final type = json['type'] as String?;
      if (type == 'token') {
        handleToken(json['text'] as String? ?? '');
      } else if (type == 'done') {
        handleToken('[DONE]');
      } else {
        _handleMessage(data);
      }
    }).toJS;

    final message = jsonEncode({
      'type': 'query',
      'query': query,
      'context': context,
    });

    _llmWorker!.postMessage(message.toJS);

    return completer.future;
  }

  @override
  void dispose() {
    _llmWorker?.terminate();
    _llmWorker = null;
    _initialized = false;
    _tokenController.close();
    _progressController.close();
    _statusController.close();
  }
}

LLMEngine createLLMEngine() => WebLLMEngine();
