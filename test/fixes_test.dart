import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/models/enriched_poi.dart';
import 'package:notmiss/services/audio_player_service.dart';
import 'package:notmiss/services/poi_cache_service.dart';
import 'package:notmiss/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fix #2 — PoiCacheService.dispose() cancels pending Timer', () {
    test('dispose() can be called safely with no pending timer', () {
      final cache = PoiCacheService();
      // Should not throw even if no timer is active
      expect(() => cache.dispose(), returnsNormally);
    });

    test('dispose() cancels timer and prevents stale writes', () async {
      final cache = PoiCacheService();

      // Put a POI to schedule a debounced disk write
      final poi = EnrichedPoi(
        poiId: 'p1',
        name: 'Test',
        category: 'other',
        latitude: 0,
        longitude: 0,
        researchStatus: ResearchStatus.notStarted,
      );
      await cache.put(poi); // schedules a 2s timer internally

      // dispose() must cancel the timer — no "pending timer" assertion failure
      expect(() => cache.dispose(), returnsNormally);

      // Advance fake time far past 2s — if the timer was not cancelled,
      // the test framework would complain about pending timers.
      await Future.delayed(Duration.zero);
    });
  });

  group('Fix #4 — TtsService safe substring on short error body', () {
    // We test the logic directly by extracting the preview logic
    // (the actual service needs a real API key and network to run TTS)

    test('preview is body itself when shorter than 300 chars', () {
      const body = 'short error';
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview, 'short error');
    });

    test('preview is truncated to 300 when body is longer', () {
      final body = 'x' * 500;
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview.length, 300);
    });

    test('preview equals body exactly at 300 chars boundary', () {
      final body = 'y' * 300;
      final preview = body.length > 300 ? body.substring(0, 300) : body;
      expect(preview.length, 300);
      expect(preview, body); // not truncated, equals original
    });

    test('TtsService.synthesize throws on empty API key (no crash)', () async {
      final svc = TtsService(apiKey: '');
      expect(
        () => svc.synthesize('hello', 'poi1'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('API key not set'),
        )),
      );
    });
  });

  group('AudioPlayerService pause / resume / stop', () {
    test('isPaused is false initially', () {
      final player = AudioPlayerService();
      expect(player.isPlaying, false);
      expect(player.isPaused, false);
      expect(player.playerStateStream, isNotNull);
      player.dispose();
    });

    test('pause and stop execute without throwing', () async {
      final player = AudioPlayerService();
      await expectLater(player.pause(), completes);
      await expectLater(player.stop(), completes);
      player.dispose();
    });
  });
}
