import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/poi.dart';
import 'content_service.dart';

/// Generates narration text from POI facts using the Gemini API.
///
/// Uses gemini-3.8-flash via REST (no backend required).
/// Called in M4 to replace static [Poi.narrationText].
class AiService {
  final String apiKey;
  final ContentService _contentService;

  static const String _model = 'gemini-3.8-flash';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/interactions';

  AiService({required this.apiKey, ContentService? contentService})
      : _contentService = contentService ?? ContentService();

  /// Generate a narration for [poi] using Gemini.
  ///
  /// Returns the generated text, or falls back to static narration on error.
  Future<String> generateNarration(Poi poi) async {
    final prompt = _contentService.buildAiPrompt(poi);

    try {
      final response = await http
          .post(
            Uri.parse(_baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode({
              'model': _model,
              'input': prompt,
              'store': false,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final text = _extractText(json);
        if (text != null && text.isNotEmpty) return text;
      }

      // Fall back to static text
      return poi.narrationText;
    } catch (e) {
      // Network error, timeout, etc — fall back silently
      return poi.narrationText;
    }
  }

  String? _extractText(Map<String, dynamic> json) {
    try {
      final steps = json['steps'] as List?;
      if (steps == null) return null;

      // Find the last model_output step
      for (final step in steps.reversed) {
        if (step['type'] == 'model_output') {
          final content = step['content'] as List?;
          if (content == null) continue;
          for (final part in content) {
            if (part['type'] == 'text') {
              return (part['text'] as String?)?.trim();
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
