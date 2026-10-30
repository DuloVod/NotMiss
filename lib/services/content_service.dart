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
  /// Different ways to open a story, so consecutive points do not sound alike.
  static const List<String> openingStyles = [
    'Почни з несподіваного факту або дивовижної деталі про це місце.',
    'Почни з запитання до слухача, яке зацікавить.',
    'Почни зі сцени з минулого: що тут колись відбувалося чи хто тут бував (лише якщо це є у фактах, інакше обери іншу манеру).',
    'Почни з того, що можна побачити, почути чи відчути просто зараз на цьому місці: деталь фасаду, звук, світло, запах.',
    'Почни з назви місця й одразу з найяскравішої риси чи факту про нього.',
    'Почни з короткого образного порівняння.',
    'Почни з контрасту: як місце виглядає і чим воно є насправді.',
    'Почни з короткого, різкого речення-інтриги, а далі розкрий її.',
  ];

  /// Styles that need no concrete facts — used when nothing reliable is known about the place,
  /// so that "start with a surprising fact" never pushes the model to invent one.
  static const List<String> safeOpeningStyles = [
    'Почни з запитання до слухача, яке зацікавить (без конкретних фактів).',
    'Почни з того, що можна побачити, почути чи відчути просто зараз на цьому місці: світло, звуки, загальний вигляд.',
    'Почни з короткого образного порівняння.',
    'Почни з короткого образного речення, що викликає цікавість до місця (без дат, імен і цифр).',
  ];

  /// Rules for the start of a story: the chosen style, no stock phrases, no repeats of recent openings.
  static String openingRules(String style, List<String> avoid) {
    final recent = avoid.isEmpty
        ? ''
        : ' Також не починай так, як останні розповіді: ${avoid.map((a) => '«$a…»').join(', ')}.';
    return '- Початок розповіді: $style\n'
        '- НІКОЛИ не починай зі слів «Зупиніться», «Погляньте», «Подивіться», «Перед вами», «Зверніть увагу», «Підніміть погляд», «Вітаю».$recent\n'
        '- Не повторюй одні й ті самі звороти в кожній розповіді: варіюй і початок, і кінцівку.';
  }

  String buildAiPrompt(Poi poi, {String? style, List<String> avoid = const []}) {
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
${openingRules(style ?? openingStyles.first, avoid)}
- Можеш звертатися до слухача, але не обов'язково з першого слова.
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
