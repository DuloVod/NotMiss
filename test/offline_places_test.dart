import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/services/overpass_service.dart';

const _lat = 49.84;
const _lng = 24.03;

Map<String, dynamic> _node(int id, String name, [double dLat = 0]) => {
      'type': 'node',
      'id': id,
      'lat': _lat + dLat,
      'lon': _lng,
      'tags': {'name': name, 'historic': 'memorial'},
    };

http.Response _ok(List<Map<String, dynamic>> e) => http.Response.bytes(
    utf8.encode(jsonEncode({'elements': e})), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

final _four = [for (var i = 1; i <= 4; i++) _node(i, 'Пам\'ятник $i', i * 0.0001)];

/// The network is out: every mirror fails.
MockClient _offline() => MockClient((_) async => throw const SocketException('no internet'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late DateTime clock;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('notmiss_cache');
    clock = DateTime(2026, 11, 20, 12);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  OverpassService service() => OverpassService(
        staggerDelay: Duration.zero,
        cacheDirectory: () async => dir.path,
        now: () => clock,
      );

  Future<List> online(OverpassService s, double lat, double lng, {bool force = false}) => http.runWithClient(
        () => s.loadPois(lat, lng, force: force),
        () => MockClient((_) async => _ok(_four)),
      );

  Future<List> offline(OverpassService s, double lat, double lng, {bool force = false}) =>
      http.runWithClient(() => s.loadPois(lat, lng, force: force), _offline);

  test('places seen once are there after restart with no internet', () async {
    expect(await online(service(), _lat, _lng), hasLength(4));

    final restarted = service(); // a new app start: nothing in memory
    final places = await offline(restarted, _lat, _lng);
    expect(places, hasLength(4));
    expect(restarted.lastLoadFailed, isFalse);
    expect(restarted.servedFromOldCache, isFalse, reason: 'fresh: used as it is');
  });

  test('a list older than a day is still shown when the network fails (and says so)', () async {
    await online(service(), _lat, _lng);
    clock = clock.add(const Duration(days: 9));

    final s = service();
    final places = await offline(s, _lat, _lng);
    expect(places, hasLength(4));
    expect(s.servedFromOldCache, isTrue);
    expect(s.shouldReload(_lat, _lng), isTrue, reason: 'asks the network again when it can');
  });

  test('an old list is replaced by a fresh one as soon as the network is back', () async {
    await online(service(), _lat, _lng);
    clock = clock.add(const Duration(days: 9));
    final s = service();
    final fresh = await http.runWithClient(
      () => s.loadPois(_lat, _lng),
      () => MockClient((_) async => _ok([..._four, _node(5, 'Новий', 0.0006)])),
    );
    expect(fresh, hasLength(5));
    expect(s.servedFromOldCache, isFalse);
  });

  test('older than 60 days is not trusted any more', () async {
    await online(service(), _lat, _lng);
    clock = clock.add(const Duration(days: 61));
    final s = service();
    expect(await offline(s, _lat, _lng), isEmpty);
    expect(s.lastLoadFailed, isTrue, reason: 'a failure to retry, not an empty area');
  });

  test('several areas are kept: coming back to the first city needs no internet', () async {
    await online(service(), _lat, _lng); // Lviv
    await online(service(), 50.45, 30.52); // Kyiv, far away
    final s = service();
    expect(await offline(s, _lat, _lng), hasLength(4));
    expect(await offline(service(), 50.45, 30.52), hasLength(4));
  });

  test('a list from another city is never shown here', () async {
    await online(service(), 50.45, 30.52);
    final s = service();
    expect(await offline(s, _lat, _lng), isEmpty);
    expect(s.lastLoadFailed, isTrue);
  });

  test('only the last few areas are kept', () async {
    for (var i = 0; i < OverpassService.maxAreas + 2; i++) {
      await online(service(), 40.0 + i, 20.0); // far from each other
    }
    final saved = jsonDecode(File('${dir.path}/osm_poi_cache.json').readAsStringSync())['areas'] as List;
    expect(saved, hasLength(OverpassService.maxAreas));
    expect(await offline(service(), 40.0, 20.0), isEmpty, reason: 'the oldest were dropped');
    expect(await offline(service(), 40.0 + OverpassService.maxAreas + 1, 20.0), hasLength(4));
  });

  test('"refresh" without internet keeps the saved places instead of emptying the map', () async {
    final s = service();
    await online(s, _lat, _lng);
    await s.clearCache(); // what the refresh button does
    final places = await offline(s, _lat, _lng, force: true);
    expect(places, hasLength(4));
    expect(s.servedFromOldCache, isTrue);
  });

  test('the old single-area cache file of earlier versions still works', () async {
    File('${dir.path}/osm_poi_cache.json').writeAsStringSync(jsonEncode({
      'center_lat': _lat,
      'center_lng': _lng,
      'timestamp': clock.toIso8601String(),
      'pois': [
        for (var i = 1; i <= 4; i++)
          {'id': 'osm_node_$i', 'name': 'Місце $i', 'latitude': _lat + i * 0.0001, 'longitude': _lng}
      ],
    }));
    expect(await offline(service(), _lat, _lng), hasLength(4));
  });

  test('a broken file does not break the app', () async {
    File('${dir.path}/osm_poi_cache.json').writeAsStringSync('{ not json');
    final s = service();
    expect(await offline(s, _lat, _lng), isEmpty);
    expect(s.lastLoadFailed, isTrue);
    expect(await online(service(), _lat, _lng), hasLength(4)); // and it heals itself
    expect(await offline(service(), _lat, _lng), hasLength(4));
  });

  test('a saved quick search keeps the full search due after restart', () async {
    await online(service(), _lat, _lng); // first search in an area is the quick one
    final restarted = service();
    await offline(restarted, _lat, _lng);
    expect(restarted.shouldReload(_lat, _lng), isTrue);
  });

  test('a quick (reduced) search does not replace a fuller saved list of the same place', () async {
    // A full list of 6 places, saved 9 days ago.
    File('${dir.path}/osm_poi_cache.json').writeAsStringSync(jsonEncode({
      'version': 2,
      'areas': [
        {
          'center_lat': _lat,
          'center_lng': _lng,
          'timestamp': clock.subtract(const Duration(days: 9)).toIso8601String(),
          'partial': false,
          'pois': [
            for (var i = 1; i <= 6; i++)
              {'id': 'osm_node_$i', 'name': 'Місце $i', 'latitude': _lat + i * 0.0001, 'longitude': _lng}
          ],
        }
      ],
    }));
    // The network answers, but with the quick search's four places.
    expect(await online(service(), _lat, _lng), hasLength(4));
    // Later, offline: the six are still there.
    expect(await offline(service(), _lat, _lng), hasLength(6));
  });

  test('an empty answer is not saved over a good list', () async {
    await online(service(), _lat, _lng);
    await http.runWithClient(() => service().loadPois(_lat, _lng, force: true), () => MockClient((_) async => _ok([])));
    expect(await offline(service(), _lat, _lng), hasLength(4));
  });
}

const maxAreasLabel = OverpassService.maxAreas;
