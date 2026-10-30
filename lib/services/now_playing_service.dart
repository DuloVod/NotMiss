import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lock-screen / Control Center "Now Playing" card and headphone buttons (iOS).
///
/// Shows the name of the place that is being narrated and forwards the remote commands
/// (play, pause, previous = replay, next = skip) back to the walk controller. Implemented
/// natively in AppDelegate.swift; on other platforms every call is a no-op.
class NowPlayingService {
  static const _channel = MethodChannel('com.dulo.notmiss/now_playing');

  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onReplay;
  VoidCallback? onSkip;
  VoidCallback? onToggle;

  final bool _enabled;

  /// Whether the system "Now Playing" card is published. Off: the Live Activity is the one
  /// lock-screen block (with its own buttons); headphone / remote commands keep working.
  static const bool publishSystemCard = false;

  NowPlayingService({bool? enabled})
      : _enabled = enabled ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    if (_enabled) _channel.setMethodCallHandler(_onCall);
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'command') handleCommand(call.arguments as String? ?? '');
  }

  /// Entry point for remote commands (also used by tests).
  @visibleForTesting
  void handleCommand(String command) {
    switch (command) {
      case 'play':
        onPlay?.call();
      case 'pause':
        onPause?.call();
      case 'replay':
        onReplay?.call();
      case 'skip':
        onSkip?.call();
      case 'toggle':
        onToggle?.call();
    }
  }

  Future<void> update({
    required String title,
    String subtitle = 'NotMiss',
    required bool playing,
    Duration elapsed = Duration.zero,
    Duration? duration,
  }) async {
    if (!_enabled || !publishSystemCard) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'subtitle': subtitle,
        'playing': playing,
        'elapsed': elapsed.inMilliseconds / 1000.0,
        'duration': duration == null ? 0.0 : duration.inMilliseconds / 1000.0,
      });
    } catch (_) {}
  }

  Future<void> clear() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('clear');
    } catch (_) {}
  }
}
