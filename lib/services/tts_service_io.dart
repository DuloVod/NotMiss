import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Save WAV bytes to a temp file on native (iOS/Android/macOS/Desktop).
/// Returns the file path.
Future<String> saveTempWav(Uint8List wavBytes, String poiId, {int? textHash}) async {
  final dir = await getTemporaryDirectory();
  // Sanitize poiId: replace characters invalid in filenames (/ \ : etc.)
  final safeId = poiId.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
  final suffix = textHash != null ? '_$textHash' : '';
  final file = File('${dir.path}/narration_${safeId}$suffix.wav');
  await file.writeAsBytes(wavBytes);
  return file.path;
}

/// Check if a cached WAV file already exists on disk for this [poiId] and [textHash].
/// Returns the file path if valid (> 1000 bytes), otherwise null.
Future<String?> getCachedTempWav(String poiId, {int? textHash}) async {
  try {
    final dir = await getTemporaryDirectory();
    final safeId = poiId.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final suffix = textHash != null ? '_$textHash' : '';
    final file = File('${dir.path}/narration_${safeId}$suffix.wav');
    if (await file.exists()) {
      final len = await file.length();
      if (len > 1000) return file.path;
    }
  } catch (_) {}
  return null;
}
