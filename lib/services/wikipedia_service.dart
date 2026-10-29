import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Fetches article summaries and extracts from Wikipedia.
///
/// Uses the Wikipedia REST API (summary endpoint) which returns
/// a clean extract without needing to parse full HTML.
class WikipediaService {
  static const _userAgent = 'NotMiss/0.2.0 (walking tour guide app)';

  DateTime? _lastRequest;
  static const _minInterval = Duration(milliseconds: 300);

  /// Fetch a summary for a Wikipedia article.
  ///
  /// [title] is the article title (e.g. 'Стрийський_парк' or 'uk:Стрийський_парк').
  /// [lang] is the language code ('uk' or 'en').
  Future<WikipediaArticle?> fetchSummary(String title, {String lang = 'uk'}) async {
    await _rateLimit();
    try {
      var targetLang = lang;
      var cleanTitle = title.trim();

      // Handle full Wikipedia URLs like https://uk.wikipedia.org/wiki/Title
      if (cleanTitle.startsWith('http://') || cleanTitle.startsWith('https://')) {
        final uri = Uri.tryParse(cleanTitle);
        if (uri != null) {
          final hostParts = uri.host.split('.');
          if (hostParts.isNotEmpty && hostParts[0].length <= 3) {
            targetLang = hostParts[0];
          }
          if (uri.pathSegments.isNotEmpty) {
            try {
              cleanTitle = Uri.decodeComponent(uri.pathSegments.last);
            } catch (_) {
              cleanTitle = uri.pathSegments.last;
            }
          }
        }
      }

      // Handle language prefix if present, e.g. "uk:Title" or "en:Title"
      final prefixMatch = RegExp(r'^([a-z]{2,3}):(.+)$').firstMatch(cleanTitle);
      if (prefixMatch != null) {
        targetLang = prefixMatch.group(1)!;
        cleanTitle = prefixMatch.group(2)!.trim();
      }

      cleanTitle = cleanTitle.replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'_+'), '_');
      final encodedTitle = Uri.encodeComponent(cleanTitle);
      final url = 'https://$targetLang.wikipedia.org/api/rest_v1/page/summary/$encodedTitle';

