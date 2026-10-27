import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
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
            cleanTitle = Uri.decodeComponent(uri.pathSegments.last);
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

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 15));

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
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final search = (json['query'] as Map<String, dynamic>?)?['search'] as List?;
      if (search == null || search.isEmpty) return null;

      // Extract query keywords (ignoring small punctuation and short words)
      final cleanQuery = query.toLowerCase().replaceAll(RegExp(r'[«»"“”.,()\[\]]'), ' ');
      final keywords = cleanQuery.split(' ').where((w) => w.length >= 4).toList();

      for (final item in search) {
        if (item is Map<String, dynamic>) {
          final t = (item['title'] as String?)?.toLowerCase() ?? '';
          if (keywords.any((kw) => t.contains(kw))) {
            return item['title'] as String?;
          }
        }
      }

      return (search[0] as Map<String, dynamic>)['title'] as String?;
    } catch (e) {
      debugPrint('[WikipediaService] Search error for $query: $e');
      return null;
    }
  }

  /// Tries multiple strategies to find and fetch a Wikipedia article for a POI:
  /// 1. Exact title lookup.
  /// 2. Sanitized title lookup (quotes/symbols removed).
  /// 3. Keyword search on Wikipedia API.
  Future<WikipediaArticle?> fetchSummaryOrSearch(String name, {String lang = 'uk'}) async {
    final direct = await fetchSummary(name, lang: lang);
    if (direct != null && direct.extract.isNotEmpty) return direct;

    // Try without quotes or special punctuation
    final stripped = name.replaceAll(RegExp(r'[«»"“”]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (stripped.isNotEmpty && stripped != name) {
      final sanitized = await fetchSummary(stripped, lang: lang);
      if (sanitized != null && sanitized.extract.isNotEmpty) return sanitized;
    }

    // Try search query
    final foundTitle = await searchArticle(name, lang: lang);
    if (foundTitle != null && foundTitle.isNotEmpty) {
      final result = await fetchSummary(foundTitle, lang: lang);
      if (result != null && result.extract.isNotEmpty) return result;
    }

    // If still not found and stripped query exists, try searching stripped
    if (stripped.isNotEmpty && stripped != name) {
      final foundStrippedTitle = await searchArticle(stripped, lang: lang);
      if (foundStrippedTitle != null && foundStrippedTitle.isNotEmpty) {
        final result = await fetchSummary(foundStrippedTitle, lang: lang);
        if (result != null && result.extract.isNotEmpty) return result;
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

  const WikipediaArticle({
    required this.title,
    required this.extract,
    this.description,
    required this.url,
    required this.lang,
    this.thumbnailUrl,
  });

  @override
  String toString() => 'WikipediaArticle($title, ${extract.length} chars)';
}
