import '../models/poi.dart';

/// Provides narration content for a POI.
///
/// This is the seam between static narration and AI-generated narration.
/// In M3, it returns [poi.narrationText] directly.
/// In M4, [AiService] will override this with generated text.
class ContentService {
  /// Returns the narration text for [poi].
  ///
  /// If [aiText] is supplied (by AiService), it is used instead of the static text.
  String getNarration(Poi poi, {String? aiText}) {
    return aiText ?? poi.narrationText;
  }

  /// Builds the Ukrainian prompt string to send to the AI for generating narration.
  String buildAiPrompt(Poi poi) {
    final factsList = poi.facts.map((f) => '- $f').join('\n');
    final desc = poi.shortDescription.isNotEmpty ? 'Опис: ${poi.shortDescription}' : '';
    return '''
Ти — захопливий, ерудований аудіогід для пішої прогулянки містом (Львів, Україна).

Об'єкт: ${poi.name}
$desc
Відомі факти:
${factsList.isNotEmpty ? factsList : 'Об\'єкт міського простору / архітектури'}

Завдання:
Створи яскраву розповідь аудіогіда на 30–45 секунд усного мовлення про це місце.
Правила:
- Звертайся до слухача від другої особи ("Перед вами...", "Погляньте на...", "Зверніть увагу...").
- Жива, цікава, розмовна мова, приємна для сприйняття на слух.
- Підкресли атмосферу, архітектурні особливості або історичний дух місця.
- БЕЗ markdown, списків, лапок чи службових символів — суто чистий текст для диктора.
- Виводь ТІЛЬКИ текст розповіді, нічого іншого.
- Мова: УКРАЇНСЬКА.
''';
  }
}
