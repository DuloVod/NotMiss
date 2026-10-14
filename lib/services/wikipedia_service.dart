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
  /// [title] is the article title (e.g. 'Стрийський_парк').
  /// [lang] is the language code ('uk' or 'en').
  Future<WikipediaArticle?> fetchSummary(String title, {String lang = 'uk'}) async {
    await _rateLimit();
    try {
      final encodedTitle = Uri.encodeComponent(title.replaceAll(' ', '_'));
      final url = 'https://$lang.wikipedia.org/api/rest_v1/page/summary/$encodedTitle';

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 404) {
        debugPrint('[WikipediaService] Article not found: $title ($lang)');
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
        debugPrint('[WikipediaService] Skipping $title: type=$type');
        return null;
      }

      return WikipediaArticle(
        title: json['title'] as String? ?? title,
        extract: json['extract'] as String? ?? '',
        description: json['description'] as String?,
        url: (json['content_urls'] as Map<String, dynamic>?)
                ?['desktop']?['page'] as String? ??
            'https://$lang.wikipedia.org/wiki/$encodedTitle',
        lang: lang,
        thumbnailUrl: (json['thumbnail'] as Map<String, dynamic>?)
                ?['source'] as String?,
      );
    } catch (e) {
      debugPrint('[WikipediaService] Error fetching $title: $e');
      return null;
    }
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
