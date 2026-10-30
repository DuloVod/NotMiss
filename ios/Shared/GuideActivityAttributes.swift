import ActivityKit
import Foundation

/// Shared by the app (starts / updates the activity) and the widget extension (draws it).
struct GuideActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// The place being narrated, or the nearest place.
    var title: String
    /// "Далі: Фонтан · 85 м", the kind of place, or a calm hint.
    var subtitle: String
    /// Very short text for the Dynamic Island, e.g. "85 м".
    var badge: String
    /// A narration is playing / paused right now.
    var speaking: Bool
  }

  var name: String
}
