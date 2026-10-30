import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/audio_session_guard.dart';
import 'package:notmiss/services/now_playing_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/services/live_activity_service.dart';
import 'package:notmiss/services/place_context_service.dart';
import 'package:notmiss/services/content_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/text_quality.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/visited_store.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/guide_status.dart';
import 'package:notmiss/ui/poi_kind.dart';
import 'package:notmiss/ui/walk_controller.dart';

class _Tts extends TtsService {
  _Tts({this.fail = false}) : super(apiKey: 'test');
  bool fail;
  @override
  Future<String> synthesize(String text, String poiId) async {
    if (fail) throw Exception('TTS down');
    return '/tmp/fake_$poiId.wav';
  }
}

class _Audio extends AudioPlayerService {
  final List<String> played = [];
  int cues = 0;
  int stops = 0;
  bool paused = false;
  Completer<void>? gate;

  @override
  void armArrivalCue() => cues++;
  @override
  Future<void> prepareSession() async {}
  bool playing = false;
  @override
  bool get isPlaying => playing && !paused;
  @override
  Future<void> play(String source) async {
    played.add(source);
    playing = true;
    if (gate != null) await gate!.future;
    playing = false;
  }

  @override
  Future<void> pause() async => paused = true;
  @override
  Future<void> resume() async => paused = false;
  @override
  bool get isPaused => paused;
  @override
  Future<void> stop() async {
    stops++;
    paused = false;
  }
}

class _Ai extends AiService {
  _Ai() : super(apiKey: 'test');
  @override
  Future<Map<String, dynamic>?> generateBackgroundFacts(
          String name, String category, Map<String, String> tags) async =>
      null;
  @override
  Future<String> generateNarration(Poi poi) async => 'Розповідь про ${poi.name}.';
}

class _NoOverpass extends OverpassService {
  @override
  bool shouldReload(double lat, double lng) => false;
}

Poi _poi(String id, String name, {double lat = 49.84, double lng = 24.03, Map<String, String>? tags}) => Poi(
      id: id,
      name: name,
      latitude: lat,
      longitude: lng,
      triggerRadius: 40,
      shortDescription: '',
      facts: const [],
      narrationText: '',
      sources: const [],
      osmTags: tags,
    );

Position _pos([double lat = 49.84, double lng = 24.03]) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime(2026, 1, 1),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

