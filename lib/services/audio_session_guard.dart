import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

/// Thin seam over the platform audio session so the lifecycle logic can be tested.
abstract class SessionAdapter {
  Future<void> configure();
  Future<void> setActive(bool active);
}

/// Real implementation: category `playback` + mode `spokenAudio` (keeps narrating with the
/// screen locked / app in background, ignores the silent switch), ducking other audio.
class PlatformSessionAdapter implements SessionAdapter {
  /// iOS: NO `duckOthers` / `mixWithOthers`. Those options make the session "mixable", and iOS
  /// never shows a mixable session as the Now Playing app — the lock-screen player (pause,
  /// replay, skip, place name) would not appear. Other audio is paused during a narration
  /// and resumes afterwards (the session deactivation notifies the other apps).
  static const AudioSessionConfiguration configuration = AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionMode: AVAudioSessionMode.spokenAudio,
    // Lets the paused music app resume once the narration is over.
    avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.media,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidWillPauseWhenDucked: false,
  );

  @override
  Future<void> configure() async {
    final session = await AudioSession.instance;
    await session.configure(configuration);
  }

  @override
  Future<void> setActive(bool active) async {
    final session = await AudioSession.instance;
    await session.setActive(active);
  }
}

/// Owns the session lifecycle around one playback:
/// configure once → activate → run playback → deactivate (un-duck other audio).
///
/// Only the most recent playback may deactivate, so a superseded narration finishing late
/// never switches the session off under the one that replaced it. Adapter failures are
/// logged and never prevent playback; the deactivation also runs when playback throws.
class AudioSessionGuard {
  final SessionAdapter _adapter;
  final bool _enabled;
  bool _configured = false;
  int _gen = 0;

  AudioSessionGuard({SessionAdapter? adapter, bool? enabled})
      : _adapter = adapter ?? PlatformSessionAdapter(),
        _enabled = enabled ?? !kIsWeb;

  /// Configure the category. Call early, in the foreground, so iOS already has the right
  /// category when the app moves to the background. Safe to call repeatedly.
  Future<void> prepare() async {
    if (!_enabled || _configured) return;
    try {
      await _adapter.configure();
      _configured = true;
    } catch (e) {
      debugPrint('[AudioSessionGuard] configure failed: $e');
    }
  }

  Future<T> around<T>(Future<T> Function() playback) async {
    final gen = ++_gen;
    if (_enabled) {
      await prepare();
      try {
        await _adapter.setActive(true);
      } catch (e) {
        debugPrint('[AudioSessionGuard] activate failed: $e');
      }
    }
    try {
      return await playback();
    } finally {
      if (_enabled && gen == _gen) {
        try {
          await _adapter.setActive(false);
        } catch (_) {}
      }
    }
  }
}
