import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'models/destination.dart';
import 'services/background_service.dart';
import 'ui/screens/home_screen.dart';
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

  Destination? destination;
  String? loadError;

  try {
    final jsonStr =
        await rootBundle.loadString('assets/data/stryiskyi_park.json');
    destination = Destination.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  } catch (e) {
    loadError = 'Помилка завантаження даних парку:\n$e';
  }

  final apiKey = dotenv.maybeGet('GEMINI_API_KEY') ?? '';

  runApp(NotMissApp(
    destination: destination,
    apiKey: apiKey,
    loadError: loadError,
  ));
}

class NotMissApp extends StatelessWidget {
  final Destination? destination;
  final String apiKey;
  final String? loadError;

  const NotMissApp({
    super.key,
    required this.destination,
    required this.apiKey,
    this.loadError,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NotMiss — AI Voice Guide',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: loadError != null || destination == null
          ? _ErrorScreen(message: loadError ?? 'Дані парку не завантажились.')
          : HomeScreen(
              destination: destination!,
              controller: WalkController(
                destination: destination!,
                apiKey: apiKey,
              ),
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
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Помилка запуску',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
