import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/poi_category_service.dart';
import 'package:notmiss/services/research_queue.dart';
import 'package:notmiss/services/research_service.dart';
import 'package:notmiss/services/tts_service.dart';
import 'package:notmiss/services/wikidata_service.dart';
import 'package:notmiss/services/wikipedia_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

class _FakeTts extends TtsService {
  _FakeTts({this.failFirst = 0}) : super(apiKey: 'test');
  final int failFirst;
  int calls = 0;
  final List<String> texts = [];

  @override
  Future<String> synthesize(String text, String poiId) async {
    calls++;
    texts.add(text);
    if (calls <= failFirst) throw Exception('TTS down');
    return '/tmp/fake_$poiId.wav';
  }
}

class _FakeAudio extends AudioPlayerService {
  final List<String> played = [];
  @override
  Future<void> play(String source) async => played.add(source);
  @override
  Future<void> stop() async {}
}

class _FakeAi extends AiService {
  _FakeAi({this.hang = false, this.delay = Duration.zero}) : super(apiKey: 'test');
  final bool hang;
  final Duration delay;
  int factCalls = 0;

  @override
  Future<Map<String, dynamic>?> generateBackgroundFacts(
      String name, String category, Map<String, String> tags) async {
    factCalls++;
    if (hang) return Completer<Map<String, dynamic>?>().future;
    await Future.delayed(delay);
    return {
      'narration': 'Розповідь про $name.',
      'description': 'Опис місця $name.',
      'facts': ['Факт перший про $name.', 'Факт другий про $name.'],
    };
  }

  @override
  Future<String> generateNarration(Poi poi) async {
    if (hang) return Completer<String>().future;
    return 'Розповідь про ${poi.name}.';
  }
}

const _poi = Poi(
  id: 'poi_trigger',
  name: 'Ратуша',
  latitude: 49.84,
  longitude: 24.03,
  triggerRadius: 40,
  shortDescription: '',
  facts: [],
  narrationText: '',
  sources: [],
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

ResearchService _research(AiService ai,
    {Duration deadline = const Duration(seconds: 25), ResearchQueue? queue}) {
  return ResearchService(
    categoryService: PoiCategoryService(),
    cacheService: PoiCacheService(),
    queue: queue ?? ResearchQueue(maxConcurrent: 2),
    wikidataService: WikidataService(),
    wikipediaService: WikipediaService(),
    aiService: ai,
    researchDeadline: deadline,
  );
}

WalkController _controller(ResearchService research, _FakeTts tts, _FakeAudio audio) {
  final c = WalkController(
    destination: const Destination(
      id: 'lviv',
      name: 'Львів',
      centerLatitude: 49.84,
      centerLongitude: 24.03,
      defaultZoom: 16,
      pois: [],
    ),
    apiKey: '',
    researchService: research,
    ttsService: tts,
    audioService: audio,
  );
  c.ttsRetryPause = Duration.zero;
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Trigger reliability', () {
    test('TTS failure keeps the card with narration text and does not lose the POI', () async {
      final tts = _FakeTts(failFirst: 99);
      final audio = _FakeAudio();
      final controller = _controller(_research(_FakeAi()), tts, audio);

      await controller.debugProcessPoi(_poi, _pos);

      expect(tts.calls, controller.ttsAttempts, reason: 'bounded retries');
      expect(audio.played, isEmpty);
      expect(controller.isProcessing, isFalse);
      expect(controller.activePoi, isNotNull, reason: 'card must stay visible');
      expect(controller.activePoi!.narrationText, isNotEmpty);
      expect(controller.statusMessage, contains('текстом'));
      expect(controller.triggeredPoiIds, contains(_poi.id));
      controller.dispose();
    });

    test('transient TTS failure is retried and audio plays', () async {
      final tts = _FakeTts(failFirst: 2);
      final audio = _FakeAudio();
      final controller = _controller(_research(_FakeAi()), tts, audio);

      await controller.debugProcessPoi(_poi, _pos);

      expect(tts.calls, 3);
      expect(audio.played, ['/tmp/fake_poi_trigger.wav']);
      expect(controller.activePoi, isNotNull, reason: 'card stays after playback');
      expect(controller.activePoi!.narrationText, isNotEmpty);
      controller.dispose();
    });

    test('research deadline fires: quick fallback text is spoken without waiting', () async {
      final tts = _FakeTts();
      final audio = _FakeAudio();
      final controller = _controller(
        _research(_FakeAi(hang: true), deadline: const Duration(milliseconds: 300)),
        tts,
        audio,
      );

      final sw = Stopwatch()..start();
      await controller.debugProcessPoi(_poi, _pos);
      sw.stop();

      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(tts.texts.single, contains('Ратуша'));
      expect(audio.played, hasLength(1));
      expect(controller.activePoi!.narrationText, contains('Ратуша'));
      controller.dispose();
    });

    test('researchImmediately joins the run started by the queue instead of duplicating it', () async {
      final ai = _FakeAi(delay: const Duration(milliseconds: 200));
      final service = _research(ai);

      service.processDiscoveredPois([_poi]); // queue starts the run right away
      await service.researchImmediately(_poi.id, poi: _poi, force: true);

      expect(ai.factCalls, 1, reason: 'no duplicate research for the same POI');
      final result = service.getEnrichedData(_poi.id)!;
      expect(result.researchStatus, ResearchStatus.complete);
      expect(result.narrationText, isNotEmpty);
      service.dispose();
    });

    test('a failed run does not overwrite a newer successful result', () async {
      final service = _research(_FakeAi());
      await service.researchImmediately(_poi.id, poi: _poi, force: true);
      final good = service.getEnrichedData(_poi.id)!;
      expect(good.researchStatus, ResearchStatus.complete);

      // Queue task for an already completed POI must be a no-op, not a rewrite.
      service.processDiscoveredPois([_poi]);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(service.getEnrichedData(_poi.id)!.narrationText, good.narrationText);
      service.dispose();
    });
  });
}
