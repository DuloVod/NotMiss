import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notmiss/services/place_photo_service.dart';

/// A fake Wikimedia: answers the four kinds of questions the photo service asks.
class _Wiki {
  final requests = <Uri>[];

  /// Wikidata entity → P18 file name.
  final Map<String, String> p18 = {};

  /// Wikipedia "lang:Title" → page image file name.
  final Map<String, String> pageImages = {};

  /// Commons file name → (mime, author html, licence).
  final Map<String, (String, String?, String?)> files = {};

  /// Commons photos near the place: (file name, distance in metres).
  final List<(String, double)> nearby = [];

  bool offline = false;

  late final client = MockClient((r) async {
    requests.add(r.url);
    if (offline) throw http.ClientException('offline', r.url);
    expect(r.headers['User-Agent'], contains('NotMiss'));
    final q = r.url.queryParameters;
    Map<String, dynamic> body;
    if (r.url.host == 'www.wikidata.org') {
      final file = p18[q['entity']];
      body = {
        'claims': file == null
            ? <String, dynamic>{}
            : {
                'P18': [
                  {
                    'rank': 'normal',
                    'mainsnak': {
                      'datavalue': {'value': file, 'type': 'string'}
                    }
                  }
                ]
              }
      };
    } else if (r.url.host.endsWith('.wikipedia.org')) {
      final lang = r.url.host.split('.').first;
      final file = pageImages['$lang:${q['titles']}'];
      body = {
        'query': {
          'pages': [
            {'title': q['titles'], if (file != null) 'pageimage': file}
          ]
        }
      };
    } else if (q['list'] == 'geosearch') {
      body = {
        'query': {
          'geosearch': [
            for (final (f, d) in nearby) {'title': 'File:$f', 'dist': d, 'ns': 6}
          ]
        }
      };
    } else {
      final name = q['titles']!.replaceFirst('File:', '');
      final f = files[name];
      body = {
        'query': {
          'pages': [
            f == null
                ? {'title': 'File:$name', 'missing': true}
                : {
                    'title': 'File:$name',
                    'imageinfo': [
                      {
                        'mime': f.$1,
                        'url': 'https://upload.wikimedia.org/full/$name',
                        'thumburl': 'https://upload.wikimedia.org/thumb/1080px-$name',
                        'descriptionurl': 'https://commons.wikimedia.org/wiki/File:$name',
                        'extmetadata': {
                          if (f.$2 != null) 'Artist': {'value': f.$2},
                          if (f.$3 != null) 'LicenseShortName': {'value': f.$3},
                        }
                      }
                    ]
                  }
          ]
        }
      };
    }
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

const _tower = PhotoQuery(
  id: 'tower',
  name: 'Водонапірна вежа',
  altNames: ['Vodonapirna vezha'],
  lat: 49.8246,
  lng: 24.0238,
);

PhotoQuery _q({
  Map<String, String> tags = const {},
  List<String> wikidata = const [],
  List<String> wikipedia = const [],
  bool done = false,
}) =>
    PhotoQuery(
      id: _tower.id,
      name: _tower.name,
      altNames: _tower.altNames,
      lat: _tower.lat,
      lng: _tower.lng,
      tags: tags,
      wikidataIds: wikidata,
      wikipediaRefs: wikipedia,
      researchDone: done,
    );

void main() {
  group('Reading references to photos', () {
    test('Commons file names from map tags and links', () {
      expect(PlacePhotoService.commonsFileName('File:Lviv_tower.jpg'), 'Lviv tower.jpg');
      expect(PlacePhotoService.commonsFileName('Lviv tower.jpg'), 'Lviv tower.jpg');
      expect(PlacePhotoService.commonsFileName('https://commons.wikimedia.org/wiki/File:Lviv_tower.jpg'),
          'Lviv tower.jpg');
      expect(
          PlacePhotoService.commonsFileName(
              'https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Lviv_tower.jpg/800px-Lviv_tower.jpg'),
          'Lviv tower.jpg');
      expect(PlacePhotoService.commonsFileName('https://upload.wikimedia.org/wikipedia/commons/a/ab/Lviv_tower.jpg'),
          'Lviv tower.jpg');
      expect(PlacePhotoService.commonsFileName('Category:Stryiskyi Park'), isNull);
      expect(PlacePhotoService.commonsFileName('https://example.com/photo.jpg'), isNull,
          reason: 'photos from other websites have no known licence');
      expect(PlacePhotoService.commonsFileName(''), isNull);
    });

    test('Wikipedia article references', () {
      expect(PlacePhotoService.wikipediaArticle('https://uk.wikipedia.org/wiki/%D0%92%D0%B5%D0%B6%D0%B0'),
          ('uk', 'Вежа'));
      expect(PlacePhotoService.wikipediaArticle('en:Stryi_Park'), ('en', 'Stryi Park'));
      expect(PlacePhotoService.wikipediaArticle('Стрийський парк'), ('uk', 'Стрийський парк'));
      expect(PlacePhotoService.wikipediaArticle('https://example.com/wiki/X'), isNull);
    });

    test('author and licence texts are plain text', () {
      expect(PlacePhotoService.plainText('<a href="//commons.wikimedia.org/wiki/User:X">Ivan&nbsp;Petrenko</a>'),
          'Ivan Petrenko');
    });
  });

  group('Finding a photo', () {
    test('the photo linked on the map comes first', () async {
      final wiki = _Wiki()
        ..files['Map tag photo.jpg'] = ('image/jpeg', 'Olena', 'CC BY 4.0')
        ..p18['Q1'] = 'Wikidata photo.jpg'
        ..files['Wikidata photo.jpg'] = ('image/jpeg', null, null);
      final s = PlacePhotoService(client: wiki.client);
      final p = await s.find(_q(tags: {'wikimedia_commons': 'File:Map_tag_photo.jpg'}, wikidata: ['Q1']));
      expect(p?.source, PhotoSource.map);
      expect(p?.url, 'https://upload.wikimedia.org/thumb/1080px-Map tag photo.jpg');
      expect(p?.author, 'Olena');
      expect(p?.license, 'CC BY 4.0');
      expect(wiki.requests.where((u) => u.host == 'www.wikidata.org'), isEmpty);
    });

    test('Wikidata main image, with its author and licence', () async {
      final wiki = _Wiki()
        ..p18['Q42'] = 'Vodonapirna vezha.jpg'
        ..files['Vodonapirna vezha.jpg'] = ('image/jpeg', '<a href="x">Ivan Petrenko</a>', 'CC BY-SA 4.0');
      final s = PlacePhotoService(client: wiki.client);
      final p = await s.find(_q(wikidata: ['https://www.wikidata.org/wiki/Q42']));
      expect(p?.source, PhotoSource.wikidata);
      expect(p?.author, 'Ivan Petrenko');
      expect(p?.license, 'CC BY-SA 4.0');
      expect(p?.pageUrl, 'https://commons.wikimedia.org/wiki/File:Vodonapirna vezha.jpg');
      expect(s.cached('tower')?.url, p?.url);
    });

    test('the Wikipedia article image when Wikidata has none', () async {
      final wiki = _Wiki()
        ..pageImages['uk:Водонапірна вежа (Львів)'] = 'Vezha.jpg'
        ..files['Vezha.jpg'] = ('image/jpeg', null, 'CC BY-SA 3.0');
      final s = PlacePhotoService(client: wiki.client);
      final p = await s.find(_q(
          wikidata: ['Q7'], wikipedia: ['https://uk.wikipedia.org/wiki/Водонапірна_вежа_(Львів)']));
      expect(p?.source, PhotoSource.wikipedia);
      expect(p?.author, isNull);
    });

    test('drawings and files missing from Commons are not used', () async {
      final wiki = _Wiki()
        ..p18['Q1'] = 'Scheme.svg'
        ..files['Scheme.svg'] = ('image/svg+xml', null, null)
        ..pageImages['uk:Вежа'] = 'Local non-free.jpg'; // not on Commons
      final s = PlacePhotoService(client: wiki.client);
      expect(await s.find(_q(wikidata: ['Q1'], wikipedia: ['uk:Вежа'])), isNull);
    });

    test('photos taken nearby: only after research, and the matching one first', () async {
      final wiki = _Wiki()
        ..nearby.addAll([
          ('Lviv map 1900.jpg', 3), // a map, never
          ('IMG_0042.jpg', 60), // too far for an unnamed photo
          ('Vodonapirna vezha u Stryiskomu parku.jpg', 90), // the place's name
        ])
        ..files['Vodonapirna vezha u Stryiskomu parku.jpg'] = ('image/jpeg', 'Taras', 'CC0')
        ..files['IMG_0042.jpg'] = ('image/jpeg', null, null)
        ..files['Lviv map 1900.jpg'] = ('image/jpeg', null, null);
      final s = PlacePhotoService(client: wiki.client);

      expect(await s.find(_q()), isNull, reason: 'research still running: a better photo may come');
      expect(wiki.requests.where((u) => u.queryParameters['list'] == 'geosearch'), isEmpty);

      final p = await s.find(_q(done: true));
      expect(p?.source, PhotoSource.nearby);
      expect(p?.author, 'Taras');
    });

    test('a close unnamed photo is used when nothing matches the name', () async {
      final wiki = _Wiki()
        ..nearby.add(('IMG_0042.jpg', 12))
        ..files['IMG_0042.jpg'] = ('image/jpeg', null, null);
      final s = PlacePhotoService(client: wiki.client);
      expect((await s.find(_q(done: true)))?.source, PhotoSource.nearby);
    });

    test('the same question is asked once; a failed connection is tried again', () async {
      final wiki = _Wiki()
        ..p18['Q42'] = 'Vezha.jpg'
        ..files['Vezha.jpg'] = ('image/jpeg', null, null)
        ..offline = true;
      var now = DateTime(2026, 11, 24, 12);
      final s = PlacePhotoService(client: wiki.client, clock: () => now);
      final q = _q(wikidata: ['Q42']);

      expect(await s.find(q), isNull);
      final afterFailure = wiki.requests.length;

      wiki.offline = false;
      await s.find(q);
      expect(wiki.requests.length, afterFailure, reason: 'no hammering while offline');

      now = now.add(PlacePhotoService.retryAfter);
      expect((await s.find(q))?.source, PhotoSource.wikidata);
      expect(wiki.requests.length, greaterThan(afterFailure));

      final asked = wiki.requests.length;
      await s.find(q);
      await s.find(q);
      expect(wiki.requests.length, asked, reason: 'answered from memory');
    });
  });
}
