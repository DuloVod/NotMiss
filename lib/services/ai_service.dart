import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;
import '../models/poi.dart';
import 'content_service.dart';
import 'text_quality.dart';

/// Generates narration text and facts for POIs using the Gemini API.
class AiService {
  final String apiKey;
  final ContentService _contentService;

  /// Ordered by measured speed/availability for the project key (Oct 2026):
  /// lite models answer in ~1.5 s; `gemini-3.8-flash` / `3.7-flash` hung for 60 s and
  /// `gemini-2.5-*` return 404 for new keys, so they must not lead the chain.
  static const List<String> _models = [
    'gemini-3.5-flash-lite',
    'gemini-3.1-flash-lite',
    'gemini-flash-lite-latest',
    'gemini-3-flash-preview',
    'gemini-3.5-flash',
    'gemini-3.8-flash',
  ];

  /// Per-model request timeout. Short on purpose: the whole research has a 25 s budget.
  static const Duration _modelTimeout = Duration(seconds: 12);

  /// Models that just failed (404 / timeout / overload) are skipped for a while, shared
  /// by every AiService instance, so one dead model costs one request, not one per call.
  static final Map<String, DateTime> _unhealthyUntil = {};

  static List<String> _activeModels() {
    final now = DateTime.now();
    final active = _models.where((m) {
      final until = _unhealthyUntil[m];
      return until == null || now.isAfter(until);
    }).toList();
    return active.isEmpty ? _models : active;
  }

  static void _markUnhealthy(String model, int? status) {
    final cooldown = status == 404 || status == 403
        ? const Duration(hours: 6)
        : const Duration(minutes: 3);
    _unhealthyUntil[model] = DateTime.now().add(cooldown);
  }

  @visibleForTesting
  static List<String> get activeModels => _activeModels();

  @visibleForTesting
  static void markUnhealthyForTest(String model, int? status) => _markUnhealthy(model, status);

  @visibleForTesting
  static void resetModelHealth() => _unhealthyUntil.clear();

