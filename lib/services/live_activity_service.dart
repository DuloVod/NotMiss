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

  /// A narration is playing / paused right now.
  final bool speaking;

  const GuideLiveState({
    required this.title,
    required this.subtitle,
    this.badge = '',
    this.speaking = false,
  });

  @override
  bool operator ==(Object other) =>
      other is GuideLiveState &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.badge == badge &&
      other.speaking == speaking;

  @override
  int get hashCode => Object.hash(title, subtitle, badge, speaking);

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
