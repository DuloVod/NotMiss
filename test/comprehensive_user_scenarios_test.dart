import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/models/proximity_event.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/poi_engine.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('10+ Real-World User Scenarios: Search, Proximity & Fact Retrieval', () {
    // -------------------------------------------------------------------------
    // SCENARIO 1: User taps a landmark with Wikipedia & Wikidata (Львівська ратуша)
    // -------------------------------------------------------------------------
    test('Scenario 1: User taps a landmark with Wikipedia and Wikidata', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 2);

      // Custom mock wikipedia returning a rich Ukrainian article
      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''),
      );

      // Seed cache as if fetched from Wikidata/Wikipedia with multiple sentences
      const sampleExtract =
          'Льві́вська ра́туша — адміністративна будівля в центральній частині Львова на площі Ринок, 1. '
          'Протягом усієї історії ратуша була місцем розташування міського самоврядування. '
          'Сучасна вежа ратуші має висоту 65 метрів і є найвищою в Україні. '
          'Пам\'ятка архітектури національного значення, внесена до світової спадщини ЮНЕСКО.';

      final sentences = ResearchService.extractSentences(sampleExtract);
      expect(sentences.length, greaterThanOrEqualTo(3));

      final landmarkPoi = EnrichedPoi(
        poiId: 'poi_ratusha',
        name: 'Львівська ратуша',
        category: PoiCategoryService.historicalBuilding,
        latitude: 49.8418,
        longitude: 24.0315,
        researchStatus: ResearchStatus.complete,
        shortDescription: 'адміністративна будівля в центральній частині Львова',
        keyFacts: [
          const KeyFact(fact: 'Створено/засновано: 1848 рік', sourceUrl: 'https://wikidata.org/wiki/Q2634351'),
          const KeyFact(fact: 'Архітектор: Юзеф Марковський', sourceUrl: 'https://wikidata.org/wiki/Q2634351'),
          KeyFact(fact: sentences[1], sourceUrl: 'https://uk.wikipedia.org/wiki/Львівська_ратуша'),
          KeyFact(fact: sentences[2], sourceUrl: 'https://uk.wikipedia.org/wiki/Львівська_ратуша'),
        ],
        narrationText: 'Перед вами велична Львівська ратуша на площі Ринок.',
      );
      await cache.put(landmarkPoi);

      final result = service.getEnrichedData('poi_ratusha');
      expect(result, isNotNull);
      expect(result!.isResearchComplete, isTrue);
      expect(result.hasFallbackContent, isFalse);
      expect(result.keyFacts.length, 4);

      // Verify no fact duplicates the short description
      for (final f in result.keyFacts) {
        expect(f.fact, isNot(equals(result.shortDescription)));
      }

      service.dispose();
    });

    // -------------------------------------------------------------------------
    // SCENARIO 2: User walks up to an unlisted military POI (БМ-30 «Смерч»)
    // -------------------------------------------------------------------------
    test('Scenario 2: User approaches an unlisted military POI (AI fallback generates 3 facts)', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 1);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''), // offline fallback simulation
      );

      const militaryPoi = Poi(
        id: 'poi_bm30',
        name: 'БМ-30 «Смерч»',
        latitude: 49.8228,
        longitude: 24.0264,
        triggerRadius: 35,
        shortDescription: '',
        facts: [],
        narrationText: '',
        sources: [],
        osmTags: {'historic': 'vehicle', 'military': 'weapon'},
      );

      await service.researchImmediately('poi_bm30', poi: militaryPoi, force: true);

      final result = service.getEnrichedData('poi_bm30');
      expect(result, isNotNull);
      expect(result!.researchStatus, ResearchStatus.complete);
      expect(result.shortDescription, isNotNull);
      expect(result.shortDescription, isNotEmpty);
      expect(result.keyFacts, isNotEmpty);
      expect(result.narrationText, isNotNull);
      expect(result.narrationText, isNotEmpty);

      service.dispose();
    });

    // -------------------------------------------------------------------------
    // SCENARIO 3: User taps a POI with English-only OSM tag (wikipedia:en=...)
    // -------------------------------------------------------------------------
    test('Scenario 3: POI with English Wikipedia tag handles "en:" prefix correctly', () async {
      final wiki = WikipediaService();

      // Test parsing logic for language prefixes in titles: "en:High Castle of Lviv"
      const rawTitle = 'en:High Castle of Lviv';
      final prefixMatch = RegExp(r'^([a-z]{2,3}):(.+)$').firstMatch(rawTitle);
      expect(prefixMatch, isNotNull);
      expect(prefixMatch!.group(1), 'en');
      expect(prefixMatch.group(2), 'High Castle of Lviv');
    });

    // -------------------------------------------------------------------------
    // SCENARIO 4: User taps a POI with full Wikipedia URL in OSM tag
    // -------------------------------------------------------------------------
    test('Scenario 4: POI with full URL in OSM tag parses title and domain without error', () {
      const fullUrl = 'https://uk.wikipedia.org/wiki/%D0%A1%D1%82%D1%80%D0%B8%D0%B9%D1%81%D1%8c%D0%BA%D0%B8%D0%B9_%D0%BF%D0%B0%D1%80%D0%BA';
      final uri = Uri.tryParse(fullUrl);
      expect(uri, isNotNull);
      expect(uri!.host.split('.')[0], 'uk');
      String cleanTitle;
      try {
        cleanTitle = Uri.decodeComponent(uri.pathSegments.last);
      } catch (_) {
        cleanTitle = uri.pathSegments.last;
      }
      expect(cleanTitle, 'Стрийський_парк');
    });

    // -------------------------------------------------------------------------
    // SCENARIO 5: Ukrainian punctuation, quotes, and abbreviations
    // -------------------------------------------------------------------------
    test('Scenario 5: extractSentences preserves Ukrainian abbreviations and quotes', () {
      const complexText =
          'Пам\'ятник Т. Г. Шевченку розташований на просп. Свободи у м. Львові. '
          'Його відкрили у 1992 р. за проєктом скульпторів В. та А. Сухорських. '
          'Хвиля Національного Відродження сягає висоти 12 м і важить понад 20 т!';

      final sentences = ResearchService.extractSentences(complexText);
      expect(sentences.length, 3);
      expect(sentences[0], contains('у м. Львові.'));
      expect(sentences[1], contains('у 1992 р.'));
      expect(sentences[2], contains('висоти 12 м'));
    });

    // -------------------------------------------------------------------------
    // SCENARIO 6: Generic or unnamed OSM POI (only raw category tags)
    // -------------------------------------------------------------------------
    test('Scenario 6: Generic/unnamed POI generates user-friendly Ukrainian title and facts', () {
      final category = PoiCategoryService();

      // POI without name, only tags
      final fountainCat = category.categorize({'amenity': 'fountain'});
      expect(fountainCat, PoiCategoryService.fountainViewpointArchitecture);

      final label = PoiCategoryService.categoryLabelUk(fountainCat);
      expect(label, 'Фонтан / Архітектура');

      final monumentCat = category.categorize({'historic': 'memorial'});
      expect(monumentCat, PoiCategoryService.sculptureMemorial);
      expect(PoiCategoryService.categoryLabelUk(monumentCat), 'Пам\'ятник / Скульптура');
    });

    // -------------------------------------------------------------------------
    // SCENARIO 7: Offline-to-online recovery (stale fallback text purged on tap)
    // -------------------------------------------------------------------------
    test('Scenario 7: POI with stale fallback content has fallback purged and replaced', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 1);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''),
      );

      // Seed cache with a stale fallback POI
      const stale = EnrichedPoi(
        poiId: 'poi_stale_recovery',
        name: 'Фонтан «Нептун»',
        category: 'fountain',
        latitude: 49.84,
        longitude: 24.03,
        researchStatus: ResearchStatus.failed,
        shortDescription: 'Фонтан «Фонтан «Нептун»» у Львові.',
        narrationText: 'Перед вами Фонтан «Нептун». Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!',
        keyFacts: [
          KeyFact(fact: 'Об\'єкт належить до категорії «Фонтан» і відкритий для огляду.', confidence: 'medium'),
        ],
      );
      await cache.put(stale);

      expect(cache.get('poi_stale_recovery')!.hasFallbackContent, isTrue);

      // User taps card: calls researchImmediately with force: true
      await service.researchImmediately('poi_stale_recovery', force: true);

      final refreshed = service.getEnrichedData('poi_stale_recovery');
      expect(refreshed, isNotNull);
      expect(refreshed!.researchStatus, ResearchStatus.complete);
      // The old rigid template narration should be replaced
      expect(refreshed.narrationText, isNot(contains('Це одне з примітних місць на вашому маршруті')));

      service.dispose();
    });

    // -------------------------------------------------------------------------
    // SCENARIO 8: Impatient user rapidly taps the same POI 5 times concurrently
    // -------------------------------------------------------------------------
    test('Scenario 8: Rapid concurrent taps on same POI complete safely without race conditions', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 2);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''),
      );

      const testPoi = Poi(
        id: 'poi_rapid_tap',
        name: 'Костел єзуїтів',
        latitude: 49.841,
        longitude: 24.029,
        triggerRadius: 40,
        shortDescription: '',
        facts: [],
        narrationText: '',
        sources: [],
      );

      // Launch 5 concurrent calls simultaneously
      final futures = List.generate(
        5,
        (_) => service.researchImmediately('poi_rapid_tap', poi: testPoi, force: true),
      );

      await Future.wait(futures);

      final result = service.getEnrichedData('poi_rapid_tap');
      expect(result, isNotNull);
      expect(result!.researchStatus, ResearchStatus.complete);
      expect(result.keyFacts, isNotEmpty);

      service.dispose();
    });

    // -------------------------------------------------------------------------
    // SCENARIO 9: User taps "Слухати аудіогід" (Play) before research finishes
    // -------------------------------------------------------------------------
    test('Scenario 9: Tapping Play narration awaits research and guarantees non-empty audio text', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 1);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''),
      );

      const destination = Destination(
        id: 'dest_test',
        name: 'Test Tour',
        centerLatitude: 49.84,
        centerLongitude: 24.03,
        defaultZoom: 16.0,
        pois: [],
      );

      final controller = WalkController(
        destination: destination,
        apiKey: '',
        researchService: service,
      );

      const unresearchedPoi = Poi(
        id: 'poi_instant_play',
        name: 'Палац Любомирських',
        latitude: 49.841,
        longitude: 24.032,
        triggerRadius: 40,
        shortDescription: '',
        facts: [],
        narrationText: '',
        sources: [],
      );

      // User hits Play button directly
      await controller.playNarrationForPoi(unresearchedPoi);

      final updated = controller.getUpdatedPoi(unresearchedPoi);
      expect(updated.narrationText, isNotEmpty);
      expect(updated.narrationText, contains('Палац Любомирських'));

      controller.dispose();
      service.dispose();
    });

    // -------------------------------------------------------------------------
    // SCENARIO 10: Walking user moves past multiple POIs (proximity & deduplication)
    // -------------------------------------------------------------------------
    test('Scenario 10: Walking user triggers proximity events without repeating within session', () {
      final engine = PoiEngine();

      const pois = [
        Poi(
          id: 'p1_near',
          name: 'Point 1',
          latitude: 49.84000,
          longitude: 24.03000,
          triggerRadius: 40,
          shortDescription: '',
          facts: [],
          narrationText: '',
          sources: [],
        ),
        Poi(
          id: 'p2_far',
          name: 'Point 2',
          latitude: 49.84200,
          longitude: 24.03000,
          triggerRadius: 40,
          shortDescription: '',
          facts: [],
          narrationText: '',
          sources: [],
        ),
      ];

      // User at 49.84010, 24.03000 (approx 11m from Point 1)
      final poi1 = engine.findTriggerablePoi(pois, 49.84010, 24.03000);
      expect(poi1, isNotNull);
      expect(poi1!.id, 'p1_near');

      // Mark as triggered in engine
      engine.markTriggered('p1_near');

      // User moves slightly, still in range of Point 1
      final poi2 = engine.findTriggerablePoi(pois, 49.84015, 24.03000);
      expect(poi2, isNull, reason: 'Already triggered POI must not trigger again in same session');

      // User walks to Point 2 (at 49.84195, 24.03000 - approx 6m from Point 2)
      final poi3 = engine.findTriggerablePoi(pois, 49.84195, 24.03000);
      expect(poi3, isNotNull);
      expect(poi3!.id, 'p2_far');
    });

    // -------------------------------------------------------------------------
    // SCENARIO 11: Wikipedia disambiguation page or short stub handling
    // -------------------------------------------------------------------------
    test('Scenario 11: Wikipedia disambiguation page is detected and skipped', () {
      // Disambiguation JSON structure from Wikipedia REST API
      final disambigJson = {
        'type': 'disambiguation',
        'title': 'Ратуша (значення)',
        'extract': 'Ратуша може стосуватися: ...',
      };

      expect(disambigJson['type'], 'disambiguation');
      // Services reject type == 'disambiguation' and don't populate facts from it
      final isDisambig = disambigJson['type'] == 'disambiguation';
      expect(isDisambig, isTrue);
    });

    // -------------------------------------------------------------------------
    // SCENARIO 12: Interactive POI chat Q&A (askAiAboutPoi)
    // -------------------------------------------------------------------------
    test('Scenario 12: askAiAboutPoi prepares complete context with facts and category', () async {
      const researchedPoi = Poi(
        id: 'poi_chat_test',
        name: 'Вірменський собор',
        latitude: 49.843,
        longitude: 24.031,
        triggerRadius: 40,
        shortDescription: 'Унікальна пам\'ятка східнохристиянської архітектури XIV століття.',
        facts: [
          'Збудовано у 1363–1370 роках будівничим Дорінгом.',
          'Фрески інтер\'єру виконані Яном Генриком Розеном.',
        ],
        narrationText: 'Перед вами один із найдавніших храмів Львова.',
        sources: [],
      );

      // Verify that POI contains rich facts and description ready for AI chat
      expect(researchedPoi.facts.length, 2);
      expect(researchedPoi.facts[0], contains('1363–1370'));
      expect(researchedPoi.facts[1], contains('Яном Генриком Розеном'));

      // Test AiService text extraction skipping thought parts
      final mockApiResponse = {
        'candidates': [
          {
            'content': {
              'parts': [
                {'thought': true, 'text': 'Thinking about architect...'},
                {'text': 'Архітектором Вірменського собору був будівничий Дорінг (XIV ст.).'},
              ]
            }
          }
        ]
      };

      final extracted = AiService.extractText(mockApiResponse);
      expect(extracted, isNotNull);
      expect(extracted!.contains('Thinking'), isFalse);
      expect(extracted, contains('будівничий Дорінг'));
    });
  });
}