      var response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 429) {
        // Polite single retry: Wikipedia rate limits are short-lived.
        await Future.delayed(const Duration(milliseconds: 1500));
        response = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': _userAgent},
        ).timeout(const Duration(seconds: 8));
      }

      if (response.statusCode == 404) {
        debugPrint('[WikipediaService] Article not found: $cleanTitle ($targetLang)');
        return null;
      }
      if (response.statusCode == 429) {
        debugPrint('[WikipediaService] Rate limited');
        return null;
      }
      if (response.statusCode != 200) {
        debugPrint('[WikipediaService] HTTP ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final type = json['type'] as String?;
      if (type == 'disambiguation' || type == 'no-extract') {
        debugPrint('[WikipediaService] Skipping $cleanTitle: type=$type');
        return null;
      }

      return WikipediaArticle(
        title: json['title'] as String? ?? cleanTitle,
        extract: json['extract'] as String? ?? '',
        description: json['description'] as String?,
        url: (json['content_urls'] as Map<String, dynamic>?)
                ?['desktop']?['page'] as String? ??
            'https://$targetLang.wikipedia.org/wiki/$encodedTitle',
        lang: targetLang,
        thumbnailUrl: (json['thumbnail'] as Map<String, dynamic>?)
                ?['source'] as String?,
        lat: ((json['coordinates'] as Map<String, dynamic>?)?['lat'] as num?)?.toDouble(),
        lon: ((json['coordinates'] as Map<String, dynamic>?)?['lon'] as num?)?.toDouble(),
      );
    } catch (e) {
      debugPrint('[WikipediaService] Error fetching $title: $e');
      return null;
    }
  }

  /// Search Wikipedia for an article title matching [query].
  Future<String?> searchArticle(String query, {String lang = 'uk'}) async {
    await _rateLimit();
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srsearch': query,
        'format': 'json',
        'srlimit': '3',
      });
      final response = await http.get(uri, headers: {
        'User-Agent': _userAgent,
      }).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final search = (json['query'] as Map<String, dynamic>?)?['search'] as List?;
      if (search == null || search.isEmpty) return null;

      // Extract query keywords (ignoring small punctuation and short words)

      for (final item in search) {
        if (item is Map<String, dynamic>) {
          final title = item['title'] as String? ?? '';
          if (titleMatchesName(title, query)) return title;
        }
      }

      // No result that actually shares a distinctive word with the name: better no article than
      // a wrong one ("Простір Львів" must never resolve to a random street).
      return null;
    } catch (e) {
      debugPrint('[WikipediaService] Search error for $query: $e');
      return null;
    }
  }

  /// Articles with coordinates near a point (Wikipedia GeoData). The most reliable way
  /// to find the article about a physical object when its OSM name differs from the
  /// article title. Returns titles ordered by distance.
  Future<List<String>> searchNearby(double lat, double lng,
      {String lang = 'uk', int radiusM = 200}) async {
    await _rateLimit();
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'geosearch',
        'gscoord': '$lat|$lng',
        'gsradius': '$radiusM',
        'gslimit': '10',
        'format': 'json',
      });
      final response = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final list = (json['query'] as Map<String, dynamic>?)?['geosearch'] as List?;
      if (list == null) return [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic> && item['title'] is String) item['title'] as String
      ];
    } catch (e) {
      debugPrint('[WikipediaService] Geosearch error: $e');
      return [];
    }
  }

  static final _wordSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Significant lowercase words of a name (≥4 letters), truncated to a 5-letter stem so
  /// that Ukrainian case endings ("Шевченка" / "Шевченку") still match.
  @visibleForTesting
  static Set<String> nameStems(String name) {
    return name
        .toLowerCase()
        .split(_wordSplit)
        .where((w) => w.length >= 4)
        .map((w) => w.length > 5 ? w.substring(0, 5) : w)
        .toSet();
  }

  /// Words that name a kind of object, not the object itself. "Музей Івана Франка" must not
  /// match "Музей Михайла Грушевського" just because both say "музей".
  static const _generic = {
    'музей', 'музею', 'пам\'ятник', 'памятник', 'пам\u2019ятник', 'пам\'ятка', 'церква', 'костел', 'собор',
    'вулиця', 'площа', 'парк', 'сквер', 'будинок', 'будівля', 'монастир', 'каплиця', 'фонтан',
    'меморіал', 'скульптура', 'статуя', 'хрест', 'готель', 'кафе', 'ресторан', 'школа',
    'університет', 'бібліотека', 'театр', 'стадіон', 'місто', 'львів', 'львові', 'львова',
    'museum', 'church', 'park', 'street', 'square', 'monument',
  };

  /// True when [title] shares the distinctive part of [name]. At least half of the
  /// distinctive words (generic ones like "музей"/"вулиця"/"Львів" are ignored) must appear;
  /// if the name has no distinctive word at all, any shared word counts.
  @visibleForTesting
  static bool titleMatchesName(String title, String name) {
    final t = nameStems(title);
    final n = nameStems(name);
    final genericStems = nameStems(_generic.join(' '));
    final distinctive = n.difference(genericStems);
    if (distinctive.isEmpty) return t.intersection(n).isNotEmpty;
    final hit = distinctive.intersection(t).length;
    return hit >= (distinctive.length / 2).ceil();
  }

  /// An article that has coordinates must be within [maxM] of the POI; articles
  /// without coordinates cannot be verified and are accepted.
  @visibleForTesting
  static bool isNear(WikipediaArticle a, double? lat, double? lng, {double maxM = 2000}) {
    if (lat == null || lng == null || a.lat == null || a.lon == null) return true;
    return Geolocator.distanceBetween(lat, lng, a.lat!, a.lon!) <= maxM;
  }

  /// Tries multiple strategies to find and fetch a Wikipedia article for a POI:
  /// 1. Exact title lookup.
  /// 2. Sanitized title lookup (quotes/symbols removed).
  /// 3. Wikipedia GeoData search around [lat]/[lng], matched by name.
  /// 4. Keyword search on Wikipedia API.
  ///
  /// When [lat]/[lng] are given, an article whose own coordinates are far from the POI
  /// is rejected, so "Ратуша" never resolves to a town hall in another city.
  Future<WikipediaArticle?> fetchSummaryOrSearch(String name,
      {String lang = 'uk', double? lat, double? lng}) async {
    bool ok(WikipediaArticle? a) => a != null && a.extract.isNotEmpty && isNear(a, lat, lng);
    // Articles found by free-text search are accepted only when Wikipedia confirms their
    // coordinates are near the POI ("Простір Львів" → "Простір імен" is a programming article
    // that has no coordinates). Without a POI position we cannot verify, so keep the old rule.
    bool okSearched(WikipediaArticle? a) =>
        ok(a) && (lat == null || lng == null || (a!.lat != null && a.lon != null));

    final direct = await fetchSummary(name, lang: lang);
    if (ok(direct)) return direct;

    // Try without quotes or special punctuation
    final stripped = name.replaceAll(RegExp(r'[«»"“”]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (stripped.isNotEmpty && stripped != name) {
      final sanitized = await fetchSummary(stripped, lang: lang);
      if (ok(sanitized)) return sanitized;
    }

    // Geo search: article about something standing at this very spot.
    if (lat != null && lng != null) {
      final nearby = await searchNearby(lat, lng, lang: lang);
      for (final title in nearby) {
        if (!titleMatchesName(title, name)) continue;
        final result = await fetchSummary(title, lang: lang);
        if (ok(result)) return result;
      }
    }

    // Try search query
    final foundTitle = await searchArticle(name, lang: lang);
    if (foundTitle != null && foundTitle.isNotEmpty) {
      final result = await fetchSummary(foundTitle, lang: lang);
      if (okSearched(result)) return result;
    }

    // If still not found and stripped query exists, try searching stripped
    if (stripped.isNotEmpty && stripped != name) {
      final foundStrippedTitle = await searchArticle(stripped, lang: lang);
      if (foundStrippedTitle != null && foundStrippedTitle.isNotEmpty) {
        final result = await fetchSummary(foundStrippedTitle, lang: lang);
        if (okSearched(result)) return result;
      }
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

/// A Wikipedia article summary.
class WikipediaArticle {
  final String title;
  final String extract;
  final String? description;
  final String url;
  final String lang;
  final String? thumbnailUrl;
  final double? lat;
  final double? lon;

  const WikipediaArticle({
    required this.title,
    required this.extract,
    this.description,
    required this.url,
    required this.lang,
    this.thumbnailUrl,
    this.lat,
    this.lon,
  });

  @override
  String toString() => 'WikipediaArticle($title, ${extract.length} chars)';
}
