import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'package:notmiss/services/navigation_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/screens/main_screen.dart';
import 'package:notmiss/ui/theme/app_theme.dart';
import 'package:notmiss/ui/walk_controller.dart';

Position _at(double lat, double lng) => Position(
    latitude: lat, longitude: lng, timestamp: DateTime(2026, 1, 1), accuracy: 5,
    altitude: 0, altitudeAccuracy: 0, heading: 0, headingAccuracy: 0, speed: 1, speedAccuracy: 0);

// ~111 m per 0.001° of latitude.
const _start = GeoPoint(49.8400, 24.0300);
const _goalPoi = Poi(
    id: 'osm_node_9', name: 'Ратуша', latitude: 49.8440, longitude: 24.0300,
    triggerRadius: 40, shortDescription: '', facts: [], narrationText: '', sources: [], confidence: 'osm');

class _Loc extends LocationService {
  final StreamController<Position> ctrl = StreamController<Position>.broadcast();
  @override
  Stream<Position> get positionStream => ctrl.stream;
  @override
  Position? get lastPosition => null;
  @override
  Future<Position?> lastKnownPosition() async => _at(_start.lat, _start.lng);
  @override
  Future<bool> requestPermission() async => true;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void dispose() {}
}

class _NoOverpass extends OverpassService {
  @override
  bool shouldReload(double lat, double lng) => false;
  @override
  Future<List<Poi>> loadPois(double lat, double lng, {bool force = false}) async {
    lastLoadFailed = false;
    return [];
  }
}

class _Ai extends AiService {
  _Ai() : super(apiKey: 'x');
}

class _Tts extends TtsService {
  _Tts() : super(apiKey: 'x');
}

class _Audio extends AudioPlayerService {
  @override
  Future<void> prepareSession() async {}
  @override
  Future<void> play(String source) async {}
  @override
  Future<void> stop() async {}
}

/// A router the test controls: answers when told to, or never.
class _Router extends NavigationService {
  _Router(this.answer);
  WalkRoute? answer;
  Completer<void>? hold;
  int asked = 0;
  @override
  Future<WalkRoute?> fetchRoute(GeoPoint from, GeoPoint to) async {
    asked++;
    if (hold != null) await hold!.future;
    return answer;
  }
}

class _Sink {
  final List<Map<String, dynamic>> events = [];
  MockClient get client => MockClient((req) async {
        for (final e in (jsonDecode(req.body)['batch'] as List)) {
          events.add(e as Map<String, dynamic>);
        }
        return http.Response('{}', 200);
      });
  List<String> get names => [for (final e in events) e['event'] as String];
}

