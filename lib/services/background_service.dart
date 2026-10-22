import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Manages the Android foreground service that keeps the app alive
/// while the screen is off during a walk.
///
/// On iOS, background location and audio are handled natively via Info.plist
/// `UIBackgroundModes: [location, audio]`, `AVAudioSession`, and `IosBackgroundTask`.
///
/// On Web and iOS, this class is a no-op.
class BackgroundService {
  static bool _initialized = false;

  /// Call once at app startup (main.dart) to configure the foreground task.
  static void init() {
    if (kIsWeb || !Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'notmiss_walk',
        channelName: 'NotMiss Walk',
        channelDescription:
            'Keeps the voice guide running while your screen is off.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // heartbeat every 5s
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _initialized = true;
  }

  /// Start the foreground service when a walk begins (Android only).
  static Future<void> start() async {
    if (kIsWeb || !Platform.isAndroid || !_initialized) return;

    // Request notification permission (Android 13+)
    final notifResult = await FlutterForegroundTask.checkNotificationPermission();
    if (notifResult != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'NotMiss — Walk in progress',
      notificationText: 'Voice guide is active. You\'ll be notified near each point.',
    );
  }

  /// Update the notification text (Android only).
  static Future<void> updateNotification(String title, String text) async {
    if (kIsWeb || !Platform.isAndroid || !_initialized) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Stop the foreground service when the walk ends (Android only).
  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid || !_initialized) return;
    await FlutterForegroundTask.stopService();
  }
}
