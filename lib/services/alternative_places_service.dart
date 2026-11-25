import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../models/poi.dart';

/// A second way to find places when OpenStreetMap's Overpass servers do not answer: the
/// Wikipedia "articles near here" search (geosearch). It needs no key, is run by a different
/// organisation on different servers, and what it finds are exactly the places that have
/// something to tell: every one has an article, and most have a Wikidata item.
///
/// Only the position of the search is sent (no identifier), as with Overpass.
class AlternativePlacesService {
  AlternativePlacesService({this.languages = const ['uk', 'en'], this.radiusM = 1000, this.limit = 50});

  /// Wikipedia editions to ask, the user's own first (their names come first).
  final List<String> languages;
  final double radiusM;
  final int limit;

  static const _userAgent = 'NotMiss/1.1 (https://github.com/DuloVod/NotMiss; walking tour guide app)';

  /// Places around [lat], [lng], in the order of the [languages]; duplicates (the same Wikidata
  /// item in two languages) are kept once. An empty list when nothing is found or nothing answers.
  Future<List<Poi>> fetch(double lat, double lng, {List<String>? languages}) async {
    final langs = languages ?? this.languages;
    final results = await Future.wait([
      for (final l in langs) _fetchOne(lat, lng, l).catchError((Object e) {
        debugPrint('[AlternativePlaces] $l failed: $e');
        return <Poi>[];
      }),
    ]);
    final out = <Poi>[];
    final seen = <String>{};
    for (final list in results) {
      for (final p in list) {
        if (seen.add(p.wikidataId ?? p.id)) out.add(p);
      }
    }
    return out;
  }

  Future<List<Poi>> _fetchOne(double lat, double lng, String lang) async {
    final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'geosearch',
      'ggscoord': '$lat|$lng',
      'ggsradius': radiusM.round().toString(),
      'ggslimit': '$limit',
      'ggsnamespace': '0',
      'prop': 'coordinates|pageprops|description',
      'ppprop': 'wikibase_item',
      'format': 'json',
      'formatversion': '2',
    });
    final res = await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}', uri);
    return parse(res.body, lang);
  }

  /// Reads a geosearch answer into places, leaving out what is not a place one walks up to.
  static List<Poi> parse(String body, String lang) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return [];
      final query = json['query'];
      final pages = query is Map ? query['pages'] : null;
      if (pages is! List) return [];
      final out = <Poi>[];
      for (final raw in pages) {
        final page = raw as Map<String, dynamic>;
        final title = (page['title'] as String? ?? '').trim();
        final coords = page['coordinates'] as List?;
        final pageId = page['pageid'];
        if (title.isEmpty || coords == null || coords.isEmpty || pageId == null) continue;
        final c = coords.first as Map<String, dynamic>;
        final lat = (c['lat'] as num?)?.toDouble();
        final lon = (c['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        final description = (page['description'] as String? ?? '').trim();
        if (!isPlace(title, description)) continue;
        final wikidata = (page['pageprops'] as Map?)?['wikibase_item'] as String?;
        out.add(Poi(
          id: 'wiki_${wikidata ?? '$lang$pageId'}',
          name: cleanTitle(title),
          latitude: lat,
          longitude: lon,
          triggerRadius: 50,
          shortDescription: description,
          facts: const [],
          narrationText: '',
          sources: [PoiSource(title: 'Wikipedia', url: 'https://$lang.wikipedia.org/?curid=$pageId')],
          confidence: 'wikipedia',
          wikidataId: wikidata,
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// "Площа Ринок (Львів)" → "Площа Ринок": the bracket only tells articles apart.
  static String cleanTitle(String title) => title.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();

  static final RegExp _notPlaceTitle = RegExp(
    r'\(\s*\d{3,4}(\s*[–—-]\s*\d{0,4})?\s*\)|^(облога|битва|бій|взяття|повстання|список|історія|siege|battle|list|history)\b',
    caseSensitive: false,
    unicode: true,
  );

  /// Cities, villages, rivers and the like surround the user instead of being "arrived at".
  static final RegExp _notPlaceDescription = RegExp(
    r'(^|\s)(місто|селище|село|район|область|країна|річка|озеро|місцевість|адміністративн\w+ (одиниц|район|центр)|'
    r'city|town|village|district|oblast|country|river|lake|municipality|human settlement)(\s|$|,)',
    caseSensitive: false,
    unicode: true,
  );

  /// Events, lists and whole towns are not places to stand in front of.
  static bool isPlace(String title, String description) {
    if (_notPlaceTitle.hasMatch(title)) return false;
    if (description.isNotEmpty && _notPlaceDescription.hasMatch(description) && !_hasBuildingWord(description)) {
      return false;
    }
    return true;
  }

  static bool _hasBuildingWord(String d) => RegExp(
          r'будинок|будівля|церква|собор|площа|парк|музей|замок|вежа|пам.ятник|театр|бібліотек|building|church|cathedral|square|park|museum|castle|tower|monument|theatre|library',
          caseSensitive: false,
          unicode: true)
      .hasMatch(d);
}
