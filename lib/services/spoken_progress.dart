/// Estimates which word of a narration is being spoken at a given moment.
///
/// The speech service returns audio without word timings, so the position is estimated from the
/// share of the audio that has played: every word takes time in proportion to its length, and
/// punctuation adds a pause (a comma a little, a full stop more). For a 45-second story this keeps
/// the highlight within a word or two of the voice, which is what following the text needs.
class SpokenWord {
  /// Where the word is in the text (end exclusive).
  final int start;
  final int end;

  /// Share of the whole narration at which the word starts / ends (0..1).
  final double from;
  final double to;

  const SpokenWord(this.start, this.end, this.from, this.to);
}

class SpokenProgress {
  final List<SpokenWord> words;

  const SpokenProgress(this.words);

  /// Silence at the start / end of generated speech, which carries no words.
  static const Duration leadIn = Duration(milliseconds: 250);
  static const Duration tail = Duration(milliseconds: 300);

  static final _word = RegExp(r"[^\s]+");

  /// Time weight of one word.
  static double _weight(String token) {
    final letters = token.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').length;
    var w = letters + 2.0;
    final end = token.isEmpty ? '' : token[token.length - 1];
    if (RegExp(r'[.!?…]').hasMatch(end)) {
      w += 6;
    } else if (RegExp(r'[,;:]').hasMatch(end)) {
      w += 3;
    } else if (end == '—' || end == '–') {
      w += 2;
    }
    return w;
  }

  factory SpokenProgress.of(String text) {
    final tokens = _word.allMatches(text).toList();
    if (tokens.isEmpty) return const SpokenProgress([]);
    final weights = [for (final t in tokens) _weight(t.group(0)!)];
    final total = weights.fold<double>(0, (a, b) => a + b);
    final words = <SpokenWord>[];
    var acc = 0.0;
    for (var i = 0; i < tokens.length; i++) {
      final from = acc / total;
      acc += weights[i];
      words.add(SpokenWord(tokens[i].start, tokens[i].end, from, acc / total));
    }
    return SpokenProgress(words);
  }

  /// Share of the speech that has been spoken, from the player's position and the length of the
  /// file, without the silence at both ends. Clamped to 0..1.
  static double fraction(Duration position, Duration? duration) {
    if (duration == null || duration <= Duration.zero) return 0;
    final speech = duration - leadIn - tail;
    if (speech <= Duration.zero) return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return ((position - leadIn).inMilliseconds / speech.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Index of the word being spoken at [fraction] (0..1); -1 when there are no words.
  int indexAt(double fraction) {
    if (words.isEmpty) return -1;
    final f = fraction.clamp(0.0, 1.0);
    for (var i = 0; i < words.length; i++) {
      if (f < words[i].to) return i;
    }
    return words.length - 1;
  }
}
