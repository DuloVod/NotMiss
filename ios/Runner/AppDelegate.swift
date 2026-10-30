import Flutter
import UIKit
import AVFoundation
import MediaPlayer

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
        options: [.duckOthers]
      )
    } catch {
      print("[AppDelegate] Failed to configure AVAudioSession: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Registered from the implicit engine callback: with the implicit-engine lifecycle the
  /// registrar is not reliably available inside didFinishLaunchingWithOptions.
  private func setupBackgroundTaskChannel(registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NotMissBackgroundTask") {
      let channel = FlutterMethodChannel(name: "com.dulo.notmiss/background_task", binaryMessenger: registrar.messenger())
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
  private func setupNowPlayingChannel(registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "NotMissNowPlaying") else { return }
    let channel = FlutterMethodChannel(name: "com.dulo.notmiss/now_playing", binaryMessenger: registrar.messenger())

    let center = MPRemoteCommandCenter.shared()
    func bind(_ command: MPRemoteCommand, _ name: String) {
      command.isEnabled = true
      command.addTarget { _ in
        channel.invokeMethod("command", arguments: name)
        return .success
      }
    }
    bind(center.playCommand, "play")
    bind(center.pauseCommand, "pause")
    bind(center.previousTrackCommand, "replay")
    bind(center.nextTrackCommand, "skip")
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { _ in
      let playing = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
      channel.invokeMethod("command", arguments: playing ? "pause" : "play")
      return .success
    }
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false

    channel.setMethodCallHandler { (call, result) in
      let info = MPNowPlayingInfoCenter.default()
      if call.method == "update", let args = call.arguments as? [String: Any] {
        var dict: [String: Any] = [
          MPMediaItemPropertyTitle: args["title"] as? String ?? "",
          MPMediaItemPropertyArtist: "NotMiss",
          MPNowPlayingInfoPropertyElapsedPlaybackTime: args["elapsed"] as? Double ?? 0,
          MPNowPlayingInfoPropertyPlaybackRate: (args["playing"] as? Bool ?? false) ? 1.0 : 0.0,
        ]
        if let duration = args["duration"] as? Double, duration > 0 {
          dict[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info.nowPlayingInfo = dict
        result(true)
      } else if call.method == "clear" {
        info.nowPlayingInfo = nil
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupBackgroundTaskChannel(registry: engineBridge.pluginRegistry)
    setupNowPlayingChannel(registry: engineBridge.pluginRegistry)
  }
}
