import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/enriched_poi.dart';

/// A task in the research queue.
class ResearchTask {
  final String poiId;
  final ResearchPriority priority;
  final Completer<void> completer;
  int retryCount;

  ResearchTask({
    required this.poiId,
    required this.priority,
    this.retryCount = 0,
  }) : completer = Completer<void>();
}

/// Priority research queue with concurrency limits.
///
/// Manages research tasks for POIs, ensuring:
/// - Maximum concurrent tasks (default: 2)
/// - Priority ordering (HIGH before MEDIUM before LOW)
/// - Deduplication (no duplicate tasks for same POI)
/// - Retry limits (max 3 retries per POI)
class ResearchQueue {
  final int maxConcurrent;
  final int maxRetries;

  final Queue<ResearchTask> _queue = Queue();
  final Set<String> _activeIds = {};
  final Set<String> _queuedIds = {};
  int _runningCount = 0;
  bool _disposed = false;

  /// Callback to execute when a task is ready to process.
  Future<void> Function(String poiId)? onProcess;

  ResearchQueue({
    this.maxConcurrent = 2,
    this.maxRetries = 3,
  });

  /// Get the 1-based position of a POI in the queue. 
  /// Returns 0 if currently processing, -1 if not in queue.
  int getQueuePosition(String poiId) {
    if (_activeIds.contains(poiId)) return 0;
    if (!_queuedIds.contains(poiId)) return -1;
    
    int index = 1;
    for (final task in _queue) {
      if (task.poiId == poiId) return index;
      index++;
    }
    return -1;
  }

  /// Add a POI to the research queue.
  ///
  /// If [bump] is true and the POI is already queued, its priority will be
  /// upgraded to [priority] (if higher) and moved forward in the queue.
  bool enqueue(String poiId, ResearchPriority priority, {bool bump = false}) {
    if (_activeIds.contains(poiId)) {
      return false;
    }

    if (_queuedIds.contains(poiId)) {
      if (!bump) return false;
      // Remove existing task to re-insert it with upgraded priority
      final existingTask = _queue.firstWhere((t) => t.poiId == poiId);
      // Lower index means higher priority (high=0, medium=1, low=2)
      if (priority.index > existingTask.priority.index) {
        priority = existingTask.priority; // keep the existing higher priority
      }
      _queue.remove(existingTask);
    } else {
      _queuedIds.add(poiId);
    }

    final task = ResearchTask(poiId: poiId, priority: priority);

    // Insert in priority order (high first, i.e. lower index first)
    bool inserted = false;
    final list = _queue.toList();
    for (var i = 0; i < list.length; i++) {
      if (priority.index < list[i].priority.index) {
        list.insert(i, task);
        inserted = true;
        break;
      }
    }
    if (!inserted) list.add(task);

    _queue.clear();
    _queue.addAll(list);

    _processNext();
    return true;
  }

  /// Number of tasks waiting in queue.
  int get pendingCount => _queue.length;

  /// Number of tasks currently being processed.
  int get activeCount => _runningCount;

  /// Whether the queue is idle (no pending or active tasks).
  bool get isIdle => _queue.isEmpty && _runningCount == 0;

  /// Clear the queue (does not cancel active tasks).
  void clear() {
    _queue.clear();
    _queuedIds.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  void _processNext() {
    while (_runningCount < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _queuedIds.remove(task.poiId);
      _activeIds.add(task.poiId);
      _runningCount++;

      _executeTask(task);
    }
  }

  Future<void> _executeTask(ResearchTask task) async {
    try {
      if (onProcess != null) {
        await onProcess!(task.poiId);
      }
      task.completer.complete();
    } catch (e) {
      debugPrint('[ResearchQueue] Task failed for ${task.poiId}: $e');
      task.retryCount++;

      if (task.retryCount < maxRetries) {
        // Re-enqueue with exponential backoff delay
        final delay = Duration(seconds: task.retryCount * task.retryCount * 5);
        debugPrint('[ResearchQueue] Retrying ${task.poiId} in ${delay.inSeconds}s '
            '(attempt ${task.retryCount + 1}/$maxRetries)');

        Future.delayed(delay, () {
          if (_disposed) return;
          _queuedIds.add(task.poiId);
          _queue.addLast(task);
          _processNext();
        });
      } else {
        debugPrint('[ResearchQueue] Max retries reached for ${task.poiId}');
        if (!task.completer.isCompleted) {
          task.completer.complete(); // Complete normally — error already logged
        }
      }
    } finally {
      _activeIds.remove(task.poiId);
      _runningCount--;
      _processNext();
    }
  }
}
