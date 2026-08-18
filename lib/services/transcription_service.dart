import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'resource_scheduler_service.dart';
import 'entitlement_service.dart';
import 'transcription_engine.dart';
import 'transcription_engine_stub.dart' if (dart.library.io) 'transcription_engine_native.dart';

export 'transcription_engine.dart';
export 'transcription_engine_stub.dart' if (dart.library.io) 'transcription_engine_native.dart';

enum TranscriptionStatus {
  idle,
  loading,
  ready,
  listening,
  paused,
  error,
}

class TranscriptSegment {
  final String text;
  final Duration timestamp;
  final String speaker;
  final bool isFinal;

  TranscriptSegment({
    required this.text,
    required this.timestamp,
    this.speaker = 'unknown',
    this.isFinal = false,
  });

  @override
  String toString() => '[$speaker] ${timestamp.inMinutes}:${(timestamp.inSeconds % 60).toString().padLeft(2, '0')} $text';
}

class TranscriptionService extends ChangeNotifier {
  TranscriptionStatus _status = TranscriptionStatus.idle;
  String _error = '';
  final List<TranscriptSegment> _segments = [];
  String _partialText = '';
  Timer? _chunkTimer;

  TranscriptionStatus get status => _status;
  String get error => _error;
  List<TranscriptSegment> get segments => List.unmodifiable(_segments);
  String get partialText => _partialText;
  String get fullTranscript => _segments.map((s) => s.text).join(' ');

  final ResourceSchedulerService _scheduler;
  bool _isWeb = kIsWeb;
  DateTime? _transcriptionStart;
  TranscriptionEngine? _engine;
  double _modelLoadProgress = 0.0;
  StreamSubscription? _partialSubscription;
  StreamSubscription? _finalSubscription;
  StreamSubscription? _progressSubscription;

  double get modelLoadProgress => _modelLoadProgress;

  TranscriptionService(this._scheduler, [this._entitlementService]);

  EntitlementService? _entitlementService;

  void setEntitlementService(EntitlementService? es) {
    _entitlementService = es;
  }

  Future<bool> initialize() async {
    if (_status == TranscriptionStatus.ready || _status == TranscriptionStatus.listening) {
      return true;
    }

    _status = TranscriptionStatus.loading;
    _error = '';
    notifyListeners();

    try {
      if (_isWeb) {
        _engine = createTranscriptionEngine();
        final ok = await _engine!.initialize();
        if (!ok) {
          _error = 'Failed to initialize web transcription engine';
          _status = TranscriptionStatus.error;
          notifyListeners();
          return false;
        }

        _progressSubscription = _engine!.onModelLoadProgress.listen((progress) {
          _modelLoadProgress = progress;
          notifyListeners();
        });

        _partialSubscription = _engine!.onPartialResult.listen((text) {
          _partialText = text;
          notifyListeners();
        });

        _finalSubscription = _engine!.onFinalResult.listen((result) {
          final text = result['text'] as String? ?? '';
          if (text.isNotEmpty) {
            final timestamp = Duration(
              seconds: _segments.isEmpty
                  ? 0
                  : _segments.last.timestamp.inSeconds + 2,
            );
            _segments.add(TranscriptSegment(
              text: text,
              timestamp: timestamp,
              speaker: 'unknown',
              isFinal: true,
            ));
          }
          _partialText = '';
          notifyListeners();
        });
      }

      _status = TranscriptionStatus.ready;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to initialize transcription: $e';
      _status = TranscriptionStatus.error;
      debugPrint('TranscriptionService: $_error');
      notifyListeners();
      return false;
    }
  }

  Future<bool> startTranscription(MediaStream? localStream, MediaStream? remoteStream) async {
    if (_status == TranscriptionStatus.listening) return true;

    if (_entitlementService != null) {
      final msg = _entitlementService!.transcriptionLimitMessage();
      if (msg != null) {
        _error = msg;
        _status = TranscriptionStatus.error;
        notifyListeners();
        return false;
      }
    }

    final acquired = await _scheduler.acquire(ResourceTask.transcription);
    if (!acquired) {
      _error = 'Cannot start transcription: resource conflict';
      _status = TranscriptionStatus.error;
      notifyListeners();
      return false;
    }

    if (_status != TranscriptionStatus.ready) {
      final initOk = await initialize();
      if (!initOk) return false;
    }

    _segments.clear();
    _partialText = '';
    _transcriptionStart = DateTime.now();
    _status = TranscriptionStatus.listening;
    notifyListeners();

    if (_isWeb && _engine != null) {
      _engine!.attachStreams(localStream!, remoteStream);
    }

    return true;
  }

  void stopTranscription() {
    if (_status != TranscriptionStatus.listening && _status != TranscriptionStatus.paused) {
      return;
    }

    _chunkTimer?.cancel();
    _chunkTimer = null;

    _scheduler.release(ResourceTask.transcription);

    if (_transcriptionStart != null) {
      final elapsed = DateTime.now().difference(_transcriptionStart!).inSeconds;
      _entitlementService?.recordTranscriptionSeconds(elapsed);
      _transcriptionStart = null;
    }

    if (_partialText.isNotEmpty) {
      _segments.add(TranscriptSegment(
        text: _partialText,
        timestamp: Duration(
            seconds: _segments.isEmpty ? 0 : _segments.last.timestamp.inSeconds + 2),
        speaker: 'unknown',
        isFinal: true,
      ));
      _partialText = '';
    }

    if (_isWeb) {
      _engine?.stop();
    }

    _status = TranscriptionStatus.ready;
    notifyListeners();
  }

  void pauseTranscription() {
    if (_status != TranscriptionStatus.listening) return;
    _chunkTimer?.cancel();
    _status = TranscriptionStatus.paused;
    notifyListeners();
  }

  void resumeTranscription() {
    if (_status != TranscriptionStatus.paused) return;
    _status = TranscriptionStatus.listening;
    notifyListeners();
  }

  void resetTranscript() {
    _segments.clear();
    _partialText = '';
    notifyListeners();
  }

  String exportTranscript() {
    final buffer = StringBuffer();
    for (final segment in _segments) {
      final mins = segment.timestamp.inMinutes;
      final secs = segment.timestamp.inSeconds % 60;
      final timestamp = '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
      buffer.writeln('[$timestamp] ${segment.speaker}: ${segment.text}');
    }
    return buffer.toString();
  }

  @override
  void dispose() {
    _chunkTimer?.cancel();
    _partialSubscription?.cancel();
    _finalSubscription?.cancel();
    _progressSubscription?.cancel();
    _engine?.dispose();
    if (_status == TranscriptionStatus.listening || _status == TranscriptionStatus.paused) {
      _scheduler.release(ResourceTask.transcription);
    }
    super.dispose();
  }
}
