import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/research_queue.dart';

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
}