  static const List<Map<String, String>> _safetySettings = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
  ];

  /// "Місто, країна" where the user currently is; added to every prompt so the model
  /// does not confuse the place with a namesake elsewhere. Null when unknown.
  static String? placeContext;

  // ── Variety: stories must not all start the same way ────────────────────────
  static final List<String> _recentOpenings = [];
  static int _styleCounter = 0;
  static const int _recentKeep = 8;

  /// Openings of the last stories (for tests and for the "do not start like these" hint).
  @visibleForTesting
  static List<String> get recentOpenings => List.unmodifiable(_recentOpenings);

  @visibleForTesting
  static void resetOpenings() {
    _recentOpenings.clear();
    _styleCounter = 0;
  }

  /// A different opening style for every story (also when the same place is generated again).
  static String _nextStyle(String seed, {required bool hasFacts}) {
    final styles = hasFacts ? ContentService.openingStyles : ContentService.safeOpeningStyles;
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7FFFFFFF;
    }
    return styles[(h + _styleCounter++) % styles.length];
  }

  static List<String> _avoidList() => _recentOpenings.reversed.take(5).toList();

  static bool _isRepetitive(String text) =>
      TextQuality.hasStockOpening(text) ||
      _recentOpenings.contains(TextQuality.openingKey(text));

  static void _rememberOpening(String text) {
    _recentOpenings.add(TextQuality.openingKey(text));
    if (_recentOpenings.length > _recentKeep) _recentOpenings.removeAt(0);
  }

  static String _endpoint(String model, String apiKey) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

  AiService({required this.apiKey, ContentService? contentService})
      : _contentService = contentService ?? ContentService();

  /// Generate a narration for [poi] using Gemini.
  Future<String> generateNarration(Poi poi) async {
    if (apiKey.isEmpty || apiKey == 'your_key_here') {
      return poi.narrationText;
    }

    final prompt = _contentService.buildAiPrompt(
      poi,
      style: _nextStyle(poi.name, hasFacts: poi.facts.isNotEmpty),
      avoid: _avoidList(),
    );
    String? repetitive; // valid but starts like an earlier story: used only if nothing better comes
    var repeats = 0;

    for (final model in _activeModels()) {
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
                  'maxOutputTokens': 2500,
                },
                'safetySettings': _safetySettings,
              }),
            )
            .timeout(_modelTimeout);

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final raw = _extractText(json);
          if (raw != null && raw.isNotEmpty) {
            final text = TextQuality.finalizeNarration(raw);
            final problem = _finishReason(json) == 'MAX_TOKENS'
                ? 'cut off (MAX_TOKENS)'
                : TextQuality.narrationProblem(text);
            if (problem == null) {
              if (!_isRepetitive(text)) {
                _rememberOpening(text);
                return text;
              }
              if (++repeats >= 2) {
                _rememberOpening(repetitive ?? text);
                return repetitive ?? text;
              }
              repetitive ??= text;
              debugPrint('[AiService] generateNarration with $model: opening repeats, trying again');
              continue;
            }
            // Leaked prompt, fragment, wrong language, truncated… try the next model.
            debugPrint('[AiService] generateNarration with $model rejected: $problem');
          }
        } else {
          debugPrint('[AiService] generateNarration with $model failed: ${response.statusCode} -> ${response.body}');
          _markUnhealthy(model, response.statusCode);
        }
      } catch (e) {
        debugPrint('[AiService] generateNarration error ($model): $e');
        if (e is TimeoutException) _markUnhealthy(model, null);
      }
    }

    if (repetitive != null) {
      _rememberOpening(repetitive);
      return repetitive;
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
${placeContext != null ? 'Розташування: $placeContext (це саме це місто, не плутай з іншими).\n' : ''}Категорія: "$category"
Теги OpenStreetMap: $tagsContext

Підготуй для туриста інформацію українською мовою:
1. "narration": захопливий текст для озвучення аудіогідом на 30–45 секунд (до 90 слів, не довше 650 символів; живий, атмосферний стиль від другої особи, розмовний стиль для вух, без списків). БЕЗ вітань ("Привіт", "Вітаю", "Ласкаво просимо") — це не перша зупинка екскурсії, а лише одна з багатьох. ${ContentService.openingRules(_nextStyle(name, hasFacts: false), _avoidList())}
2. "description": короткий змістовний опис (1–2 красивих речення українською: що це за місце).
3. "facts": 3 факти про нього.

ВАЖЛИВО: пиши лише те, що знаєш достеменно. НЕ вигадуй дат, імен, цифр і подій; якщо про об'єкт нічого певного не відомо — описуй загальними словами (вигляд, атмосфера, розташування), а факти формулюй обережно, без конкретних цифр. Усі тексти — чиста українська мова, без латиниці, без markdown.

Формат відповіді СТРОГО валідний JSON:
{
  "narration": "...",
  "description": "...",
  "facts": ["...", "...", "..."]
}
''';

    for (final model in _activeModels()) {
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
              'temperature': 0.4,
              'maxOutputTokens': 2500,
              'responseMimeType': 'application/json',
            },
            'safetySettings': _safetySettings,
          }),
        ).timeout(_modelTimeout);

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final text = _extractText(json);
          if (text != null && text.isNotEmpty) {
            final cleaned = _cleanJson(text);
            final decoded = jsonDecode(cleaned);
            if (decoded is Map<String, dynamic>) {
              // Never hand a broken narration downstream: drop it so a proper one is generated.
              final narr = decoded['narration'];
              if (narr is String) {
                final clean = TextQuality.finalizeNarration(narr);
                if (TextQuality.isValidNarration(clean) &&
                    _finishReason(json) != 'MAX_TOKENS' &&
                    !_isRepetitive(clean)) {
                  _rememberOpening(clean);
                  decoded['narration'] = clean;
                } else {
                  decoded.remove('narration');
                }
              }
              return decoded;
            }
            return null; // Unexpected JSON type (e.g. array)
          }
        } else {
          debugPrint('[AiService] generateBackgroundFacts with $model failed: ${response.statusCode} -> ${response.body}');
          _markUnhealthy(model, response.statusCode);
        }
      } catch (e) {
        debugPrint('[AiService] generateBackgroundFacts error ($model): $e');
        if (e is TimeoutException) _markUnhealthy(model, null);
      }
    }
    return null;
  }

  static String _cleanJson(String raw) {
    var text = raw.trim();
    if (text.contains('```')) {
      final codeFenceRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
      final match = codeFenceRegex.firstMatch(text);
      if (match != null) {
        text = match.group(1)!.trim();
      }
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start != -1 && end != -1 && end > start) {
      return text.substring(start, end + 1).trim();
    }
    return text;
  }

  @visibleForTesting
  static String cleanJson(String raw) => _cleanJson(raw);

  static String? _finishReason(Map<String, dynamic> json) {
    try {
      final c = (json['candidates'] as List?)?.first as Map<String, dynamic>?;
      return c?['finishReason'] as String?;
    } catch (_) {
      return null;
    }
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
${placeContext != null ? 'Розташування: $placeContext.\n' : ''}$desc$narration${factsList.isNotEmpty ? 'Відомі факти:\n$factsList\n' : ''}

Запитання туриста:
"$question"

Вимоги до відповіді:
1. Відповідай українською мовою, цікаво, природно та по суті (2–4 речення).
2. Якщо знаєш точну історичну дату, автора, розробника чи цікаву деталь — обов'язково назви їх.
3. Стиль живого екскурсовода: пиши одразу текст відповіді для туриста (без вітань на кшталт "Вітаю!", без списків, без мета-коментарів і роздумів).
4. Завжди повністю закінчуй думку та останнє речення крапкою.
''';

    for (final model in _activeModels()) {
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
                  'maxOutputTokens': 2500,
                },
                'safetySettings': _safetySettings,
              }),
            )
            .timeout(_modelTimeout);

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final text = _extractText(json);
          if (text != null && text.trim().isNotEmpty) {
            return text.trim();
          }
        } else {
          debugPrint('[AiService] answerQuestionAboutPoi with $model failed: ${response.statusCode} -> ${response.body}');
          _markUnhealthy(model, response.statusCode);
        }
      } catch (e) {
        debugPrint('[AiService] answerQuestionAboutPoi error ($model): $e');
        if (e is TimeoutException) _markUnhealthy(model, null);
      }
    }

    return 'На жаль, не вдалося зв\'язатися з ШІ. Спробуйте ще раз.';
  }
}
