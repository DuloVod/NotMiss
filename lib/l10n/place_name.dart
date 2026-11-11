import '../models/poi.dart';
import 'app_lang.dart';

/// Names of places in the language of the user.
///
/// Place names come from the map in Ukrainian. An English user gets the English name when the
/// map has one (`name:en`); otherwise a Latin transliteration (the national 2010 system, which
/// is what street signs in Ukraine use), so that nobody has to read Cyrillic.
class PlaceNames {
  PlaceNames._();

  static final _cyrillic = RegExp(r'[Ѐ-ӿ]');
  static final _latinLetter = RegExp(r'[A-Za-z]');

  static const _map = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'h', 'ґ': 'g', 'д': 'd', 'е': 'e', 'є': 'ie', 'ж': 'zh',
    'з': 'z', 'и': 'y', 'і': 'i', 'ї': 'i', 'й': 'i', 'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n',
    'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u', 'ф': 'f', 'х': 'kh', 'ц': 'ts',
    'ч': 'ch', 'ш': 'sh', 'щ': 'shch', 'ь': '', 'ю': 'iu', 'я': 'ia',
    // Russian letters sometimes appear in map names
    'ы': 'y', 'э': 'e', 'ё': 'e', 'ъ': '',
  };

  /// Word-initial forms that differ from the rest of the word.
  static const _initial = {'є': 'ye', 'ї': 'yi', 'й': 'y', 'ю': 'yu', 'я': 'ya'};

  /// "Бібліотека УКУ" → "Biblioteka UKU", "Єфремова" → "Yefremova", "Згорани" → "Zhorany"
  /// (the national system writes "зг" as "zgh").
  static String transliterate(String text) {
    final buffer = StringBuffer();
    final chars = text.split('');
    var wordStart = true;
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final lower = ch.toLowerCase();
      if (ch == '\'' || ch == 'ʼ' || ch == '’' || ch == '`') {
        // The apostrophe inside a word is dropped; a quote around a word is kept.
        if (!wordStart && i + 1 < chars.length && _cyrillic.hasMatch(chars[i + 1])) continue;
        buffer.write(ch);
        wordStart = true;
        continue;
      }
      if (!_cyrillic.hasMatch(ch)) {
        buffer.write(ch);
        wordStart = !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch);
        continue;
      }
      var out = (wordStart ? _initial[lower] : null) ?? _map[lower] ?? ch;
      if (lower == 'г' && i > 0 && chars[i - 1].toLowerCase() == 'з') out = 'gh';
      if (ch != lower && out.isNotEmpty) {
        // Capital letter: a capitalised first letter, or all capitals inside a capitalised word
        // ("УКУ" → "UKU", "Львів" → "Lviv").
        final next = i + 1 < chars.length ? chars[i + 1] : '';
        final prevUpper = i > 0 && chars[i - 1] != chars[i - 1].toLowerCase();
        final nextUpper = next.isNotEmpty && next != next.toLowerCase();
        out = (prevUpper || nextUpper) ? out.toUpperCase() : out[0].toUpperCase() + out.substring(1);
      }
      buffer.write(out);
      wordStart = false;
    }
    return buffer.toString();
  }

  /// The name to show for a place called [name] on the map with [tags].
  static String of(String name, Map<String, String>? tags) {
    if (L.uk) {
      final uk = tags?['name:uk'];
      return (uk != null && uk.trim().isNotEmpty) ? uk.trim() : name;
    }
    final en = tags?['name:en']?.trim();
    if (en != null && en.isNotEmpty) return en;
    final intl = tags?['int_name']?.trim();
    if (intl != null && intl.isNotEmpty && _latinLetter.hasMatch(intl) && !_cyrillic.hasMatch(intl)) {
      return intl;
    }
    return _cyrillic.hasMatch(name) ? transliterate(name) : name;
  }
}

extension PoiShownName on Poi {
  /// The name in the user's language (what the screen, the lock screen and the status say).
  String get shownName => PlaceNames.of(name, osmTags);
}
