import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:ui' show PlatformDispatcher;
import 'l10n/app_lang.dart';
import 'models/destination.dart';
import 'services/analytics_service.dart';
import 'services/settings_store.dart';
import 'services/background_service.dart';
import 'ui/screens/main_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/walk_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background foreground-service (Android only; no-op on web/iOS)
  BackgroundService.init();

  // Load .env for API key (silently ignore if missing — app still works without TTS/AI)
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env not found — API key will be empty, AI/TTS features will be skipped
  }

  // Language: the user's choice, otherwise the phone's language (first launch).
  final settings = SettingsStore();
  await settings.init();
  L.lang = settings.lang ?? AppLang.fromDevice(PlatformDispatcher.instance.locale.languageCode);

  await settings.ensureAnalyticsId();

  // Usage statistics: the project key is write-only (safe to ship). No key → disabled.
  final analytics = AnalyticsService(
    apiKey: _setting('POSTHOG_KEY'),
    host: _setting('POSTHOG_HOST'),
  )..configure(
      distinctId: settings.analyticsId,
      enabled: settings.analyticsEnabled,
      base: {
        'lang': L.lang.code,
        'device_lang': PlatformDispatcher.instance.locale.languageCode,
      },
    );

  Destination? destination;
  String? loadError;

  try {
    final jsonStr =
        await rootBundle.loadString('assets/data/stryiskyi_park.json');
    final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
    destination = Destination.fromJson(parsed);
  } catch (e) {
    loadError = L.t('Помилка завантаження даних парку:\n$e', 'Could not load the park data:\n$e');
  }

  final envKey = dotenv.maybeGet('GEMINI_API_KEY');
  final apiKey = (envKey != null && envKey.trim().isNotEmpty)
      ? envKey.trim()
      : const String.fromEnvironment('GEMINI_API_KEY');

  runApp(NotMissApp(
    destination: destination,
    apiKey: apiKey,
    settings: settings,
    analytics: analytics,
    loadError: loadError,
  ));
}

/// A value from .env, otherwise from --dart-define.
String _setting(String name) {
  final fromEnv = dotenv.maybeGet(name)?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return switch (name) {
    'POSTHOG_KEY' => const String.fromEnvironment('POSTHOG_KEY'),
    'POSTHOG_HOST' => const String.fromEnvironment('POSTHOG_HOST'),
    _ => '',
  };
}

/// Root widget. Uses StatefulWidget to ensure WalkController is created once
/// and survives rebuilds (MediaQuery changes, keyboard, rotation, etc.).
class NotMissApp extends StatefulWidget {
  final Destination? destination;
  final String apiKey;
  final SettingsStore settings;
  final AnalyticsService? analytics;
  final String? loadError;

  const NotMissApp({
    super.key,
    required this.destination,
    required this.apiKey,
    required this.settings,
    this.analytics,
    this.loadError,
  });

  @override
  State<NotMissApp> createState() => _NotMissAppState();
}

class _NotMissAppState extends State<NotMissApp> {
  WalkController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.destination != null && widget.loadError == null) {
      _controller = WalkController(
        destination: widget.destination!,
        apiKey: widget.apiKey,
        settingsStore: widget.settings,
        analytics: widget.analytics,
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // The app's language follows the selected one: system texts (copy / paste menu, dialogs,
    // screen-reader labels) come out in it too.
    return ListenableBuilder(
      listenable: controller ?? ValueNotifier<int>(0),
      builder: (context, _) => MaterialApp(
        title: 'NotMiss',
        debugShowCheckedModeBanner: false,
        theme: NmTheme.light(),
        locale: Locale(L.lang.code),
        supportedLocales: [for (final l in AppLang.values) Locale(l.code)],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: controller == null
            ? _ErrorScreen(message: widget.loadError ?? L.t('Дані парку не завантажились.', 'The park data could not be loaded.'))
            : MainScreen(controller: controller),
      ),
    );
  }
}

/// Shown instead of black screen when startup fails.
class _ErrorScreen extends StatelessWidget {
  final String message;
  const _ErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NmColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: NmColors.wine),
              const SizedBox(height: 16),
              Text(
                L.t('Помилка запуску', 'Startup error'),
                style: NmText.title(22),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: NmText.small,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