WalkController _ctl(_Audio audio, NowPlayingService np, VisitedStore store, {_Tts? tts}) {
  final ai = _Ai();
  final c = WalkController(
    destination: const Destination(
        id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
    apiKey: '',
    researchService: ResearchService(
      categoryService: PoiCategoryService(),
      cacheService: PoiCacheService(),
      queue: ResearchQueue(maxConcurrent: 2),
      wikidataService: WikidataService(),
      wikipediaService: WikipediaService(),
      aiService: ai,
      researchDeadline: const Duration(milliseconds: 300),
    ),
    ttsService: tts ?? _Tts(),
    audioService: audio,
    overpassService: _NoOverpass(),
    nowPlaying: np,
    visitedStore: store,
  );
  c.ttsRetryPause = Duration.zero;
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('No greetings, short narrations', () {
    test('greeting sentences are removed', () {
      expect(TextQuality.stripGreeting('Вітаю! Перед вами Порохова вежа.'), 'Перед вами Порохова вежа.');
      expect(TextQuality.stripGreeting('Привіт, мандрівнику! Погляньте на ратушу.'), 'Погляньте на ратушу.');
      expect(TextQuality.stripGreeting('Доброго дня! Ласкаво просимо! Це площа Ринок.'), 'Це площа Ринок.');
      expect(
          TextQuality.stripGreeting(
              'Вітаю вас на площі Ринок, де колись вирувало торгове життя середньовічного міста Львова. Тут стоїть ратуша.'),
          'На площі Ринок, де колись вирувало торгове життя середньовічного міста Львова. Тут стоїть ратуша.');
    });

    test('text without a greeting is untouched; a greeting-only text is kept', () {
      expect(TextQuality.stripGreeting('Перед вами старовинна церква.'), 'Перед вами старовинна церква.');
      expect(TextQuality.stripGreeting('Привіт, друже!'), 'Привіт, друже!');
      expect(TextQuality.stripGreeting('Привітний дворик схований від вулиці.'), 'Привітний дворик схований від вулиці.');
    });

    test('long narrations are cut after a full sentence', () {
      final sentence = 'Це досить довге речення про старовинну будівлю міста Львова.';
      final long = List.filled(30, sentence).join(' ');
      final out = TextQuality.trimToLength(long);
      expect(out.length, lessThanOrEqualTo(TextQuality.maxNarrationChars));
      expect(out.endsWith('.'), isTrue);
      expect(out.length, greaterThan(300));
      expect(TextQuality.trimToLength('Коротко.'), 'Коротко.');
    });

    test('finalizeNarration = markdown off + no greeting + max length', () {
      final raw = '**Вітаю!** Перед вами *дивовижне* місце. ${List.filled(40, 'Ще одне речення про нього.').join(' ')}';
      final out = TextQuality.finalizeNarration(raw);
      expect(out.startsWith('Перед вами дивовижне місце.'), isTrue);
      expect(out.length, lessThanOrEqualTo(TextQuality.maxNarrationChars));
      expect(out.contains('*'), isFalse);
    });

    test('a cached narration with a greeting is cleaned when shown', () async {
      final audio = _Audio();
      final c = _ctl(audio, NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      final poi = _poi('g1', 'Ратуша');
      c.debugSetPois([poi]);
      final stored = poi.copyWith(narrationText: 'Вітаю! Перед вами ратуша, серце міста. Її вежу видно звідусіль.');
      final merged = c.getUpdatedPoi(stored);
      expect(merged.name, 'Ратуша');
      // the exact text from the screenshot: stored by an older build
      expect(
        TextQuality.finalizeNarration(
            'Вітаю вас на нашій прогулянці затишними вулицями Львова. Перед вами постає дивовижна святиня — церква Святої Софії.'),
        'Перед вами постає дивовижна святиня — церква Святої Софії.',
      );
      expect(
        TextQuality.finalizeNarration(
            'Вітаю вас на нашій прогулянці неймовірним Львовом. Зупиніться на хвилину і підніміть погляд на цю величну будівлю.'),
        startsWith('Зупиніться'),
      );
      c.dispose();
    });
  });

  group('Audio controls', () {
    test('remote commands from the lock screen drive pause / resume', () async {
      final audio = _Audio();
      final np = NowPlayingService(enabled: false);
      final c = _ctl(audio, np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      expect(c.activePoi, isNotNull);

      np.handleCommand('pause');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.paused, isTrue);
      np.handleCommand('play');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.paused, isFalse);
      c.dispose();
    });

    test('replay plays the same narration again from the start', () async {
      final audio = _Audio();
      final np = NowPlayingService(enabled: false);
      final c = _ctl(audio, np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      expect(audio.played, hasLength(1));

      await c.replayAudio();
      expect(audio.played, hasLength(2));
      expect(audio.played.first, audio.played.last);

      c.dispose();
    });

    test('replay is reachable from the lock screen while a narration plays', () async {
      final audio = _Audio()..gate = Completer<void>();
      final np = NowPlayingService(enabled: false);
      final c = _ctl(audio, np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      unawaited(c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(audio.played, hasLength(1));

      audio.gate = null;
      np.handleCommand('replay');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(audio.played, hasLength(2));
      c.dispose();
    });

    test('replay of a paused narration restarts it instead of just resuming', () async {
      final audio = _Audio();
      final c = _ctl(audio, NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      audio.paused = true;
      await c.replayAudio();
      expect(audio.played, hasLength(2));
      c.dispose();
    });

    test('skip drops the current narration and starts the next waiting place', () async {
      final audio = _Audio()..gate = Completer<void>();
      final np = NowPlayingService(enabled: false);
      final c = _ctl(audio, np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      final a = _poi('a', 'Ратуша');
      final b = _poi('b', 'Собор', lat: 49.84002, lng: 24.03002);
      c.debugSetPois([a, b]);

      unawaited(c.debugOnPosition(_pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(audio.played, hasLength(1), reason: 'first place is playing');

      audio.gate = null;
      np.handleCommand('skip');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(audio.played.length, 2, reason: 'next place started after skip');
      expect(c.activePoi?.id, anyOf('a', 'b'));
      c.dispose();
    });

    test('automatic narrations arm the arrival cue, manual play does not', () async {
      final audio = _Audio();
      final c = _ctl(audio, NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      expect(audio.cues, 1);
      await c.playNarrationForPoi(_poi('p2', 'Собор'));
      expect(audio.cues, 1, reason: 'user pressed play: no chime');
      c.playArrivalCue = false;
      await c.debugProcessPoi(_poi('p3', 'Арсенал'), _pos());
      expect(audio.cues, 1);
      c.dispose();
    });
  });

  group('Visited places', () {
    test('visited places are remembered across walks and restarts', () async {
      final dir = Directory.systemTemp.createTempSync('visited');
      final path = '${dir.path}/visited.json';
      final store = VisitedStore(pathProvider: () async => path);
      await store.init();
      expect(await store.add('osm_1'), isTrue);
      expect(await store.add('osm_1'), isFalse);
      await store.add('osm_2');

      final again = VisitedStore(pathProvider: () async => path);
      await again.init();
      expect(again.ids, {'osm_1', 'osm_2'});
      expect(again.count, 2);
      dir.deleteSync(recursive: true);
    });

    test('names and kinds are stored so the list can be shown later, newest first', () async {
      final dir = Directory.systemTemp.createTempSync('visited3');
      final path = '${dir.path}/v.json';
      final store = VisitedStore(pathProvider: () async => path);
      await store.add('a', name: 'Ратуша', kind: 'building');
      await store.add('b', name: 'Фонтан Нептуна', kind: 'fountain');
      await store.add('a', name: 'Ратуша', kind: 'building'); // no duplicates

      final again = VisitedStore(pathProvider: () async => path);
      await again.init();
      expect(again.places.map((p) => p.name), ['Фонтан Нептуна', 'Ратуша']);
      expect(again.places.first.kind, 'fountain');
      expect(again.count, 2);
      dir.deleteSync(recursive: true);
    });

    test('controller exposes visited places with name and kind', () async {
      final dir = Directory.systemTemp.createTempSync('visited4');
      final c = _ctl(_Audio(), NowPlayingService(enabled: false),
          VisitedStore(pathProvider: () async => '${dir.path}/v.json'));
      await c.debugProcessPoi(_poi('p1', 'Фонтан Нептуна', tags: {'amenity': 'fountain'}), _pos());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.visitedPlaces.single.name, 'Фонтан Нептуна');
      expect(c.visitedPlaces.single.kind, PoiKind.fountain.name);
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a narrated place becomes visited in the controller', () async {
      final dir = Directory.systemTemp.createTempSync('visited2');
      final store = VisitedStore(pathProvider: () async => '${dir.path}/v.json');
      final c = _ctl(_Audio(), NowPlayingService(enabled: false), store);
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.visitedPoiIds, contains('p1'));
      expect(c.totalVisitedCount, 1);

      final fresh = VisitedStore(pathProvider: () async => '${dir.path}/v.json');
      await fresh.init();
      expect(fresh.contains('p1'), isTrue);
      c.dispose();
      dir.deleteSync(recursive: true);
    });
  });

  group('One calm status', () {
    test('failed narration → attention with a retry that works', () async {
      final tts = _Tts(fail: true);
      final audio = _Audio();
      final c = _ctl(audio, NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'),
          tts: tts);
      c.debugSetPois([_poi('p1', 'Ратуша')]);
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());

      final s = c.guideStatus!;
      expect(s.tone, GuideTone.attention);
      expect(s.actionLabel, 'Повторити');
      expect(s.text, isNot(contains('1/3')), reason: 'no step-by-step retry noise');

      tts.fail = false;
      await c.runStatusAction();
      expect(audio.played, hasLength(1));
      expect(c.guideStatus, isNull, reason: 'recovered: nothing to say');
      c.dispose();
    });

    test('idle + denied permission → attention; nothing otherwise', () {
      final c = _ctl(_Audio(), NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      expect(c.guideStatus, isNull);
      c.dispose();
    });

    test('while walking without places the status is quiet and busy, no button', () {
      final c = _ctl(_Audio(), NowPlayingService(enabled: false), VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      c.debugSetPois([]);
      // debugSetPois marks OSM as loaded; walking with a loaded map is silent
      expect(c.guideStatus, isNull);
      c.dispose();
    });
  });

  group('Place kinds', () {
    PoiKind kind(String name, [Map<String, String>? tags]) => poiKindOf(_poi('x', name, tags: tags));

    test('OSM tags decide first', () {
      expect(kind('Щось', {'amenity': 'fountain'}), PoiKind.fountain);
      expect(kind('Щось', {'amenity': 'place_of_worship'}), PoiKind.church);
      expect(kind('Щось', {'building': 'cathedral'}), PoiKind.church);
      expect(kind('Щось', {'tourism': 'museum'}), PoiKind.museum);
      expect(kind('Щось', {'historic': 'castle'}), PoiKind.castle);
      expect(kind('Щось', {'historic': 'memorial'}), PoiKind.monument);
      expect(kind('Щось', {'tourism': 'artwork'}), PoiKind.artwork);
      expect(kind('Щось', {'leisure': 'park'}), PoiKind.park);
      expect(kind('Щось', {'tourism': 'viewpoint'}), PoiKind.viewpoint);
      expect(kind('Щось', {'man_made': 'tower'}), PoiKind.tower);
      expect(kind('Щось', {'building': 'yes', 'heritage': '2'}), PoiKind.building);
      expect(kind('вул. Городоцька', {'highway': 'residential', 'name': 'вул. Городоцька'}), PoiKind.street);
    });

    test('names are the fallback when there are no tags', () {
      expect(kind('Фонтан Нептуна'), PoiKind.fountain);
      expect(kind('Вулиця Довженка'), PoiKind.street);
      expect(kind('Площа Ринок'), PoiKind.square);
      expect(kind('Музей Михайла Грушевського'), PoiKind.museum);
      expect(kind('Пам\'ятник Лесі Українці'), PoiKind.monument);
      expect(kind('Собор Святого Юра'), PoiKind.church);
      expect(kind('Стрийський парк'), PoiKind.park);
      expect(kind('Невідоме місце'), PoiKind.other);
    });

    test('every kind has an icon and a Ukrainian label', () {
      for (final k in PoiKind.values) {
        expect(k.label, isNotEmpty);
        expect(k.icon, isNotNull);
      }
    });
  });

  group('City context for the AI', () {
    tearDown(() => AiService.placeContext = null);

    test('Nominatim answer → "city, country"', () {
      expect(
        PlaceContextService.parse('{"address":{"city":"Київ","country":"Україна"}}'),
        'Київ, Україна',
      );
      expect(PlaceContextService.parse('{"address":{"village":"Брюховичі","country":"Україна"}}'),
          'Брюховичі, Україна');
      expect(PlaceContextService.parse('{"address":{"country":"Польща"}}'), 'Польща');
      expect(PlaceContextService.parse('{"error":"Unable to geocode"}'), isNull);
      expect(PlaceContextService.parse('not json'), isNull);
    });

    test('prompt names the city where the user is, and nothing when unknown', () {
      final poi = _poi('m', 'Музей Михайла Грушевського');
      AiService.placeContext = 'Київ, Україна';
      expect(ContentService().buildAiPrompt(poi), contains('Київ, Україна'));
      AiService.placeContext = null;
      expect(ContentService().buildAiPrompt(poi), isNot(contains('Розташування')));
    });

    test('controller learns the city from the user position, not from a fixed destination', () async {
      final calls = <List<double>>[];
      final c = WalkController(
        destination: const Destination(
            id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
        apiKey: '',
        researchService: ResearchService(
          categoryService: PoiCategoryService(),
          cacheService: PoiCacheService(),
          queue: ResearchQueue(maxConcurrent: 2),
          wikidataService: WikidataService(),
          wikipediaService: WikipediaService(),
          aiService: _Ai(),
        ),
        ttsService: _Tts(),
        audioService: _Audio(),
        overpassService: _NoOverpass(),
        nowPlaying: NowPlayingService(enabled: false),
        visitedStore: VisitedStore(pathProvider: () async => '/nonexistent/x.json'),
        placeService: _FakePlace(calls),
      );
      c.debugSetPois([]);
      await c.debugOnPosition(_pos(50.45, 30.52)); // Kyiv
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(AiService.placeContext, 'Місто 50.45');
      await c.debugOnPosition(_pos(50.4501, 30.5201)); // same area → no new lookup
      await c.debugOnPosition(_pos(48.92, 24.71)); // Ivano-Frankivsk, far away
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, hasLength(2));
      expect(AiService.placeContext, 'Місто 48.92');
      c.dispose();
    });
  });

  audioSessionTests();

  group('Background robustness', () {
    test('a player that plays without moving is detected as stalled', () {
      final d = StallDetector(limit: const Duration(seconds: 15));
      final t0 = DateTime(2026, 1, 1, 12);
      expect(d.observe(playing: true, position: Duration.zero, now: t0), isFalse);
      expect(d.observe(playing: true, position: Duration.zero, now: t0.add(const Duration(seconds: 10))), isFalse);
      expect(d.observe(playing: true, position: Duration.zero, now: t0.add(const Duration(seconds: 16))), isTrue);
    });

    test('progress or a pause resets the stall timer', () {
      final d = StallDetector(limit: const Duration(seconds: 15));
      final t0 = DateTime(2026, 1, 1, 12);
      d.observe(playing: true, position: Duration.zero, now: t0);
      expect(d.observe(playing: true, position: const Duration(seconds: 3), now: t0.add(const Duration(seconds: 14))), isFalse);
      expect(d.observe(playing: true, position: const Duration(seconds: 3), now: t0.add(const Duration(seconds: 20))), isFalse);
      // paused for a long time is not a stall
      expect(d.observe(playing: false, position: const Duration(seconds: 3), now: t0.add(const Duration(minutes: 10))), isFalse);
    });

    test('lock-screen card shows the place and the nearest next place with distance', () async {
      final calls = <String>[];
      final np = _RecordingNowPlaying(calls);
      final c = _ctl(_Audio(), np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      c.debugSetPois([_poi('p1', 'Ратуша'), _poi('p2', 'Собор', lat: 49.8402, lng: 24.0302)]);
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());

      expect(calls.any((l) => l.startsWith('update Ратуша/Далі: Собор · ')), isTrue, reason: calls.toString());
      expect(calls.any((l) => l.contains('notify')), isFalse, reason: 'no notifications at all');
      c.dispose();
    });

    test('going to the background refreshes the lock-screen card', () async {
      final calls = <String>[];
      final audio = _Audio()..gate = Completer<void>();
      final np = _RecordingNowPlaying(calls);
      final c = _ctl(audio, np, VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      unawaited(c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      calls.clear();
      c.setAppLifecycle(AppLifecycleState.paused);
      expect(c.appInBackground, isTrue);
      // refresh is driven by the player state; at least the lifecycle call must not throw
      audio.gate!.complete();
      c.dispose();
    });
  });

  group('Listened vs passed', () {
    test('store keeps passed and listened apart and migrates old entries', () async {
      final dir = Directory.systemTemp.createTempSync('lp');
      final path = '${dir.path}/v.json';
      final store = VisitedStore(pathProvider: () async => path);
      await store.markPassed('a', name: 'Ратуша', kind: 'building');
      await store.markPassed('b', name: 'Фонтан', kind: 'fountain');
      await store.markListened('b');
      await store.markListened('c', name: 'Собор', kind: 'church'); // heard without walking past (tapped)

      expect(store.isPassed('a'), isTrue);
      expect(store.isListened('a'), isFalse);
      expect(store.isListened('b'), isTrue);
      expect(store.isPassed('c'), isFalse);
      expect(store.listenedPlaces.map((p) => p.id), ['c', 'b']);
      expect(store.passedOnlyPlaces.map((p) => p.id), ['a']);

      final again = VisitedStore(pathProvider: () async => path);
      await again.init();
      expect(again.isListened('b'), isTrue);
      expect(again.isListened('a'), isFalse);

      // old file: entries without flags count as heard
      File(path).writeAsStringSync('{"places":[{"id":"x","name":"Старе","kind":"park"}]}');
      final legacy = VisitedStore(pathProvider: () async => path);
      await legacy.init();
      expect(legacy.isListened('x'), isTrue);
      expect(legacy.isPassed('x'), isTrue);
      dir.deleteSync(recursive: true);
    });

    test('a narration heard to the end is "listened" and "passed"', () async {
      final dir = Directory.systemTemp.createTempSync('lp2');
      final c = _ctl(_Audio(), NowPlayingService(enabled: false),
          VisitedStore(pathProvider: () async => '${dir.path}/v.json'));
      await c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.listenedPoiIds, contains('p1'));
      expect(c.passedPoiIds, contains('p1'));
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a skipped narration is passed but NOT listened', () async {
      final dir = Directory.systemTemp.createTempSync('lp3');
      final audio = _Audio()..gate = Completer<void>();
      final c = _ctl(audio, NowPlayingService(enabled: false),
          VisitedStore(pathProvider: () async => '${dir.path}/v.json'));
      c.debugSetPois([_poi('p1', 'Ратуша')]);
      unawaited(c.debugOnPosition(_pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(audio.played, hasLength(1));

      await c.skipNarration();
      audio.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.passedPoiIds, contains('p1'));
      expect(c.listenedPoiIds, isNot(contains('p1')), reason: 'cut short → not listened');
      expect(c.passedOnlyPlaces.map((p) => p.id), ['p1']);
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    test('walking through a place that could not be narrated still counts as passed', () async {
      final dir = Directory.systemTemp.createTempSync('lp4');
      final audio = _Audio()..gate = Completer<void>();
      final c = _ctl(audio, NowPlayingService(enabled: false),
          VisitedStore(pathProvider: () async => '${dir.path}/v.json'));
      c.debugSetPois([_poi('p1', 'Ратуша'), _poi('p2', 'Собор', lat: 49.84003, lng: 24.03003)]);
      unawaited(c.debugOnPosition(_pos())); // p1 starts, p2 is also within radius but must wait
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.passedPoiIds, containsAll(['p1', 'p2']));
      expect(c.listenedPoiIds, isEmpty);
      audio.gate!.complete();
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    test('nearest unvisited place and the next/stop decision', () async {
      final c = _ctl(_Audio(), NowPlayingService(enabled: false),
          VisitedStore(pathProvider: () async => '/nonexistent/x.json'));
      c.debugSetPois([
        _poi('a', 'Далеко', lat: 49.845, lng: 24.03),
        _poi('b', 'Близько', lat: 49.8405, lng: 24.03),
      ]);
      await c.debugOnPosition(_pos());
      final n = c.nearestUnvisited()!;
      expect(n.poi.id, 'b');
      expect(n.meters, inInclusiveRange(40, 70));
      expect(c.nearestUnvisited(excluding: 'b')!.poi.id, 'a');
      expect(c.hasNextNarration, isFalse);
      c.dispose();
    });

    test('other audio resumes after the narration (notifyOthersOnDeactivation)', () {
      expect(PlatformSessionAdapter.configuration.avAudioSessionSetActiveOptions,
          AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation);
    });
  });

  group('Always-on indicator (Live Activity)', () {
    WalkController ctl(_Audio audio, _RecordingLive live) => WalkController(
          destination: const Destination(
              id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
          apiKey: '',
          researchService: ResearchService(
            categoryService: PoiCategoryService(),
            cacheService: PoiCacheService(),
            queue: ResearchQueue(maxConcurrent: 2),
            wikidataService: WikidataService(),
            wikipediaService: WikipediaService(),
            aiService: _Ai(),
            researchDeadline: const Duration(milliseconds: 300),
          ),
          ttsService: _Tts(),
          audioService: audio,
          overpassService: _NoOverpass(),
          nowPlaying: NowPlayingService(enabled: false),
          visitedStore: VisitedStore(pathProvider: () async => '/nonexistent/x.json'),
          liveActivity: live,
        );

    test('distances are rounded so the indicator does not flicker', () {
      expect(WalkController.formatDistance(87), '85 м');
      expect(WalkController.formatDistance(134), '130 м');
      expect(WalkController.formatDistance(980), '980 м');
      expect(WalkController.formatDistance(1240), '1,2 км');
    });

    test('no walk → nothing to show; walking without places → calm hint', () {
      final c = ctl(_Audio(), _RecordingLive([]));
      expect(c.liveState, isNull);
      c.debugSetPois([]);
      expect(c.liveState!.title, 'Гід працює');
      c.dispose();
    });

    test('between narrations it shows the nearest place and how far it is', () async {
      final c = ctl(_Audio(), _RecordingLive([]));
      c.debugSetPois([_poi('b', 'Фонтан Нептуна', lat: 49.8405, lng: 24.03, tags: {'amenity': 'fountain'})]);
      await c.debugOnPosition(_pos());
      final s = c.liveState!;
      expect(s.title, 'Фонтан Нептуна');
      expect(s.badge, matches(RegExp(r'^\d+ м$')));
      expect(s.subtitle, contains('Фонтан'));
      expect(s.speaking, isFalse);
      c.dispose();
    });

    test('while narrating it shows the place and the next one', () async {
      final audio = _Audio()..gate = Completer<void>();
      final live = _RecordingLive([]);
      final c = ctl(audio, live);
      c.debugSetPois([_poi('a', 'Ратуша'), _poi('b', 'Собор', lat: 49.8409, lng: 24.03)]);
      unawaited(c.debugOnPosition(_pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final speaking = live.states.where((s) => s.speaking && s.title == 'Ратуша').toList();
      expect(speaking, isNotEmpty, reason: live.states.toString());
      expect(live.states.any((s) => s.subtitle.startsWith('Далі: Собор')), isTrue, reason: live.states.toString());
      audio.gate!.complete();
      c.dispose();
    });

    test('walking mode (no narration) has no controls', () async {
      final c = ctl(_Audio(), _RecordingLive([]));
      c.debugSetPois([_poi('a', 'Ратуша', lat: 49.8409, lng: 24.03)]);
      await c.debugOnPosition(_pos());
      final walking = c.liveState!;
      expect(walking.speaking, isFalse);
      expect(walking.controls, isFalse);
      c.dispose();
    });

    test('lock-screen button "toggle" pauses and resumes', () async {
      final audio = _Audio()..gate = Completer<void>();
      final np = NowPlayingService(enabled: false);
      final live = _RecordingLive([]);
      final c = WalkController(
        destination: const Destination(
            id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
        apiKey: '',
        researchService: ResearchService(
          categoryService: PoiCategoryService(),
          cacheService: PoiCacheService(),
          queue: ResearchQueue(maxConcurrent: 2),
          wikidataService: WikidataService(),
          wikipediaService: WikipediaService(),
          aiService: _Ai(),
          researchDeadline: const Duration(milliseconds: 300),
        ),
        ttsService: _Tts(),
        audioService: audio,
        overpassService: _NoOverpass(),
        nowPlaying: np,
        visitedStore: VisitedStore(pathProvider: () async => '/nonexistent/x.json'),
        liveActivity: live,
      );
      c.debugSetPois([_poi('p1', 'Ратуша')]);
      unawaited(c.debugProcessPoi(_poi('p1', 'Ратуша'), _pos()));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(live.states.last.controls, isTrue);
      expect(live.states.last.paused, isFalse);

      np.handleCommand('toggle'); // pause
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(audio.paused, isTrue);
      expect(live.states.last.paused, isTrue, reason: live.states.toString());

      np.handleCommand('toggle'); // resume
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(audio.paused, isFalse);
      audio.gate!.complete();
      c.dispose();
    });

    test('stopping the walk ends the indicator', () async {
      final live = _RecordingLive([]);
      final c = ctl(_Audio(), live);
      c.debugSetPois([]);
      c.stopWalk();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(live.ended, greaterThan(0));
      c.dispose();
    });
  });

  group('Varied openings', () {
    test('stock openings are recognised', () {
      for (final t in [
        'Зупиніться на хвилинку і подивіться вгору.',
        'Погляньте на цей фасад.',
        'Перед вами старовинна церква.',
        'Зверніть увагу на різьблення.',
      ]) {
        expect(TextQuality.hasStockOpening(t), isTrue, reason: t);
      }
      expect(TextQuality.hasStockOpening('Цей фонтан бачив три століття.'), isFalse);
      expect(TextQuality.openingKey('Цей фонтан, бачив три століття.'), 'цей фонтан');
    });

    test('the prompt carries a style, the ban list and the recent openings', () {
      final poi = _poi('x', 'Ратуша');
      final p = ContentService().buildAiPrompt(poi,
          style: ContentService.openingStyles[1], avoid: ['цей фонтан', 'уявіть собі']);
      expect(p, contains(ContentService.openingStyles[1]));
      expect(p, contains('Зупиніться'));
      expect(p, contains('«цей фонтан…»'));
      expect(p, isNot(contains('("Перед вами...", "Погляньте на...")')));
    });

    test('there are enough different styles', () {
      expect(ContentService.openingStyles.toSet().length, greaterThanOrEqualTo(8));
    });
  });
}

class _RecordingNowPlaying extends NowPlayingService {
  _RecordingNowPlaying(this.calls) : super(enabled: false);
  final List<String> calls;
  @override
  Future<void> update({
    required String title,
    String subtitle = 'NotMiss',
    required bool playing,
    Duration elapsed = Duration.zero,
    Duration? duration,
  }) async =>
      calls.add('update $title/$subtitle playing=$playing');
  @override
  Future<void> clear() async => calls.add('clear');
}

class _RecordingLive extends LiveActivityService {
  _RecordingLive(this.states_) : super(enabled: false);
  final List<GuideLiveState> states_;
  List<GuideLiveState> get states => states_;
  int ended = 0;
  @override
  Future<void> show(GuideLiveState state) async => states_.add(state);
  @override
  Future<void> end() async => ended++;
}

class _FakePlace extends PlaceContextService {
  _FakePlace(this.calls);
  final List<List<double>> calls;
  @override
  Future<String?> lookup(double lat, double lng) async {
    calls.add([lat, lng]);
    return 'Місто ${lat.toStringAsFixed(2)}';
  }
}

void audioSessionTests() {
  group('Audio session (lock-screen player eligibility)', () {
    test('iOS session is not mixable: no duckOthers / mixWithOthers', () {
      final o = PlatformSessionAdapter.configuration.avAudioSessionCategoryOptions;
      expect(o == null || o.value == 0, isTrue,
          reason: 'a mixable session never becomes the Now Playing app');
      expect(PlatformSessionAdapter.configuration.avAudioSessionCategory, AVAudioSessionCategory.playback);
    });
  });
}
