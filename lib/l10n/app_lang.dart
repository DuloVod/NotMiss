/// Languages of the app: interface, stories, AI answers and voice all follow the selected one.
enum AppLang {
  uk('uk', 'Українська'),
  en('en', 'English');

  final String code;

  /// Name in its own language (shown in the language picker).
  final String nativeName;

  const AppLang(this.code, this.nativeName);

  static AppLang? fromCode(String? code) {
    for (final l in values) {
      if (l.code == code) return l;
    }
    return null;
  }

  /// First launch: the phone's language. Ukrainian and the languages Ukrainians commonly set
  /// their phones to (Russian, Belarusian) get the Ukrainian app; everybody else gets English.
  static AppLang fromDevice(String? languageCode) {
    switch ((languageCode ?? '').toLowerCase()) {
      case 'uk':
      case 'ru':
      case 'be':
        return AppLang.uk;
      default:
        return AppLang.en;
    }
  }
}

/// The current language and the two-language string helper.
///
/// Read directly (not passed around): the app has one active language at a time, and content
/// produced for another language is recognised by its own `contentLang` and not shown.
class L {
  L._();

  static AppLang lang = AppLang.uk;

  static bool get en => lang == AppLang.en;
  static bool get uk => lang == AppLang.uk;

  /// `L.t('Привіт', 'Hello')`
  static String t(String uk, String en) => lang == AppLang.en ? en : uk;

  /// "85 m" / "1.2 km" and "85 м" / "1,2 км".
  static String distance(double meters) {
    if (meters >= 1000) {
      final km = (meters / 1000).toStringAsFixed(1);
      return en ? '$km km' : '${km.replaceAll('.', ',')} км';
    }
    final rounded = meters < 100 ? (meters / 5).round() * 5 : (meters / 10).round() * 10;
    return en ? '$rounded m' : '$rounded м';
  }
}
