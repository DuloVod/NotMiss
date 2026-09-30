import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Manages the Android foreground service that keeps the app alive
/// while the screen is off during a walk.
///
/// On iOS, background location is handled natively via Info.plist
/// `UIBackgroundModes: [location, audio]` — no extra service needed.
///
/// On Web, this class is a no-op.
class BackgroundService {
  static bool _initialized = false;

  /// Call once at app startup (main.dart) to configure the foreground task.
  static void init() {
    if (kIsWeb) return;

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
        showNotification: false, // iOS handles background via UIBackgroundModes
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

  /// Start the foreground service when a walk begins.
  /// Shows a persistent notification on Android so the OS doesn't kill the app.
  static Future<void> start() async {
    if (kIsWeb || !_initialized) return;

    // Request notification permission (Android 13+)
    final notifResult = await FlutterForegroundTask.checkNotificationPermission();
    if (notifResult != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'NotMiss — Walk in progress',
      notificationText: 'Voice guide is active. You\'ll be notified near each point.',
      notificationIcon: null,
      notificationButtons: [
        const NotificationButton(id: 'stop', text: 'Stop Walk'),
      ],
    );
  }

  /// Update the notification text (e.g. when a POI is triggered).
  static Future<void> updateNotification(String title, String text) async {
    if (kIsWeb || !_initialized) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Stop the foreground service when the walk ends.
  static Future<void> stop() async {
    if (kIsWeb || !_initialized) return;
    await FlutterForegroundTask.stopService();
  }
}
