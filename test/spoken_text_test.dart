import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/services/spoken_progress.dart';
import 'package:notmiss/ui/spoken_text.dart';

const _text = 'Ратушу збудовано у 1835 році. Її вежа, найвища в Україні, видна здалеку. Ходімо далі!';

void main() {
  group('SpokenProgress', () {
    test('every word is found with its place in the text, in order', () {
      final p = SpokenProgress.of(_text);
      expect(p.words, hasLength(14));
      expect(_text.substring(p.words.first.start, p.words.first.end), 'Ратушу');
      expect(_text.substring(p.words.last.start, p.words.last.end), 'далі!');
      for (var i = 1; i < p.words.length; i++) {
        expect(p.words[i].start, greaterThan(p.words[i - 1].end - 1));
        expect(p.words[i].from, closeTo(p.words[i - 1].to, 1e-9), reason: 'no gaps in time');
      }
      expect(p.words.first.from, 0);
      expect(p.words.last.to, closeTo(1, 1e-9));
    });

    test('the start is the first word, the end is the last, and it only moves forward', () {
      final p = SpokenProgress.of(_text);
      expect(p.indexAt(0), 0);
      expect(p.indexAt(1), p.words.length - 1);
      expect(p.indexAt(5), p.words.length - 1, reason: 'clamped');
      expect(p.indexAt(-1), 0);
      var last = -1;
      for (var f = 0.0; f <= 1.0; f += 0.01) {
        final i = p.indexAt(f);
        expect(i, greaterThanOrEqualTo(last));
        last = i;
      }
    });

    test('long words and sentence ends take longer than short words', () {
      final p = SpokenProgress.of('Я ж збудовано. Ні');
      final short = p.words[0].to - p.words[0].from; // "Я"
      final long = p.words[2].to - p.words[2].from; // "збудовано." (long + full stop)
      expect(long, greaterThan(short * 3));
      final comma = SpokenProgress.of('Так, так').words;
      expect(comma[0].to - comma[0].from, greaterThan(comma[1].to - comma[1].from), reason: 'a comma is a pause');
    });

    test('the middle of the audio is about the middle of the text', () {
      final p = SpokenProgress.of(_text);
      final mid = p.indexAt(0.5);
      expect(mid, inInclusiveRange(5, 9));
    });

    test('silence at both ends of the audio carries no words', () {
      const d = Duration(seconds: 10);
      expect(SpokenProgress.fraction(Duration.zero, d), 0);
      expect(SpokenProgress.fraction(const Duration(milliseconds: 200), d), 0, reason: 'still in the lead-in');
      expect(SpokenProgress.fraction(const Duration(seconds: 10), d), 1);
      expect(SpokenProgress.fraction(const Duration(milliseconds: 9800), d), 1);
      expect(SpokenProgress.fraction(const Duration(seconds: 5), d), closeTo(0.5, 0.03));
      expect(SpokenProgress.fraction(const Duration(seconds: 1), null), 0);
      expect(SpokenProgress.fraction(const Duration(seconds: 1), Duration.zero), 0);
    });

    test('empty text and strange spacing do not break it', () {
      expect(SpokenProgress.of('').words, isEmpty);
      expect(SpokenProgress.of('   ').indexAt(0.5), -1);
      final p = SpokenProgress.of('  один   два\nтри ');
      expect(p.words, hasLength(3));
    });
  });

  group('SpokenText', () {
    const style = TextStyle(fontSize: 15, color: Colors.black);

    List<(String, TextStyle)> parts(WidgetTester tester) {
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      final out = <(String, TextStyle)>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text != null) out.add((s.text!, s.style ?? const TextStyle()));
        return true;
      });
      return out;
    }

    Widget host(StreamController<Duration> ctrl, {required bool active, Duration? total = const Duration(seconds: 10)}) =>
        MaterialApp(
          home: Scaffold(
            body: SpokenText(
              text: _text,
              style: style,
              active: active,
              position: ctrl.stream,
              currentPosition: () => Duration.zero,
              duration: () => total,
            ),
          ),
        );

    testWidgets('while it plays the current word is highlighted, spoken words dimmed, the rest normal', (tester) async {
      final ctrl = StreamController<Duration>();
      addTearDown(() { ctrl.close(); });
      await tester.pumpWidget(host(ctrl, active: true));
      ctrl.add(const Duration(milliseconds: 5000));
      await tester.pump();

      final words = parts(tester).where((p) => p.$1.trim().isNotEmpty).toList();
      final highlighted = words.where((p) => p.$2.backgroundColor != null).toList();
      expect(highlighted, hasLength(1), reason: 'exactly one word is lit');
      final idx = words.indexWhere((p) => p.$2.backgroundColor != null);
      expect(idx, inInclusiveRange(5, 9));
      for (var i = 0; i < idx; i++) {
        expect(words[i].$2.color, isNot(style.color), reason: 'spoken word ${words[i].$1} is dimmed');
      }
      for (var i = idx + 1; i < words.length; i++) {
        expect(words[i].$2.color, style.color, reason: 'upcoming word ${words[i].$1} is normal');
      }
      // all the text is still there, unchanged
      expect(parts(tester).map((p) => p.$1).join(), _text);
    });

    testWidgets('the highlight follows the voice', (tester) async {
      final ctrl = StreamController<Duration>();
      addTearDown(() { ctrl.close(); });
      await tester.pumpWidget(host(ctrl, active: true));
      var last = -1;
      for (final ms in [500, 2000, 4000, 6000, 8000, 9500]) {
        ctrl.add(Duration(milliseconds: ms));
        await tester.pump();
        await tester.pump();
        final words = parts(tester).where((p) => p.$1.trim().isNotEmpty).toList();
        final idx = words.indexWhere((p) => p.$2.backgroundColor != null);
        expect(idx, greaterThanOrEqualTo(last), reason: 'at $ms ms');
        last = idx;
      }
      expect(last, 13, reason: 'the last word at the end');
    });

    testWidgets('not playing: plain text, nothing highlighted', (tester) async {
      final ctrl = StreamController<Duration>();
      addTearDown(() { ctrl.close(); });
      await tester.pumpWidget(host(ctrl, active: false));
      expect(find.text(_text), findsOneWidget);
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      var lit = 0;
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.style?.backgroundColor != null) lit++;
        return true;
      });
      expect(lit, 0);
    });

    testWidgets('before the length of the audio is known the text stays plain', (tester) async {
      final ctrl = StreamController<Duration>();
      addTearDown(() { ctrl.close(); });
      await tester.pumpWidget(host(ctrl, active: true, total: null));
      ctrl.add(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text(_text), findsOneWidget);
    });
  });
}
