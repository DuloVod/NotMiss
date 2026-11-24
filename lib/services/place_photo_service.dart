import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Where a place photo was found.
enum PhotoSource {
  /// The map itself links the photo (OSM `wikimedia_commons` / `image` tag).
  map,

  /// The place's Wikidata entry (its main image, P18).
  wikidata,

  /// The main image of the place's Wikipedia article.
  wikipedia,

  /// A Wikimedia Commons photo taken right at the place.
  nearby,
}

/// A real photo of a place, always a freely licensed file on Wikimedia Commons.
class PlacePhoto {
  /// Image to show (a ~1080 px wide thumbnail).
  final String url;

  /// The file's page on Commons (author, licence, full size).
  final String pageUrl;

  /// Who took it (plain text), when Commons says.
  final String? author;

  /// Short licence name, e.g. "CC BY-SA 4.0".
  final String? license;

  final PhotoSource source;

  const PlacePhoto({
    required this.url,
    required this.pageUrl,
    required this.source,
    this.author,
    this.license,
  });
}

/// Everything known about a place that can lead to its photo.
class PhotoQuery {
  final String id;
  final String name;

  /// Other spellings of the name (English, transliterated) for matching file names.
  final List<String> altNames;
  final double lat;
  final double lng;
  final Map<String, String> tags;
  final List<String> wikidataIds;

  /// Wikipedia articles about the place: full URLs or "lang:Title".
  final List<String> wikipediaRefs;

  /// Research is finished: nothing better will turn up, so photos taken nearby may be tried.
  final bool researchDone;

  /// Interface language ('uk' / 'en') for author and licence texts.
  final String lang;

  const PhotoQuery({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.altNames = const [],
    this.tags = const {},
    this.wikidataIds = const [],
    this.wikipediaRefs = const [],
    this.researchDone = false,
    this.lang = 'uk',
  });

  /// Same inputs → same answer; a changed input (research found an article) → a new look.
  String get signature => [
        id,
        tags['wikimedia_commons'] ?? '',
        tags['image'] ?? '',
        ...wikidataIds,
        ...wikipediaRefs,
        researchDone ? 'done' : '',
        lang,
      ].join('|');
}

/// Finds a real photo of a place from open sources, in this order:
/// 1. the photo the map links to; 2. the Wikidata main image; 3. the Wikipedia article image;
/// 4. a Commons photo taken right there (only once research has finished).
///
/// Only files on Wikimedia Commons are used: they are freely licensed and carry the author
/// and licence that the app shows under the photo.
class PlacePhotoService {
  static const userAgent = 'NotMiss/1.1 (https://github.com/DuloVod/NotMiss; walking tour guide app)';

  /// Headers for loading the images themselves (Wikimedia asks every client to name itself).
  static const imageHeaders = {'User-Agent': userAgent};

  /// Photos taken this close count as "at the place" when the file name matches the place.
  static const nameMatchRadius = 120;

  /// … and this close even without a matching name.
  static const anyPhotoRadius = 25;

  final http.Client _client;
  final Duration _timeout;
  final Map<String, Future<PlacePhoto?>> _bySignature = {};
  final Map<String, PlacePhoto> _byId = {};

  /// When a look-up last failed for lack of connection (tried again after [retryAfter]).
  final Map<String, DateTime> _failedAt = {};
  static const retryAfter = Duration(seconds: 30);

