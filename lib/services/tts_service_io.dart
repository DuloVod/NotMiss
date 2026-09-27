import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Save WAV bytes to a temp file on native (iOS/Android/macOS/Desktop).
/// Returns the file path.
Future<String> saveTempWav(Uint8List wavBytes, String poiId) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/narration_$poiId.wav');
  await file.writeAsBytes(wavBytes);
  return file.path;
}
