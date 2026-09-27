import 'dart:typed_data';

/// On web there is no file system — this stub is never actually called
/// because tts_service.dart handles the web case inline (data URI).
/// This file exists only to satisfy the conditional import.
Future<String> saveTempWav(Uint8List wavBytes, String poiId) async {
  throw UnsupportedError('saveTempWav is not supported on web');
}
