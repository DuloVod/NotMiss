import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/services/text_quality.dart';
import 'package:notmiss/services/wikipedia_service.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

void main() {
  group('TextQuality.narrationProblem', () {
    test('rejects the leaked prompt fragment seen in the app', () {
      expect(TextQuality.narrationProblem(':* NO markdown (no bold, no italics, no bullet points, no quotation marks).'),
          isNotNull);
      expect(TextQuality.isBadStoredNarration(':* NO markdown (no bold, no italics, no bullet points, no quotation marks).'),
          isTrue);
    });

    test('rejects a cut-off one-liner without final punctuation', () {
      const cut = 'Зверніть увагу на цю вишукану галицьку віллу';
      expect(TextQuality.narrationProblem(cut), isNotNull);
      expect(TextQuality.isBadStoredNarration(cut), isTrue, reason: 'truncated text must be regenerated');
    });

    test('rejects mixed-script glitches and English text', () {
      expect(TextQuality.hasMixedScript('розташований уhistoric будівлі'), isTrue);
      expect(TextQuality.isCleanUkrainian('розташований уhistoric будівлі'), isFalse);
      expect(TextQuality.isCleanUkrainian('museum in Ukraine'), isFalse);
      expect(TextQuality.isCleanUkrainian('Меморіальний музей у Львові.'), isTrue);
    });

    test('accepts a proper multi-sentence Ukrainian narration', () {
      const ok = 'Перед вами Порохова вежа — справжній страж старого Львова. '
          'Погляньте на її товсті кам\'яні стіни: колись вони ховали міський арсенал. '
          'Уявіть, як тут гуркотіли вози з порохом, а варта пильнувала місто. '
          'Зупиніться на мить і відчуйте подих історії.';
      expect(TextQuality.narrationProblem(ok), isNull);
    });

    test('stored short but clean sentences are not considered broken', () {
      expect(TextQuality.isBadStoredNarration('Чудовий фонтан у центрі Львова.'), isFalse);
    });

    test('sanitize removes markdown the TTS would read aloud', () {
      expect(TextQuality.sanitizeNarration('**Вітаю** вас!\n* Перед вами _вежа_.'), 'Вітаю вас! Перед вами вежа.');
    });

    test('raw Wikidata timestamps become readable', () {
      expect(TextQuality.normalizeFact('Створено/засновано: +1998-05-00T00:00:00Z'), 'Створено/засновано: 1998 рік');
      expect(TextQuality.normalizeFact('Архітектор: Іван'), 'Архітектор: Іван');
    });
  });

  test('EnrichedPoi with a leaked narration counts as fallback → gets re-researched', () {
    const e = EnrichedPoi(
      poiId: 'p', name: 'Знак', category: 'x', latitude: 0, longitude: 0,
      narrationText: ':* NO markdown (no bold, no italics, no bullet points, no quotation marks).',
    );
    expect(e.hasFallbackContent, isTrue);
  });

  group('Wikipedia relevance', () {
    test('generic words do not make a different museum match', () {
      expect(WikipediaService.titleMatchesName('Музей Івана Франка', 'Музей Михайла Грушевського'), isFalse);
      expect(WikipediaService.titleMatchesName('Меморіальний музей Михайла Грушевського', 'Музей Михайла Грушевського'), isTrue);
      expect(WikipediaService.titleMatchesName('Вулиця Довженка', 'Простір Львів'), isFalse);
    });

    Future<WikipediaArticle?> run({required Map<String, dynamic> summary, double? lat = 49.82, double? lng = 24.03}) {
      final client = MockClient((req) async {
        if (req.url.path.contains('/page/summary/')) {
          final isTarget = Uri.decodeComponent(req.url.path).endsWith('Простір_імен');
          return isTarget ? http.Response(jsonEncode(summary), 200, headers: _json) : http.Response('{}', 404);
        }
        if (req.url.queryParameters['list'] == 'geosearch') {
          return http.Response(jsonEncode({'query': {'geosearch': []}}), 200, headers: _json);
        }
        return http.Response(
            jsonEncode({'query': {'search': [{'title': 'Простір імен'}]}}), 200, headers: _json);
      });
      return http.runWithClient(
          () => WikipediaService().fetchSummaryOrSearch('Простір Львів', lat: lat, lng: lng), () => client);
    }

    test('search hit without coordinates (programming article) is rejected', () async {
      final a = await run(summary: {
        'type': 'standard', 'title': 'Простір імен', 'extract': 'Простір імен — концепція у програмуванні, призначена для розмежування ідентифікаторів.',
      });
      expect(a, isNull);
    });

    test('search hit with far-away coordinates is rejected', () async {
      final a = await run(summary: {
        'type': 'standard', 'title': 'Простір імен', 'extract': 'Довгий текст про щось у Києві.',
        'coordinates': {'lat': 50.45, 'lon': 30.52},
      });
      expect(a, isNull);
    });

    test('search hit with nearby coordinates is accepted', () async {
      final a = await run(summary: {
        'type': 'standard', 'title': 'Простір імен', 'extract': 'Культурний простір у Львові.',
        'coordinates': {'lat': 49.8201, 'lon': 24.0301},
      });
      expect(a?.title, 'Простір імен');
    });
  });
}