Future<(WalkController, _Loc, _Sink)> _walking(NavigationService nav) async {
  final loc = _Loc();
  final sink = _Sink();
  final analytics = AnalyticsService(apiKey: 'k', client: sink.client, flushEvery: const Duration(hours: 1), platform: 'iOS')
    ..configure(distinctId: 'anon', enabled: true);
  final c = WalkController(
    destination: const Destination(
        id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
    apiKey: '',
    locationService: loc,
    overpassService: _NoOverpass(),
    ttsService: _Tts(),
    audioService: _Audio(),
    navigation: nav,
    analytics: analytics,
    researchService: ResearchService(
      categoryService: PoiCategoryService(),
      cacheService: PoiCacheService(),
      queue: ResearchQueue(),
      wikidataService: WikidataService(),
      wikipediaService: WikipediaService(),
      aiService: _Ai(),
    ),
  );
  await c.startWalk();
  await c.debugOnPosition(_at(_start.lat, _start.lng));
  return (c, loc, sink);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => L.lang = AppLang.uk);

  group('navigation maths', () {
    test('distance: 0.001° of latitude is about 111 m', () {
      final d = NavigationService.distance(const GeoPoint(49.0, 24.0), const GeoPoint(49.001, 24.0));
      expect(d, closeTo(111, 1));
    });

    test('bearing: north 0°, east 90°, south 180°, west 270°', () {
      const o = GeoPoint(49.0, 24.0);
      expect(NavigationService.bearing(o, const GeoPoint(49.01, 24.0)), closeTo(0, 0.5));
      expect(NavigationService.bearing(o, const GeoPoint(49.0, 24.01)), closeTo(90, 0.5));
      expect(NavigationService.bearing(o, const GeoPoint(48.99, 24.0)), closeTo(180, 0.5));
      expect(NavigationService.bearing(o, const GeoPoint(49.0, 23.99)), closeTo(270, 0.5));
    });

    test('minutes: 1.33 m/s, at least one minute until there', () {
      expect(NavigationService.minutes(0), 0);
      expect(NavigationService.minutes(10), 1);
      expect(NavigationService.minutes(400), 5);
      expect(NavigationService.minutes(1330 * 2), 33);
    });

    test('progress: on the line the rest is counted along the line, not as the crow flies', () {
      // An "L": 111 m north, then 111 m east.
      const route = WalkRoute([GeoPoint(49.0, 24.0), GeoPoint(49.001, 24.0), GeoPoint(49.001, 24.0015)]);
      final atStart = NavigationService.progress(route, const GeoPoint(49.0, 24.0));
      final crow = NavigationService.distance(const GeoPoint(49.0, 24.0), const GeoPoint(49.001, 24.0015));
      expect(atStart.offRoute, lessThan(1));
      expect(atStart.remaining, greaterThan(crow + 20)); // the way round is longer
      expect(atStart.remaining, closeTo(111 + 109, 6));

      final midway = NavigationService.progress(route, const GeoPoint(49.0005, 24.0));
      expect(midway.remaining, closeTo(55 + 109, 6));
    });

    test('progress: far from the line is reported as off route', () {
      const route = WalkRoute([GeoPoint(49.0, 24.0), GeoPoint(49.002, 24.0)]);
      final p = NavigationService.progress(route, const GeoPoint(49.001, 24.002)); // ~145 m to the side
      expect(p.offRoute, greaterThan(NavigationService.offRouteDistance));
    });

    test('parseRoute reads an OSRM answer and refuses nonsense', () {
      final ok = NavigationService.parseRoute(jsonEncode({
        'code': 'Ok',
        'routes': [
          {
            'geometry': {
              'coordinates': [
                [24.0, 49.0],
                [24.0, 49.001],
                [24.001, 49.001],
              ]
            }
          }
        ]
      }));
      expect(ok, isNotNull);
      expect(ok!.points.length, 3);
      expect(ok.points.first, const GeoPoint(49.0, 24.0)); // lon,lat → lat,lng
      expect(ok.straight, isFalse);

      expect(NavigationService.parseRoute('not json'), isNull);
      expect(NavigationService.parseRoute(jsonEncode({'code': 'NoRoute', 'routes': []})), isNull);
      expect(NavigationService.parseRoute(jsonEncode({'code': 'Ok', 'routes': []})), isNull);
    });

    test('fetchRoute asks for the foot profile with only the two ends and survives a failure', () async {
      Uri? asked;
      final good = NavigationService(
          client: MockClient((req) async {
        asked = req.url;
        return http.Response(
            jsonEncode({
              'code': 'Ok',
              'routes': [
                {
                  'geometry': {
                    'coordinates': [
                      [24.0, 49.0],
                      [24.0, 49.001]
                    ]
                  }
                }
              ]
            }),
            200);
      }));
      final r = await good.fetchRoute(const GeoPoint(49.0, 24.0), const GeoPoint(49.001, 24.0));
      expect(r, isNotNull);
      expect(asked!.path, contains('/routed-foot/route/v1/foot/24.0,49.0;24.0,49.001'));
      expect(asked!.queryParameters.keys, unorderedEquals(['overview', 'geometries', 'steps']));

      final down = NavigationService(client: MockClient((_) async => throw Exception('offline')));
      expect(await down.fetchRoute(const GeoPoint(49.0, 24.0), const GeoPoint(49.001, 24.0)), isNull);
      final bad = NavigationService(client: MockClient((_) async => http.Response('oops', 500)));
      expect(await bad.fetchRoute(const GeoPoint(49.0, 24.0), const GeoPoint(49.001, 24.0)), isNull);
    });
  });

  group('leading the user to a place', () {
    test('start: shows a straight line at once, then swaps in the real route', () async {
      final router = _Router(const WalkRoute([GeoPoint(49.84, 24.03), GeoPoint(49.842, 24.031), GeoPoint(49.844, 24.03)]))
        ..hold = Completer<void>();
      final (c, _, _) = await _walking(router);

      final started = c.startNavigation(_goalPoi);
      await Future<void>.delayed(Duration.zero);
      expect(c.navTarget?.id, _goalPoi.id);
      expect(c.navLoading, isTrue);
      expect(c.navRoute!.straight, isTrue); // something to show while waiting
      expect(c.navRemainingMeters, closeTo(445, 8)); // 0.004° ≈ 445 m
      expect(c.navBearing, closeTo(0, 1)); // goal is due north

      router.hold!.complete();
      expect(await started, isTrue);
      expect(c.navLoading, isFalse);
      expect(c.navRoute!.straight, isFalse);
      expect(c.navRemainingMeters!, greaterThan(445)); // the way round is a little longer
      expect(c.navMinutes, greaterThan(0));
      c.dispose();
    });

    test('no route available: keeps a straight line and follows the user', () async {
      final router = _Router(null);
      final (c, loc, _) = await _walking(router);
      await c.startNavigation(_goalPoi);
      expect(c.navRoute!.straight, isTrue);
      final before = c.navRemainingMeters!;

      await c.debugOnPosition(_at(49.8420, 24.0300)); // 222 m closer
      expect(c.navRemainingMeters!, lessThan(before - 200));
      expect(c.navRoute!.points.first, const GeoPoint(49.8420, 24.0300)); // line starts at the user
      await loc.ctrl.close();
      c.dispose();
    });

    test('without a known position nothing starts', () async {
      final c = (await _walking(_Router(null))).$1;
      // A controller that has not had a fix yet:
      final fresh = WalkController(
        destination: const Destination(
            id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
        apiKey: '',
        locationService: _Loc(),
        overpassService: _NoOverpass(),
        ttsService: _Tts(),
        audioService: _Audio(),
        navigation: _Router(null),
        analytics: AnalyticsService(),
      );
      expect(await fresh.startNavigation(_goalPoi), isFalse);
      expect(fresh.navTarget, isNull);
      fresh.dispose();
      c.dispose();
    });

    test('arrival: within 25 m the navigation ends and the place is announced', () async {
      final (c, _, sink) = await _walking(_Router(null));
      await c.startNavigation(_goalPoi);
      await c.debugOnPosition(_at(49.8438, 24.0300)); // ~22 m short
      expect(c.navTarget, isNull);
      expect(c.navArrived?.id, _goalPoi.id);
      expect(c.navRoute, isNull);

      c.dismissNavArrival();
      expect(c.navArrived, isNull);
      await c.analytics.flush();
      expect(sink.names, containsAllInOrder(['nav_started', 'nav_arrived']));
      c.dispose();
    });

    test('starting at the door counts as arrived straight away', () async {
      final (c, _, _) = await _walking(_Router(null));
      await c.debugOnPosition(_at(49.8440, 24.0301));
      await c.startNavigation(_goalPoi);
      expect(c.navTarget, isNull);
      expect(c.navArrived?.id, _goalPoi.id);
      c.dispose();
    });

    test('cancel: everything is cleared and a late route answer is ignored', () async {
      final router = _Router(const WalkRoute([GeoPoint(49.84, 24.03), GeoPoint(49.844, 24.03)]))
        ..hold = Completer<void>();
      final (c, _, sink) = await _walking(router);
      final started = c.startNavigation(_goalPoi);
      await Future<void>.delayed(Duration.zero);

      c.stopNavigation();
      expect(c.navTarget, isNull);
      expect(c.navRoute, isNull);
      expect(c.navRemainingMeters, isNull);

      router.hold!.complete(); // the answer arrives after cancelling
      await started;
      expect(c.navTarget, isNull);
      expect(c.navRoute, isNull);
      expect(c.navLoading, isFalse);
      await c.analytics.flush();
      expect(sink.names, containsAllInOrder(['nav_started', 'nav_stopped']));
      c.dispose();
    });

    test('a new target replaces the old one and an old answer cannot overwrite it', () async {
      final slow = _Router(const WalkRoute([GeoPoint(49.84, 24.03), GeoPoint(49.85, 24.03)]))..hold = Completer<void>();
      final (c, _, _) = await _walking(slow);
      final first = c.startNavigation(_goalPoi);
      await Future<void>.delayed(Duration.zero);

      const other = Poi(
          id: 'osm_node_10', name: 'Музей', latitude: 49.8400, longitude: 24.0340,
          triggerRadius: 40, shortDescription: '', facts: [], narrationText: '', sources: [], confidence: 'osm');
      unawaited(c.startNavigation(other));
      await Future<void>.delayed(Duration.zero);
      expect(c.navTarget?.id, other.id);

      slow.hold!.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(c.navTarget?.id, other.id);
      c.dispose();
    });

    test('leaving the path asks for a new route, but not again straight away', () async {
      final router = _Router(const WalkRoute([GeoPoint(49.84, 24.03), GeoPoint(49.844, 24.03)]));
      final (c, _, _) = await _walking(router);
      await c.startNavigation(_goalPoi);
      expect(router.asked, 1);

      await c.debugOnPosition(_at(49.8420, 24.0320)); // ~145 m off the line
      await Future<void>.delayed(Duration.zero);
      expect(router.asked, 1, reason: 'asked a moment ago: wait');

      WalkController.navRerouteGap = Duration.zero;
      addTearDown(() => WalkController.navRerouteGap = const Duration(seconds: 20));
      await c.debugOnPosition(_at(49.8421, 24.0320));
      await Future<void>.delayed(Duration.zero);
      expect(router.asked, 2, reason: 'still off the path after the wait: new route');

      await c.debugOnPosition(_at(49.8420, 24.03005)); // back on the line
      await Future<void>.delayed(Duration.zero);
      expect(router.asked, 2, reason: 'on the path: no need');
      c.dispose();
    });

    test('with only a straight line the real route is tried again after a while', () async {
      final router = _Router(null);
      final (c, _, _) = await _walking(router);
      await c.startNavigation(_goalPoi);
      expect(router.asked, 1);
      WalkController.navRetryGap = Duration.zero;
      addTearDown(() => WalkController.navRetryGap = const Duration(seconds: 60));
      router.answer = const WalkRoute([GeoPoint(49.84, 24.03), GeoPoint(49.844, 24.03)]);
      await c.debugOnPosition(_at(49.8402, 24.0300));
      await Future<void>.delayed(Duration.zero);
      expect(router.asked, 2);
      expect(c.navRoute!.straight, isFalse);
      c.dispose();
    });

    test('ending the walk ends the navigation', () async {
      final (c, _, _) = await _walking(_Router(null));
      await c.startNavigation(_goalPoi);
      c.stopWalk();
      expect(c.navTarget, isNull);
      c.dispose();
    });
  });

  group('on the screen', () {
    setUp(() {
      // No compass in the test runner: the arrow then simply points by the bearing.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('hemanthraj/flutter_compass'), (call) async => null);
    });

    Widget app(WalkController c) => MaterialApp(
          theme: NmTheme.light(),
          locale: Locale(L.lang.code),
          supportedLocales: [for (final l in AppLang.values) Locale(l.code)],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: MainScreen(controller: c),
        );

    for (final lang in [AppLang.uk, AppLang.en]) {
      testWidgets('${lang.code}: "Go here" on a place card shows distance and a stop button', (tester) async {
        L.lang = lang;
        late WalkController c;
        await tester.runAsync(() async => c = (await _walking(_Router(null))).$1);
        c.debugSetPois(const [_goalPoi]);
        await tester.binding.setSurfaceSize(const Size(430, 932));
        await tester.pumpWidget(app(c));
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(find
            .byWidgetPredicate((w) => w is Tooltip && RegExp('Ратуша|Ratusha').hasMatch(w.message ?? ''))
            .first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        final go = find.text(L.t('Піти сюди', 'Go here'));
        expect(go, findsOneWidget);

        await tester.runAsync(() async {
          await tester.tap(go);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 600));
        expect(c.navTarget?.id, _goalPoi.id);
        expect(find.textContaining(L.t(' м · ~', ' ft · ~')), findsOneWidget); // distance and time
        expect(find.byTooltip(L.t('Скасувати навігацію', 'Stop navigation')), findsOneWidget);
        if (lang == AppLang.en) {
          final cyr = RegExp(r'[А-Яа-яІіЇїЄєҐґ]');
          for (final e in find.byType(Text).evaluate()) {
            final text = (e.widget as Text).data ?? '';
            expect(cyr.hasMatch(text), isFalse, reason: 'Ukrainian text in English navigation: $text');
          }
        }

        await tester.tap(find.byTooltip(L.t('Скасувати навігацію', 'Stop navigation')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(c.navTarget, isNull);
        expect(find.byTooltip(L.t('Скасувати навігацію', 'Stop navigation')), findsNothing);

        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.binding.setSurfaceSize(null);
      });
    }

    testWidgets('arrival shows "You have arrived" until it is closed', (tester) async {
      L.lang = AppLang.uk;
      late WalkController c;
      await tester.runAsync(() async => c = (await _walking(_Router(null))).$1);
      c.debugSetPois(const [_goalPoi]);
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpWidget(app(c));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await c.startNavigation(_goalPoi);
        await c.debugOnPosition(_at(49.8439, 24.0300));
      });
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Ви на місці'), findsOneWidget);
      await tester.tap(find.byTooltip('Закрити'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ви на місці'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
