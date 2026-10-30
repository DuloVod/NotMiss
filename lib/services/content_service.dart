import '../models/poi.dart';
import 'ai_service.dart';

/// Provides narration content for a POI.
///
/// This is the seam between static narration and AI-generated narration.
/// In M3, it returns [poi.narrationText] directly.
/// In M4, [AiService] will override this with generated text.
class ContentService {
  /// Returns the narration text for [poi].
  ///
  /// If [aiText] is supplied (by AiService), it is used instead of the static text.
  /// Returns empty string only if both aiText and static text are missing.
  String getNarration(Poi poi, {String? aiText}) {
    // Treat empty AI text as null (don't let empty string bypass fallback)
    if (aiText != null && aiText.trim().isNotEmpty) return aiText;
    return poi.narrationText;
  }

  /// Builds the Ukrainian prompt string to send to the AI for generating narration.
  String buildAiPrompt(Poi poi) {
    final desc = poi.shortDescription.isNotEmpty ? 'Опис: ${poi.shortDescription}' : '';
    
    // Build facts section only if there are actual facts
    String factsSection = '';
    if (poi.facts.isNotEmpty) {
      final factsList = poi.facts.map((f) => '- $f').join('\n');
      factsSection = 'Відомі факти:\n$factsList';
    }
    
    return '''
Ти — захопливий, ерудований аудіогід для пішої прогулянки.

Об'єкт: ${poi.name}
${AiService.placeContext != null ? 'Розташування: ${AiService.placeContext} (це саме це місто, не плутай з іншими).\n' : ''}$desc
${factsSection.isNotEmpty ? factsSection : 'Об\'єкт міського простору / архітектури'}

Завдання:
Створи яскраву розповідь аудіогіда на 30–45 секунд усного мовлення про це місце: до 90 слів, не довше 650 символів.
Правила:
- ЗАБОРОНЕНО вітатися: жодних "Привіт", "Вітаю", "Ласкаво просимо", "Доброго дня". Це лише одна із зупинок прогулянки — починай одразу з місця.
- Звертайся до слухача від другої особи ("Перед вами...", "Погляньте на...", "Зверніть увагу...").
- Жива, цікава, розмовна мова, приємна для сприйняття на слух.
- Підкресли атмосферу, архітектурні особливості або історичний дух місця.
- Спирайся ЛИШЕ на наведені факти й на те, що ти знаєш достеменно. НЕ вигадуй дат, імен, цифр і подій. Коли фактів мало — опиши місце загальними словами (атмосфера, архітектурний вигляд, що варто помітити), без конкретики, в якій не впевнений.
- Мінімум 4 повні речення; обов'язково закінчуй останнє речення крапкою.
- БЕЗ markdown, списків, лапок чи службових символів — суто чистий текст для диктора.
- Виводь ТІЛЬКИ текст розповіді, нічого іншого.
- Мова: УКРАЇНСЬКА.
''';
  }
}
