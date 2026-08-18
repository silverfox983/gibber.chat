import 'dart:async';
import 'dart:js_interop';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:web/web.dart' as web;
import 'transcription_engine.dart';

class WebTranscriptionEngine implements TranscriptionEngine {
  web.AudioContext? _ctx;
  web.Worker? _whisperWorker;
  web.AudioWorkletNode? _worklet;
  web.MediaStreamAudioDestinationNode? _dest;
  web.MediaStreamAudioSourceNode? _localSource;
  web.MediaStreamAudioSourceNode? _remoteSource;

  bool _initialized = false;
  bool _attached = false;
  double _modelLoadProgress = 0.0;

  final _partialResultController = StreamController<String>.broadcast();
  final _finalResultController = StreamController<Map<String, dynamic>>.broadcast();
  final _progressController = StreamController<double>.broadcast();

  @override
  double get modelLoadProgress => _modelLoadProgress;

  @override
  bool get isInitialized => _initialized;

  @override
  Stream<String> get onPartialResult => _partialResultController.stream;

  @override
  Stream<Map<String, dynamic>> get onFinalResult => _finalResultController.stream;

  @override
  Stream<double> get onModelLoadProgress => _progressController.stream;

  @override
  Future<bool> initialize() async {
    if (!kIsWeb) return false;
    if (_initialized) return true;

    try {
      _ctx = web.AudioContext();
      await _ctx!.audioWorklet.addModule('transcription_worklet.js').toDart;

      _whisperWorker = web.Worker('whisper_worker.js'.toJS);
      _whisperWorker!.onmessage = ((web.MessageEvent e) {
        _handleWorkerMessage(e.data);
      }).toJS;

      _initialized = true;
      return true;
    } catch (e) {
      debugPrint('WebTranscriptionEngine: init failed: $e');
      return false;
    }
  }

  void _handleWorkerMessage(JSAny? data) {
    if (data == null) return;
    final str = data.toString();
    try {
      if (str.startsWith('{')) {
        final parsed = _parseJson(str);
        if (parsed == null) return;
        final type = parsed['type'] as String?;

        switch (type) {
          case 'progress':
            final progress = (parsed['progress'] as num?)?.toDouble() ?? 0.0;
            _modelLoadProgress = progress.clamp(0.0, 1.0);
            _progressController.add(_modelLoadProgress);
            break;
          case 'ready':
            _modelLoadProgress = 1.0;
            _progressController.add(1.0);
            break;
          case 'final':
            final text = parsed['text'] as String? ?? '';
            _finalResultController.add({'text': text});
            break;
          case 'error':
            debugPrint('WebTranscriptionEngine: worker error: ${parsed['error']}');
            break;
        }
      }
    } catch (e) {
      debugPrint('WebTranscriptionEngine: parse error: $e');
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
  void attachStreams(MediaStream localStream, MediaStream? remoteStream) {
    if (!_initialized || _ctx == null || _whisperWorker == null) return;
    if (_attached) return;

    try {
      final localStreamImpl = localStream as dynamic;
      if (localStreamImpl is MediaStreamWeb) {
        _attachSource(localStreamImpl.jsStream);
      }

      if (remoteStream != null) {
        final remoteStreamImpl = remoteStream as dynamic;
        if (remoteStreamImpl is MediaStreamWeb) {
          _attachSource(remoteStreamImpl.jsStream);
        }
      }

      _attached = true;
    } catch (e) {
      debugPrint('WebTranscriptionEngine: attachStreams failed: $e');
    }
  }

  void _attachSource(web.MediaStream jsStream) {
    if (_ctx == null) return;

    final source = _ctx!.createMediaStreamSource(jsStream);
    if (_worklet == null) {
      _worklet = web.AudioWorkletNode(_ctx!, 'transcription-processor');
      _dest = _ctx!.createMediaStreamDestination();

      _worklet!.port.onmessage = ((web.MessageEvent e) {
        _handleAudioChunk(e.data);
      }).toJS;

      _worklet!.connect(_dest!);
    }

    source.connect(_worklet!);

    if (_localSource == null) {
      _localSource = source;
    } else {
      _remoteSource = source;
    }
  }

  void _handleAudioChunk(JSAny? data) {
    if (_whisperWorker == null || data == null) return;

    try {
      final str = data.toString();
      if (!str.startsWith('{')) return;

      final parsed = _parseJson(str);
      if (parsed == null) return;
      if (parsed['type'] != 'chunk') return;

      final audioData = parsed['data'];
      if (audioData == null) return;

      final List<double> floatList;
      if (audioData is List) {
        floatList = audioData.map((e) => (e as num).toDouble()).toList();
      } else {
        return;
      }

      final message = {
        'type': 'transcribe',
        'audioData': floatList,
      };
      _whisperWorker!.postMessage(jsonEncode(message).toJS);
    } catch (e) {
      debugPrint('WebTranscriptionEngine: handleAudioChunk failed: $e');
    }
  }

  @override
  void stop() {
    try {
      _localSource?.disconnect();
      _remoteSource?.disconnect();
      _worklet?.disconnect();
      _localSource = null;
      _remoteSource = null;
      _worklet = null;
      _attached = false;
    } catch (e) {
      debugPrint('WebTranscriptionEngine: stop failed: $e');
    }
  }

  @override
  void dispose() {
    stop();
    _whisperWorker?.terminate();
    _whisperWorker = null;
    _ctx?.close();
    _ctx = null;
    _initialized = false;
    _partialResultController.close();
    _finalResultController.close();
    _progressController.close();
  }
}

TranscriptionEngine createTranscriptionEngine() => WebTranscriptionEngine();