  PlacePhotoService({
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _timeout = timeout,
        _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// The photo already found for a place (shown at once, no flicker).
  PlacePhoto? cached(String id) => _byId[id];

  /// The photo of a place; the same query returns the same future, so a screen can ask on
  /// every rebuild.
  Future<PlacePhoto?> find(PhotoQuery q) {
    final known = _byId[q.id];
    // A photo the place's own records point to never gets replaced.
    if (known != null && known.source != PhotoSource.nearby) return Future.value(known);
    final failed = _failedAt[q.signature];
    if (failed != null && _clock().difference(failed) >= retryAfter) {
      _failedAt.remove(q.signature);
      _bySignature.remove(q.signature);
    }
    return _bySignature[q.signature] ??= _find(q);
  }

  Future<PlacePhoto?> _find(PhotoQuery q) async {
    var failed = false;
    Future<T?> attempt<T>(Future<T?> Function() step) async {
      try {
        return await step();
      } catch (_) {
        failed = true; // no connection: try again next time instead of remembering "no photo"
        return null;
      }
    }

    PlacePhoto? photo;

    // 1. The map links a photo.
    final commonsTag = q.tags['wikimedia_commons'];
    final fromTag = commonsFileName(commonsTag) ?? commonsFileName(q.tags['image']);
    if (fromTag != null) {
      photo = await attempt(() => fileInfo(fromTag, PhotoSource.map, q.lang));
    }

    // 2. Wikidata main image.
    for (final id in q.wikidataIds.toSet()) {
      if (photo != null) break;
      final file = await attempt(() => _wikidataImage(id));
      if (file != null) photo = await attempt(() => fileInfo(file, PhotoSource.wikidata, q.lang));
    }

    // 3. The Wikipedia article's own image (free images only).
    for (final ref in q.wikipediaRefs.toSet()) {
      if (photo != null) break;
      final file = await attempt(() => _articleImage(ref));
      if (file != null) photo = await attempt(() => fileInfo(file, PhotoSource.wikipedia, q.lang));
    }

    // 4. A photo taken right at the place.
    if (photo == null && q.researchDone) {
      photo = await attempt(() => _nearbyPhoto(q));
    }

    if (photo != null) {
      _byId[q.id] = photo;
    } else if (failed) {
      _failedAt[q.signature] = _clock();
    }
    return photo;
  }

  // ── Sources ────────────────────────────────────────────────────────────────────────────

  /// "File:X.jpg", "X.jpg", a commons.wikimedia.org/wiki/File:… page or an upload.wikimedia.org
  /// URL → "X.jpg". Anything else (a link to some other website) → null.
  static String? commonsFileName(String? value) {
    if (value == null) return null;
    var v = value.trim();
    if (v.isEmpty) return null;
    if (v.startsWith('http://') || v.startsWith('https://')) {
      final uri = Uri.tryParse(v);
      if (uri == null) return null;
      if (uri.host.endsWith('commons.wikimedia.org')) {
        final i = uri.path.indexOf('File:');
        if (i < 0) return null;
        v = Uri.decodeComponent(uri.path.substring(i + 5));
      } else if (uri.host == 'upload.wikimedia.org') {
        final segs = uri.pathSegments;
        if (segs.isEmpty) return null;
        // …/thumb/a/ab/Name.jpg/800px-Name.jpg → Name.jpg
        final ti = segs.indexOf('thumb');
        v = Uri.decodeComponent(ti >= 0 && segs.length > ti + 3 ? segs[ti + 3] : segs.last);
      } else {
        return null;
      }
    } else if (v.startsWith('Category:')) {
      return null;
    }
    v = v.replaceFirst(RegExp(r'^(File|Файл|Image):'), '').replaceAll('_', ' ').trim();
    return v.isEmpty ? null : v;
  }

  Future<String?> _wikidataImage(String id) async {
    final qid = RegExp(r'Q\d+').firstMatch(id)?.group(0);
    if (qid == null) return null;
    final json = await _getJson(Uri.https('www.wikidata.org', '/w/api.php', {
      'action': 'wbgetclaims',
      'format': 'json',
      'entity': qid,
      'property': 'P18',
    }));
    final claims = (json?['claims'] as Map?)?['P18'];
    if (claims is! List || claims.isEmpty) return null;
    // A "preferred" image first, otherwise the first one.
    claims.sort((a, b) => ((b as Map)['rank'] == 'preferred' ? 1 : 0)
        .compareTo((a as Map)['rank'] == 'preferred' ? 1 : 0));
    final value = ((claims.first as Map)['mainsnak'] as Map?)?['datavalue'] as Map?;
    final file = value?['value'];
    return file is String && file.isNotEmpty ? file : null;
  }

  Future<String?> _articleImage(String ref) async {
    final article = wikipediaArticle(ref);
    if (article == null) return null;
    final (lang, title) = article;
    final json = await _getJson(Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'prop': 'pageimages',
      'piprop': 'name',
      'pilicense': 'free',
      'redirects': '1',
      'titles': title,
    }));
    final page = _firstPage(json);
    final name = page?['pageimage'];
    return name is String && name.isNotEmpty ? name : null;
  }

  /// "https://uk.wikipedia.org/wiki/Title" or "uk:Title" or "Title" → (lang, "Title").
  static (String, String)? wikipediaArticle(String ref) {
    var lang = 'uk';
    var title = ref.trim();
    if (title.isEmpty) return null;
    if (title.startsWith('http://') || title.startsWith('https://')) {
      final uri = Uri.tryParse(title);
      if (uri == null || !uri.host.endsWith('wikipedia.org')) return null;
      final host = uri.host.split('.');
      if (host.length >= 3) lang = host.first == 'm' ? 'uk' : host.first;
      if (host.length >= 4 && host[1] == 'm') lang = host.first;
      final i = uri.path.indexOf('/wiki/');
      if (i < 0) return null;
      title = Uri.decodeComponent(uri.path.substring(i + 6));
    } else {
      final m = RegExp(r'^([a-z]{2,3}):(.+)$').firstMatch(title);
      if (m != null) {
        lang = m.group(1)!;
        title = m.group(2)!;
      }
    }
    title = title.replaceAll('_', ' ').trim();
    return title.isEmpty ? null : (lang, title);
  }

