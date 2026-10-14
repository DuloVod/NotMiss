import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';

/// Plays audio through the device speaker/headphones.
///
/// Accepts either:
///   - A file path (native: iOS, Android, macOS) — uses setFilePath()
///   - A data URI "data:audio/wav;base64,..." (web) — uses setUrl()
///   - An https:// URL — uses setUrl()
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  bool get isPlaying => _player.playing;

  bool get isPaused =>
      !_player.playing &&
      _player.processingState == ProcessingState.ready;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  /// Play audio from [source].
  ///
  /// [source] can be a file path or a data/https URI.
  /// Returns when playback completes, is stopped, or is interrupted by another play().
  Future<void> play(String source) async {
    await _player.stop();

    if (kIsWeb || source.startsWith('data:') || source.startsWith('http')) {
      await _player.setUrl(source);
    } else {
      await _player.setFilePath(source);
    }

    _player.play(); // Do not await this future directly

    // Wait for playback to complete, stop, or idle.
    // Also handles pause → stop scenario: when paused, processingState stays
    // `ready`, so we don't hang. We complete on completed/idle only.
    await _player.playerStateStream.firstWhere((state) =>
        state.processingState == ProcessingState.completed ||
        state.processingState == ProcessingState.idle);
  }

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
    await _player.stop();
  }

  void dispose() {
    _player.dispose();
  }
}
