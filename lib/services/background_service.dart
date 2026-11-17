import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_lang.dart';

/// Buttons of the Android walk notification (ids are what the service reports back).
class NotificationActions {
  static const pause = 'pause';
  static const resume = 'resume';
  static const skip = 'skip';
}

/// The foreground-service task runs in its own isolate; it only forwards button presses to
/// the app (main isolate), where the walk controller lives.
@pragma('vm:entry-point')
void notMissTaskStart() {
  FlutterForegroundTask.setTaskHandler(_WalkTaskHandler());
}

class _WalkTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain(id);
  }
}

/// Manages the Android foreground service that keeps the app alive
/// while the screen is off during a walk.
///
/// On iOS, background location and audio are handled natively via Info.plist
/// `UIBackgroundModes: [location, audio]`, `AVAudioSession`, and `IosBackgroundTask`.
///
/// On Web and iOS, this class is a no-op.
class BackgroundService {
  static bool _initialized = false;
  static bool _listening = false;

  /// Receives the id of a pressed notification button ([NotificationActions]).
  static void Function(String id)? onAction;

  /// Tests only: sees every notification update, also where there is no Android service.
  @visibleForTesting
  static void Function(String title, String text, List<String> actions)? notificationSpy;

  /// Call once at app startup (main.dart) to configure the foreground task.
  static void init() {
    if (kIsWeb || !Platform.isAndroid) return;

    FlutterForegroundTask.initCommunicationPort();
    if (!_listening) {
      FlutterForegroundTask.addTaskDataCallback(handleTaskData);
      _listening = true;
    }

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
        eventAction: ForegroundTaskEventAction.nothing(), // the task only forwards button presses
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
      callback: notMissTaskStart,
    );
  }

  /// A button of the notification was pressed (data sent by the task isolate).
  @visibleForTesting
  static void handleTaskData(Object data) {
    if (data is String) onAction?.call(data);
  }

  /// The notification buttons for [actions] (ids from [NotificationActions]), in the app language.
  @visibleForTesting
  static List<NotificationButton> buttonsFor(List<String> actions) {
    String label(String id) => switch (id) {
          NotificationActions.pause => L.t('Пауза', 'Pause'),
          NotificationActions.resume => L.t('Продовжити', 'Resume'),
          NotificationActions.skip => L.t('Далі', 'Next'),
          _ => id,
        };
    return [for (final id in actions) NotificationButton(id: id, text: label(id))];
  }

  /// Update the notification text and its buttons (Android only). [actions] always replaces the
  /// previous buttons: none given means none shown.
  static Future<void> updateNotification(String title, String text, {List<String> actions = const []}) async {
    notificationSpy?.call(title, text, actions);
    if (kIsWeb || !Platform.isAndroid || !_initialized) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
        notificationButtons: buttonsFor(actions),
      );
    } catch (_) {
      // A notification failure must never break narration.
    }
  }

  /// Stop the foreground service when the walk ends (Android only).
  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid || !_initialized) return;
    await FlutterForegroundTask.stopService();
  }
}
