import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import '../models/poi.dart';
import 'content_service.dart';

/// Generates narration text and facts for POIs using the Gemini API.
class AiService {
  final String apiKey;
  final ContentService _contentService;

  static const List<String> _models = [
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-3.5-flash-lite',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  static String _endpoint(String model, String apiKey) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

  AiService({required this.apiKey, ContentService? contentService})
      : _contentService = contentService ?? ContentService();

  /// Generate a narration for [poi] using Gemini.
  Future<String> generateNarration(Poi poi) async {
    if (apiKey.isEmpty || apiKey == 'your_key_here') {
      return poi.narrationText;
    }

    final prompt = _contentService.buildAiPrompt(poi);

    for (final model in _models) {
      try {
        final response = await http
            .post(
              Uri.parse(_endpoint(model, apiKey)),
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
                  'maxOutputTokens': 500,
                },
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final text = _extractText(json);
          if (text != null && text.isNotEmpty) return text;
        } else {
          debugPrint('[AiService] generateNarration with $model failed: ${response.statusCode} -> ${response.body}');
        }
      } catch (e) {
        debugPrint('[AiService] generateNarration error ($model): $e');
      }
    }

    return poi.narrationText;
  }

  /// Use AI to generate an audio narration, short description, and facts for a POI.
  Future<Map<String, dynamic>?> generateBackgroundFacts(
      String name, String category, Map<String, String> tags) async {
    if (apiKey.isEmpty || apiKey == 'your_key_here') return null;

    final tagsContext = tags.entries.map((e) => '${e.key}=${e.value}').join(', ');
    final prompt = '''
Ти — досвідчений, захопливий аудіогід для пішої прогулянки.
Об'єкт на мапі:
Назва: "$name"
Категорія: "$category"
Теги OpenStreetMap: $tagsContext

Підготуй для туриста інформацію українською мовою:
1. "narration": захопливий текст для озвучення аудіогідом на 30–45 секунд (живий, атмосферний стиль від другої особи: "Перед вами...", "Погляньте на...", розмовний стиль для вух, без списків).
2. "description": короткий змістовний опис (1–2 красивих речення українською: що це за місце).
3. "facts": 3 цікавих факти про нього (архітектура, рік, значення для міста).

Формат відповіді СТРОГО валідний JSON:
{
  "narration": "...",
  "description": "...",
  "facts": ["...", "...", "..."]
}
''';

    for (final model in _models) {
      try {
        final response = await http.post(
          Uri.parse(_endpoint(model, apiKey)),
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
              'maxOutputTokens': 800,
              'responseMimeType': 'application/json',
            },
          }),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final text = _extractText(json);
          if (text != null && text.isNotEmpty) {
            final cleaned = _cleanJson(text);
            final decoded = jsonDecode(cleaned);
            if (decoded is Map<String, dynamic>) return decoded;
            return null; // Unexpected JSON type (e.g. array)
          }
        } else {
          debugPrint('[AiService] generateBackgroundFacts with $model failed: ${response.statusCode} -> ${response.body}');
        }
      } catch (e) {
        debugPrint('[AiService] generateBackgroundFacts error ($model): $e');
      }
    }
    return null;
  }

  String _cleanJson(String raw) {
    var text = raw.trim();
    if (text.startsWith('```json')) {
      text = text.substring(7);
    } else if (text.startsWith('```')) {
      text = text.substring(3);
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    return text.trim();
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

  /// Answer a user's question about a specific POI using Gemini.
  Future<String> answerQuestionAboutPoi(
    Poi poi,
    String question,
  ) async {
    if (apiKey.isEmpty || apiKey == 'your_key_here') {
      return 'Вибачте, сервіс ШІ наразі недоступний (відсутній API ключ).';
    }

    final factsList = poi.facts.map((f) => '- $f').join('\n');
    final desc = poi.shortDescription.isNotEmpty ? 'Опис: ${poi.shortDescription}\n' : '';
    final narration = poi.narrationText.isNotEmpty ? 'Розповідь: ${poi.narrationText}\n' : '';

    final prompt = '''
Ти — ерудований, доброзичливий гід-екскурсовод.
Користувач зараз знаходиться біля або запитує про це місце:
Назва: "${poi.name}"
$desc$narration${factsList.isNotEmpty ? 'Відомі факти:\n$factsList\n' : ''}

Запитання користувача:
"$question"

Вимоги до відповіді:
1. Відповідай українською мовою, цікаво, природно та по суті (2–4 речення).
2. Якщо знаєш точну історичну дату, автора, архітектора чи цікаву деталь — обов'язково назви їх.
3. Стиль живого екскурсовода, без шаблонних вступів, без списків.
''';

    for (final model in _models) {
      try {
        final response = await http
            .post(
              Uri.parse(_endpoint(model, apiKey)),
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
                  'maxOutputTokens': 500,
                },
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final text = _extractText(json);
          if (text != null && text.trim().isNotEmpty) {
            return text.trim();
          }
        } else {
          debugPrint('[AiService] answerQuestionAboutPoi with $model failed: ${response.statusCode} -> ${response.body}');
        }
      } catch (e) {
        debugPrint('[AiService] answerQuestionAboutPoi error ($model): $e');
      }
    }

    return 'На жаль, не вдалося зв\'язатися з ШІ. Спробуйте ще раз.';
  }
}
