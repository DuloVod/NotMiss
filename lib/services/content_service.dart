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
    return '''
Ти — захопливий аудіогід для пішої екскурсії Стрийським парком у Львові.

Місце: ${poi.name}

Відомі факти:
$factsList

Завдання:
Напиши розповідь на 30–50 секунд усного мовлення про це місце.
Правила:
- Розповідай ТІЛЬКИ те, що підтверджено фактами вище. НЕ вигадуй нових деталей.
- Пиши від другої особи ("Ви стоїте..."), щоб занурити слухача.
- Розмовний стиль — цей текст буде прочитаний вголос, не для очей.
- Короткі речення. Варіюй ритм.
- Зверши чимось цікавим або несподіваним.
- БЕЗ markdown, списків або форматування.
- Виводь ТІЛЬКИ текст розповіді, нічого іншого.
- Мова відповіді: УКРАЇНСЬКА.
''';
  }
}
