import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/models/poi.dart';
import 'package:notmiss/services/alternative_places_service.dart';
import 'package:notmiss/services/overpass_service.dart';
import 'package:notmiss/ui/walk_controller.dart';

const _lat = 49.8419;
const _lng = 24.0315;

Map<String, dynamic> _page(int id, String title, {String? desc, String? wd, double dLat = 0}) => {
      'pageid': id,
      'ns': 0,
      'title': title,
      'coordinates': [
        {'lat': _lat + dLat, 'lon': _lng, 'primary': true, 'globe': 'earth'}
      ],
      if (wd != null) 'pageprops': {'wikibase_item': wd},
      if (desc != null) 'description': desc,
    };

String _geo(List<Map<String, dynamic>> pages) => jsonEncode({'batchcomplete': true, 'query': {'pages': pages}});

final _lviv = [
  _page(1, 'Львівська ратуша', desc: 'адміністративний будинок у центрі Львова', wd: 'Q4271056'),
  _page(2, 'Площа Ринок (Львів)', desc: 'центральна площа Львова', wd: 'Q1980511', dLat: 0.0001),
  _page(3, 'Облога Львова (1655)', wd: 'Q4337395'),
  _page(4, 'Львів', desc: 'місто в Україні', wd: 'Q36036'),
  _page(5, 'Галерея військового однострою', wd: 'Q12094037', dLat: 0.0002),
];

http.Response _json(String body) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

bool _isWiki(http.BaseRequest r) => r.url.host.endsWith('wikipedia.org');