  Future<PlacePhoto?> _nearbyPhoto(PhotoQuery q) async {
    final json = await _getJson(Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'list': 'geosearch',
      'gscoord': '${q.lat}|${q.lng}',
      'gsradius': '$nameMatchRadius',
      'gsnamespace': '6',
      'gsprimary': 'all',
      'gslimit': '30',
    }));
    final list = (json?['query'] as Map?)?['geosearch'];
    if (list is! List) return null;

    final candidates = <(String, double)>[];
    for (final item in list) {
      if (item is! Map) continue;
      final title = item['title'];
      final dist = (item['dist'] as num?)?.toDouble();
      if (title is! String || dist == null) continue;
      final file = title.replaceFirst(RegExp(r'^File:'), '');
      if (!_looksLikePhoto(file)) continue;
      candidates.add((file, dist));
    }
    candidates.sort((a, b) => a.$2.compareTo(b.$2));

    final stems = nameStems([q.name, ...q.altNames]);
    final named = candidates.where((c) => fileMatchesName(c.$1, stems));
    final close = candidates.where((c) => c.$2 <= anyPhotoRadius);
    for (final (file, _) in [...named, ...close].take(4)) {
      final photo = await fileInfo(file, PhotoSource.nearby, q.lang);
      if (photo != null) return photo;
    }
    return null;
  }

  /// Distinctive pieces of a name for matching file names ("Водонапірна вежа" → "водон", "вежа").
  static List<String> nameStems(List<String> names) {
    const skip = {
      'вулиця', 'площа', 'парк', 'сквер', 'пам\'ятник', 'памятник', 'church', 'street', 'park',
      'square', 'monument', 'the', 'and', 'імені', 'святого', 'святої',
    };
    final out = <String>{};
    for (final n in names) {
      for (final w in n.toLowerCase().split(RegExp(r"[^\p{L}\p{N}']+", unicode: true))) {
        if (w.length < 4 || skip.contains(w)) continue;
        out.add(w.length > 6 ? w.substring(0, 6) : w);
      }
    }
    return out.toList();
  }

  static bool fileMatchesName(String file, List<String> stems) {
    if (stems.isEmpty) return false;
    final f = file.toLowerCase().replaceAll('_', ' ');
    return stems.any(f.contains);
  }

  /// Photos only: no maps, plans, coats of arms, logos, flags, documents or drawings.
  static bool _looksLikePhoto(String file) {
    final f = file.toLowerCase();
    if (!RegExp(r'\.(jpe?g|png|webp)$').hasMatch(f)) return false;
    return !RegExp(r'(\bmap\b|карта|\bplan\b|план |coat[ _]of[ _]arms|герб|herb |logo|логотип|flag|прапор|locator|location map|scheme|схема|diagram)')
        .hasMatch(f);
  }

  /// Thumbnail URL, page, author and licence of a Commons file; null when it is not a free photo.
  Future<PlacePhoto?> fileInfo(String file, PhotoSource source, String lang) async {
    final json = await _getJson(Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'prop': 'imageinfo',
      'titles': 'File:$file',
      'iiprop': 'url|mime|extmetadata',
      'iiurlwidth': '1080',
      'iiextmetadatafilter': 'Artist|LicenseShortName|ObjectName',
      'iiextmetadatalanguage': lang,
    }));
    final page = _firstPage(json);
    if (page == null || page['missing'] == true || page['missing'] == '') return null;
    final infos = page['imageinfo'];
    if (infos is! List || infos.isEmpty) return null;
    final info = infos.first as Map;
    final mime = info['mime'] as String? ?? '';
    if (!(mime == 'image/jpeg' || mime == 'image/png' || mime == 'image/webp')) return null;
    final url = (info['thumburl'] ?? info['url']) as String?;
    if (url == null || url.isEmpty) return null;
    final meta = info['extmetadata'] as Map? ?? const {};
    String? metaText(String key) {
      final v = (meta[key] as Map?)?['value'];
      if (v is! String) return null;
      final t = plainText(v);
      return t.isEmpty ? null : t;
    }

    var author = metaText('Artist');
    if (author != null && author.length > 60) author = '${author.substring(0, 57).trimRight()}…';
    return PlacePhoto(
      url: url,
      pageUrl: (info['descriptionurl'] as String?) ??
          'https://commons.wikimedia.org/wiki/File:${Uri.encodeComponent(file.replaceAll(' ', '_'))}',
      author: author,
      license: metaText('LicenseShortName'),
      source: source,
    );
  }

  /// HTML from Commons metadata → plain text.
  static String plainText(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ── HTTP ───────────────────────────────────────────────────────────────────────────────

  static Map? _firstPage(Map? json) {
    final pages = (json?['query'] as Map?)?['pages'];
    if (pages is List && pages.isNotEmpty) return pages.first as Map?;
    if (pages is Map && pages.isNotEmpty) return pages.values.first as Map?; // formatversion 1
    return null;
  }

  /// GET → JSON object. Null for "no such thing" answers; throws when the network fails, so
  /// the caller knows to try again later.
  Future<Map?> _getJson(Uri uri) async {
    final response = await _client.get(uri, headers: {
      'User-Agent': userAgent,
      'Api-User-Agent': userAgent,
    }).timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body is Map ? body : null;
  }

  /// Straight-line distance in metres (used by tests and for choosing nearby photos).
  static double distance(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }
}
