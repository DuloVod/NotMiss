import ActivityKit
import AppIntents
import Foundation

/// Shared by the app (starts / updates the activity, runs the buttons) and the widget
/// extension (draws it).
struct GuideActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// The place being narrated, or the nearest place.
    var title: String
    /// "Далі: Фонтан · 85 м", the kind of place, or a calm hint.
    var subtitle: String
    /// Very short text for the Dynamic Island / right side, e.g. "85 м".
    var badge: String
    /// A narration is being prepared / played / paused (the "speaking" mode).
    var speaking: Bool
    /// The narration is paused.
    var paused: Bool
    /// Pause and next/stop buttons are shown.
    var controls: Bool
    /// "Next" would start another narration (otherwise the button stops this one).
    var canSkipNext: Bool
  }

  var name: String
}

/// Carries button presses from the activity to the Flutter side (set by AppDelegate).
enum GuideCommandBus {
  static var handler: ((String) -> Void)?

  static func send(_ command: String) {
    handler?(command)
  }
}

/// A button on the Live Activity. `LiveActivityIntent` is performed in the app's process,
/// where the running walk can react to it.
@available(iOS 17.0, *)
struct GuideCommandIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Керування гідом"

  @Parameter(title: "Команда")
  var command: String

  init() {
    self.command = "toggle"
  }

  init(command: String) {
    self.command = command
  }

  func perform() async throws -> some IntentResult {
    GuideCommandBus.send(command)
    return .result()
  }
}
