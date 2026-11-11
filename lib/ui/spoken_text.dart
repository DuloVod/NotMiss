import 'package:flutter/material.dart';
import '../services/spoken_progress.dart';
import 'theme/app_theme.dart';

/// A narration that lights up the word being spoken, so that a listener can follow the text.
///
/// Words already spoken are dimmed, the current word is highlighted. When nothing is playing
/// ([active] false, or no duration yet) the text is shown plainly.
class SpokenText extends StatelessWidget {
  final String text;
  final TextStyle style;

  /// This narration is the one being played (or paused) right now.
  final bool active;

  /// Position of the player (emits while playing).
  final Stream<Duration> position;

  /// Last known position (shown while paused, before the first emission).
  final Duration Function() currentPosition;
  final Duration? Function() duration;

  const SpokenText({
    super.key,
    required this.text,
    required this.style,
    required this.active,
    required this.position,
    required this.currentPosition,
    required this.duration,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return Text(text, style: style);
    return StreamBuilder<Duration>(
      stream: position,
      builder: (context, snapshot) {
        final total = duration();
        if (total == null || total <= Duration.zero) return Text(text, style: style);
        final pos = snapshot.data ?? currentPosition();
        final progress = SpokenProgress.of(text);
        final current = progress.indexAt(SpokenProgress.fraction(pos, total));
        return Text.rich(buildSpans(text, progress, current, style));
      },
    );
  }

  /// The text as spans: spoken words dimmed, the current word highlighted.
  @visibleForTesting
  static TextSpan buildSpans(String text, SpokenProgress progress, int current, TextStyle style) {
    final spoken = style.copyWith(color: NmColors.muted);
    final now = style.copyWith(
      fontWeight: FontWeight.w700,
      backgroundColor: NmColors.ochre.withValues(alpha: 0.35),
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < progress.words.length; i++) {
      final w = progress.words[i];
      if (w.start > cursor) spans.add(TextSpan(text: text.substring(cursor, w.start), style: style));
      final s = i < current ? spoken : (i == current ? now : style);
      spans.add(TextSpan(text: text.substring(w.start, w.end), style: s));
      cursor = w.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor), style: style));
    return TextSpan(children: spans, style: style);
  }
}
