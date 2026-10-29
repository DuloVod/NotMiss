import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/location_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

Position _at(double lat, double lng) => Position(
      latitude: lat, longitude: lng, timestamp: DateTime(2026, 1, 1), accuracy: 5,
      altitude: 0, altitudeAccuracy: 0, heading: 0, headingAccuracy: 0, speed: 1, speedAccuracy: 0);

const _tower = Poi(
  id: 'osm_node_1', name: 'Порохова вежа', latitude: 49.8449, longitude: 24.0347,
  triggerRadius: 40, shortDescription: '', facts: [], narrationText: '', sources: [], confidence: 'osm');

class _Loc extends LocationService {
  _Loc({this.known});
  final Position? known;
  final StreamController<Position> ctrl = StreamController<Position>.broadcast();
  @override
  Stream<Position> get positionStream => ctrl.stream;
  @override
  Position? get lastPosition => null;
  @override
  Future<Position?> lastKnownPosition() async => known;
  @override
  Future<bool> requestPermission() async => true;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void dispose() {}
}

/// Fails (empty + lastLoadFailed) the first [failures] calls, then returns the tower.
class _FlakyOverpass extends OverpassService {
  _FlakyOverpass(this.failures);
  int failures;
  int calls = 0;
  @override
  bool shouldReload(double lat, double lng) => false;
  @override
  Future<List<Poi>> loadPois(double lat, double lng, {bool force = false}) async {
    calls++;
    if (failures > 0) {
      failures--;
      lastLoadFailed = true;
      return [];
    }
    lastLoadFailed = false;
    return [_tower];
  }
}

class _Ai extends AiService {
  _Ai() : super(apiKey: 'x');
}

class _Tts extends TtsService {
  _Tts() : super(apiKey: 'x');
  @override
  Future<String> synthesize(String text, String poiId) async => '/tmp/x.wav';
}

class _Audio extends AudioPlayerService {
  @override
  Future<void> prepareSession() async {}
  @override
  Future<void> play(String source) async {}
  @override
  Future<void> stop() async {}
}

WalkController _ctl(LocationService loc, OverpassService ov) {
  final c = WalkController(
    destination: const Destination(
        id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
    apiKey: '',
    locationService: loc,
    overpassService: ov,
    ttsService: _Tts(),
    audioService: _Audio(),
    researchService: ResearchService(
      categoryService: PoiCategoryService(),
      cacheService: PoiCacheService(),
      queue: ResearchQueue(),
      wikidataService: WikidataService(),
      wikipediaService: WikipediaService(),
      aiService: _Ai(),
    ),
  );
  c.osmRetryDelay = const Duration(milliseconds: 100);
  return c;
}

Future<void> _until(bool Function() cond, {int seconds = 10}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future.delayed(const Duration(milliseconds: 25));
  }
}

const _json = {'content-type': 'application/json; charset=utf-8'};

String _overpassJson() => jsonEncode({
      'elements': [
        for (var i = 0; i < 4; i++)
          {'type': 'node', 'id': i + 1, 'lat': 49.8449 + i * 0.0001, 'lon': 24.0347, 'tags': {'name': 'Об\'єкт $i', 'historic': 'tower'}}
      ]
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('POI discovery in the walk', () {
    test('network failure is not "loaded": points appear after an automatic retry', () async {
      final ov = _FlakyOverpass(2);
      final loc = _Loc(known: _at(49.8449, 24.0347));
      final c = _ctl(loc, ov);

      await c.startWalk();
      await _until(() => c.allPois.isNotEmpty);

      expect(c.allPois.map((p) => p.id), contains(_tower.id));
      expect(ov.calls, 3, reason: '2 failures + 1 success, no GPS movement needed');
      expect(c.osmLoaded, isTrue);
      c.stopWalk();
      c.dispose();
    });

    test('while failing the user is told what is happening', () async {
      final ov = _FlakyOverpass(99);
      final c = _ctl(_Loc(known: _at(49.8449, 24.0347)), ov);
      await c.startWalk();
      await _until(() => ov.calls >= 1);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(c.osmLoaded, isFalse);
      expect(c.statusMessage, contains('повторюю'));
      c.stopWalk();
      c.dispose();
    });

    test('loading starts at once from the OS last-known position (no wait for a fine GPS fix)', () async {
      final ov = _FlakyOverpass(0);
      final c = _ctl(_Loc(known: _at(49.8449, 24.0347)), ov);
      await c.startWalk();
      await _until(() => c.allPois.isNotEmpty, seconds: 3);
      expect(c.allPois, isNotEmpty);
      c.stopWalk();
      c.dispose();
    });
  });

  group('OverpassService mirrors', () {
    test('dead first mirror does not block: second answers in the race', () async {
      final svc = OverpassService(staggerDelay: const Duration(milliseconds: 50));
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.host);
        if (req.url.host == 'overpass.openstreetmap.fr') {
          return Completer<http.Response>().future; // hangs forever
        }
        if (req.url.host == 'z.overpass-api.de') return http.Response(_overpassJson(), 200, headers: _json);
        return http.Response('bad', 502);
      });

      final sw = Stopwatch()..start();
      final pois = await http.runWithClient(() => svc.loadPois(49.8449, 24.0347, force: true), () => client);
      sw.stop();

      expect(pois, hasLength(4));
      expect(svc.lastLoadFailed, isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(hits.first, 'overpass.openstreetmap.fr');
    });

    test('all mirrors down: empty list but flagged as a failure', () async {
      final svc = OverpassService(staggerDelay: const Duration(milliseconds: 10));
      final client = MockClient((req) async => http.Response('down', 502));
      final pois = await http.runWithClient(() => svc.loadPois(49.8449, 24.0347, force: true), () => client);
      expect(pois, isEmpty);
      expect(svc.lastLoadFailed, isTrue);
    });

    test('a genuinely empty area is NOT a failure', () async {
      final svc = OverpassService(staggerDelay: const Duration(milliseconds: 10));
      final client = MockClient((req) async => http.Response(jsonEncode({'elements': []}), 200));
      final pois = await http.runWithClient(() => svc.loadPois(10, 10, force: true), () => client);
      expect(pois, isEmpty);
      expect(svc.lastLoadFailed, isFalse);
    });
  });
}
