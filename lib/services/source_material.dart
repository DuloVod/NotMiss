import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// One verifiable piece of knowledge about a place, with where it came from.
class SourceDoc {
  /// "osm", "wikidata", "wikipedia", "official".
  final String type;
  final String title;
  final String url;
  final String text;

  const SourceDoc({required this.type, required this.title, required this.url, required this.text});
}

/// Everything known about a place from real sources. It is the ONLY basis for what the guide
/// says: the AI may retell it, never add to it.
class SourceMaterial {
  final List<SourceDoc> docs;

  const SourceMaterial(this.docs);

  /// Upper bound of what is sent to the model (size of the request, not of the knowledge).
  static const int maxChars = 9000;

  /// Sends the most useful text first and within [maxChars].
  String get promptText {
    final buffer = StringBuffer();
    for (final d in docs) {
      if (d.text.trim().isEmpty) continue;
      final left = maxChars - buffer.length;
      if (left < 80) break;
      final text = d.text.trim();
      buffer.writeln('[${d.title}]');
      buffer.writeln(text.length <= left ? text : text.substring(0, left));
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  bool get isEmpty => docs.every((d) => d.text.trim().isEmpty);
  bool get isNotEmpty => !isEmpty;
}

/// Facts that are stated directly in OpenStreetMap tags.
class OsmFacts {
  OsmFacts._();

  static const _denominations = {
    'greek_catholic': 'греко-католицька',
    'ukrainian_greek_catholic': 'греко-католицька',
    'roman_catholic': 'римо-католицька',
    'catholic': 'католицька',
    'orthodox': 'православна',
    'ukrainian_orthodox': 'православна',
    'armenian_apostolic': 'вірменська апостольська',
    'lutheran': 'лютеранська',
  };

  static const _religions = {
    'christian': 'християнство',
    'jewish': 'юдаїзм',
    'muslim': 'іслам',
  };

  static const _styles = {
    'baroque': 'бароко',
    'gothic': 'готика',
    'renaissance': 'ренесанс',
    'neoclassicism': 'класицизм',
    'classicism': 'класицизм',
    'art_nouveau': 'сецесія',
    'secession': 'сецесія',
    'neo-renaissance': 'неоренесанс',
    'neo-baroque': 'необароко',
    'neo-gothic': 'неоготика',
    'functionalism': 'функціоналізм',
    'modern': 'модернізм',
  };

  /// Year or date from an OSM value: "1898", "1898-05", "C19" stays out (not a precise value).
  static String? _date(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^\D{0,3}(\d{3,4})').firstMatch(v.trim());
    return m?.group(1);
  }

  static String? _first(Map<String, String> t, List<String> keys) {
    for (final k in keys) {
      final v = t[k]?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Statements about the place itself (history, authors, description).
  ///
  /// [withDates] is false when an encyclopedia also covers the place: map dates are often
  /// wrong or about something else (the Boim Chapel is tagged 1360, it was built in 1609–1615).
  static List<String> from(Map<String, String> t, {bool withDates = true}) {
    final out = <String>[];
    // A couple of words ("пам'ятний знак") only repeat the kind of object: nothing to tell.
    final description = _first(t, ['description:uk', 'description']);
    if (description != null && description.length >= 30) out.add(description);
    final year = withDates ? (_date(t['start_date']) ?? _date(t['construction_date'])) : null;
    if (year != null) out.add('Рік створення: $year.');
    final architect = _first(t, ['architect:uk', 'architect']);
    if (architect != null) out.add('Архітектор: $architect.');
    final artist = _first(t, ['artist_name:uk', 'artist_name', 'sculptor', 'artist']);
    if (artist != null) out.add('Автор: $artist.');
    final inscription = _first(t, ['inscription:uk', 'inscription']);
    if (inscription != null) out.add('Напис: «$inscription».');
    final oldName = _first(t, ['old_name:uk', 'old_name']);
    if (oldName != null) out.add('Колишня назва: $oldName.');
    final official = _first(t, ['official_name:uk', 'official_name']);
    if (official != null && official != t['name']) out.add('Офіційна назва: $official.');
    final denomination = _denominations[t['denomination']];
    if (denomination != null) {
      out.add('Конфесія: $denomination.');
    } else {
      final religion = _religions[t['religion']];
      if (religion != null) out.add('Релігія: $religion.');
    }
    final style = _styles[t['building:architecture'] ?? t['architecture']];
    if (style != null) out.add('Архітектурний стиль: $style.');
    final subject = _first(t, ['subject:uk', 'subject']);
    if (subject != null) out.add('Присвячено: $subject.');
    if (t.containsKey('heritage') && t['heritage'] != 'no') {
      final ref = _first(t, ['ref:heritage', 'heritage:ref', 'ref:UA:monument']);
      out.add(ref == null ? 'Має статус пам\'ятки.' : 'Має статус пам\'ятки (охоронний номер $ref).');
    }
    return out;
  }

  /// Practical details: good for answering questions, but not a story about the place.
  static List<String> practical(Map<String, String> t) {
    final out = <String>[];
    final street = t['addr:street'];
    if (street != null) {
      final number = t['addr:housenumber'];
      out.add('Адреса: $street${number != null ? ', $number' : ''}.');
    }
    final hours = t['opening_hours'];
    if (hours != null) out.add('Години роботи (формат OpenStreetMap): $hours.');
    final operator = t['operator'];
    if (operator != null) out.add('Належить або керує: $operator.');
    final website = websiteOf(t);
    if (website != null) out.add('Сайт: $website.');
    return out;
  }

  static String? websiteOf(Map<String, String> t) {
    final w = _first(t, ['website', 'contact:website', 'url']);
    if (w == null || !w.startsWith('http')) return null;
    return w;
  }
}

/// Reads the place's own website, when OpenStreetMap links to one. The link comes from the map
/// entry of this very object, so the identity of the page is not in doubt.
class OfficialSiteService {
  static const _skipHosts = ['facebook.com', 'instagram.com', 'twitter.com', 'x.com', 'tiktok.com', 'youtube.com', 't.me'];

  /// Short description + first paragraphs; null when unavailable or useless.
  Future<String?> fetchText(String url, {int maxChars = 2500}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    if (_skipHosts.any((h) => uri.host.endsWith(h))) return null;
    try {
      final response = await http
          .get(uri, headers: {'User-Agent': 'NotMiss/1.1 (https://github.com/DuloVod/NotMiss; walking tour guide app)'})
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final type = response.headers['content-type'] ?? '';
      if (type.isNotEmpty && !type.contains('html')) return null;
      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      final text = extractText(html, maxChars: maxChars);
      return text.length >= 60 ? text : null;
    } catch (e) {
      debugPrint('[OfficialSiteService] $url: $e');
      return null;
    }
  }

  static String _clean(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'&[a-zA-Z#0-9]+;'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String extractText(String html, {int maxChars = 2500}) {
    final body = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<(nav|header|footer)[\s\S]*?</\1>', caseSensitive: false), ' ');
    final parts = <String>[];
    final meta = RegExp(
      r'''<meta[^>]+(?:name|property)=["'](?:description|og:description)["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (meta != null) parts.add(_clean(meta.group(1)!));
    for (final m in RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false).allMatches(body)) {
      final t = _clean(m.group(1)!);
      if (t.length >= 50 && !parts.contains(t)) parts.add(t);
    }
    final joined = parts.join('\n');
    return joined.length <= maxChars ? joined : joined.substring(0, maxChars);
  }
}
