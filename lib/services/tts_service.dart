import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:http/http.dart' as http;


// dart:io is unavailable on web — import it conditionally
import 'tts_service_io.dart' if (dart.library.html) 'tts_service_web.dart'
    as platform;

/// Converts narration text to audio using the Gemini TTS REST API.
///
/// Returns either a file path (mobile/desktop) or a data URI (web).
/// The caller (AudioPlayerService) must handle both.
class TtsService {
  final String apiKey;

  static const List<String> _models = [
    'gemini-2.5-flash-preview-tts',
  ];

  static String _endpoint(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

  // A warm, clear voice suitable for an audio guide
  static const String _voice = 'Kore';

  TtsService({required this.apiKey});

  /// Deterministic 31-bit DJB2 hash of text content for cache validation.
  int _hashText(String text) {
    var hash = 5381;
    for (var i = 0; i < text.length; i++) {
      hash = ((hash << 5) + hash) + text.codeUnitAt(i);
      hash &= 0x7FFFFFFF;
    }
    return hash;
  }

  /// Convert [text] to audio.
  ///
  /// Returns a data URI on web (for use with AudioPlayer.setUrl),
  /// or a file path on native (for use with AudioPlayer.setFilePath).
  Future<String> synthesize(String text, String poiId) async {
    final textHash = _hashText(text);

    // Check disk cache first to avoid redundant API calls and enable offline / instant playback.
    // textHash ensures that if a POI's narration text was updated (e.g. from fallback to rich
    // Wikipedia research), the old fallback audio is never mistakenly reused.
    if (!kIsWeb) {
      final cached = await platform.getCachedTempWav(poiId, textHash: textHash);
      if (cached != null) {
        debugPrint('[TtsService] Using cached audio for $poiId: $cached');
        return cached;
      }
    }

    if (apiKey.isEmpty || apiKey == 'your_key_here') {
      throw Exception('Gemini API key not set — TTS unavailable.');
    }

    http.Response? lastResponse;
    String? lastError;

    for (final model in _models) {
      try {
        final response = await http
            .post(
              Uri.parse(_endpoint(model)),
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey,
              },
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {'text': text}
                    ]
                  }
                ],
                'generationConfig': {
                  'responseModalities': ['AUDIO'],
                  'speechConfig': {
                    'voiceConfig': {
                      'prebuiltVoiceConfig': {
                        'voiceName': _voice,
                      }
                    }
                  }
                },
              }),
            )
            .timeout(const Duration(seconds: 40));

        lastResponse = response;
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final audioBase64 = _extractAudio(json);

          if (audioBase64 == null || audioBase64.isEmpty) {
            continue;
          }

          final pcmBytes = base64Decode(audioBase64);
          final wavBytes = _wrapPcmInWav(pcmBytes);

          if (kIsWeb) {
            final base64Wav = base64Encode(wavBytes);
            return 'data:audio/wav;base64,$base64Wav';
          } else {
            return await platform.saveTempWav(wavBytes, poiId, textHash: textHash);
          }
        } else {
          lastError = 'TTS API error with $model ${response.statusCode}: ${response.body}';
        }
      } catch (e) {
        lastError = 'TTS exception with $model: $e';
      }
    }

    if (lastResponse != null) {
      throw Exception(
          'TTS API error ${lastResponse.statusCode}: ${lastResponse.body}');
    }
    throw Exception(lastError ?? 'TTS synthesis failed.');
  }

  String? _extractAudio(Map<String, dynamic> json) {
    try {
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final content = candidates[0]['content'] as Map<String, dynamic>?;
      if (content == null) return null;

      final parts = content['parts'] as List?;
      if (parts == null) return null;

      for (final part in parts) {
        final inlineData = part['inlineData'] as Map<String, dynamic>?;
        if (inlineData != null) {
          return inlineData['data'] as String?;
        }
      }
    } catch (e) {
      // ignore parse errors
    }
    return null;
  }

  /// Wrap raw PCM bytes (24kHz, 16-bit, mono) in a WAV header.
  Uint8List _wrapPcmInWav(
    Uint8List pcm, {
    int sampleRate = 24000,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    // Ensure even length for 16-bit PCM (2 bytes per sample)
    if (pcm.length.isOdd) {
      pcm = pcm.sublist(0, pcm.length - 1);
    }
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataLength = pcm.length;
    final totalLength = 44 + dataLength;

    final header = ByteData(44);
    // RIFF
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, totalLength - 8, Endian.little);
    header.setUint8(8, 0x57);  // W
    header.setUint8(9, 0x41);  // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    // fmt
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); //
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);  // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data
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
