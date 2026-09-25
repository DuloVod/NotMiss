import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Converts narration text to audio using Gemini TTS.
///
/// Returns the path to a .wav file ready for playback.
/// Uses gemini-3.1-flash-tts-preview via the interactions REST API.
class TtsService {
  final String apiKey;

  static const String _model = 'gemini-3.1-flash-tts-preview';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/interactions';

  // A warm, clear voice suitable for an audio guide
  static const String _voice = 'Kore';

  TtsService({required this.apiKey});

  /// Convert [text] to audio and return the path to the generated .wav file.
  ///
  /// Throws on unrecoverable errors.
  Future<String> synthesize(String text, String poiId) async {
    final response = await http
        .post(
          Uri.parse(_baseUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: jsonEncode({
            'model': _model,
            'input': text,
            'response_format': {'type': 'audio'},
            'generation_config': {
              'speech_config': [
                {'voice': _voice}
              ]
            },
            'store': false,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(
          'TTS API error ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final audioBase64 = _extractAudio(json);

    if (audioBase64 == null || audioBase64.isEmpty) {
      throw Exception('No audio data in TTS response');
    }

    final pcmBytes = base64Decode(audioBase64);
    final wavBytes = _wrapPcmInWav(pcmBytes);

    // Write to a temp file
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/narration_$poiId.wav');
    await file.writeAsBytes(wavBytes);
    return file.path;
  }

  String? _extractAudio(Map<String, dynamic> json) {
    try {
      final steps = json['steps'] as List?;
      if (steps == null) return null;

      for (final step in steps.reversed) {
        if (step['type'] == 'model_output') {
          final content = step['content'] as List?;
          if (content == null) continue;
          for (final part in content) {
            if (part['type'] == 'audio') {
              return part['data'] as String?;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Wrap raw PCM bytes (24kHz, 16-bit, mono) in a WAV header.
  Uint8List _wrapPcmInWav(
    Uint8List pcm, {
    int sampleRate = 24000,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataLength = pcm.length;
    final totalLength = 44 + dataLength;

    final header = ByteData(44);
    // RIFF header
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, totalLength - 8, Endian.little);
    header.setUint8(8, 0x57);  // W
    header.setUint8(9, 0x41);  // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    // fmt chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // space
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little);  // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataLength, Endian.little);

    final result = Uint8List(totalLength);
    result.setAll(0, header.buffer.asUint8List());
    result.setAll(44, pcm);
    return result;
  }
}
