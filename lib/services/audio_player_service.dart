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

  /// Play audio from [source].
  ///
  /// [source] can be a file path or a data/https URI.
  Future<void> play(String source) async {
    await _player.stop();

    if (kIsWeb || source.startsWith('data:') || source.startsWith('http')) {
      // Web or URL: use setUrl (supports data URIs in just_audio_web)
      await _player.setUrl(source);
    } else {
      // Native: use file path
      await _player.setFilePath(source);
    }

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
