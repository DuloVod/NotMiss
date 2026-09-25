import 'package:just_audio/just_audio.dart';

/// Plays audio files through the device speaker/headphones.
///
/// Wraps just_audio with simple play/stop semantics.
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  bool get isPlaying => _player.playing;

  /// Play the audio file at [filePath].
  ///
  /// Stops any currently playing audio first.
  Future<void> play(String filePath) async {
    await _player.stop();
    await _player.setFilePath(filePath);
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
