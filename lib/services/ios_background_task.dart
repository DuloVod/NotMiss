import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Manages iOS background execution tasks (UIApplication.beginBackgroundTask)
/// to ensure the OS does not suspend the app during asynchronous POI triggering,
/// narration generation, and TTS synthesis when the screen is locked.
class IosBackgroundTask {
  static const _channel = MethodChannel('com.dulo.notmiss/background_task');

  /// Requests up to 30 seconds of background execution time from iOS.
  static Future<void> begin() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('beginBackgroundTask');
    } catch (_) {}
  }

  /// Tells iOS that the background task has completed.
  static Future<void> end() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('endBackgroundTask');
    } catch (_) {}
  }
}
