import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/audio_session_guard.dart';
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

// ───────────────────────── fakes ─────────────────────────

class _RecordingAdapter implements SessionAdapter {
  final List<String> log = [];
  bool failConfigure = false;
  bool failActivate = false;

  @override
  Future<void> configure() async {
    log.add('configure');
    if (failConfigure) throw Exception('configure failed');
  }

  @override
  Future<void> setActive(bool active) async {
    log.add(active ? 'activate' : 'deactivate');
    if (active && failActivate) throw Exception('activate failed');
  }
}

class _FakeLocation extends LocationService {
  final StreamController<Position> ctrl = StreamController<Position>.broadcast();
  Position? last;
  bool started = false;

  @override
  Stream<Position> get positionStream => ctrl.stream;
  @override
  Position? get lastPosition => last;
  @override
  Future<bool> requestPermission() async => true;
  @override
  void start() => started = true;
  @override
  void stop() => started = false;
  @override
  void dispose() {}

  void emit(Position p) {
    last = p;
    ctrl.add(p);
  }
}

class _FakeOverpass extends OverpassService {
  _FakeOverpass(this.pois);
  final List<Poi> pois;
  @override
  bool shouldReload(double lat, double lng) => false;
  @override
  Future<List<Poi>> loadPois(double lat, double lng, {bool force = false}) async => pois;
  @override
  Future<void> clearCache() async {}
}

class _FakeTts extends TtsService {
  _FakeTts() : super(apiKey: 'test');
  int calls = 0;
  @override
  Future<String> synthesize(String text, String poiId) async {
    calls++;
    return '/tmp/bg_$poiId.wav';
  }
}

class _FakeAudio extends AudioPlayerService {
  final List<String> played = [];
  int prepared = 0;
  @override
  Future<void> prepareSession() async => prepared++;
  @override
  Future<void> play(String source) async => played.add(source);
  @override
  Future<void> stop() async {}
}

class _FakeAi extends AiService {
  _FakeAi() : super(apiKey: 'test');
  @override
  Future<Map<String, dynamic>?> generateBackgroundFacts(
          String name, String category, Map<String, String> tags) async =>
      {
        'narration': 'Розповідь про $name.',
        'description': 'Опис $name.',
        'facts': ['Факт 1 про $name.', 'Факт 2 про $name.'],
      };
  @override
  Future<String> generateNarration(Poi poi) async => 'Розповідь про ${poi.name}.';
}

Position _at(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime(2026, 1, 1),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1.2,
      speedAccuracy: 0,
    );

