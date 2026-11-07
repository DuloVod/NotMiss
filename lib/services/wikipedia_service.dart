import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Fetches article summaries and extracts from Wikipedia.
///
/// Uses the Wikipedia REST API (summary endpoint) which returns
/// a clean extract without needing to parse full HTML.
class WikipediaService {
  static const _userAgent = 'NotMiss/1.1 (https://github.com/DuloVod/NotMiss; walking tour guide app)';

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

      final response = await _get(Uri.parse(url));

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
        extract: _noAccents(json['extract'] as String? ?? ''),
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
  Future<String?> searchArticle(String query, {String lang = 'uk', String? matchName}) async {
    await _rateLimit();
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srsearch': query,
        'format': 'json',
        'srlimit': '3',
      });
      final response = await _get(uri);

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final search = (json['query'] as Map<String, dynamic>?)?['search'] as List?;
      if (search == null || search.isEmpty) return null;

      // Extract query keywords (ignoring small punctuation and short words)

      for (final item in search) {
        if (item is Map<String, dynamic>) {
          final title = item['title'] as String? ?? '';
          if (titleMatchesName(title, matchName ?? query)) return title;
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
      final response = await _get(uri);
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

  /// Title without the parenthetical disambiguator: "Сонячна (зупинний пункт)" → "Сонячна".
  static String _bareTitle(String title) => title.replaceAll(RegExp(r'\([^)]*\)'), ' ');

  /// Both ways: all distinctive words of the name are in the title AND the title has no extra
  /// distinctive words. "Сонячна енергія" is not about a place called "Сонячна".
  @visibleForTesting
  static bool titleMatchesStrictly(String title, String name) {
    final genericStems = nameStems(_generic.join(' '));
    final t = nameStems(_bareTitle(title)).difference(genericStems);
    final n = nameStems(name).difference(genericStems);
    if (n.isEmpty || t.isEmpty) return false;
    return t.containsAll(n) && n.containsAll(t);
  }

  /// Words in a title that say what kind of object an article is about.
  static const _kindWords = {
    'вулиця', 'площа', 'провулок', 'проспект', 'бульвар', 'парк', 'сквер', 'музей', 'театр',
    'церква', 'костел', 'собор', 'монастир', 'каплиця', 'синагога', 'пам\'ятник', 'меморіал',
    'скульптура', 'статуя', 'фонтан', 'будинок', 'будівля', 'палац', 'замок', 'вежа', 'готель',
    'школа', 'університет', 'бібліотека', 'стадіон', 'станція', 'вокзал', 'кладовище', 'озеро',
  };

  /// Same name, different thing: the railway stop «Сонячна» is not «Вулиця Сонячна». A title
  /// that names a kind absent from the POI's name must name the POI's own kind ([allowedKinds]).
  @visibleForTesting
  static bool kindIsCompatible(String title, String name, List<String> allowedKinds) {
    final kinds = nameStems(_kindWords.join(' '));
    final inTitle = nameStems(_bareTitle(title)).intersection(kinds);
    final extra = inTitle.difference(nameStems(name));
    return extra.isEmpty || extra.difference(nameStems(allowedKinds.join(' '))).isEmpty;
  }

  /// Does [text] mention the city? Compared by a 3-letter prefix so that case endings match
  /// ("Львів" / "Львові" / "Львова").
  @visibleForTesting
  static bool mentionsCity(String text, String city) {
    final c = city.trim().toLowerCase();
    if (c.length < 3) return false;
    final prefix = c.substring(0, 3);
    return text.toLowerCase().split(_wordSplit).any((w) => w.startsWith(prefix));
  }

  /// Is this article really about the physical object at [lat]/[lng]? A wrong article is worse
  /// than none: its text would be told to the user as the truth about this place.
  ///
  /// - Article with coordinates: must be within [_maxArticleDistanceM].
  /// - Article without coordinates: the title must match the name both ways and the text must
  ///   mention the city ("Сонячна енергія", the animal "Лама" and the tank "Т-64" are rejected).
  /// - Without a position nothing can be checked and the title rule alone applies.
  @visibleForTesting
  static bool isAboutPlace(WikipediaArticle a, String name,
      {double? lat, double? lng, String? city, List<String>? kindWords}) {
    if (kindWords != null && !kindIsCompatible(a.title, name, kindWords)) return false;
    if (lat != null && lng != null && a.lat != null && a.lon != null) {
      return Geolocator.distanceBetween(lat, lng, a.lat!, a.lon!) <= _maxArticleDistanceM;
    }
    if (!titleMatchesStrictly(a.title, name)) return false;
    if (lat == null || lng == null) return true;
    return city != null && mentionsCity(a.extract, city);
  }

  static const double _maxArticleDistanceM = 1500;

  /// Full plain text of an article without its reference sections (the summary endpoint only
  /// gives the first paragraph). Null when unavailable: callers keep the summary.
  Future<String?> fetchFullText(String title, {String lang = 'uk', int maxChars = 6000}) async {
    await _rateLimit();
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'prop': 'extracts',
        'explaintext': '1',
        'exsectionformat': 'wiki',
        'redirects': '1',
        'titles': title,
        'format': 'json',
      });
      final response = await _get(uri);
      if (response.statusCode != 200) return null;
      final pages = ((jsonDecode(response.body) as Map<String, dynamic>)['query']
          as Map<String, dynamic>?)?['pages'] as Map<String, dynamic>?;
      if (pages == null || pages.isEmpty) return null;
      final extract = (pages.values.first as Map<String, dynamic>)['extract'] as String?;
      if (extract == null || extract.trim().isEmpty) return null;
      return _noAccents(cleanArticleText(extract, maxChars: maxChars));
    } catch (e) {
      debugPrint('[WikipediaService] Full text error for $title: $e');
      return null;
    }
  }

  static final _referenceHeading = RegExp(
    r'^=+\s*(Примітки|Джерела|Посилання|Література|Див\.?\s*також|Галерея|Виноски|References|Notes|See also|External links|Further reading|Bibliography|Gallery|Przypisy|Bibliografia|Linki zewnętrzne|Zobacz też|Einzelnachweise|Literatur|Weblinks|Siehe auch)\s*=+\s*$',
    caseSensitive: false,
    multiLine: true,
  );

  /// Drops reference sections and heading markers, then limits the size.
  @visibleForTesting
  static String cleanArticleText(String raw, {int maxChars = 6000}) {
    final cut = _referenceHeading.firstMatch(raw);
    var t = cut == null ? raw : raw.substring(0, cut.start);
    t = t.replaceAllMapped(RegExp(r'^=+\s*(.*?)\s*=+\s*$', multiLine: true), (m) => '${m[1]}:');
    t = t.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
    return t.length <= maxChars ? t : t.substring(0, maxChars);
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
      {String lang = 'uk', double? lat, double? lng, String? city, List<String>? kindWords}) async {
    bool ok(WikipediaArticle? a) =>
        a != null &&
        a.extract.isNotEmpty &&
        isAboutPlace(a, name, lat: lat, lng: lng, city: city, kindWords: kindWords);
    bool okSearched(WikipediaArticle? a) => ok(a);

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

    // Search together with the city: "Сонячна Львів" finds the railway stop, not solar energy.
    if (city != null && city.isNotEmpty) {
      final withCity = await searchArticle('$stripped $city', lang: lang, matchName: name);
      if (withCity != null && withCity.isNotEmpty) {
        final result = await fetchSummary(withCity, lang: lang);
        if (okSearched(result)) return result;
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

  /// A name specific enough to look for in other articles. "Сонячна" or "Лама" could mean
  /// anything; "Соколу-Батьку" or "Дерево закоханих" can only mean this object.
  @visibleForTesting
  static bool isDistinctiveName(String name) {
    final clean = name.replaceAll(RegExp(r'[«»"“”]'), ' ').trim();
    if (clean.length < 8) return false;
    final words = clean.split(RegExp(r'\s+'));
    if (words.length < 2 && !clean.contains('-')) return false;
    return nameStems(clean).difference(nameStems(_generic.join(' '))).isNotEmpty;
  }

  /// Sentences of [text] that mention [name], allowing for case endings.
  @visibleForTesting
  static List<String> sentencesMentioning(String text, String name, {int limit = 4}) {
    final words = name
        .replaceAll(RegExp(r'[«»"“”]'), ' ')
        .trim()
        .split(RegExp(r'[\s-]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => RegExp.escape(w.length > 4 ? w.substring(0, w.length - 2) : w));
    final pattern = RegExp('${words.join(r'\p{L}*[\s-]+')}\\p{L}*', caseSensitive: false, unicode: true);
    return text
        .split(RegExp(r'(?<=[.!?…])\s+|\n+'))
        .map((s) => s.trim())
        .where((s) => s.length >= 25 && s.length <= 400 && pattern.hasMatch(s))
        .take(limit)
        .toList();
  }

  /// For a place without an article of its own: what articles about its surroundings say about
  /// it ("Стрийський парк" describes the monument «Соколу-Батьку»). The article must be located
  /// nearby, and only sentences that name the place are taken.
  Future<WikipediaMention?> findMention(String name,
      {required double lat, required double lng, String? city, String lang = 'uk'}) async {
    if (!isDistinctiveName(name)) return null;
    final clean = name.replaceAll(RegExp(r'[«»"“”]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final titles = <String>{
      ...(await searchNearby(lat, lng, lang: lang, radiusM: 1000)).take(3),
    };
    await _rateLimit();
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        // Not an exact phrase: other articles use other case endings ("Сокола-Батька").
        'srsearch': '$clean${city != null ? ' $city' : ''}',
        'format': 'json',
        'srlimit': '3',
      });
      final response = await _get(uri);
      if (response.statusCode == 200) {
        final found = ((jsonDecode(response.body) as Map<String, dynamic>)['query'] as Map<String, dynamic>?)?['search'] as List?;
        for (final item in found ?? const []) {
          final title = (item as Map<String, dynamic>)['title'];
          if (title is String) titles.add(title);
        }
      }
    } catch (e) {
      debugPrint('[WikipediaService] Mention search error: $e');
    }

    for (final title in titles.take(5)) {
      final article = await fetchSummary(title, lang: lang);
      if (article == null || article.lat == null || article.lon == null) continue;
      if (Geolocator.distanceBetween(lat, lng, article.lat!, article.lon!) > _maxMentionDistanceM) continue;
      final text = await fetchFullText(article.title, lang: lang, maxChars: 40000);
      if (text == null) continue;
      final sentences = sentencesMentioning(text, clean);
      if (sentences.isNotEmpty) {
        return WikipediaMention(articleTitle: article.title, url: article.url, sentences: sentences);
      }
    }
    return null;
  }

  static const double _maxMentionDistanceM = 2500;

  /// GET with one polite retry: Wikipedia's rate limits and hiccups are short-lived, and a lost
  /// response here means a poorer story for the place.
  Future<http.Response> _get(Uri uri) async {
    Future<http.Response> once() =>
        http.get(uri, headers: {'User-Agent': _userAgent}).timeout(const Duration(seconds: 8));
    try {
      final response = await once();
      if (response.statusCode != 429 && response.statusCode < 500) return response;
    } on TimeoutException {
      // Falls through to the retry.
    }
    await Future.delayed(const Duration(milliseconds: 1500));
    return once();
  }

  /// Stress marks of encyclopedia headwords ("Капли́ця") only get in the way of reading.
  static String _noAccents(String text) => text.replaceAll('\u0301', '');

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

/// Sentences about a place from an article on something nearby.
class WikipediaMention {
  final String articleTitle;
  final String url;
  final List<String> sentences;

  const WikipediaMention({required this.articleTitle, required this.url, required this.sentences});
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