Map<String, dynamic> _osmNode(int id, String name) => {
      'type': 'node',
      'id': id,
      'lat': _lat,
      'lon': _lng,
      'tags': {'name': name, 'historic': 'memorial'},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading the Wikipedia answer', () {
    test('keeps places, drops events, lists and whole towns; cleans the title', () {
      final pois = AlternativePlacesService.parse(_geo(_lviv), 'uk');
      expect(pois.map((p) => p.name), ['Львівська ратуша', 'Площа Ринок', 'Галерея військового однострою']);
      final hall = pois.first;
      expect(hall.id, 'wiki_Q4271056');
      expect(hall.wikidataId, 'Q4271056');
      expect(hall.shortDescription, contains('адміністративний'));
      expect(hall.sources.single.url, contains('uk.wikipedia.org'));
      expect(hall.confidence, 'wikipedia');
      expect(hall.triggerRadius, 50);
    });

    test('a page without coordinates or a title, and garbage, give nothing', () {
      expect(AlternativePlacesService.parse('not json', 'uk'), isEmpty);
      expect(AlternativePlacesService.parse('{}', 'uk'), isEmpty);
      expect(
          AlternativePlacesService.parse(
              _geo([
                {'pageid': 9, 'title': 'Без координат'}
              ]),
              'uk'),
          isEmpty);
    });

    test('a building described as a "town hall in a city" is still a place', () {
      expect(AlternativePlacesService.isPlace('Ратуша', 'ратуша міста Львів, пам\'ятка'), isTrue);
      expect(AlternativePlacesService.isPlace('Lviv', 'city in Ukraine'), isFalse);
      expect(AlternativePlacesService.isPlace('Battle of Lviv', ''), isFalse);
      expect(AlternativePlacesService.isPlace('Заміська дорога (1920)', ''), isFalse);
    });
  });

  group('asking Wikipedia', () {
    test('both languages are asked and the same Wikidata item is kept once', () async {
      final asked = <String>[];
      final pois = await http.runWithClient(
        () => AlternativePlacesService().fetch(_lat, _lng),
        () => MockClient((r) async {
          asked.add(r.url.host);
          expect(r.url.queryParameters['ggscoord'], '$_lat|$_lng');
          expect(r.headers['User-Agent'], contains('NotMiss'));
          return _json(_geo([_page(1, r.url.host.startsWith('uk') ? 'Львівська ратуша' : 'Lviv City Hall', wd: 'Q4271056')]));
        }),
      );
      expect(asked, unorderedEquals(['uk.wikipedia.org', 'en.wikipedia.org']));
      expect(pois, hasLength(1));
      expect(pois.single.name, 'Львівська ратуша', reason: 'the user\'s language first');
    });

    test('one language failing does not lose the other', () async {
      final pois = await http.runWithClient(
        () => AlternativePlacesService().fetch(_lat, _lng),
        () => MockClient((r) async {
          if (r.url.host.startsWith('uk')) throw const SocketException('down');
          return _json(_geo([_page(1, 'Lviv City Hall', wd: 'Q4271056')]));
        }),
      );
      expect(pois.single.name, 'Lviv City Hall');
    });
  });

  group('when OpenStreetMap does not answer', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('notmiss_alt'));
    tearDown(() => dir.deleteSync(recursive: true));

    OverpassService service({Duration delay = const Duration(seconds: 5), Duration timeout = const Duration(seconds: 28)}) =>
        OverpassService(
          staggerDelay: Duration.zero,
          requestTimeout: timeout,
          alternativeDelay: delay,
          cacheDirectory: () async => dir.path,
          alternativeLanguages: () => ['uk'],
        );

    test('every Overpass mirror failing: places come from Wikipedia at once, not after the delay', () async {
      final s = service(delay: const Duration(hours: 1));
      final pois = await http.runWithClient(
        () => s.loadPois(_lat, _lng),
        () => MockClient((r) async {
          if (_isWiki(r)) return _json(_geo(_lviv));
          throw const SocketException('overpass down');
        }),
      );
      expect(pois, hasLength(3));
      expect(s.usedAlternative, isTrue);
      expect(s.lastLoadFailed, isFalse);
      expect(s.shouldReload(_lat, _lng), isTrue, reason: 'Overpass is asked again soon');
    });

    test('a slow Overpass: Wikipedia is started after the delay and wins', () async {
      final s = service(delay: const Duration(milliseconds: 100), timeout: const Duration(seconds: 3));
      final watch = Stopwatch()..start();
      final pois = await http.runWithClient(
        () => s.loadPois(_lat, _lng),
        () => MockClient((r) async {
          if (_isWiki(r)) return _json(_geo(_lviv));
          await Future<void>.delayed(const Duration(seconds: 2));
          return _json(jsonEncode({'elements': [_osmNode(1, 'Памʼятник')]}));
        }),
      );
      expect(pois, hasLength(3));
      expect(s.usedAlternative, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)), reason: 'did not wait for the slow server');
    });

    test('Overpass answering in time: Wikipedia is not even asked', () async {
      final s = service();
      var wikiCalls = 0;
      final pois = await http.runWithClient(
        () => s.loadPois(_lat, _lng),
        () => MockClient((r) async {
          if (_isWiki(r)) {
            wikiCalls++;
            return _json(_geo(_lviv));
          }
          return _json(jsonEncode({'elements': [_osmNode(1, 'Памʼятник')]}));
        }),
      );
      expect(pois.single.id, 'osm_node_1');
      expect(s.usedAlternative, isFalse);
      expect(wikiCalls, 0);
    });

    test('both failing is a failure to retry, not an empty area', () async {
      final s = service();
      final pois = await http.runWithClient(
        () => s.loadPois(_lat, _lng),
        () => MockClient((_) async => throw const SocketException('no internet')),
      );
      expect(pois, isEmpty);
      expect(s.lastLoadFailed, isTrue);
    });

    test('Wikipedia finding nothing here leaves Overpass\'s failure as it was', () async {
      final s = service();
      final pois = await http.runWithClient(
        () => s.loadPois(_lat, _lng),
        () => MockClient((r) async {
          if (_isWiki(r)) return _json(_geo([]));
          throw const SocketException('overpass down');
        }),
      );
      expect(pois, isEmpty);
      expect(s.lastLoadFailed, isTrue);
    });

    test('places found through Wikipedia are saved and there offline next time', () async {
      await http.runWithClient(
        () => service().loadPois(_lat, _lng),
        () => MockClient((r) async {
          if (_isWiki(r)) return _json(_geo(_lviv));
          throw const SocketException('overpass down');
        }),
      );
      final again = await http.runWithClient(
        () => service().loadPois(_lat, _lng),
        () => MockClient((_) async => throw const SocketException('no internet')),
      );
      expect(again, hasLength(3));
    });
  });

  group('the same place from two sources', () {
    Poi p(String id, String name, {String? wd, double dLat = 0}) => Poi(
        id: id, name: name, latitude: _lat + dLat, longitude: _lng, triggerRadius: 40,
        shortDescription: '', facts: const [], narrationText: '', sources: const [], wikidataId: wd);

    test('same Wikidata item', () => expect(WalkController.samePlace(p('a', 'X', wd: 'Q1'), p('b', 'Y', wd: 'Q1', dLat: 0.01)), isTrue));
    test('one name inside the other, close by', () => expect(WalkController.samePlace(p('a', 'Львівська ратуша'), p('b', 'Ратуша', dLat: 0.0001)), isTrue));
    test('same name far apart is another place', () => expect(WalkController.samePlace(p('a', 'Ратуша'), p('b', 'Ратуша', dLat: 0.01)), isFalse));
    test('different places close by', () => expect(WalkController.samePlace(p('a', 'Ратуша'), p('b', 'Фонтан', dLat: 0.0001)), isFalse));
  });
}
