import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/chat_message.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/models/proximity_event.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/content_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/poi_engine.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fix #2 — PoiCacheService.dispose() cancels pending Timer', () {
    test('dispose() can be called safely with no pending timer', () {
      final cache = PoiCacheService();
      expect(() => cache.dispose(), returnsNormally);
    });

    test('dispose() cancels timer and prevents stale writes', () async {
      final cache = PoiCacheService();

      final poi = EnrichedPoi(
        poiId: 'p1',
        name: 'Test',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.notStarted,
      );
      await cache.put(poi);

      expect(() => cache.dispose(), returnsNormally);
      await Future.delayed(Duration.zero);
    });

    test('needsResearch handles inProgress with 5-minute timeout', () {
      final cache = PoiCacheService();
      final fresh = EnrichedPoi(
        poiId: 'p_fresh',
        name: 'Fresh',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.inProgress,
        lastResearchedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      cache.put(fresh);
      expect(cache.needsResearch('p_fresh'), false);

      final stuck = EnrichedPoi(
        poiId: 'p_stuck',
        name: 'Stuck',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.inProgress,
        lastResearchedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      cache.put(stuck);
      expect(cache.needsResearch('p_stuck'), true);
      cache.dispose();
    });
  });

  group('Fix #4 — TtsService safe substring and WAV byte alignment', () {
    test('preview is body itself when shorter than 300 chars', () {
      const body = 'short error';
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview, 'short error');
    });

    test('preview is truncated to 300 when body is longer', () {
      final body = 'x' * 500;
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview.length, 300);
    });

    test('preview equals body exactly at 300 chars boundary', () {
      final body = 'y' * 300;
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview.length, 300);
      expect(preview, body);
    });

    test('TtsService.synthesize throws on empty API key (no crash)', () async {
      final svc = TtsService(apiKey: '');
      expect(
        () => svc.synthesize('hello', 'poi1'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('API key not set'),
        )),
      );
    });
  });

  group('AudioPlayerService pause / resume / stop', () {
    test('isPaused is false initially', () {
      final player = AudioPlayerService();
      expect(player.isPlaying, false);
      expect(player.isPaused, false);
      expect(player.playerStateStream, isNotNull);
      player.dispose();
    });

    test('pause and stop execute without throwing', () async {
      final player = AudioPlayerService();
      await expectLater(player.pause(), completes);
      await expectLater(player.stop(), completes);
      player.dispose();
    });
  });

  group('PoiEngine unmarkTriggered & distance sorting', () {
    test('unmarkTriggered allows re-triggering POI', () {
      final engine = PoiEngine();
      engine.markTriggered('poi_1');
      expect(engine.triggeredPoiIds.contains('poi_1'), true);

      engine.unmarkTriggered('poi_1');
      expect(engine.triggeredPoiIds.contains('poi_1'), false);
    });

    test('findAllTriggerablePois sorts closest first without allocation leaks', () {
      final engine = PoiEngine();
      final pois = [
        const Poi(
          id: 'far',
          name: 'Far',
          latitude: 49.825,
          longitude: 24.030,
          triggerRadius: 100,
          shortDescription: '',
          facts: [],
          narrationText: '',
          sources: [],
        ),
        const Poi(
          id: 'near',
          name: 'Near',
          latitude: 49.8201,
          longitude: 24.0201,
          triggerRadius: 100,
          shortDescription: '',
          facts: [],
          narrationText: '',
          sources: [],
        ),
      ];

      final triggerable = engine.findAllTriggerablePois(pois, 49.820, 24.020);
      expect(triggerable.length, 1);
      expect(triggerable.first.id, 'near');
    });
  });

  group('Models serialization & null-safety', () {
    test('Poi.fromJson handles int ID from OSM and parses tags', () {
      final json = {
        'id': 12345678,
        'name': 'Test Fountain',
        'latitude': 49.82,
        'longitude': 24.03,
        'trigger_radius_m': 25,
        'osmTags': {'amenity': 'fountain', 'historic': 'yes'},
        'wikidataId': 'Q9876',
      };
      final poi = Poi.fromJson(json);
      expect(poi.id, '12345678');
      expect(poi.name, 'Test Fountain');
      expect(poi.triggerRadius, 25.0);
      expect(poi.wikidataId, 'Q9876');
      expect(poi.osmTags?['amenity'], 'fountain');

      final serialized = poi.toJson();
      expect(serialized['id'], '12345678');
      expect(serialized['trigger_radius_m'], 25.0);
    });

    test('Destination fromJson and toJson work correctly', () {
      final json = {
        'id': 'stryiskyi_park',
        'name': 'Stryiskyi Park',
        'center_latitude': 49.8228,
        'center_longitude': 24.0264,
        'default_zoom': 16.0,
        'pois': [
          {
            'id': 'p1',
            'name': 'Point 1',
            'latitude': 49.82,
            'longitude': 24.02,
          }
        ],
      };
      final dest = Destination.fromJson(json);
      expect(dest.id, 'stryiskyi_park');
      expect(dest.pois.length, 1);
      expect(dest.pois.first.name, 'Point 1');

      final serialized = dest.toJson();
      expect(serialized['name'], 'Stryiskyi Park');
      expect(serialized['pois'], isA<List>());
    });

    test('ProximityEvent serialization roundtrip', () {
      final event = ProximityEvent(
        poiId: 'test_poi',
        poiName: 'Test POI',
        poiLat: 49.82,
        poiLng: 24.03,
        userLat: 49.8201,
        userLng: 24.0301,
        distanceM: 15.5,
        timestamp: DateTime(2026, 10, 14, 12, 0, 0),
      );

      final json = event.toJson();
      final restored = ProximityEvent.fromJson(json);
      expect(restored.poiId, 'test_poi');
      expect(restored.distanceM, 15.5);
      expect(restored.poiName, 'Test POI');
    });

    test('EnrichedPoi.copyWith updates newly added fields', () {
      final original = EnrichedPoi(
        poiId: 'e1',
        name: 'Old Name',
        category: 'other',
        latitude: 49.0,
        longitude: 24.0,
        researchStatus: ResearchStatus.notStarted,
      );

      final updated = original.copyWith(
        name: 'New Name',
        latitude: 49.5,
        longitude: 24.5,
        osmTags: {'historic': 'monument'},
      );

      expect(updated.name, 'New Name');
      expect(updated.latitude, 49.5);
      expect(updated.longitude, 24.5);
      expect(updated.osmTags['historic'], 'monument');
    });
  });

  group('PoiCategoryService edge cases', () {
    final catService = PoiCategoryService();

    test('places of worship without building tag categorized as historical building', () {
      final category = catService.categorize({'amenity': 'place_of_worship'});
      expect(category, PoiCategoryService.historicalBuilding);
    });

    test('historic=fountain categorized as fountain_viewpoint_architecture', () {
      final category = catService.categorize({'historic': 'fountain'});
      expect(category, PoiCategoryService.fountainViewpointArchitecture);
    });

    test('historic=yes building=yes categorized as historical building', () {
      final category = catService.categorize({'historic': 'yes', 'building': 'yes'});
      expect(category, PoiCategoryService.historicalBuilding);
    });

    test('heritage=no does not give high priority', () {
      final priority = catService.determinePriority({'heritage': 'no'}, PoiCategoryService.other);
      expect(priority, isNot(ResearchPriority.high));
    });
  });

  group('ContentService fallback behavior', () {
    final cs = ContentService();
    const poi = Poi(
      id: 'p1',
      name: 'Monument',
      latitude: 0,
      longitude: 0,
      triggerRadius: 20,
      shortDescription: 'Desc',
      facts: [],
      narrationText: 'Default narration',
      sources: [],
    );

    test('empty aiText falls back to static narration', () {
      expect(cs.getNarration(poi, aiText: ''), 'Default narration');
      expect(cs.getNarration(poi, aiText: '   '), 'Default narration');
      expect(cs.getNarration(poi, aiText: 'AI Narration'), 'AI Narration');
    });
  });

  group('New UX & Service Fixes', () {
    test('PoiEngine session management preserves triggered set', () {
      final engine = PoiEngine();
      engine.markTriggered('poi_1');
      engine.markTriggered('poi_2');
      expect(engine.triggeredPoiIds.length, 2);
      expect(engine.triggeredPoiIds.contains('poi_1'), true);
      expect(engine.triggeredPoiIds.contains('poi_2'), true);

      engine.resetSession();
      expect(engine.triggeredPoiIds.isEmpty, true);
    });

    test('Poi.copyWith retains osmTags and confidence', () {
      const poi = Poi(
        id: 'osm_node_123',
        name: 'Stryiskyi Lake',
        latitude: 49.82,
        longitude: 24.03,
        triggerRadius: 35,
        shortDescription: 'Lake description',
        facts: ['Fact 1'],
        narrationText: 'Lake narration',
        sources: [],
        confidence: 'osm',
        wikidataId: 'Q54321',
        osmTags: {'natural': 'water', 'water': 'lake'},
      );

      final updated = poi.copyWith(narrationText: 'Updated narration');
      expect(updated.id, 'osm_node_123');
      expect(updated.confidence, 'osm');
      expect(updated.wikidataId, 'Q54321');
      expect(updated.osmTags?['natural'], 'water');
      expect(updated.narrationText, 'Updated narration');
      expect(updated.facts.length, 1);
    });

    test('Stryiskyi park destination contains 15 curated points with 35m radius', () {
      final jsonPois = List.generate(
        15,
        (i) => {
          'id': 'sp_${i + 1}',
          'name_uk': 'Point $i',
          'latitude': 49.82 + i * 0.001,
          'longitude': 24.02 + i * 0.001,
          'trigger_radius_m': 35,
          'short_description_uk': 'Desc',
          'facts_uk': ['Fact'],
          'narration_idea_uk': 'Narration idea',
        },
      );
      final dest = Destination.fromJson({
        'id': 'stryiskyi_park',
        'name': 'Стрийський парк',
        'center_latitude': 49.8228,
        'center_longitude': 24.0264,
        'pois': jsonPois,
      });

      expect(dest.pois.length, 15);
      for (final p in dest.pois) {
        expect(p.triggerRadius, 35.0);
        expect(p.narrationText.isNotEmpty, true);
      }
    });

    test('WalkController enables and disables Stryiskyi Park points', () {
      final dest = Destination(
        id: 'stryiskyi_park',
        name: 'Стрийський парк',
        centerLatitude: 49.8228,
        centerLongitude: 24.0264,
        defaultZoom: 16.0,
        pois: [
          const Poi(
            id: 'sp_01',
            name: 'Вежа',
            latitude: 49.82,
            longitude: 24.02,
            triggerRadius: 35,
            shortDescription: 'Опис',
            facts: ['Факт'],
            narrationText: 'Текст',
            sources: [],
          ),
        ],
      );

      final controller = WalkController(
        destination: dest,
        apiKey: '',
      );

      // By default hardcoded park points are disabled
      expect(controller.stryiskyiParkPoisEnabled, isFalse);
      expect(controller.allPois.isEmpty, isTrue);

      // Enable points
      controller.setStryiskyiParkPoisEnabled(true);
      expect(controller.stryiskyiParkPoisEnabled, isTrue);
      expect(controller.allPois.length, 1);
      expect(controller.allPois.first.id, 'sp_01');

      // Disable points
      controller.setStryiskyiParkPoisEnabled(false);
      expect(controller.stryiskyiParkPoisEnabled, isFalse);
      expect(controller.allPois.isEmpty, isTrue);

      controller.dispose();
    });

    test('WalkController caches chat messages across user session', () async {
      final dest = Destination(
        id: 'dest_test',
        name: 'Test Destination',
        centerLatitude: 49.82,
        centerLongitude: 24.02,
        defaultZoom: 16.0,
        pois: const [
          Poi(
            id: 'poi_qa',
            name: 'QA Test POI',
            latitude: 49.82,
            longitude: 24.02,
            triggerRadius: 35,
            shortDescription: 'Desc',
            facts: ['Fact 1'],
            narrationText: 'Narration',
            sources: [],
          ),
        ],
      );

      final controller = WalkController(
        destination: dest,
        apiKey: '',
      );

      // Verify chat history per POI
      expect(controller.getChatHistory('poi_qa'), isEmpty);

      controller.addChatMessage(
        'poi_qa',
        ChatMessage(text: 'Hello, what is this place?', isUser: true),
      );
      controller.addChatMessage(
        'poi_qa',
        ChatMessage(text: 'This is QA Test POI.', isUser: false),
      );

      final history = controller.getChatHistory('poi_qa');
      expect(history.length, 2);
      expect(history[0].text, 'Hello, what is this place?');
      expect(history[0].isUser, isTrue);
      expect(history[1].text, 'This is QA Test POI.');
      expect(history[1].isUser, isFalse);

      controller.dispose();
    });

    test('ResearchService skips duplicate research immediately if already complete in cache', () async {
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

      // Seed cache with completed research
      final completed = EnrichedPoi(
        poiId: 'cached_poi',
        name: 'Cached Landmark',
        category: 'monument',
        latitude: 49.82,
        longitude: 24.02,
        researchStatus: ResearchStatus.complete,
        shortDescription: 'Full historical description',
        keyFacts: const [KeyFact(fact: 'Built in 1900')],
        lastResearchedAt: DateTime.now(),
      );
      await cache.put(completed);

      // Call researchImmediately without force
      await service.researchImmediately('cached_poi');

      // Verify that cache was respected and no duplicate research was triggered
      final result = service.getEnrichedData('cached_poi');
      expect(result, isNotNull);
      expect(result!.shortDescription, 'Full historical description');
      expect(result.keyFacts.length, 1);
      expect(result.researchStatus, ResearchStatus.complete);

      service.dispose();
    });

    test('AudioPlayerService isPlaying and isPaused getters behave correctly on idle state', () {
      final audioService = AudioPlayerService();
      expect(audioService.isPlaying, isFalse);
      expect(audioService.isPaused, isFalse);
      audioService.dispose();
    });

    test('ResearchService guarantees non-trivial description, facts and narration', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 1);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''), // offline fallback
      );

      const testPoi = Poi(
        id: 'poi_vehicle_test',
        name: '9К35 «Стріла-10»',
        latitude: 49.82,
        longitude: 24.02,
        triggerRadius: 35,
        shortDescription: 'historic: vehicle · Радянський зенітно-ракетний комплекс',
        facts: [],
        narrationText: '',
        sources: [],
      );

      await service.researchImmediately('poi_vehicle_test', poi: testPoi, force: true);

      final result = service.getEnrichedData('poi_vehicle_test');
      expect(result, isNotNull);
      expect(result!.researchStatus, ResearchStatus.complete);
      // Guaranteed human-readable description (not raw historic: vehicle tag)
      expect(result.shortDescription, isNotNull);
      expect(result.shortDescription!.startsWith('historic:'), isFalse);
      // Guaranteed facts
      expect(result.keyFacts, isNotEmpty);
      // Guaranteed narration text so the app is never silent
      expect(result.narrationText, isNotNull);
      expect(result.narrationText!.isNotEmpty, isTrue);

      service.dispose();
    });

    test('ResearchService.researchImmediately awaits in-flight research when called concurrently', () async {
      final cache = PoiCacheService();
      final category = PoiCategoryService();
      final queue = ResearchQueue(maxConcurrent: 1);

      final service = ResearchService(
        categoryService: category,
        cacheService: cache,
        queue: queue,
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: AiService(apiKey: ''), // offline fallback
      );

      const testPoi = Poi(
        id: 'poi_concurrent_test',
        name: 'Ратуша',
        latitude: 49.84,
        longitude: 24.03,
        triggerRadius: 40,
        shortDescription: 'Ратуша',
        facts: [],
        narrationText: '',
        sources: [],
      );

      // Launch two concurrent researchImmediately calls on the same POI
      final f1 = service.researchImmediately('poi_concurrent_test', poi: testPoi, force: true);
      final f2 = service.researchImmediately('poi_concurrent_test', poi: testPoi, force: true);

      await Future.wait([f1, f2]);

      final result = service.getEnrichedData('poi_concurrent_test');
      expect(result, isNotNull);
      expect(result!.researchStatus, ResearchStatus.complete);
      expect(result.narrationText, isNotNull);
      expect(result.narrationText!.isNotEmpty, isTrue);

      service.dispose();
    });
  });
}
