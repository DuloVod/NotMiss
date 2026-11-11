import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:notmiss/l10n/app_lang.dart';
import 'package:notmiss/l10n/place_name.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/live_activity_service.dart';
import 'package:notmiss/services/now_playing_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/services/place_context_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/settings_store.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/visited_store.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/screens/main_screen.dart';
import 'package:notmiss/ui/theme/app_theme.dart';
import 'package:notmiss/ui/walk_controller.dart';

final _cyr = RegExp(r'[А-Яа-яІіЇїЄєҐґ]');

class _Ai extends AiService {
  _Ai() : super(apiKey: 'test');
  @override
  Future<String> generateNarration(Poi poi) async =>
      L.t('Розповідь про місце. Друге речення.', 'A story about the place. A second sentence.');
}

class _Tts extends TtsService {
  _Tts() : super(apiKey: 'test');
  @override
  Future<String> synthesize(String text, String poiId) async => '/tmp/$poiId.wav';
}

class _Audio extends AudioPlayerService {
  @override
  void armArrivalCue() {}
  @override
  Future<void> prepareSession() async {}
  @override
  Future<void> play(String source) async {}
  @override
  Future<void> stop() async {}
}

class _NoOverpass extends OverpassService {
  @override
  bool shouldReload(double lat, double lng) => false;
}

class _Place extends PlaceContextService {
  @override
  Future<String?> lookup(double lat, double lng) async => null;
  @override
  Future<String?> lookupLocalCity(double lat, double lng) async => null;
}

Poi _poi(String id, String name, double dLat, Map<String, String> tags) => Poi(
      id: id,
      name: name,
      latitude: 49.84 + dLat,
      longitude: 24.03,
      triggerRadius: 40,
      shortDescription: '',
      facts: const [],
      narrationText: '',
      sources: const [],
      osmTags: tags,
    );

Position _at() => Position(
      latitude: 49.84,
      longitude: 24.03,
      timestamp: DateTime(2026, 1, 1),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1,
      speedAccuracy: 0,
    );

/// Every string a user can read or hear described on the current screen: texts, tooltips,
/// hints, tab labels, button labels, accessibility labels.
List<String> _visibleStrings(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
  }
  for (final e in find.byType(Tooltip).evaluate()) {
    out.add((e.widget as Tooltip).message ?? '');
  }
  for (final e in find.byType(TextField).evaluate()) {
    final d = (e.widget as TextField).decoration;
    out.add(d?.hintText ?? '');
    out.add(d?.labelText ?? '');
  }
  for (final e in find.byType(Semantics).evaluate()) {
    out.add((e.widget as Semantics).properties.label ?? '');
  }
  return out.where((t) => t.trim().isNotEmpty).toList();
}

void _expectNoCyrillic(WidgetTester tester, String where) {
  final bad = _visibleStrings(tester).where(_cyr.hasMatch).toList();
  expect(bad, isEmpty, reason: 'Ukrainian text on the English "$where" screen: $bad');
}

