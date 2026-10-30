import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:just_audio/just_audio.dart';
import 'audio_session_guard.dart';

/// Detects a player that claims to play but makes no progress (e.g. the iOS audio session
/// could not be activated in the background): without it the narration would wait forever
/// and block every following point.
class StallDetector {
  final Duration limit;
  Duration? _lastPosition;
  DateTime? _since;

  StallDetector({this.limit = const Duration(seconds: 15)});

  /// True once [playing] has stayed true for [limit] without the position moving.
  bool observe({required bool playing, required Duration position, required DateTime now}) {
    if (!playing || _lastPosition != position) {
      _lastPosition = position;
      _since = now;
      return false;
    }
    return now.difference(_since!) >= limit;
  }
}

/// Plays audio through the device speaker/headphones.
///
/// Accepts either:
///   - A file path (native: iOS, Android, macOS) — uses setFilePath()
///   - A data URI "data:audio/wav;base64,..." (web) — uses setUrl()
///   - An https:// URL — uses setUrl()
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  final AudioSessionGuard _session;

  AudioPlayerService({AudioSessionGuard? sessionGuard})
      : _session = sessionGuard ?? AudioSessionGuard();

  /// Configure the audio session early (foreground) — see [AudioSessionGuard.prepare].
  Future<void> prepareSession() => _session.prepare();

  bool get isPlaying =>
      _player.playing &&
      _player.processingState != ProcessingState.completed &&
      _player.processingState != ProcessingState.idle;

  bool get isPaused =>
      !_player.playing &&
      _player.processingState == ProcessingState.ready;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  bool _cueNext = false;
  int _stopToken = 0;

  /// The next [play] starts with a short soft chime ("you are at a place"), so the
  /// voice never cuts in abruptly. One-shot; plays inside the same audio session as the
  /// narration, so other apps' audio is not un-ducked in between.
  void armArrivalCue() => _cueNext = true;

  static const _chimeAsset = 'assets/audio/arrival_chime.wav';

  Future<void> _playChime() async {
    try {
      await _player.setAsset(_chimeAsset);
      _player.play();
      await _player.playerStateStream
          .firstWhere((state) =>
              state.processingState == ProcessingState.completed ||
              state.processingState == ProcessingState.idle)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // The cue is a nicety: never let it block the narration.
    }
  }

  /// Play audio from [source].
  ///
  /// [source] can be a file path or a data/https URI.
  /// Returns when playback completes, is stopped, or is interrupted by another play().
  Future<void> play(String source) => _session.around(() async {
        final token = _stopToken;
        await _player.stop();

        if (_cueNext) {
          _cueNext = false;
          await _playChime();
          if (token != _stopToken) return; // stopped / skipped during the chime
        }

        if (kIsWeb || source.startsWith('data:') || source.startsWith('http')) {
          await _player.setUrl(source);
        } else {
          await _player.setFilePath(source);
        }

        _player.play(); // Do not await this future directly

        // Watchdog: a player that "plays" without moving (session not active, route lost)
        // is stopped, so the narration queue can never hang.
        final stall = StallDetector();
        final watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
          if (stall.observe(
              playing: _player.playing, position: _player.position, now: DateTime.now())) {
            debugPrint('[AudioPlayerService] playback stalled — stopping');
            _player.stop();
          }
        });

        // Wait for playback to complete, stop, or idle.
        // Also handles pause → stop scenario: when paused, processingState stays
        // `ready`, so we don't hang. We complete on completed/idle only.
        try {
          await _player.playerStateStream.firstWhere((state) =>
              state.processingState == ProcessingState.completed ||
              state.processingState == ProcessingState.idle);
        } finally {
          watchdog.cancel();
        }

        // Cleanly reset player when playback reaches completion naturally
        try {
          await _player.stop();
        } catch (_) {}
      });

  /// Pause playback.
  Future<void> pause() async {
    await _player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await _player.play();
  }

  /// Stop playback.
  Future<void> stop() async {
    _stopToken++;
    _cueNext = false;
    await _player.stop();
  }

  void dispose() {
    _player.dispose();
  }
}