const _tower = Poi(
  id: 'bg_tower',
  name: 'Порохова вежа',
  latitude: 49.8449,
  longitude: 24.0347,
  triggerRadius: 40,
  shortDescription: '',
  facts: [],
  narrationText: '',
  sources: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ───────────── 1. Native iOS configuration (regression guards) ─────────────
  group('iOS background configuration', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final location = File('lib/services/location_service.dart').readAsStringSync();

    test('Info.plist declares audio and location background modes', () {
      final modes = RegExp(r'<key>UIBackgroundModes</key>\s*<array>([\s\S]*?)</array>')
          .firstMatch(plist)!
          .group(1)!;
      expect(modes, contains('<string>audio</string>'));
      expect(modes, contains('<string>location</string>'));
    });

    test('Info.plist has location usage descriptions incl. Always', () {
      for (final key in [
        'NSLocationWhenInUseUsageDescription',
        'NSLocationAlwaysAndWhenInUseUsageDescription',
      ]) {
        expect(plist, contains('<key>$key</key>'));
      }
    });

    test('AppDelegate audio session: playback category with only valid options', () {
      final call = RegExp(r'setCategory\(([\s\S]*?)\)\s*\n').firstMatch(delegate)!.group(1)!;
      expect(call, contains('.playback'));
      expect(call, contains('.spokenAudio'));
      // .allowBluetooth* are invalid with .playback and make setCategory fail (-50),
      // silently dropping background audio.
      expect(call, isNot(contains('allowBluetooth')));
    });

    test('AppDelegate registers the background-task channel from the engine callback', () {
      final body = delegate.substring(delegate.indexOf('didInitializeImplicitFlutterEngine'));
      expect(body, contains('setupBackgroundTaskChannel'));
      expect(delegate, contains('com.dulo.notmiss/background_task'));
      expect(delegate, contains('beginBackgroundTask'));
      expect(delegate, contains('endBackgroundTask'));
    });

    test('Location stream keeps running in the background on Apple platforms', () {
      expect(location, contains('allowBackgroundLocationUpdates: true'));
      expect(location, contains('pauseLocationUpdatesAutomatically: false'));
    });
  });

  // ───────────── 2. Audio session lifecycle ─────────────
  group('AudioSessionGuard', () {
    test('configure once, activate before playback, deactivate after', () async {
      final a = _RecordingAdapter();
      final g = AudioSessionGuard(adapter: a, enabled: true);
      await g.prepare();
      await g.prepare(); // idempotent
      await g.around(() async => a.log.add('playing'));
      await g.around(() async => a.log.add('playing'));
      expect(a.log, [
        'configure',
        'activate', 'playing', 'deactivate',
        'activate', 'playing', 'deactivate',
      ]);
    });

    test('session is released even when playback throws', () async {
      final a = _RecordingAdapter();
      final g = AudioSessionGuard(adapter: a, enabled: true);
      await expectLater(g.around(() async => throw StateError('bad file')), throwsStateError);
      expect(a.log.last, 'deactivate');
    });

    test('a superseded playback does not deactivate the session of its replacement', () async {
      final a = _RecordingAdapter();
      final g = AudioSessionGuard(adapter: a, enabled: true);
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();

      final first = g.around(() => firstGate.future);
      await Future.delayed(Duration.zero);
      final second = g.around(() => secondGate.future);
      await Future.delayed(Duration.zero);

      firstGate.complete(); // old narration ends while the new one is playing
      await first;
      expect(a.log.where((e) => e == 'deactivate'), isEmpty);

      secondGate.complete();
      await second;
      expect(a.log.where((e) => e == 'deactivate'), hasLength(1));
    });

    test('adapter failures never block playback', () async {
      final a = _RecordingAdapter()
        ..failConfigure = true
        ..failActivate = true;
      final g = AudioSessionGuard(adapter: a, enabled: true);
      var played = false;
      await g.around(() async => played = true);
      expect(played, isTrue);
    });

    test('a failed configure is retried on the next playback', () async {
      final a = _RecordingAdapter()..failConfigure = true;
      final g = AudioSessionGuard(adapter: a, enabled: true);
      await g.prepare();
      a.failConfigure = false;
      await g.around(() async {});
      expect(a.log.where((e) => e == 'configure'), hasLength(2));
    });

    test('disabled guard (web) touches nothing', () async {
      final a = _RecordingAdapter();
      final g = AudioSessionGuard(adapter: a, enabled: false);
      await g.around(() async {});
      expect(a.log, isEmpty);
    });
  });

  // ───────────── 3. Whole walk while the app is backgrounded ─────────────
  group('Walk while app is in background', () {
    late _FakeLocation loc;
    late _FakeTts tts;
    late _FakeAudio audio;
    late WalkController controller;

    setUp(() {
      loc = _FakeLocation();
      tts = _FakeTts();
      audio = _FakeAudio();
      controller = WalkController(
        destination: const Destination(
            id: 'lviv', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
        apiKey: '',
        locationService: loc,
        overpassService: _FakeOverpass([_tower]),
        ttsService: tts,
        audioService: audio,
        researchService: ResearchService(
          categoryService: PoiCategoryService(),
          cacheService: PoiCacheService(),
          queue: ResearchQueue(),
          wikidataService: WikidataService(),
          wikipediaService: WikipediaService(),
          aiService: _FakeAi(),
        ),
      );
    });

    tearDown(() {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      controller.dispose();
    });

    Future<void> pump() => Future.delayed(const Duration(milliseconds: 300));

    /// Research goes through the real (rate-limited) Wikipedia client, so wait for the
    /// outcome instead of sleeping a fixed time.
    Future<void> waitFor(bool Function() cond) async {
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (!cond() && DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    test('audio session is prepared while still in the foreground at walk start', () async {
      await controller.startWalk();
      expect(audio.prepared, 1);
      expect(loc.started, isTrue);
      controller.stopWalk();
    });

    test('screen locked: approaching a point narrates it without any UI', () async {
      await controller.startWalk();
      loc.emit(_at(49.8460, 24.0360)); // ~150 m away, POIs get loaded
      await pump();

      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      loc.emit(_at(49.8450, 24.0348)); // walk up to the tower while backgrounded
      await waitFor(() => audio.played.isNotEmpty);

      expect(controller.triggeredPoiIds, contains(_tower.id));
      expect(tts.calls, 1);
      expect(audio.played, hasLength(1));
      expect(controller.activePoi?.narrationText, isNotEmpty);
      controller.stopWalk();
    });

    test('repeated GPS fixes in the same spot do not replay the narration', () async {
      await controller.startWalk();
      loc.emit(_at(49.8460, 24.0360));
      await pump();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      for (var i = 0; i < 6; i++) {
        loc.emit(_at(49.8449, 24.0347));
        await Future.delayed(const Duration(milliseconds: 80));
      }
      await waitFor(() => audio.played.isNotEmpty);
      await pump(); // give a (wrong) replay the chance to show up

      expect(audio.played, hasLength(1));
      expect(controller.proximityEvents.where((e) => e.poiId == _tower.id), hasLength(1));
      controller.stopWalk();
    });

    test('app returns to foreground: state is intact and walk keeps going', () async {
      await controller.startWalk();
      loc.emit(_at(49.8460, 24.0360));
      await pump();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      loc.emit(_at(49.8450, 24.0348));
      await pump();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      expect(controller.status, WalkStatus.walking);
      expect(controller.triggeredPoiIds, contains(_tower.id));
      expect(controller.activePoi, isNotNull, reason: 'card with the text is waiting for the user');
      controller.stopWalk();
    });
  });
}
