import 'package:flutter/material.dart';

/// NotMiss design system — colours, fonts and buttons from the approved
/// design canvas ("NotMiss — дизайн застосунку").
///
/// Every screen takes its colours from [NmColors] and its buttons from
/// [NmButtons], so a palette change only ever needs to happen here.
class NmColors {
  NmColors._();

  /// Near-black from the app icon: primary buttons, titles, unvisited markers.
  static const Color ink = Color(0xFF1B1A17);

  /// Cream from the app icon: secondary buttons, badges, soft panels.
  static const Color cream = Color(0xFFEFEBE0);

  /// Light cream screen background.
  static const Color background = Color(0xFFF7F5EF);

  /// Cards, sheets and chat surface.
  static const Color surface = Color(0xFFFFFFFF);

  /// Secondary text (addresses, hints, subtitles).
  static const Color muted = Color(0xFF5E5A52);

  /// Tertiary text / visited markers / placeholders.
  static const Color stone = Color(0xFF9A9282);

  /// Thin outlines on chips and the chat input field.
  static const Color line = Color(0xFFE4DFD3);

  /// Drag handles and other quiet shapes.
  static const Color sand = Color(0xFFD6D0C2);

  /// Destructive actions: "Завершити прогулянку", "Так, завершити".
  static const Color wine = Color(0xFF7A1E2E);

  /// Accent: active place on the map, "Гід розповідає" wave, fact bullets.
  static const Color ochre = Color(0xFFC99228);

  /// The user's own location dot on the map.
  static const Color userDot = Color(0xFF2F6FEB);

  /// Red half of the compass needle.
  static const Color compassRed = Color(0xFFD92D20);
}

/// Font families bundled in assets/fonts (see pubspec.yaml).
class NmFonts {
  NmFonts._();

  /// Serif for titles and headings.
  static const String serif = 'Lora';

  /// Sans for everything else (body, buttons, labels).
  static const String sans = 'Onest';
}

/// Ready-made text styles used across the app.
class NmText {
  NmText._();

  /// Lora 600 heading. Sizes in the design: 28 (place), 22 (cards),
  /// 20 (sheet headers), 18 (sections).
  static TextStyle title(double size, {Color color = NmColors.ink}) => TextStyle(
        fontFamily: NmFonts.serif,
        fontSize: size,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.01 * size,
        color: color,
      );

  static const TextStyle body = TextStyle(
    fontFamily: NmFonts.sans,
    fontSize: 16,
    height: 23 / 16,
    color: NmColors.ink,
  );

  static const TextStyle small = TextStyle(
    fontFamily: NmFonts.sans,
    fontSize: 13,
    height: 1.35,
    color: NmColors.muted,
  );

  static const TextStyle button = TextStyle(
    fontFamily: NmFonts.sans,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
}

/// Pill-shaped buttons from the design (56 px tall, fully rounded).
class NmButtons {
  NmButtons._();

  static const double height = 56;

  static ButtonStyle _base({
    required Color background,
    required Color foreground,
    double minHeight = height,
  }) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? background.withValues(alpha: 0.6)
              : background),
      foregroundColor: WidgetStatePropertyAll(foreground),
      iconColor: WidgetStatePropertyAll(foreground),
      overlayColor: WidgetStatePropertyAll(foreground.withValues(alpha: 0.08)),
      elevation: const WidgetStatePropertyAll(0),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      side: const WidgetStatePropertyAll(BorderSide.none),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      minimumSize: WidgetStatePropertyAll(Size(minHeight, minHeight)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 22),
      ),
      textStyle: const WidgetStatePropertyAll(NmText.button),
      iconSize: const WidgetStatePropertyAll(20),
    );
  }

  /// Dark main action ("Почати прогулянку", "Запитати ШІ").
  static ButtonStyle primary({double minHeight = height}) => _base(
        background: NmColors.ink,
        foreground: Colors.white,
        minHeight: minHeight,
      );

  /// Light secondary action ("Пауза", "Прослухати", "Закрити").
  static ButtonStyle secondary({double minHeight = height}) => _base(
        background: NmColors.cream,
        foreground: NmColors.ink,
        minHeight: minHeight,
      );

  /// Wine destructive action ("Завершити прогулянку", "Так, завершити").
  static ButtonStyle destructive({double minHeight = height}) => _base(
        background: NmColors.wine,
        foreground: Colors.white,
        minHeight: minHeight,
      );
}

/// App-wide Material theme built on the NotMiss palette.
class NmTheme {
  NmTheme._();

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: NmColors.ink,
      brightness: Brightness.light,
    ).copyWith(
      primary: NmColors.ink,
      onPrimary: Colors.white,
      secondary: NmColors.ochre,
      onSecondary: NmColors.ink,
      error: NmColors.wine,
      onError: Colors.white,
      surface: NmColors.surface,
      onSurface: NmColors.ink,
      onSurfaceVariant: NmColors.muted,
      outline: NmColors.line,
      outlineVariant: NmColors.line,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: NmFonts.sans,
      scaffoldBackgroundColor: NmColors.background,
      canvasColor: NmColors.background,
      splashFactory: InkSparkle.splashFactory,
      elevatedButtonTheme: ElevatedButtonThemeData(style: NmButtons.primary()),
      filledButtonTheme: FilledButtonThemeData(style: NmButtons.primary()),
      outlinedButtonTheme:
          OutlinedButtonThemeData(style: NmButtons.secondary()),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: NmColors.ink,
          textStyle: NmText.button,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: NmColors.ink,
      ),
      // The design has no grey divider lines anywhere.
      dividerTheme: const DividerThemeData(
        color: Colors.transparent,
        space: 0,
        thickness: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: NmColors.surface,
        side: const BorderSide(color: NmColors.line),
        shape: const StadiumBorder(),
        labelStyle: const TextStyle(
          fontFamily: NmFonts.sans,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: NmColors.ink,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: NmColors.background,
        hintStyle: const TextStyle(color: NmColors.stone),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: NmColors.line, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: NmColors.line, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: NmColors.ink, width: 1.5),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: NmColors.surface,
        foregroundColor: NmColors.ink,
        shape: CircleBorder(),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: NmColors.ink,
      ),
    );
  }
}
