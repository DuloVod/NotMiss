import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/l10n/app_lang.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/analytics_service.dart';
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
import 'package:notmiss/ui/guide_status.dart';
import 'package:notmiss/ui/walk_controller.dart';

Position _at(double lat, double lng) => Position(
    latitude: lat, longitude: lng, timestamp: DateTime(2026, 1, 1), accuracy: 5,
    altitude: 0, altitudeAccuracy: 0, heading: 0, headingAccuracy: 0, speed: 1, speedAccuracy: 0);

const _tower = Poi(
    id: 'osm_node_1', name: 'Порохова вежа', latitude: 49.8449, longitude: 24.0347,
    triggerRadius: 40, shortDescription: '', facts: [], narrationText: '', sources: [], confidence: 'osm');

class _Loc extends LocationService {
  _Loc({this.granted = true, this.blocked = false});
  bool granted;
  final bool blocked;
  int settingsOpened = 0;
  final StreamController<Position> ctrl = StreamController<Position>.broadcast();
  @override
  Stream<Position> get positionStream => ctrl.stream;
  @override
  Position? get lastPosition => null;
  @override
  Future<Position?> lastKnownPosition() async => _at(49.8449, 24.0347);
  @override
  bool get needsSettings => !granted && blocked;
  @override
  Future<void> openSettings() async => settingsOpened++;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void dispose() {}
}

/// Behaves like the real one after a quick search: asks for another load on every fix.
class _AlwaysReload extends OverpassService {
  int calls = 0;
  @override
  bool shouldReload(double lat, double lng) => true;
  @override
  Future<List<Poi>> loadPois(double lat, double lng, {bool force = false}) async {
    calls++;
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

class _Sink {
  final List<String> names = [];
  final List<Map<String, dynamic>> events = [];
  MockClient get client => MockClient((req) async {
        for (final e in (jsonDecode(req.body)['batch'] as List)) {
          events.add(e as Map<String, dynamic>);
          names.add(e['event'] as String);
        }
        return http.Response('{}', 200);
      });
}

WalkController _ctl(LocationService loc, OverpassService ov, AnalyticsService a) => WalkController(
      destination: const Destination(
          id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
      apiKey: '',
      locationService: loc,
      overpassService: ov,
      ttsService: _Tts(),
      audioService: _Audio(),
      analytics: a,
      researchService: ResearchService(
        categoryService: PoiCategoryService(),
        cacheService: PoiCacheService(),
        queue: ResearchQueue(),
        wikidataService: WikidataService(),
        wikipediaService: WikipediaService(),
        aiService: _Ai(),
      ),
    );

AnalyticsService _analytics(_Sink s) => AnalyticsService(
    apiKey: 'k', client: s.client, flushEvery: const Duration(hours: 1), platform: 'iOS')
  ..configure(distinctId: 'anon', enabled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => L.lang = AppLang.uk);

  group('location permission', () {
    test('blocked in Settings: the status says so and its button opens Settings', () async {
      final sink = _Sink();
      final a = _analytics(sink);
      final loc = _Loc(granted: false, blocked: true);
      final c = _ctl(loc, _AlwaysReload(), a);

      await c.startWalk();
      final status = c.guideStatus!;
      expect(status.tone, GuideTone.attention);
      expect(status.text, contains('Налаштування'));
      expect(status.actionLabel, 'Налаштування');

      await c.runStatusAction();
      expect(loc.settingsOpened, 1);

      await a.flush();
      expect((sink.events.firstWhere((e) => e['event'] == 'walk_denied')['properties'] as Map)['reason'],
          'blocked_in_settings');
      expect(sink.names, contains('permission_settings_opened'));
      c.dispose();
    });

    test('simply denied (the phone can still ask): the button asks again, not Settings', () async {
      final loc = _Loc(granted: false, blocked: false);
      final c = _ctl(loc, _AlwaysReload(), _analytics(_Sink()));

      await c.startWalk();
      expect(c.guideStatus!.actionLabel, 'Дозволити');
      await c.runStatusAction();
      expect(loc.settingsOpened, 0);
      c.dispose();
    });

    test('coming back from Settings with access allowed starts the walk', () async {
      final loc = _Loc(granted: false, blocked: true);
      final c = _ctl(loc, _AlwaysReload(), _analytics(_Sink()));
      await c.startWalk();
      expect(c.status, WalkStatus.idle);

      loc.granted = true; // the user allowed it in Settings
      c.setAppLifecycle(AppLifecycleState.paused);
      c.setAppLifecycle(AppLifecycleState.resumed);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(c.status, WalkStatus.walking);
      c.stopWalk();
      c.dispose();
    });
  });

  group('statistics volume', () {
    test('repeated place searches do not flood places_loaded', () async {
      final sink = _Sink();
      final a = _analytics(sink);
      final ov = _AlwaysReload();
      final c = _ctl(_Loc(), ov, a);

      await c.startWalk();
      for (var i = 0; i < 12; i++) {
        await c.debugOnPosition(_at(49.8449, 24.0347));
        await Future.delayed(const Duration(milliseconds: 20));
      }
      await a.flush();

      expect(ov.calls, greaterThan(3), reason: 'the search really did repeat');
      expect(sink.names.where((n) => n == 'places_loaded').length, lessThanOrEqualTo(1));
      c.stopWalk();
      c.dispose();
    });
  });
}
