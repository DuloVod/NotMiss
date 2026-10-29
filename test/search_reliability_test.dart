import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';

void main() {
  group('AiService model health', () {
    setUp(AiService.resetModelHealth);
    tearDown(AiService.resetModelHealth);

    test('chain does not lead with models that hang or return 404', () {
      final models = AiService.activeModels;
      expect(models.first, 'gemini-3.5-flash-lite');
      expect(models.any((m) => m.startsWith('gemini-2.5')), isFalse);
      expect(models.indexOf('gemini-3.8-flash'), models.length - 1);
    });

    test('a failed model is skipped, and never leaves the chain empty', () {
      AiService.markUnhealthyForTest('gemini-3.5-flash-lite', 404);
      expect(AiService.activeModels, isNot(contains('gemini-3.5-flash-lite')));
      for (final m in List.of(AiService.activeModels)) {
        AiService.markUnhealthyForTest(m, null);
      }
      expect(AiService.activeModels, isNotEmpty);
    });
  });

  group('WikipediaService matching', () {
    test('titleMatchesName tolerates Ukrainian case endings', () {
      expect(WikipediaService.titleMatchesName('Пам\'ятник Тарасові Шевченку (Львів)', 'Пам\'ятник Шевченку'), isTrue);
      expect(WikipediaService.titleMatchesName('Вулиця Винниченка (Львів)', 'Порохова вежа'), isFalse);
    });

    test('articles from far away are rejected, unverifiable ones accepted', () {
      const kyiv = WikipediaArticle(
          title: 'Ратуша', extract: 'x', url: 'u', lang: 'uk', lat: 50.45, lon: 30.52);
      const lviv = WikipediaArticle(
          title: 'Ратуша', extract: 'x', url: 'u', lang: 'uk', lat: 49.8419, lon: 24.0315);
      const noCoords = WikipediaArticle(title: 'Ратуша', extract: 'x', url: 'u', lang: 'uk');
      expect(WikipediaService.isNear(kyiv, 49.84, 24.03), isFalse);
      expect(WikipediaService.isNear(lviv, 49.84, 24.03), isTrue);
      expect(WikipediaService.isNear(noCoords, 49.84, 24.03), isTrue);
      expect(WikipediaService.isNear(kyiv, null, null), isTrue);
    });
  });
}
