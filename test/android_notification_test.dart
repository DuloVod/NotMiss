import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show PlayerState, ProcessingState;
import 'package:notmiss/l10n/app_lang.dart';
import 'package:notmiss/models/destination.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/ai_service.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/background_service.dart';
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

const _tower = Poi(
    id: 'osm_node_1', name: 'Порохова вежа', latitude: 49.8449, longitude: 24.0347,
    triggerRadius: 40, shortDescription: '', facts: [], narrationText: 'Це стара вежа.', sources: [], confidence: 'osm');

class _Ai extends AiService {
  _Ai() : super(apiKey: 'x');
}

class _Tts extends TtsService {
  _Tts() : super(apiKey: 'x');
  @override
  Future<String> synthesize(String text, String poiId) async => '/tmp/x.wav';
}

/// A player the test drives by hand: playing / paused / stopped.
class _Audio extends AudioPlayerService {
  bool _playing = false;
  bool _paused = false;
  Completer<void>? _done;
  final StreamController<PlayerState> _states = StreamController<PlayerState>.broadcast(sync: true);

  void _emit() => _states.add(PlayerState(_playing, _playing || _paused ? ProcessingState.ready : ProcessingState.idle));

  @override
  Future<void> prepareSession() async {}
  @override
  bool get isPlaying => _playing;
  @override
  bool get isPaused => _paused;
  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Future<void> play(String source) async {
    _playing = true;
    _paused = false;
    _done = Completer<void>();
    _emit();
    await _done!.future;
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _paused = true;
    _emit();
  }

  @override
  Future<void> resume() async {
    _playing = true;
    _paused = false;
    _emit();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _paused = false;
    _emit();
    if (_done != null && !_done!.isCompleted) _done!.complete();
  }
}

class _Loc extends LocationService {
  @override
  void dispose() {}
}

class _Update {
  _Update(this.title, this.text, this.actions);
  final String title;
  final String text;
  final List<String> actions;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<_Update> updates;

  setUp(() {
    L.lang = AppLang.uk;
    updates = [];
    BackgroundService.notificationSpy = (t, x, a) => updates.add(_Update(t, x, a));
  });
  tearDown(() {
    BackgroundService.notificationSpy = null;
    BackgroundService.onAction = null;
  });

  group('notification buttons', () {
    test('labels follow the app language and ids are kept', () {
      final uk = BackgroundService.buttonsFor([NotificationActions.pause, NotificationActions.skip]);
      expect(uk.map((b) => b.id), ['pause', 'skip']);
      expect(uk.map((b) => b.text), ['Пауза', 'Далі']);

      L.lang = AppLang.en;
      final en = BackgroundService.buttonsFor([NotificationActions.resume, NotificationActions.skip]);
      expect(en.map((b) => b.text), ['Resume', 'Next']);
    });

    test('no actions means no buttons (replaces the old ones)', () {
      expect(BackgroundService.buttonsFor(const []), isEmpty);
    });

    test('a pressed button reaches the app; other data is ignored', () {
      final got = <String>[];
      BackgroundService.onAction = got.add;
      BackgroundService.handleTaskData('pause');
      BackgroundService.handleTaskData(42);
      BackgroundService.handleTaskData('skip');
      expect(got, ['pause', 'skip']);
    });
  });

  group('walk controller drives the notification', () {
    WalkController ctl(_Audio audio) => WalkController(
          destination: const Destination(
              id: 'l', name: 'Львів', centerLatitude: 49.84, centerLongitude: 24.03, defaultZoom: 16, pois: []),
          apiKey: '',
          locationService: _Loc(),
          overpassService: OverpassService(),
          ttsService: _Tts(),
          audioService: audio,
          researchService: ResearchService(
            categoryService: PoiCategoryService(),
            cacheService: PoiCacheService(),
            queue: ResearchQueue(),
            wikidataService: WikidataService(),
            wikipediaService: WikipediaService(),
            aiService: _Ai(),
          ),
        );

    Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

    test('playing: place name with Pause and Next; pressing them pauses, resumes, skips', () async {
      final audio = _Audio();
      final c = ctl(audio);
      unawaited(c.playNarrationForPoi(_tower));
      await settle();

      expect(audio.isPlaying, isTrue);
      expect(updates.last.title, contains('Порохова вежа'));
      expect(updates.last.actions, ['pause', 'skip']);

      BackgroundService.handleTaskData('pause'); // the button on the notification
      await settle();
      expect(audio.isPaused, isTrue);
      expect(updates.last.actions, ['resume', 'skip']);
      expect(updates.last.text, 'Paused');

      BackgroundService.handleTaskData('resume');
      await settle();
      expect(audio.isPlaying, isTrue);
      expect(updates.last.actions, ['pause', 'skip']);

      BackgroundService.handleTaskData('skip');
      await settle();
      expect(audio.isPlaying, isFalse);
      expect(updates.last.actions, isEmpty, reason: 'nothing is narrated: the buttons go away');
      expect(updates.last.title, contains('Walk in progress'));
      c.dispose();
    });

    test('with no narration the notification never shows buttons', () async {
      final c = ctl(_Audio());
      await settle();
      expect(updates.where((u) => u.actions.isNotEmpty), isEmpty);
      c.dispose();
    });
  });
}