Widget _app(WalkController c) => MaterialApp(
      theme: NmTheme.light(),
      locale: Locale(L.lang.code),
      supportedLocales: [for (final l in AppLang.values) Locale(l.code)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: MainScreen(controller: c),
    );

final _latinWord = RegExp(r'[A-Za-z]{3,}');
const _allowedLatin = {'NotMiss', 'Gemini', 'OSM', 'GPS', 'EN', 'UK'};

void _expectNoEnglish(WidgetTester tester, String where) {
  final bad = _visibleStrings(tester)
      .where((t) => _latinWord.allMatches(t).any((m) => !_allowedLatin.contains(m.group(0))))
      .toList();
  expect(bad, isEmpty, reason: 'English text on the Ukrainian "$where" screen: $bad');
}

Future<WalkController> _controller() async {
  final ai = _Ai();
  final c = WalkController(
    destination: const Destination(
        id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
    apiKey: '',
    aiService: ai,
    researchService: ResearchService(
      categoryService: PoiCategoryService(),
      cacheService: PoiCacheService(),
      queue: ResearchQueue(maxConcurrent: 2),
      wikidataService: WikidataService(),
      wikipediaService: WikipediaService(),
      aiService: ai,
    ),
    ttsService: _Tts(),
    audioService: _Audio(),
    overpassService: _NoOverpass(),
    nowPlaying: NowPlayingService(enabled: false),
    visitedStore: VisitedStore(pathProvider: () async => '/nonexistent/x.json'),
    placeService: _Place(),
    liveActivity: LiveActivityService(enabled: false),
    settingsStore: SettingsStore(pathProvider: () async => '/nonexistent/s.json'),
  );
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    L.lang = AppLang.uk;
    // The compass plugin has no implementation in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hemanthraj/flutter_compass'), (call) async => null);
  });
  tearDown(() => L.lang = AppLang.uk);

  group('Place names', () {
    test('transliteration follows the national system', () {
      expect(PlaceNames.transliterate('Бібліотека УКУ'), 'Biblioteka UKU');
      expect(PlaceNames.transliterate('Львів'), 'Lviv');
      expect(PlaceNames.transliterate('Київ'), 'Kyiv');
      expect(PlaceNames.transliterate('Харків'), 'Kharkiv');
      expect(PlaceNames.transliterate('Єфремова'), 'Yefremova');
      expect(PlaceNames.transliterate('Згорани'), 'Zghorany');
      expect(PlaceNames.transliterate("Соколу-Батьку"), 'Sokolu-Batku');
      expect(PlaceNames.transliterate("Пам'ятник Шевченку"), 'Pamiatnyk Shevchenku');
      expect(PlaceNames.transliterate('Вулиця Городоцька'), 'Vulytsia Horodotska');
      expect(PlaceNames.transliterate('Linden'), 'Linden');
      expect(PlaceNames.transliterate('9К72 «Ельбрус»'), '9K72 «Elbrus»');
    });

    test('the map\'s own English name wins; Ukrainian users get Ukrainian', () {
      L.lang = AppLang.en;
      expect(PlaceNames.of('Ратуша', {'name:en': 'Town Hall'}), 'Town Hall');
      expect(PlaceNames.of('Ратуша', {'int_name': 'Ratusha'}), 'Ratusha');
      expect(PlaceNames.of('Ратуша', {'int_name': 'Ратуша'}), 'Ratusha');
      expect(PlaceNames.of('Ратуша', null), 'Ratusha');
      expect(PlaceNames.of('Linden', null), 'Linden');
      L.lang = AppLang.uk;
      expect(PlaceNames.of('Ратуша', {'name:en': 'Town Hall'}), 'Ратуша');
      expect(PlaceNames.of('Ratusha', {'name:uk': 'Ратуша'}), 'Ратуша');
    });
  });

  group('English interface has no Ukrainian text', () {
    testWidgets('map, cards, lists, language sheet, report sheet, details and chat', (tester) async {
      L.lang = AppLang.en;
      final c = await _controller();
      final pois = [
        _poi('lib', 'Бібліотека УКУ', 0, {'amenity': 'library', 'description': 'Бібліотека веде свій відлік від 1929 року, коли митрополит передав книги семінарії.'}),
        _poi('tank', 'Т-64', 0.0002, const {}),
        _poi('hall', 'Ратуша', 0.003, {'historic': 'building', 'name:en': 'Town Hall'}),
      ];
      c.debugSetPois(pois);
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpWidget(_app(c));
      await tester.pump(const Duration(milliseconds: 300));

      // 1. map screen, walking, nothing playing
      await tester.runAsync(() => c.debugOnPosition(_at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'map');

      // 2. a story is playing (active card)
      await tester.runAsync(() => c.debugProcessPoi(pois[0], _at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'active card');
      expect(find.textContaining('Biblioteka UKU'), findsWidgets);

      // 3. a silent place
      await tester.runAsync(() => c.debugProcessPoi(pois[1], _at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'silent place card');
      expect(find.textContaining('not narrated'), findsWidgets);

      // 4. my places
      await tester.tap(find.byTooltip('My places').first);
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'my places');
      await tester.tap(find.textContaining('Passed'));
      await tester.pump(const Duration(milliseconds: 400));
      _expectNoCyrillic(tester, 'my places / passed');
      Navigator.of(tester.element(find.byType(MainScreen))).pop();
      await tester.pump(const Duration(milliseconds: 600));

      // 5. language sheet
      await tester.tap(find.byTooltip('Language'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Українська'), findsOneWidget, reason: 'each language is named in itself');
      Navigator.of(tester.element(find.byType(MainScreen))).pop();
      await tester.pump(const Duration(milliseconds: 600));

      // 6. report sheet
      await tester.tap(find.byTooltip('Inaccurate information').first);
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'report sheet');
      Navigator.of(tester.element(find.byType(MainScreen))).pop();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.binding.setSurfaceSize(null);
      c.dispose();
    });

    testWidgets('details sheet and AI chat of a place', (tester) async {
      L.lang = AppLang.en;
      final c = await _controller();
      final poi = _poi('hall', 'Ратуша', 0, {'historic': 'building', 'description': 'Міська будівля, у якій понад шість століть працювала міська влада; нинішню споруду звели на місці попередньої.'});
      c.debugSetPois([poi]);
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpWidget(_app(c));
      await tester.runAsync(() => c.debugProcessPoi(poi, _at()));
      await tester.pump(const Duration(milliseconds: 800));

      await tester.tap(find.textContaining('Read all'));
      await tester.pump(const Duration(milliseconds: 800));
      _expectNoCyrillic(tester, 'details sheet');

      await tester.tap(find.textContaining('Ask the AI').last);
      await tester.pump(const Duration(milliseconds: 800));
      _expectNoCyrillic(tester, 'AI chat');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.binding.setSurfaceSize(null);
      c.dispose();
    });

    testWidgets('the Ukrainian interface has no English text', (tester) async {
      L.lang = AppLang.uk;
      final c = await _controller();
      final pois = [
        _poi('lib', 'Бібліотека УКУ', 0, {'amenity': 'library', 'description': 'Бібліотека веде свій відлік від 1929 року, коли митрополит передав книги семінарії.'}),
        _poi('tank', 'Т-64', 0.0002, const {}),
      ];
      c.debugSetPois(pois);
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpWidget(_app(c));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => c.debugOnPosition(_at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoEnglish(tester, 'map');
      await tester.runAsync(() => c.debugProcessPoi(pois[0], _at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoEnglish(tester, 'active card');
      await tester.runAsync(() => c.debugProcessPoi(pois[1], _at()));
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoEnglish(tester, 'silent place card');
      await tester.tap(find.byTooltip('Мої місця').first);
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoEnglish(tester, 'my places');
      Navigator.of(tester.element(find.byType(MainScreen))).pop();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byTooltip('Неточна інформація').first);
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoEnglish(tester, 'report sheet');
      Navigator.of(tester.element(find.byType(MainScreen))).pop();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.binding.setSurfaceSize(null);
      c.dispose();
    });

    testWidgets('start / stopped / permission cards', (tester) async {
      L.lang = AppLang.en;
      final c = await _controller();
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpWidget(_app(c));
      await tester.pump(const Duration(milliseconds: 800));
      _expectNoCyrillic(tester, 'start (permission) card');
      c.debugSetPois([]);
      c.stopWalk();
      await tester.pump(const Duration(milliseconds: 600));
      _expectNoCyrillic(tester, 'walk finished card');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.binding.setSurfaceSize(null);
      c.dispose();
    });
  });
}
