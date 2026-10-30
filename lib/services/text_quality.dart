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

  /// Drops greetings ("Вітаю!", "Привіт, мандрівнику!") from the start: the guide goes
  /// straight to the place, also for the very first point of a walk.
  static String stripGreeting(String text) {
    var t = text.trim();
    for (var i = 0; i < 3; i++) {
      final m = _greetSentence.firstMatch(t);
      if (m == null) break;
      final sentence = m.group(0)!;
      final words = sentence.trim().split(RegExp(r'\s+')).length;
      String rest;
      if (words <= 12) {
        rest = t.substring(m.end);
      } else {
        final p = _greetPrefix.firstMatch(t);
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
    if (_leak.hasMatch(t)) return 'prompt leak';
    if (cyrillicShare(t) < 0.8) return 'not Ukrainian';
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
      fact.replaceAllMapped(_isoDate, (m) => '${int.parse(m.group(1)!)} рік');
}
