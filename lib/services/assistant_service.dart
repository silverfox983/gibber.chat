import 'dart:async';
import 'package:flutter/foundation.dart';
import 'transcription_service.dart';
import 'resource_scheduler_service.dart';
import 'entitlement_service.dart';

enum AssistantStatus {
  idle,
  loading,
  ready,
  generating,
  error,
}

class AssistantMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  AssistantMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class AssistantService extends ChangeNotifier {
  AssistantStatus _status = AssistantStatus.idle;
  String _error = '';
  final List<AssistantMessage> _messages = [];
  String _partialResponse = '';
  Object? _llmInstance;
  bool _isWeb = kIsWeb;

  AssistantStatus get status => _status;
  String get error => _error;
  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  String get partialResponse => _partialResponse;

  final ResourceSchedulerService _scheduler;
  final TranscriptionService? _transcriptionService;

  AssistantService(this._scheduler, [this._transcriptionService]);

  EntitlementService? _entitlementService;

  void setEntitlementService(EntitlementService? es) {
    _entitlementService = es;
  }


  Future<bool> initialize() async {
    if (_status == AssistantStatus.ready || _status == AssistantStatus.generating) {
      return true;
    }

    _status = AssistantStatus.loading;
    _error = '';
    notifyListeners();

    try {
      if (_isWeb) {
        _llmInstance = await _initLlmWeb();
      } else {
        _llmInstance = await _initLlmNative();
      }

      _status = AssistantStatus.ready;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to initialize AI assistant: $e';
      _status = AssistantStatus.error;
      debugPrint('AssistantService: $_error');
      notifyListeners();
      return false;
    }
  }

  Future<dynamic> _initLlmWeb() async {
    debugPrint('AssistantService: Initializing Web LLM (lazy-load)');
    return true;
  }

  Future<dynamic> _initLlmNative() async {
    debugPrint('AssistantService: Native LLM not yet implemented');
    return null;
  }

  String _buildContext() {
    final buffer = StringBuffer();
    buffer.writeln('=== Call Context ===');
    buffer.writeln('Time: ${DateTime.now().toIso8601String()}');

    if (_transcriptionService != null && _transcriptionService!.segments.isNotEmpty) {
      buffer.writeln('\n=== Recent Transcript ===');
      final recent = _transcriptionService!.segments.length > 20
          ? _transcriptionService!.segments.sublist(
              _transcriptionService!.segments.length - 20)
          : _transcriptionService!.segments;
      for (final segment in recent) {
        buffer.writeln('[${segment.speaker}] ${segment.text}');
      }
    }

    if (_messages.isNotEmpty) {
      buffer.writeln('\n=== Previous Q&A ===');
      for (final msg in _messages.take(10)) {
        buffer.writeln('${msg.isUser ? "User" : "Assistant"}: ${msg.text}');
      }
    }

    return buffer.toString();
  }

  Future<String> ask(String query) async {
    if (_entitlementService != null) {
      final msg = _entitlementService!.aiLimitMessage();
      if (msg != null) {
        return msg;
      }
    }

    if (_status != AssistantStatus.ready && _status != AssistantStatus.generating) {
      final initOk = await initialize();
      if (!initOk) return 'Assistant not available. Please try again later.';
    }

    final acquired = await _scheduler.acquire(ResourceTask.llmQuery);
    if (!acquired) {
      return 'Assistant busy. A call or transcription is using resources. Try again in a moment.';
    }

    try {
      _entitlementService?.recordAIQuery();
      _messages.add(AssistantMessage(text: query, isUser: true));
      _status = AssistantStatus.generating;
      _partialResponse = '';
      notifyListeners();

      final context = _buildContext();
      final response = await _generateResponse(query, context);

      _messages.add(AssistantMessage(text: response, isUser: false));
      _partialResponse = '';
      _status = AssistantStatus.ready;
      notifyListeners();

      return response;
    } catch (e) {
      _error = 'Failed to generate response: $e';
      _status = AssistantStatus.ready;
      notifyListeners();
      return 'Sorry, I encountered an error. Please try again.';
    } finally {
      _scheduler.release(ResourceTask.llmQuery);
    }
  }

  Future<String> _generateResponse(String query, String context) async {
    if (_llmInstance == null) {
      return _simulateResponse(query);
    }

    return _simulateResponse(query);
  }

  String _simulateResponse(String query) {
    final q = query.toLowerCase();

    if (q.contains('summar')) {
      return _simulateSummary();
    } else if (q.contains('action') || q.contains('todo') || q.contains('follow')) {
      return _simulateActionItems();
    } else if (q.contains('decide') || q.contains('agree')) {
      return 'Based on the call context, the key decisions made were: (1) Continue with the current approach, (2) Follow up on pending items by end of week.';
    } else if (q.contains('hello') || q.contains('hi') || q.contains('hey')) {
      return 'Hi! I\'m Gibber AI, your call assistant. I can summarize the call, list action items, draft follow-ups, or answer questions about what\'s been discussed. What would you like help with?';
    } else {
      return 'I can help with: summarizing the call, listing action items, drafting follow-up messages, or answering questions about the discussion. What would you like me to do?';
    }
  }

  String _simulateSummary() {
    if (_transcriptionService != null && _transcriptionService!.segments.isNotEmpty) {
      final count = _transcriptionService!.segments.length;
      final speakers = _transcriptionService!.segments.map((s) => s.speaker).toSet();
      return 'Call summary ($count transcript segments, $speakers participants): The discussion covered the main topics on the agenda. Key points were raised and addressed. A follow-up is planned.';
    }
    return 'No transcript available yet. Start transcription first, then I can provide a summary of the call.';
  }

  String _simulateActionItems() {
    return 'Action items identified:\n1. Follow up on discussion points\n2. Send meeting notes to participants\n3. Schedule next call to review progress';
  }

  Future<String> summarizeCall() => ask('Summarize the call so far');
  Future<String> listActionItems() => ask('List action items from the call');
  Future<String> draftFollowUp() => ask('Draft a follow-up message based on the call');

  void clearMessages() {
    _messages.clear();
    _partialResponse = '';
    notifyListeners();
  }

  @override
  void dispose() {
    if (_status == AssistantStatus.generating) {
      _scheduler.release(ResourceTask.llmQuery);
    }
    super.dispose();
  }
}