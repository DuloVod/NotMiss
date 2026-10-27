import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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

  static const List<Map<String, String>> _safetySettings = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
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
                  'maxOutputTokens': 1500,
                },
                'safetySettings': _safetySettings,
              }),
            )
            .timeout(const Duration(seconds: 30));

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
              'maxOutputTokens': 1500,
              'responseMimeType': 'application/json',
            },
            'safetySettings': _safetySettings,
          }),
        ).timeout(const Duration(seconds: 30));

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

  static String? _extractText(Map<String, dynamic> json) {
    try {
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final candidate = candidates[0] as Map<String, dynamic>?;
      if (candidate == null) return null;

      final content = candidate['content'] as Map<String, dynamic>?;
      if (content == null) return null;

      final parts = content['parts'] as List?;
      if (parts == null || parts.isEmpty) return null;

      final buffer = StringBuffer();
      for (final part in parts) {
        if (part is Map<String, dynamic>) {
          // Skip internal thinking / reasoning traces from Gemini 2.5 / 3.8
          if (part['thought'] == true) continue;
          final text = part['text'] as String?;
          if (text != null && text.isNotEmpty) {
            buffer.write(text);
          }
        }
      }

      var text = buffer.toString().trim();

      // Fallback: if all parts had thought == true or no non-thought text found
      if (text.isEmpty) {
        for (final part in parts.reversed) {
          if (part is Map<String, dynamic>) {
            final t = part['text'] as String?;
            if (t != null && t.trim().isNotEmpty) {
              text = t.trim();
              break;
            }
          }
        }
      }

      if (text.isNotEmpty) {
        return _cleanThoughtLeak(text);
      }
    } catch (_) {}
    return null;
  }

  static String _cleanThoughtLeak(String raw) {
    var text = raw.trim();
    // 1. Remove leaked prompt / persona markers like:
    // "2-4 sentences], applying persona):* " or "[2-4 sentences]...:"
    final residueRegex = RegExp(
      r'^(?:\[?[^\]\n]*\](?:,\s*[^:\n]*)*\)?:\*?\s*|\*\s*)',
      caseSensitive: false,
    );
    text = text.replaceFirst(residueRegex, '').trim();

    // 2. Remove leading "* " or "- " or "Відповідь:" if present
    final prefixRegex = RegExp(r'^(?:відповідь|гід|екскурсовод):\s*', caseSensitive: false);
    text = text.replaceFirst(prefixRegex, '').trim();

    if (text.startsWith('* ') || text.startsWith('- ')) {
      text = text.substring(2).trim();
    }
    return text;
  }

  @visibleForTesting
  static String cleanThoughtLeak(String raw) => _cleanThoughtLeak(raw);

  @visibleForTesting
  static String? extractText(Map<String, dynamic> json) => _extractText(json);

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
Ти — ерудований, доброзичливий гід-екскурсовод для пішої прогулянки.
Користувач зараз знаходиться біля або запитує про це місце:
Назва: "${poi.name}"
$desc$narration${factsList.isNotEmpty ? 'Відомі факти:\n$factsList\n' : ''}

Запитання туриста:
"$question"

Вимоги до відповіді:
1. Відповідай українською мовою, цікаво, природно та по суті (2–4 речення).
2. Якщо знаєш точну історичну дату, автора, розробника чи цікаву деталь — обов'язково назви їх.
3. Стиль живого екскурсовода: пиши одразу текст відповіді для туриста (без вітань на кшталт "Вітаю!", без списків, без мета-коментарів і роздумів).
4. Завжди повністю закінчуй думку та останнє речення крапкою.
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
                  'maxOutputTokens': 1500,
                },
                'safetySettings': _safetySettings,
              }),
            )
            .timeout(const Duration(seconds: 30));

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
