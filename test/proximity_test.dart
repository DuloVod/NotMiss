import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/models/proximity_event.dart';
import 'package:notmiss/services/poi_engine.dart';

void main() {
  // Test POI: Lviv center area
  Poi makePoi(String id, double lat, double lng, {double radius = 40.0}) {
    return Poi(
      id: id,
      name: 'Test POI $id',
      latitude: lat,
      longitude: lng,
      triggerRadius: radius,
      shortDescription: 'desc',
      facts: [],
      narrationText: '',
      sources: [],
    );
  }

  // Reference point: ~49.8205, 24.0270 (Stryiskyi Park area)
  const userLat = 49.8205;
  const userLng = 24.0270;

  group('PoiEngine proximity detection', () {
    late PoiEngine engine;

    setUp(() {
      engine = PoiEngine();
    });

    test('1. User at 35m — event registers', () {
      // ~35m north of user
      final poi = makePoi('p1', 49.82081, 24.0270);
      final result = engine.findTriggerablePoi([poi], userLat, userLng);
      expect(result, isNotNull);
      expect(result!.id, 'p1');
    });

    test('2. User at 100m — no event', () {
      // ~100m north of user
      final poi = makePoi('p2', 49.8214, 24.0270);
      final result = engine.findTriggerablePoi([poi], userLat, userLng);
      expect(result, isNull);
    });

    test('3. Multiple GPS updates near same POI — triggers only once', () {
      final poi = makePoi('p3', 49.82081, 24.0270);
      final pois = [poi];

      // First check — should trigger
      final r1 = engine.findTriggerablePoi(pois, userLat, userLng);
      expect(r1, isNotNull);
      engine.markTriggered(r1!.id);

      // Second check at slightly different position — should NOT trigger
      final r2 = engine.findTriggerablePoi(pois, userLat + 0.00001, userLng);
      expect(r2, isNull);

      // Third check — still no
      final r3 = engine.findTriggerablePoi(pois, userLat - 0.00001, userLng);
      expect(r3, isNull);
    });

    test('4. User leaves and returns to same POI — no re-trigger within session', () {
      final poi = makePoi('p4', 49.82081, 24.0270);
      final pois = [poi];

      // Trigger
      final r1 = engine.findTriggerablePoi(pois, userLat, userLng);
      expect(r1, isNotNull);
      engine.markTriggered(r1!.id);

      // Walk far away (200m)
      final r2 = engine.findTriggerablePoi(pois, 49.8225, 24.0270);
      expect(r2, isNull);

      // Come back within range
      final r3 = engine.findTriggerablePoi(pois, userLat, userLng);
      expect(r3, isNull); // Still blocked
    });

    test('5. After resetSession, same POI can trigger again', () {
      final poi = makePoi('p5', 49.82081, 24.0270);
      final pois = [poi];

      // First session
      final r1 = engine.findTriggerablePoi(pois, userLat, userLng);
      expect(r1, isNotNull);
      engine.markTriggered(r1!.id);

      // Reset (simulates Stop Walk → Start Walk)
      engine.resetSession();

      // Same POI should trigger again
      final r2 = engine.findTriggerablePoi(pois, userLat, userLng);
      expect(r2, isNotNull);
      expect(r2!.id, 'p5');
    });

    test('picks closest POI when multiple are in range', () {
      // Two POIs, both within 40m, but one is closer
      final near = makePoi('near', 49.82065, 24.0270); // ~17m
      final far = makePoi('far', 49.82081, 24.0270);  // ~35m
      final result = engine.findTriggerablePoi([near, far], userLat, userLng);
      expect(result, isNotNull);
      expect(result!.id, 'near');
    });

    test('distanceTo uses Haversine (not Euclidean)', () {
      final poi = makePoi('geo', 49.8215, 24.0270);
      final dist = engine.distanceTo(poi, userLat, userLng);
      // ~111m per degree of latitude, so 0.001° ≈ 111m
      expect(dist, greaterThan(100));
      expect(dist, lessThan(120));
    });
  });

  group('ProximityEvent', () {
    test('stores all fields correctly', () {
      final event = ProximityEvent(
        poiId: 'test1',
        poiName: 'Test Place',
        poiLat: 49.82081,
        poiLng: 24.0270,
        userLat: 49.8205,
        userLng: 24.0270,
        distanceM: 34.5,
        timestamp: DateTime(2026, 10, 9, 12, 0),
      );

      expect(event.poiId, 'test1');
      expect(event.poiName, 'Test Place');
      expect(event.distanceM, 34.5);
      expect(event.toString(), contains('Test Place'));
      expect(event.toString(), contains('34.5'));
    });
  });

  group('Overpass response parsing', () {
    test('6. Empty Overpass result does not crash', () {
      // Simulate parsing empty elements list
      final pois = _parseTestElements([]);
      expect(pois, isEmpty);
    });

    test('8. Way/relation with center — coordinates extracted', () {
      final elements = [
        {
          'type': 'way',
          'id': 12345,
          'center': {'lat': 49.822, 'lon': 24.028},
          'tags': {'name': 'Test Way', 'historic': 'monument'},
        },
        {
          'type': 'relation',
          'id': 67890,
          'center': {'lat': 49.823, 'lon': 24.029},
          'tags': {'name': 'Test Relation', 'tourism': 'attraction'},
        },
      ];

      final pois = _parseTestElements(elements);
      expect(pois.length, 2);
      expect(pois[0].id, 'osm_way_12345');
      expect(pois[0].latitude, 49.822);
      expect(pois[0].longitude, 24.028);
      expect(pois[1].id, 'osm_relation_67890');
    });

    test('way without center is skipped', () {
      final elements = [
        {
          'type': 'way',
          'id': 11111,
          'tags': {'name': 'No Center', 'historic': 'ruins'},
        },
      ];
      final pois = _parseTestElements(elements);
      expect(pois, isEmpty);
    });

    test('node without name is skipped', () {
      final elements = [
        {
          'type': 'node',
          'id': 22222,
          'lat': 49.82,
          'lon': 24.03,
          'tags': {'historic': 'ruins'},
        },
      ];
      final pois = _parseTestElements(elements);
      expect(pois, isEmpty);
    });

    test('node with name is included', () {
      final elements = [
        {
          'type': 'node',
          'id': 33333,
          'lat': 49.82,
          'lon': 24.03,
          'tags': {'name': 'Named Node', 'tourism': 'viewpoint'},
        },
      ];
      final pois = _parseTestElements(elements);
      expect(pois.length, 1);
      expect(pois[0].name, 'Named Node');
      expect(pois[0].id, 'osm_node_33333');
      expect(pois[0].confidence, 'osm');
    });

    test('duplicate OSM IDs are deduplicated', () {
      final elements = [
        {
          'type': 'node',
          'id': 44444,
          'lat': 49.82,
          'lon': 24.03,
          'tags': {'name': 'Dup', 'tourism': 'attraction'},
        },
        {
          'type': 'node',
          'id': 44444,
          'lat': 49.82,
          'lon': 24.03,
          'tags': {'name': 'Dup', 'tourism': 'attraction'},
        },
      ];
      final pois = _parseTestElements(elements);
      expect(pois.length, 1);
    });
  });

  group('Repeated start/stop', () {
    test('11. Reset clears triggered set', () {
      final engine = PoiEngine();
      final poi = makePoi('rs1', 49.82081, 24.0270);

      engine.findTriggerablePoi([poi], userLat, userLng);
      engine.markTriggered('rs1');
      expect(engine.triggeredPoiIds, contains('rs1'));

      engine.resetSession();
      expect(engine.triggeredPoiIds, isEmpty);
    });
  });
}

