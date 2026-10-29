import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:just_audio/just_audio.dart';

/// Plays audio through the device speaker/headphones.
///
/// Accepts either:
///   - A file path (native: iOS, Android, macOS) — uses setFilePath()
///   - A data URI "data:audio/wav;base64,..." (web) — uses setUrl()
///   - An https:// URL — uses setUrl()
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  bool _sessionConfigured = false;
  int _playGen = 0;

  /// Configures the platform audio session for a spoken-word guide: category
  /// `playback` (keeps playing with the screen locked / app in background and ignores
  /// the silent switch), ducking other audio while narrating. Safe to call repeatedly;
  /// call it early (in the foreground) so iOS already has the right category when the
  /// app moves to the background.
  Future<void> prepareSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      if (!_sessionConfigured) {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ));
        _sessionConfigured = true;
      }
    } catch (e) {
      debugPrint('[AudioPlayerService] prepareSession failed: $e');
    }
  }

  /// Activates the session right before playback (works from the background thanks to
  /// the `audio` background mode).
  Future<void> _activateSession() async {
    if (kIsWeb) return;
    await prepareSession();
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      debugPrint('[AudioPlayerService] activate session failed: $e');
    }
  }

  /// Releases the session so music that was ducked gets its volume back.
  Future<void> _deactivateSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }

  bool get isPlaying =>
      _player.playing &&
      _player.processingState != ProcessingState.completed &&
      _player.processingState != ProcessingState.idle;

  bool get isPaused =>
      !_player.playing &&
      _player.processingState == ProcessingState.ready;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  /// Play audio from [source].
  ///
  /// [source] can be a file path or a data/https URI.
  /// Returns when playback completes, is stopped, or is interrupted by another play().
  Future<void> play(String source) async {
    final gen = ++_playGen;
    await _player.stop();
    await _activateSession();

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

    // Cleanly reset player when playback reaches completion naturally
    try {
      await _player.stop();
    } catch (_) {}
    // Only the latest play() may release the session, otherwise a superseded call would
    // deactivate the session under the narration that replaced it.
    if (gen == _playGen) await _deactivateSession();
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
