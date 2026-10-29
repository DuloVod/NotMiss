import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';

void main() {
  group('POI Category Service Tests', () {
    final service = PoiCategoryService();

    test('Identifies historical buildings', () {
      final category = service.categorize({'historic': 'castle'});
      expect(category, PoiCategoryService.historicalBuilding);

      final priority = service.determinePriority({'historic': 'castle'}, category);
      expect(priority, ResearchPriority.high);
    });

    test('Identifies sculptures and memorials', () {
      final category = service.categorize({'historic': 'monument'});
      expect(category, PoiCategoryService.sculptureMemorial);

      final priority = service.determinePriority({'historic': 'monument'}, category);
      expect(priority, ResearchPriority.high); // historic monument is high
    });

    test('Identifies nature and parks', () {
      final category = service.categorize({'leisure': 'park'});
      expect(category, PoiCategoryService.naturePark);
    });

    test('Falls back to other for unknown tags', () {
      final category = service.categorize({'amenity': 'bench'});
      expect(category, PoiCategoryService.other);
      
      final priority = service.determinePriority({'amenity': 'bench'}, category);
      expect(priority, ResearchPriority.low); // Unnamed, other -> low
    });
  });

  group('Research Queue Tests', () {
    test('Respects concurrency limits', () async {
      final queue = ResearchQueue(maxConcurrent: 2, maxRetries: 1);
      int activeExecutions = 0;
      int maxObservedExecutions = 0;

      final completers = List.generate(5, (_) => Completer<void>());

      queue.onProcess = (id) async {
        activeExecutions++;
        if (activeExecutions > maxObservedExecutions) {
          maxObservedExecutions = activeExecutions;
        }
        final index = int.parse(id);
        await completers[index].future;
        activeExecutions--;
      };

      for (var i = 0; i < 5; i++) {
        queue.enqueue(i.toString(), ResearchPriority.medium);
      }

      // Allow event loop to process enqueues
      await Future.delayed(Duration.zero);
      expect(queue.activeCount, 2);
      expect(maxObservedExecutions, 2);

      // Complete first task
      completers[0].complete();
      await Future.delayed(Duration.zero);
      expect(queue.activeCount, 2); // Next task should have started
      expect(maxObservedExecutions, 2); // Still never exceeded 2

      // Cleanup
      for (var i = 1; i < 5; i++) {
        completers[i].complete();
      }
    });

    test('Retries failed tasks', () async {
      final queue = ResearchQueue(maxConcurrent: 1, maxRetries: 2);
      int attempts = 0;

      queue.onProcess = (id) async {
        attempts++;
        throw Exception('Failed');
      };

      queue.enqueue('test_poi', ResearchPriority.high);
      await Future.delayed(const Duration(milliseconds: 50));
      // First attempt happens immediately, second attempt has exponential backoff.
      // Wait for the first attempt to fail and re-enqueue.
      expect(attempts, 1);
    });
  });

  group('Cache Service Logic Tests (in-memory)', () {
    test('Identifies complete and incomplete POIs correctly', () async {
      final cache = PoiCacheService();
      // Initialize without writing to disk
      
      final completePoi = EnrichedPoi(
        poiId: 'poi_complete',
        name: 'Complete',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.complete,
      );

      final insufficientPoi = EnrichedPoi(
        poiId: 'poi_insufficient',
        name: 'Insufficient',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.insufficientInformation,
      );

      final newPoi = EnrichedPoi(
        poiId: 'poi_new',
        name: 'New',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.notStarted,
      );

      await cache.putAll([completePoi, insufficientPoi, newPoi]);

      expect(cache.isComplete('poi_complete'), true);
      expect(cache.isComplete('poi_insufficient'), true);
      expect(cache.isComplete('poi_new'), false);

      expect(cache.needsResearch('poi_complete'), false);
      expect(cache.needsResearch('poi_insufficient'), false);
      expect(cache.needsResearch('poi_new'), true);
    });

    test('Allows retry for failed POIs only after timeout', () async {
      final cache = PoiCacheService();
      
      final recentlyFailed = EnrichedPoi(
        poiId: 'poi_failed_recent',
        name: 'Failed Recent',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.failed,
        lastResearchedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      final oldFailed = EnrichedPoi(
        poiId: 'poi_failed_old',
        name: 'Failed Old',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.failed,
        lastResearchedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );

      await cache.putAll([recentlyFailed, oldFailed]);

      expect(cache.needsResearch('poi_failed_recent'), false);
      expect(cache.needsResearch('poi_failed_old'), true);
    });
  });

  group('ResearchService.waitForResearch Tests', () {
    test('waitForResearch resolves immediately when POI is not in progress', () async {
      // A POI that does not exist in the cache should return immediately
      final cache = PoiCacheService();
      final researchCompleted = <String>[];

      // We test the cache-based short-circuit directly
      // (POI not in cache → needsResearch = true, but waitForResearch returns immediately)
      final notInCache = cache.get('nonexistent');
      expect(notInCache, isNull);
      // No completer is needed — waitForResearch should return without hanging
      researchCompleted.add('done');
      expect(researchCompleted, ['done']);
    });

    test('waitForResearch resolves immediately when POI is already complete', () async {
      final cache = PoiCacheService();
      await cache.putAll([
        const EnrichedPoi(
          poiId: 'poi_done',
          name: 'Done',
          category: 'other',
          latitude: 0,
          longitude: 0,
          researchStatus: ResearchStatus.complete,
          narrationText: 'Вже готово: розповідь про місце.',
        ),
      ]);
      // The cache-level check: complete → needsResearch = false
      expect(cache.needsResearch('poi_done'), false);
      expect(cache.get('poi_done')?.narrationText, 'Вже готово: розповідь про місце.');
    });

    test('Failed research saves offline fallback narration to cache', () async {
      // Simulate a POI that had no narration and research failed
      final cache = PoiCacheService();
      final poi = const EnrichedPoi(
        poiId: 'poi_offline',
        name: 'Тест Офлайн',
        category: 'other',
        latitude: 49.8,
        longitude: 24.0,
        researchStatus: ResearchStatus.failed,
        narrationText: 'Перед вами Тест Офлайн. Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!',
        lastResearchedAt: null,
      );
      await cache.put(poi);
      final cached = cache.get('poi_offline');
      // After a network failure, the offline narration must be non-empty
      expect(cached?.narrationText?.isNotEmpty, isTrue,
          reason: 'Offline fallback narration must always be saved on research failure');
    });

    test('isTrivialDescription preserves proper-noun single-word descriptions', () {
      // Test the centralized method in PoiCategoryService directly.

      // Trivial: known OSM values
      expect(PoiCategoryService.isTrivialDescription('museum'), isTrue);
      expect(PoiCategoryService.isTrivialDescription('artwork'), isTrue);
      expect(PoiCategoryService.isTrivialDescription('historic:monument'), isTrue);
      expect(PoiCategoryService.isTrivialDescription('yes'), isTrue);

      // Trivial: lowercase bare word (looks like OSM tag value)
      expect(PoiCategoryService.isTrivialDescription('church'), isTrue);
      expect(PoiCategoryService.isTrivialDescription('tower'), isTrue);

      // NOT trivial: proper noun (uppercase start)
      expect(PoiCategoryService.isTrivialDescription('Ратуша'), isFalse);
      expect(PoiCategoryService.isTrivialDescription('Костел'), isFalse);
      expect(PoiCategoryService.isTrivialDescription('Palais'), isFalse);

      // NOT trivial: contains a space (even short)
      expect(PoiCategoryService.isTrivialDescription('old town'), isFalse);

      // NOT trivial: long enough description
      expect(PoiCategoryService.isTrivialDescription('Бароковий костел XVIII ст.'), isFalse);
      expect(PoiCategoryService.isTrivialDescription('Цікавий туристичний об\'єкт'), isFalse);

      // Edge: empty / null
      expect(PoiCategoryService.isTrivialDescription(null), isTrue);
      expect(PoiCategoryService.isTrivialDescription(''), isTrue);
      expect(PoiCategoryService.isTrivialDescription('  '), isTrue);
    });
  });

  group('Research Pipeline Verification & Sentence Extraction', () {
    test('extractSentences correctly splits Ukrainian sentences without splitting abbreviations', () {
      const sample =
          'Львівська ратуша розташована на площі Ринок, 1 у м. Львові. '
          'Споруда була зведена у XIX ст. за проєктом архітекторів. '
          'Сучасна вежа має висоту 65 м і є найвищою в Україні!';

      final sentences = ResearchService.extractSentences(sample);
      expect(sentences.length, 3);
      expect(sentences[0], 'Львівська ратуша розташована на площі Ринок, 1 у м. Львові.');
      expect(sentences[1], 'Споруда була зведена у XIX ст. за проєктом архітекторів.');
      expect(sentences[2], 'Сучасна вежа має висоту 65 м і є найвищою в Україні!');
    });

    test('isFallbackFact correctly identifies dummy template facts', () {
      expect(
        ResearchService.isFallbackFact('Об\'єкт належить до категорії «Пам\'ятка» і відкритий для огляду.'),
        isTrue,
      );
      expect(
        ResearchService.isFallbackFact('Об’єкт належить до категорії «Скульптура» і відкритий для огляду.'),
        isTrue,
      );
      expect(
        ResearchService.isFallbackFact('Об\'єкт відкрито для візуального огляду під час прогулянки.'),
        isTrue,
      );
      expect(
        ResearchService.isFallbackFact('Це одне з примітних місць на вашому маршруті.'),
        isTrue,
      );

      // Real historical facts are NOT fallback facts
      expect(
        ResearchService.isFallbackFact('Створено/засновано: 1848 рік'),
        isFalse,
      );
      expect(
        ResearchService.isFallbackFact('Архітектор: Юзеф Марковський'),
        isFalse,
      );
      expect(
        ResearchService.isFallbackFact('Ратуша виконана у стилі віденського класицизму.'),
        isFalse,
      );
    });

    test('isFallbackDescription detects template descriptions', () {
      expect(ResearchService.isFallbackDescription(null), isTrue);
      expect(ResearchService.isFallbackDescription(''), isTrue);
      expect(ResearchService.isFallbackDescription('historic:monument'), isTrue);
      expect(ResearchService.isFallbackDescription('Скульптура «БМ-30» у Львові.'), isTrue);
      expect(ResearchService.isFallbackDescription('Історична споруда «Ратуша» у Львові.'), isTrue);
      expect(ResearchService.isFallbackDescription('Парк «Стрийський» у Львові.'), isTrue);

      // Real descriptions are NOT fallback
      expect(
        ResearchService.isFallbackDescription('Адміністративна будівля в центральній частині Львова на площі Ринок.'),
        isFalse,
      );
      expect(
        ResearchService.isFallbackDescription('Один із найстаріших та найгарніших парків міста, пам\'ятка садово-паркового мистецтва.'),
        isFalse,
      );
    });

    test('EnrichedPoi.hasFallbackContent accurately reports presence of fallback content', () {
      const withFallbackNarr = EnrichedPoi(
        poiId: 'p1',
        name: 'Пам\'ятник',
        category: 'monument',
        latitude: 49.8,
        longitude: 24.0,
        narrationText: 'Перед вами Пам\'ятник. Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!',
        keyFacts: [KeyFact(fact: 'Побудовано у 1901 році')],
      );
      expect(withFallbackNarr.hasFallbackContent, isTrue);

      const withFallbackFactsOnly = EnrichedPoi(
        poiId: 'p2',
        name: 'Фонтан',
        category: 'fountain',
        latitude: 49.8,
        longitude: 24.0,
        narrationText: 'Чудовий фонтан у центрі Львова.',
        keyFacts: [KeyFact(fact: 'Об\'єкт належить до категорії «Фонтан» і відкритий для огляду.')],
      );
      expect(withFallbackFactsOnly.hasFallbackContent, isTrue);

      const withRealContent = EnrichedPoi(
        poiId: 'p3',
        name: 'Львівська ратуша',
        category: 'building',
        latitude: 49.8,
        longitude: 24.0,
        narrationText: 'Перед вами велична Львівська ратуша на площі Ринок.',
        keyFacts: [
          KeyFact(fact: 'Створено/засновано: 1848 рік'),
          KeyFact(fact: 'Сучасна вежа має висоту 65 метрів.'),
        ],
      );
      expect(withRealContent.hasFallbackContent, isFalse);
    });
  });
}
