import Flutter
import UIKit
import AVFoundation

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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupBackgroundTaskChannel(registry: engineBridge.pluginRegistry)
  }
}
