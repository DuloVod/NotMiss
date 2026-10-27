import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Fetches structured data about entities from Wikidata API.
///
/// Uses the wbgetentities endpoint for known IDs and
/// wbsearchentities for name-based lookup.
class WikidataService {
  static const _endpoint = 'https://www.wikidata.org/w/api.php';
  static const _userAgent = 'NotMiss/0.2.0 (walking tour guide app)';

  DateTime? _lastRequest;
  static const _minInterval = Duration(milliseconds: 500);

  /// Fetch entity data by Wikidata ID (e.g. Q12345).
  ///
  /// Returns a map with label, description, sitelinks, and claims,
  /// or null if not found or on error.
  Future<WikidataResult?> fetchById(String wikidataId) async {
    await _rateLimit();
    try {
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'action': 'wbgetentities',
        'ids': wikidataId,
        'props': 'labels|descriptions|sitelinks|claims',
        'languages': 'uk|en',
        'sitefilter': 'ukwiki|enwiki',
        'format': 'json',
      });

      final response = await http.get(uri, headers: {
        'User-Agent': _userAgent,
      }).timeout(const Duration(seconds: 15));

      if (response.statusCode == 429) {
        debugPrint('[WikidataService] Rate limited (429)');
        return null;
      }
      if (response.statusCode != 200) {
        debugPrint('[WikidataService] HTTP ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final entities = json['entities'] as Map<String, dynamic>?;
      if (entities == null) return null;

      // Handle entity redirects (e.g. {"redirects": [{"from": "Q123", "to": "Q456"}]})
      String targetId = wikidataId;
      final redirects = json['redirects'] as List<dynamic>?;
      if (redirects != null) {
        for (final r in redirects) {
          if (r is Map<String, dynamic> && r['from'] == wikidataId) {
            final to = r['to'] as String?;
            if (to != null) targetId = to;
            break;
          }
        }
      }

      if (!entities.containsKey(targetId)) return null;

      final entity = entities[targetId] as Map<String, dynamic>;
      if (entity.containsKey('missing')) return null;

      return await _parseEntity(wikidataId, entity);
    } catch (e) {
      debugPrint('[WikidataService] Error fetching $wikidataId: $e');
      return null;
    }
  }

  /// Batch fetch multiple Wikidata entities (max 50 per request).
  Future<Map<String, WikidataResult>> fetchBatch(List<String> ids) async {
    if (ids.isEmpty) return {};
    final results = <String, WikidataResult>{};

    // Wikidata allows up to 50 IDs per request
    for (var i = 0; i < ids.length; i += 50) {
      final batch = ids.sublist(i, (i + 50).clamp(0, ids.length));
      await _rateLimit();

      try {
        final uri = Uri.parse(_endpoint).replace(queryParameters: {
          'action': 'wbgetentities',
          'ids': batch.join('|'),
          'props': 'labels|descriptions|sitelinks|claims',
          'languages': 'uk|en',
          'sitefilter': 'ukwiki|enwiki',
          'format': 'json',
        });

        final response = await http.get(uri, headers: {
          'User-Agent': _userAgent,
        }).timeout(const Duration(seconds: 20));

        if (response.statusCode != 200) continue;

        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final entities = json['entities'] as Map<String, dynamic>? ?? {};

        // Build redirect mapping
        final redirectMap = <String, String>{};
        final redirects = json['redirects'] as List<dynamic>?;
        if (redirects != null) {
          for (final r in redirects) {
            if (r is Map<String, dynamic>) {
              final from = r['from'] as String?;
              final to = r['to'] as String?;
              if (from != null && to != null) {
                redirectMap[from] = to;
              }
            }
          }
        }

        for (final id in batch) {
          final targetId = redirectMap[id] ?? id;
          final entity = entities[targetId] as Map<String, dynamic>?;
          if (entity == null || entity.containsKey('missing')) continue;
          final result = await _parseEntity(id, entity);
          if (result != null) results[id] = result;
        }
      } catch (e) {
        debugPrint('[WikidataService] Batch error: $e');
      }
    }

    return results;
  }