/// Mimics OverpassService._parseElements for testing without network.
/// This is a simplified copy to validate parsing logic in tests.
List<Poi> _parseTestElements(List<dynamic> elements) {
  final pois = <Poi>[];
  final seenIds = <String>{};

  for (final el in elements) {
    final type = el['type'] as String?;
    final osmId = el['id'];
    if (type == null || osmId == null) continue;

    final id = 'osm_${type}_$osmId';
    if (seenIds.contains(id)) continue;

    double? lat;
    double? lng;

    if (type == 'node') {
      lat = (el['lat'] as num?)?.toDouble();
      lng = (el['lon'] as num?)?.toDouble();
    } else {
      final center = el['center'] as Map<String, dynamic>?;
      if (center != null) {
        lat = (center['lat'] as num?)?.toDouble();
        lng = (center['lon'] as num?)?.toDouble();
      }
    }

    if (lat == null || lng == null) continue;

    final tags = el['tags'] as Map<String, dynamic>? ?? {};
    final name = tags['name'] as String?;
    if (name == null || name.isEmpty) continue;

    seenIds.add(id);

    pois.add(Poi(
      id: id,
      name: name,
      latitude: lat,
      longitude: lng,
      triggerRadius: 40.0,
      shortDescription: '',
      facts: [],
      narrationText: '',
      sources: [],
      confidence: 'osm',
    ));
  }

  return pois;
}
