import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/poi.dart';
import 'content_service.dart';

/// Generates narration text from POI facts using the Gemini API.
///
/// Uses gemini-2.0-flash via REST (no backend required).
/// Falls back to static [Poi.narrationText] on any error.
class AiService {
  final String apiKey;
  final ContentService _contentService;

  static const String _model = 'gemini-2.0-flash';

  // Correct endpoint: /v1beta/models/{model}:generateContent
  static String get _baseUrl =>
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent';

  AiService({required this.apiKey, ContentService? contentService})
      : _contentService = contentService ?? ContentService();

  /// Generate a narration for [poi] using Gemini.
  ///
  /// Returns the generated text, or falls back to static narration on error.
  Future<String> generateNarration(Poi poi) async {
    if (apiKey.isEmpty || apiKey == 'your_key_here') {
      // No API key — skip AI, use static text immediately
      return poi.narrationText;
    }

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
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {
                'temperature': 0.7,
                'maxOutputTokens': 300,
              },
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final text = _extractText(json);
        if (text != null && text.isNotEmpty) return text;
      }

      // Fall back to static narration idea
      return poi.narrationText;
    } catch (e) {
      // Network error, timeout, etc — fall back silently
      return poi.narrationText;
    }
  }

  String? _extractText(Map<String, dynamic> json) {
    try {
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final content = candidates[0]['content'] as Map<String, dynamic>?;
      if (content == null) return null;

      final parts = content['parts'] as List?;
      if (parts == null) return null;

      for (final part in parts) {
        final text = part['text'] as String?;
        if (text != null && text.isNotEmpty) return text.trim();
      }
    } catch (_) {}
    return null;
  }
}
