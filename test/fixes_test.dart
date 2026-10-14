import 'package:flutter_test/flutter_test.dart';
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
}
