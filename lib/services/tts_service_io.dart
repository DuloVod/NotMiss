import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Save WAV bytes to a temp file on native (iOS/Android/macOS/Desktop).
/// Returns the file path.
Future<String> saveTempWav(Uint8List wavBytes, String poiId) async {
  final dir = await getTemporaryDirectory();
  // Sanitize poiId: replace characters invalid in filenames (/ \ : etc.)
  final safeId = poiId.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
  final file = File('${dir.path}/narration_$safeId.wav');
  await file.writeAsBytes(wavBytes);
  return file.path;
}
