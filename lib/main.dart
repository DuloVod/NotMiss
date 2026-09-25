import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'models/destination.dart';
import 'ui/screens/home_screen.dart';
import 'ui/walk_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load .env for API key
  await dotenv.load(fileName: '.env');

  // Load Stryiskyi Park POI data
  final jsonStr =
      await rootBundle.loadString('assets/data/stryiskyi_park.json');
  final destination = Destination.fromJson(
    jsonDecode(jsonStr) as Map<String, dynamic>,
  );

  final apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';

  runApp(NotMissApp(destination: destination, apiKey: apiKey));
}

class NotMissApp extends StatelessWidget {
  final Destination destination;
  final String apiKey;

  const NotMissApp({
    super.key,
    required this.destination,
    required this.apiKey,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NotMiss — AI Voice Guide',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32), // park green
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(
        destination: destination,
        controller: WalkController(
          destination: destination,
          apiKey: apiKey,
        ),
      ),
    );
  }
}
