import '../l10n/app_lang.dart';

/// Validation / cleanup of AI- and Wikipedia-sourced text before it is shown or spoken.
class TextQuality {
  TextQuality._();

  static final _cyr = RegExp(r'[Ѐ-ӿ]');
  static final _lat = RegExp(r'[A-Za-z]');

  /// Fragments that show the model leaked its prompt / reasoning instead of the story.
  static final _leak = RegExp(
    r'markdown|bullet point|constraint|persona|instruction|sentences?\]|here is|here’s|here\x27s|'
    r'\bdraft\b|the user|output only|word count|\bnote:|\bNO\s+[a-z]|без markdown|'
    r'тільки текст розповіді|as an ai|я — штучний|я штучний',
    caseSensitive: false,
  );

  static final _leakEn = RegExp(
    r'markdown|bullet point|constraint|persona|word count|output only|as an ai|language model|'
    r'system prompt|\bdraft\b|\binstructions?\b|\bNO\s+[a-z]+\s+(?:markdown|lists?)',
    caseSensitive: false,
  );

  /// Share of Latin among Cyrillic+Latin letters (0 when there are none).
  static double latinShare(String text) {
    final c = _cyr.allMatches(text).length;
    final l = _lat.allMatches(text).length;
    final total = c + l;
    return total == 0 ? 0 : l / total;
  }

  /// Share of letters in the script of the current language.
  static double scriptShare(String text) => L.en ? latinShare(text) : cyrillicShare(text);

  /// Text fit to show in the current language: mostly in its script, no glitchy mixed words.
  static bool isCleanText(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    return scriptShare(text) >= 0.6 && !hasMixedScript(text);
  }

  /// Share of Cyrillic among Cyrillic+Latin letters (0 when there are none).
  static double cyrillicShare(String text) {
    final c = _cyr.allMatches(text).length;
    final l = _lat.allMatches(text).length;
    final total = c + l;
    return total == 0 ? 0 : c / total;
  }

  /// Latin and Cyrillic letters glued inside one word ("уhistoric") — a typical model glitch.
  static final _mixedScript = RegExp(r'[\u0400-\u04FF][A-Za-z]|[A-Za-z][\u0400-\u04FF]');

  static bool hasMixedScript(String text) => _mixedScript.hasMatch(text);

  /// Text fit to show: mostly Ukrainian and without glitchy mixed-script words.
  static bool isCleanUkrainian(String? text) =>
      isMostlyCyrillic(text) && !hasMixedScript(text!);

  /// True when the text is predominantly Ukrainian/Cyrillic. Null/empty → false.
  static bool isMostlyCyrillic(String? text, {double min = 0.6}) {
    if (text == null || text.trim().isEmpty) return false;
    return cyrillicShare(text) >= min;
  }

  /// Strip markdown emphasis / list markers and stray quotes the TTS would read aloud.
  static String sanitizeNarration(String raw) {
    var t = raw.replaceAll(RegExp(r'[*#`_~]+'), '');
    t = t.replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'\s*\n\s*'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    if (t.length > 1 && (t.startsWith('"') || t.startsWith('«')) && (t.endsWith('"') || t.endsWith('»'))) {
      t = t.substring(1, t.length - 1).trim();
    }
    return t;
  }

  /// Stock openings that made every story sound the same.
  static final _stockOpening = RegExp(
    r'^\s*(?:зупиніться|зупинімось|зупинімося|погляньте|подивіться|перед вами|перед вами постає|зверніть увагу|підніміть погляд|вітаю|привіт)',
    caseSensitive: false,
    unicode: true,
  );

  static final _stockOpeningEn = RegExp(
    r'^\s*(?:look at|take a moment|stop for a moment|stop and|pause for a moment|in front of you|pay attention|notice the|welcome|hello|hi\b|hey\b)',
    caseSensitive: false,
  );

  static bool hasStockOpening(String text) =>
      (L.en ? _stockOpeningEn : _stockOpening).hasMatch(text);

