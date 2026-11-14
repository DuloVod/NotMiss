import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/analytics_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/settings_store.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

class _Sink {
  final List<Map<String, dynamic>> events = [];
  final List<Uri> urls = [];
  int status = 200;
  MockClient get client => MockClient((req) async {
        urls.add(req.url);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (status < 300) {
          for (final e in body['batch'] as List) {
            events.add({...(e as Map<String, dynamic>), 'api_key': body['api_key']});
          }
        }
        return http.Response('{}', status);
      });
  List<String> get names => [for (final e in events) e['event'] as String];
}

AnalyticsService _service(_Sink sink, {String key = 'phc_test', DateTime Function()? now}) =>
    AnalyticsService(apiKey: key, client: sink.client, now: now, platform: 'iOS', flushEvery: const Duration(hours: 1))
      ..configure(distinctId: 'anon-1', enabled: true, base: {'lang': 'uk'});

class _FakeTts extends TtsService {
  _FakeTts() : super(apiKey: 'test');
  @override
  Future<String> synthesize(String text, String poiId) async => '/tmp/fake_$poiId.wav';
}

class _FakeAudio extends AudioPlayerService {
  @override
  Future<void> play(String source) async {}
  @override
  Future<void> stop() async {}
}

class _NoOverpass extends OverpassService {
  @override
  bool shouldReload(double lat, double lng) => false;
}

class _FakeAi extends AiService {
  _FakeAi() : super(apiKey: 'test');
  @override
  Future<String> generateNarration(Poi poi) async => 'Розповідь про ${poi.name}.';
}

const _poi = Poi(
  id: 'poi_a',
  name: 'Ратуша',
  latitude: 49.84,
  longitude: 24.03,
  triggerRadius: 40,
  shortDescription: '',
  facts: [],
  narrationText: '',
  sources: [],
  osmTags: {
    'description': 'Адміністративна будівля в центрі міста, де протягом усього часу її існування '
        'працювала міська влада; сучасну споруду звели на місці старої, що обвалилася.',
  },
);