  Future<WikidataResult?> _parseEntity(String id, Map<String, dynamic> entity) async {
    try {
      // Labels
      final labels = entity['labels'] as Map<String, dynamic>? ?? {};
      final labelUk = (labels['uk'] as Map<String, dynamic>?)?['value'] as String?;
      final labelEn = (labels['en'] as Map<String, dynamic>?)?['value'] as String?;

      // Descriptions
      final descriptions = entity['descriptions'] as Map<String, dynamic>? ?? {};
      final descUk = (descriptions['uk'] as Map<String, dynamic>?)?['value'] as String?;
      final descEn = (descriptions['en'] as Map<String, dynamic>?)?['value'] as String?;

      // Sitelinks (Wikipedia articles)
      final sitelinks = entity['sitelinks'] as Map<String, dynamic>? ?? {};
      final ukWiki = (sitelinks['ukwiki'] as Map<String, dynamic>?)?['title'] as String?;
      final enWiki = (sitelinks['enwiki'] as Map<String, dynamic>?)?['title'] as String?;

      // Extract key claims
      final claims = entity['claims'] as Map<String, dynamic>? ?? {};
      final rawInception = _getClaimStringValue(claims, 'P571'); // inception date
      String? inception = rawInception;
      if (rawInception != null) {
        // Format Wikidata timestamp e.g. "+1898-00-00T00:00:00Z" -> "1898 рік"
        final match = RegExp(r'^[+-]?(\d{3,4})').firstMatch(rawInception);
        if (match != null) {
          inception = '${match.group(1)} рік';
        }
      }
      final heritage = _getClaimStringValue(claims, 'P1435'); // heritage status

      // Resolve entity references (architect, creator) to human-readable labels
      final architectId = _getClaimStringValue(claims, 'P84');
      final creatorId = _getClaimStringValue(claims, 'P170');
      
      String? architect = architectId;
      String? creator = creatorId;
      
      // Resolve Q-IDs to labels via batch fetch
      final idsToResolve = <String>[
        if (architectId != null && architectId.startsWith('Q')) architectId,
        if (creatorId != null && creatorId.startsWith('Q')) creatorId,
      ];
      
      if (idsToResolve.isNotEmpty) {
        final resolved = await _resolveLabels(idsToResolve);
        if (architectId != null && resolved.containsKey(architectId)) {
          architect = resolved[architectId];
        }
        if (creatorId != null && resolved.containsKey(creatorId)) {
          creator = resolved[creatorId];
        }
      }

      return WikidataResult(
        wikidataId: id,
        labelUk: labelUk,
        labelEn: labelEn,
        descriptionUk: descUk,
        descriptionEn: descEn,
        wikipediaUk: ukWiki,
        wikipediaEn: enWiki,
        inception: inception,
        architect: architect,
        creator: creator,
        heritageStatus: heritage,
      );
    } catch (e) {
      debugPrint('[WikidataService] Parse error for $id: $e');
      return null;
    }
  }

  /// Resolve a list of Wikidata entity IDs to their labels.
  Future<Map<String, String>> _resolveLabels(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      await _rateLimit();
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'action': 'wbgetentities',
        'ids': ids.join('|'),
        'props': 'labels',
        'languages': 'uk|en',
        'format': 'json',
      });
      final response = await http.get(uri, headers: {
        'User-Agent': _userAgent,
      }).timeout(const Duration(seconds: 10));
      
      if (response.statusCode != 200) return {};
      
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final entities = json['entities'] as Map<String, dynamic>? ?? {};
      final result = <String, String>{};
      
      for (final id in ids) {
        final entity = entities[id] as Map<String, dynamic>?;
        if (entity == null) continue;
        final labels = entity['labels'] as Map<String, dynamic>? ?? {};
        final uk = (labels['uk'] as Map<String, dynamic>?)?['value'] as String?;
        final en = (labels['en'] as Map<String, dynamic>?)?['value'] as String?;
        final label = uk ?? en;
        if (label != null) result[id] = label;
      }
      
      return result;
    } catch (e) {
      debugPrint('[WikidataService] Failed to resolve labels: $e');
      return {};
    }
  }

  String? _getClaimStringValue(Map<String, dynamic> claims, String property) {
    final claim = claims[property] as List<dynamic>?;
    if (claim == null || claim.isEmpty) return null;
    final mainsnak = (claim[0] as Map<String, dynamic>)['mainsnak'] as Map<String, dynamic>?;
    if (mainsnak == null) return null;
    final datavalue = mainsnak['datavalue'] as Map<String, dynamic>?;
    if (datavalue == null) return null;
    final value = datavalue['value'];
    if (value is String) return value;
    if (value is Map<String, dynamic>) {
      // Time value
      if (value.containsKey('time')) return value['time'] as String?;
      // Entity value
      if (value.containsKey('id')) return value['id'] as String?;
    }
    return null;
  }

  Future<void>? _rateLimitQueue;

  Future<void> _rateLimit() {
    final next = (_rateLimitQueue ?? Future.value()).then((_) async {
      if (_lastRequest != null) {
        final elapsed = DateTime.now().difference(_lastRequest!);
        if (elapsed < _minInterval) {
          await Future.delayed(_minInterval - elapsed);
        }
      }
      _lastRequest = DateTime.now();
    });
    _rateLimitQueue = next;
    return next;
  }
}

/// Structured result from a Wikidata entity query.
class WikidataResult {
  final String wikidataId;
  final String? labelUk;
  final String? labelEn;
  final String? descriptionUk;
  final String? descriptionEn;
  final String? wikipediaUk;
  final String? wikipediaEn;
  final String? inception;
  final String? architect;
  final String? creator;
  final String? heritageStatus;

  const WikidataResult({
    required this.wikidataId,
    this.labelUk,
    this.labelEn,
    this.descriptionUk,
    this.descriptionEn,
    this.wikipediaUk,
    this.wikipediaEn,
    this.inception,
    this.architect,
    this.creator,
    this.heritageStatus,
  });

  /// Best available description.
  String? get description => descriptionUk ?? descriptionEn;

  /// Best available label.
  String? get label => labelUk ?? labelEn;

  /// Best available Wikipedia article title.
  String? get wikipediaTitle => wikipediaUk ?? wikipediaEn;

  /// Language code for the best available Wikipedia article.
  String? get wikipediaLang {
    if (wikipediaUk != null) return 'uk';
    if (wikipediaEn != null) return 'en';
    return null;
  }
}
