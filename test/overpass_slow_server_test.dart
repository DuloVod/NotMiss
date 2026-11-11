import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/services/overpass_service.dart';

const _lat = 49.84;
const _lng = 24.03;

Map<String, dynamic> _node(int id, String name) => {
      'type': 'node',
      'id': id,
      'lat': _lat,
      'lon': _lng,
      'tags': {'name': name, 'historic': 'memorial'},
    };

http.Response _ok(List<Map<String, dynamic>> elements) => http.Response.bytes(
      utf8.encode(jsonEncode({'elements': elements})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

bool _isQuick(http.Request r) => !Uri.decodeComponent(r.body).contains('theme_park');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first search in an area is the quick one, and the full one is due right after', () async {
    final seen = <bool>[];
    final service = OverpassService(staggerDelay: Duration.zero);
    final first = await http.runWithClient(
      () => service.loadPois(_lat, _lng, force: true),
      () => MockClient((r) async {
        seen.add(_isQuick(r));
        return _ok([_node(1, 'Пам\'ятник А')]);
      }),
    );
    expect(first, hasLength(1));
    expect(seen.first, isTrue, reason: 'quick query first');
    expect(service.shouldReload(_lat, _lng), isTrue, reason: 'full search follows');
    expect(service.lastLoadFailed, isFalse);
  });

  test('a slow server that needs longer than the old 12 s limit still delivers', () async {
    final service = OverpassService(
      staggerDelay: Duration.zero,
      requestTimeout: const Duration(milliseconds: 600),
    );
    final result = await http.runWithClient(
      () => service.loadPois(_lat, _lng, force: true),
      () => MockClient((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _ok([_node(1, 'Пам\'ятник А')]);
      }),
    );
    expect(result, hasLength(1));
  });

  test('a server slower than the limit is a failure, not an empty area', () async {
    final service = OverpassService(
      staggerDelay: Duration.zero,
      requestTimeout: const Duration(milliseconds: 100),
    );
    final result = await http.runWithClient(
      () => service.loadPois(_lat, _lng, force: true),
      () => MockClient((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return _ok([_node(1, 'Пам\'ятник А')]);
      }),
    );
    expect(result, isEmpty);
    expect(service.lastLoadFailed, isTrue, reason: 'the controller must retry');
  });

  test('when the full search fails, the quick one still gives points', () async {
    var calls = 0;
    final service = OverpassService(staggerDelay: Duration.zero);
    await http.runWithClient(
      () => service.loadPois(_lat, _lng, force: true),
      () => MockClient((r) async {
        calls++;
        return _ok([_node(1, 'Пам\'ятник А')]);
      }),
    );
    expect(calls, greaterThan(0));

    // The area is cached; the next full search hits a failing server and falls back to the quick one.
    var phase = 0;
    final result = await http.runWithClient(
      () async {
        await Future<void>.delayed(const Duration(seconds: 11));
        return service.loadPois(_lat, _lng);
      },
      () => MockClient((r) async {
        phase++;
        if (!_isQuick(r)) return http.Response('overloaded', 502);
        return _ok([_node(2, 'Пам\'ятник Б')]);
      }),
    );
    expect(phase, greaterThan(0));
    expect(result, isNotEmpty);
    expect(service.lastLoadFailed, isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
