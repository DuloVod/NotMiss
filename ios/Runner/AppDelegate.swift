import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import ActivityKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure AVAudioSession for background audio playback and voice guide
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // NOTE: .allowBluetooth / .allowBluetoothA2DP are only valid for playAndRecord/record;
      // passing them with .playback makes setCategory fail (OSStatus -50) and leaves the
      // default ambient session, which does not play in the background. Bluetooth
      // headphones (A2DP) work automatically with .playback.
      try audioSession.setCategory(
        .playback,
        mode: .spokenAudio,
        options: []
      )
    } catch {
      print("[AppDelegate] Failed to configure AVAudioSession: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Registered from the implicit engine callback: with the implicit-engine lifecycle the
  /// registrar is not reliably available inside didFinishLaunchingWithOptions.
  private func setupBackgroundTaskChannel(messenger: FlutterBinaryMessenger) {
    do {
      let channel = FlutterMethodChannel(name: "com.dulo.notmiss/background_task", binaryMessenger: messenger)
      channel.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        if call.method == "beginBackgroundTask" {
          if self.backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
          }
          self.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "NotMissPoiTrigger") {
            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
            self.backgroundTaskId = .invalid
          }
          result(true)
        } else if call.method == "endBackgroundTask" {
          if self.backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
            self.backgroundTaskId = .invalid
          }
          result(true)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  /// Lock-screen "Now Playing" card + remote commands (play / pause / previous = replay /
  /// next = skip). Commands are forwarded to Dart over the same channel.
  private func setupNowPlayingChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.dulo.notmiss/now_playing", binaryMessenger: messenger)

    // Buttons on the Live Activity arrive here (see GuideCommandIntent) and go to Dart.
    GuideCommandBus.handler = { command in
      DispatchQueue.main.async { channel.invokeMethod("command", arguments: command) }
    }

    // The lock-screen block is the Live Activity (with its own buttons). The app must NOT also
    // appear as a system "Now Playing" player, so every remote command is switched off.
    let center = MPRemoteCommandCenter.shared()
    for command in [
      center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
      center.stopCommand, center.nextTrackCommand, center.previousTrackCommand,
      center.skipForwardCommand, center.skipBackwardCommand,
      center.seekForwardCommand, center.seekBackwardCommand,
      center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
    ] as [MPRemoteCommand] {
      command.isEnabled = false
    }
    UIApplication.shared.endReceivingRemoteControlEvents()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

    channel.setMethodCallHandler { (call, result) in
      let info = MPNowPlayingInfoCenter.default()
      NSLog("[NotMiss.LockScreen] %@", call.method)
      switch call.method {
      case "update":
        guard let args = call.arguments as? [String: Any] else { result(false); return }
        let playing = args["playing"] as? Bool ?? false
        var dict: [String: Any] = [
          MPMediaItemPropertyTitle: args["title"] as? String ?? "",
          MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "NotMiss",
          MPMediaItemPropertyAlbumTitle: "NotMiss",
          MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
          MPNowPlayingInfoPropertyIsLiveStream: false,
          MPNowPlayingInfoPropertyElapsedPlaybackTime: args["elapsed"] as? Double ?? 0,
          MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
          MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let duration = args["duration"] as? Double, duration > 0 {
          dict[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info.nowPlayingInfo = dict
        info.playbackState = playing ? .playing : .paused
        result(true)
      case "clear":
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Always-on indicator (Live Activity) on the lock screen and in the Dynamic Island, like
  /// navigation apps: what the guide is telling about / the nearest place and its distance.
  /// Needs iOS 16.2+; on older systems every call just reports `false`.
  private func setupLiveActivityChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.dulo.notmiss/live_activity", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else { result(false); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "show":
        let state = GuideActivityAttributes.ContentState(
          title: args["title"] as? String ?? "",
          subtitle: args["subtitle"] as? String ?? "",
          badge: args["badge"] as? String ?? "",
          speaking: args["speaking"] as? Bool ?? false,
          paused: args["paused"] as? Bool ?? false,
          controls: args["controls"] as? Bool ?? false,
          canSkipNext: args["canSkipNext"] as? Bool ?? false
        )
        // The app refreshes the activity regularly; if it stops (app closed), iOS marks it
        // stale and the card says the guide is not active instead of showing old data.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        Task {
          if let existing = Activity<GuideActivityAttributes>.activities.first {
            await existing.update(content)
            DispatchQueue.main.async { result(true) }
            return
          }
          guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[NotMiss.LiveActivity] disabled by the user")
            DispatchQueue.main.async { result(false) }
            return
          }
          do {
            _ = try Activity.request(
              attributes: GuideActivityAttributes(name: "NotMiss"),
              content: content,
              pushType: nil
            )
            DispatchQueue.main.async { result(true) }
          } catch {
            NSLog("[NotMiss.LiveActivity] request failed: %@", error.localizedDescription)
            DispatchQueue.main.async { result(false) }
          }
        }
      case "end":
        Task {
          for activity in Activity<GuideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
          DispatchQueue.main.async { result(true) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// A fresh process has no walk: remove an indicator left behind by a previous run.
  private func endStaleLiveActivities() {
    guard #available(iOS 16.2, *) else { return }
    Task {
      for activity in Activity<GuideActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  /// The user closed the app: take the indicator down with it.
  override func applicationWillTerminate(_ application: UIApplication) {
    if #available(iOS 16.2, *) {
      let done = DispatchSemaphore(value: 0)
      Task {
        for activity in Activity<GuideActivityAttributes>.activities {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
        done.signal()
      }
      _ = done.wait(timeout: .now() + 2)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    super.applicationWillTerminate(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Application-level channels go through the application registrar (the documented way for
    // the implicit-engine / UIScene lifecycle).
    let messenger = engineBridge.applicationRegistrar.messenger()
    setupBackgroundTaskChannel(messenger: messenger)
    setupNowPlayingChannel(messenger: messenger)
    setupLiveActivityChannel(messenger: messenger)
    endStaleLiveActivities()
  }
}
