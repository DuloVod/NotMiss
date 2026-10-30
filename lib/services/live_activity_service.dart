import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the always-on "Live Activity" (lock screen + Dynamic Island, like Google Maps
/// navigation) shows while a walk is running.
@immutable
class GuideLiveState {
  /// Main line: the place being narrated, or the nearest place.
  final String title;

  /// Second line: "Далі: Фонтан · 85 м", the kind of place, or a calm hint.
  final String subtitle;

  /// Very short text for the Dynamic Island, e.g. "85 м".
  final String badge;

  /// "Speaking" mode: a narration is being prepared, played or paused.
  final bool speaking;

  /// The narration is paused.
  final bool paused;

  /// Pause and next/stop buttons are shown (only while a narration is audible or paused).
  final bool controls;

  /// "Next" starts another narration; otherwise the button stops this one.
  final bool canSkipNext;

  const GuideLiveState({
    required this.title,
    required this.subtitle,
    this.badge = '',
    this.speaking = false,
    this.paused = false,
    this.controls = false,
    this.canSkipNext = false,
  });

  @override
  bool operator ==(Object other) =>
      other is GuideLiveState &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.badge == badge &&
      other.speaking == speaking &&
      other.paused == paused &&
      other.controls == controls &&
      other.canSkipNext == canSkipNext;

  @override
  int get hashCode => Object.hash(title, subtitle, badge, speaking, paused, controls, canSkipNext);

  @override
  String toString() => 'GuideLiveState($title | $subtitle | $badge | speaking=$speaking)';
}

/// iOS Live Activity bridge (ActivityKit, implemented in AppDelegate.swift + the
/// NotMissLiveActivity widget extension). No-op on other platforms and on iOS < 16.2.
class LiveActivityService {
  static const _channel = MethodChannel('com.dulo.notmiss/live_activity');

  final bool _enabled;

  LiveActivityService({bool? enabled})
      : _enabled = enabled ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  /// Starts the activity, or updates it when it is already running.
  Future<void> show(GuideLiveState state) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('show', {
        'title': state.title,
        'subtitle': state.subtitle,
        'badge': state.badge,
        'speaking': state.speaking,
        'paused': state.paused,
        'controls': state.controls,
        'canSkipNext': state.canSkipNext,
      });
    } catch (_) {}
  }

  Future<void> end() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('end');
    } catch (_) {}
  }
}