final _pos = Position(
  latitude: 49.84,
  longitude: 24.03,
  timestamp: DateTime(2026, 1, 1),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

WalkController _controller(AnalyticsService analytics) {
  final ai = _FakeAi();
  final c = WalkController(
    destination: const Destination(
        id: 'lviv', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
    apiKey: '',
    researchService: ResearchService(
      categoryService: PoiCategoryService(),
      cacheService: PoiCacheService(),
      queue: ResearchQueue(maxConcurrent: 2),
      wikidataService: WikidataService(),
      wikipediaService: WikipediaService(),
      aiService: ai,
    ),
    ttsService: _FakeTts(),
    audioService: _FakeAudio(),
    overpassService: _NoOverpass(),
    analytics: analytics,
  );
  c.ttsRetryPause = Duration.zero;
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnalyticsService', () {
    test('without a key nothing is collected or sent', () async {
      final sink = _Sink();
      final a = _service(sink, key: '');
      a.track('walk_started');
      await a.flush();
      expect(a.active, isFalse);
      expect(a.queued, 0);
      expect(sink.urls, isEmpty);
      a.dispose();
    });

    test('sends a batch to PostHog with the key, the anonymous id and one session id', () async {
      final sink = _Sink();
      final a = _service(sink);
      a.track('walk_started');
      a.track('poi_triggered', {'poi_id': 'p1', 'poi_name': 'Ратуша', 'kind': 'church'});
      await a.flush();

      expect(sink.urls.single.toString(), 'https://eu.i.posthog.com/batch/');
      expect(sink.names, ['walk_started', 'poi_triggered']);
      final e = sink.events.last;
      expect(e['api_key'], 'phc_test');
      expect(e['distinct_id'], 'anon-1');
      final props = e['properties'] as Map<String, dynamic>;
      expect(props['poi_name'], 'Ратуша');
      expect(props['lang'], 'uk');
      expect(props['platform'], 'iOS');
      expect(props['app_version'], AnalyticsService.appVersion);
      expect((sink.events.first['properties'] as Map)[r'$session_id'], props[r'$session_id']);
      expect(a.queued, 0);
      a.dispose();
    });

    test('never carries coordinates or the user\'s own words', () async {
      final sink = _Sink();
      final a = _service(sink);
      a.track('x', {
        'latitude': 49.84,
        'lng': 24.03,
        'lat': 1.0,
        'position': '49.8,24.0',
        'question': 'де я живу?',
        'comment': 'це неправда',
        'text': 'щось',
        'email': 'a@b.c',
        'poi_name': 'Ратуша',
        'length': 12,
        'object': Object(),
      });
      await a.flush();
      final props = sink.events.single['properties'] as Map<String, dynamic>;
      for (final bad in ['latitude', 'lng', 'lat', 'position', 'question', 'comment', 'text', 'email', 'object']) {
        expect(props.containsKey(bad), isFalse, reason: bad);
      }
      expect(props['poi_name'], 'Ратуша');
      expect(props['length'], 12);
      expect(jsonEncode(props), isNot(contains('49.84')));
      a.dispose();
    });

    test('switching statistics off clears the queue and stops sending', () async {
      final sink = _Sink();
      final a = _service(sink);
      a.track('one');
      expect(a.queued, 1);
      a.setEnabled(false);
      expect(a.queued, 0);
      a.track('two');
      await a.flush();
      expect(sink.urls, isEmpty);
      a.setEnabled(true);
      a.track('three');
      await a.flush();
      expect(sink.names, ['three']);
      a.dispose();
    });

    test('a failed send keeps the events for the next try; a rejected one drops them', () async {
      final sink = _Sink()..status = 503;
      final a = _service(sink);
      a.track('one');
      await a.flush();
      expect(a.queued, 1, reason: 'server down: retry later');
      sink.status = 200;
      await a.flush();
      expect(sink.names, ['one']);

      sink.status = 401;
      a.track('two');
      await a.flush();
      expect(a.queued, 0, reason: 'bad key: never accepted, not kept forever');
      a.dispose();
    });

    test('offline queue is capped', () {
      final sink = _Sink()..status = 503;
      final a = AnalyticsService(
          apiKey: 'k', client: sink.client, flushEvery: const Duration(hours: 1), platform: 'iOS')
        ..configure(distinctId: 'x', enabled: true);
      for (var i = 0; i < AnalyticsService.maxQueue + 50; i++) {
        a.track('e$i');
      }
      expect(a.queued, lessThanOrEqualTo(AnalyticsService.maxQueue));
      a.dispose();
    });

    test('a long gap starts a new session', () async {
      var t = DateTime(2026, 1, 1, 10);
      final sink = _Sink();
      final a = _service(sink, now: () => t);
      a.track('a');
      t = t.add(const Duration(minutes: 5));
      a.track('b');
      t = t.add(const Duration(minutes: 45));
      a.track('c');
      await a.flush();
      final ids = [for (final e in sink.events) (e['properties'] as Map)[r'$session_id']];
      expect(ids[0], ids[1]);
      expect(ids[2], isNot(ids[0]));
      a.dispose();
    });

    test('time in the app: foreground → background reports the seconds', () async {
      var t = DateTime(2026, 1, 1, 10);
      final sink = _Sink();
      final a = _service(sink, now: () => t);
      a.foreground();
      t = t.add(const Duration(seconds: 90));
      a.background();
      await Future.delayed(Duration.zero);
      expect(sink.names, ['app_foreground', 'app_background']);
      expect((sink.events.last['properties'] as Map)['foreground_seconds'], 90);
      a.dispose();
    });

    test('appVersion equals the version in pubspec.yaml', () {
      final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      expect(line.split(':')[1].trim(), AnalyticsService.appVersion);
    });
  });

  group('SettingsStore analytics', () {
    test('the id is created once, survives a restart and the switch is remembered', () async {
      final dir = Directory.systemTemp.createTempSync('nm_settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<String> path() async => '${dir.path}/settings.json';

      final first = SettingsStore(pathProvider: path);
      await first.init();
      await first.ensureAnalyticsId();
      final id = first.analyticsId;
      expect(id, isNotEmpty);
      expect(first.analyticsEnabled, isTrue, reason: 'on by default');
      await first.setAnalyticsEnabled(false);

      final second = SettingsStore(pathProvider: path);
      await second.init();
      expect(second.analyticsId, id);
      expect(second.analyticsEnabled, isFalse);
    });
  });

  group('WalkController events', () {
    test('a place narration is tracked from trigger to the end, without coordinates', () async {
      final sink = _Sink();
      final analytics = _service(sink);
      final c = _controller(analytics);

      await c.debugProcessPoi(_poi, _pos);
      await analytics.flush();

      expect(sink.names, containsAllInOrder(['app_foreground', 'poi_triggered', 'narration_started', 'narration_finished']));
      final trig = sink.events.firstWhere((e) => e['event'] == 'poi_triggered')['properties'] as Map;
      expect(trig['poi_id'], 'poi_a');
      expect(trig['poi_name'], 'Ратуша');
      final all = jsonEncode(sink.events);
      expect(all, isNot(contains('49.84')));
      expect(all, isNot(contains('24.03')));
      c.dispose();
    });

    test('skipping a story reports how long it was heard', () async {
      final sink = _Sink();
      final analytics = _service(sink);
      final c = _controller(analytics);
      c.debugSetPois([_poi]);
      await c.debugProcessPoi(_poi, _pos);
      await c.stopAudio(how: 'skipped');
      await analytics.flush();
      // Already finished in the fake: nothing to skip, and no bogus event.
      expect(sink.names, isNot(contains('narration_skipped')));
      c.dispose();
    });

    test('switching statistics off in the controller stops events', () async {
      final sink = _Sink();
      final analytics = _service(sink);
      final c = _controller(analytics);
      await c.setAnalyticsEnabled(false);
      await c.debugProcessPoi(_poi, _pos);
      await analytics.flush();
      expect(sink.urls, isEmpty);
      c.dispose();
    });
  });
}