  /// First two words, lower-case, without punctuation — to spot repeated openings.
  static String openingKey(String text) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\s\x27ʼ’-]', unicode: true), ' ')
        .trim()
        .split(RegExp(r'\s+'));
    return words.take(2).join(' ');
  }

  /// ~45 seconds of speech; longer stories tire a person who is walking.
  static const int maxNarrationChars = 700;

  static const _greetWords =
      r'(?:привіт(?:ання)?|вітаю|вітаємо|добрий\s+(?:день|вечір|ранок)|доброго\s+(?:дня|ранку|вечора)|'
      r'добридень|здрастуйте|ласкаво\s+просимо)';

  /// A whole opening sentence that starts with a greeting.
  static final _greetSentence = RegExp(
    '^\\s*(?:ну\\s+)?(?:всім\\s+)?$_greetWords[^.!?…]*[.!?…]+\\s*',
    caseSensitive: false,
    unicode: true,
  );

  /// Just the greeting words (and a vocative) at the start of a long sentence.
  static final _greetPrefix = RegExp(
    '^\\s*$_greetWords(?:\\s+(?:вас|вам|усіх|всіх|друзі|друже|мандрівнику|мандрівнице|мандрівники|мандрівники))*\\s*[,!:—–-]*\\s*',
    caseSensitive: false,
    unicode: true,
  );

  static const _greetWordsEn =
      r'(?:hello|hi|hey|greetings|welcome|good\s+(?:morning|afternoon|evening|day))';

  static final _greetSentenceEn = RegExp(
    '^\\s*$_greetWordsEn\\b[^.!?…]*[.!?…]+\\s*',
    caseSensitive: false,
  );

  static final _greetPrefixEn = RegExp(
    '^\\s*$_greetWordsEn\\b(?:\\s+(?:to\\s+\\w+|everyone|all|friends|traveler|traveller|there))*\\s*[,!:—–-]*\\s*',
    caseSensitive: false,
  );

  /// Drops greetings ("Вітаю!", "Привіт, мандрівнику!") from the start: the guide goes
  /// straight to the place, also for the very first point of a walk.
  static String stripGreeting(String text) {
    var t = text.trim();
    for (var i = 0; i < 3; i++) {
      final m = (L.en ? _greetSentenceEn : _greetSentence).firstMatch(t);
      if (m == null) break;
      final sentence = m.group(0)!;
      final words = sentence.trim().split(RegExp(r'\s+')).length;
      String rest;
      if (words <= 12) {
        rest = t.substring(m.end);
      } else {
        final p = (L.en ? _greetPrefixEn : _greetPrefix).firstMatch(t);
        rest = p == null ? t : t.substring(p.end);
        if (rest.isNotEmpty) rest = rest[0].toUpperCase() + rest.substring(1);
        t = rest.trim();
        break;
      }
      if (rest.trim().isEmpty) return text.trim();
      t = rest.trim();
    }
    return t;
  }

  /// Shortens [text] to at most [max] characters, cutting after a complete sentence.
  static String trimToLength(String text, {int max = maxNarrationChars}) {
    final t = text.trim();
    if (t.length <= max) return t;
    final head = t.substring(0, max);
    var cut = -1;
    for (final m in RegExp(r'[.!?…](?=\s|$)').allMatches(head)) {
      cut = m.end;
    }
    if (cut >= max * 0.4) return head.substring(0, cut).trim();
    final sp = head.lastIndexOf(' ');
    final body = (sp > 0 ? head.substring(0, sp) : head).replaceFirst(RegExp(r'[,;:\-—–\s]+$'), '');
    return '$body.';
  }

  /// Everything a narration needs before it is shown or spoken: markdown removed,
  /// no greeting, no longer than [maxNarrationChars].
  static String finalizeNarration(String raw) =>
      trimToLength(stripGreeting(sanitizeNarration(raw)));

  static final _number = RegExp(r'\d+(?:[.,]\d+)?');

  /// Numbers in [text] (years, metres, counts) that do not occur in [source]. Any such number
  /// was made up by the model: a cheap and exact check, independent of the model's own opinion.
  static List<String> unsupportedNumbers(String text, String source) {
    final known = _number.allMatches(source).map((m) => m.group(0)!.replaceAll(',', '.')).toSet();
    return _number
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((n) => !known.contains(n.replaceAll(',', '.')))
        .toSet()
        .toList();
  }

  /// Why [text] is not a usable narration, or null when it is fine.
  ///
  /// [strict] (generation time) additionally requires a real story: ≥[minChars] characters and
  /// at least two sentences. Stored text is checked non-strictly: only real defects count.
  static String? narrationProblem(String? text, {int minChars = 120, bool strict = true}) {
    final t = text?.trim() ?? '';
    if (t.isEmpty) return 'empty';
    if (strict && t.length < minChars) return 'too short (${t.length})';
    if (t.length > 2000) return 'too long';
    if (RegExp(r'[*#`\[\]{}<>]').hasMatch(t)) return 'markup characters';
    if ((L.en ? _leakEn : _leak).hasMatch(t)) return 'prompt leak';
    if (scriptShare(t) < 0.8) return 'wrong language';
    if (hasMixedScript(t)) return 'mixed-script word';
    if (!RegExp(r'[.!?…»")]$').hasMatch(t)) return 'truncated (no final punctuation)';
    final sentences = RegExp(r'[.!?…]+(\s|$)').allMatches(t).length;
    if (strict && sentences < 2) return 'single sentence';
    return null;
  }

  static bool isValidNarration(String? text, {int minChars = 120}) =>
      narrationProblem(text, minChars: minChars) == null;

  /// A narration already stored in the cache is "bad" (must be regenerated) when it
  /// leaks prompt text, is not Ukrainian, is cut off or is only a fragment.
  static bool isBadStoredNarration(String? text) {
    final t = text?.trim() ?? '';
    if (t.isEmpty) return false; // empty is handled elsewhere
    return narrationProblem(t, strict: false) != null;
  }

  static final _isoDate = RegExp(r'[+-]?(\d{4})-(\d{2})-(\d{2})T[\d:]+Z?');

  /// "+1998-05-00T00:00:00Z" → "1998 рік"; leaves other text untouched.
  static String normalizeFact(String fact) =>
      fact.replaceAllMapped(_isoDate, (m) => L.t('${int.parse(m.group(1)!)} рік', '${int.parse(m.group(1)!)}'));
}
