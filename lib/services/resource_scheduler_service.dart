import 'dart:async';
import 'package:flutter/foundation.dart';

enum ResourceTask {
  webrtcCall,
  transcription,
  llmQuery,
  miner,
}

enum TaskPriority {
  critical,
  high,
  medium,
  low,
}

extension ResourceTaskPriority on ResourceTask {
  TaskPriority get priority {
    switch (this) {
      case ResourceTask.webrtcCall:
        return TaskPriority.critical;
      case ResourceTask.transcription:
        return TaskPriority.high;
      case ResourceTask.llmQuery:
        return TaskPriority.medium;
      case ResourceTask.miner:
        return TaskPriority.low;
    }
  }

  String get label {
    switch (this) {
      case ResourceTask.webrtcCall:
        return 'WebRTC Call';
      case ResourceTask.transcription:
        return 'Transcription';
      case ResourceTask.llmQuery:
        return 'LLM Query';
      case ResourceTask.miner:
        return 'Miner';
    }
  }
}

class ResourceSchedulerService extends ChangeNotifier {
  final Set<ResourceTask> _activeTasks = {};
  double _minerCpuCap = 0.3;
  bool _minerConsent = false;

  Set<ResourceTask> get activeTasks => Set.unmodifiable(_activeTasks);
  double get minerCpuCap => _minerCpuCap;
  bool get minerConsent => _minerConsent;

  bool get isCallActive => _activeTasks.contains(ResourceTask.webrtcCall);
  bool get isTranscriptionActive =>
      _activeTasks.contains(ResourceTask.transcription);
  bool get isLlmQueryActive => _activeTasks.contains(ResourceTask.llmQuery);
  bool get isMinerActive => _activeTasks.contains(ResourceTask.miner);

  bool canRun(ResourceTask task) {
    switch (task) {
      case ResourceTask.webrtcCall:
        return true;
      case ResourceTask.transcription:
        if (_activeTasks.contains(ResourceTask.llmQuery)) return false;
        return true;
      case ResourceTask.llmQuery:
        if (_activeTasks.contains(ResourceTask.transcription)) return false;
        return true;
      case ResourceTask.miner:
        if (_activeTasks.contains(ResourceTask.webrtcCall)) return false;
        if (_activeTasks.contains(ResourceTask.transcription)) return false;
        if (_activeTasks.contains(ResourceTask.llmQuery)) return false;
        if (!_minerConsent) return false;
        return true;
    }
  }

  Future<bool> acquire(ResourceTask task) async {
    if (!canRun(task)) return false;
    _activeTasks.add(task);
    _handlePriorityConflicts(task);
    notifyListeners();
    debugPrint(
        'ResourceScheduler: $task acquired. Active: $_activeTasks');
    return true;
  }

  void release(ResourceTask task) {
    _activeTasks.remove(task);
    notifyListeners();
    debugPrint(
        'ResourceScheduler: $task released. Active: $_activeTasks');

    _notifyWaitingTasks();
  }

  Future<bool> acquireMiner() async {
    if (!_minerConsent) return false;
    return acquire(ResourceTask.miner);
  }

  void setMinerCpuCap(double cap) {
    _minerCpuCap = cap.clamp(0.1, 0.8);
    notifyListeners();
  }

  void setMinerConsent(bool consent) {
    _minerConsent = consent;
    if (!consent && _activeTasks.contains(ResourceTask.miner)) {
      release(ResourceTask.miner);
    }
    notifyListeners();
  }

  void _handlePriorityConflicts(ResourceTask newlyActive) {
    switch (newlyActive) {
      case ResourceTask.webrtcCall:
        if (_activeTasks.contains(ResourceTask.miner)) {
          _activeTasks.remove(ResourceTask.miner);
          _minerSuspendController.add(true);
          debugPrint('ResourceScheduler: Miner suspended for call');
        }
        break;
      case ResourceTask.transcription:
        if (_activeTasks.contains(ResourceTask.miner)) {
          _activeTasks.remove(ResourceTask.miner);
          _minerSuspendController.add(true);
          debugPrint(
              'ResourceScheduler: Miner suspended for transcription');
        }
        break;
      case ResourceTask.llmQuery:
        if (_activeTasks.contains(ResourceTask.miner)) {
          _activeTasks.remove(ResourceTask.miner);
          _minerSuspendController.add(true);
          debugPrint('ResourceScheduler: Miner suspended for LLM');
        }
        break;
      case ResourceTask.miner:
        break;
    }
  }

  final StreamController<bool> _minerSuspendController =
      StreamController<bool>.broadcast();

  Stream<bool> get onMinerSuspended => _minerSuspendController.stream;

  Stream<bool> get onMinerResumed =>
      _minerResumeController.stream;
  final StreamController<bool> _minerResumeController =
      StreamController<bool>.broadcast();

  void _notifyWaitingTasks() {
    if (canRun(ResourceTask.miner) && _minerConsent) {
      _minerResumeController.add(true);
      debugPrint('ResourceScheduler: Miner can resume');
    }
  }

  @override
  void dispose() {
    _minerSuspendController.close();
    _minerResumeController.close();
    super.dispose();
  }
}