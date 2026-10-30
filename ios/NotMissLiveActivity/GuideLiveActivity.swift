import ActivityKit
import SwiftUI
import WidgetKit

/// Always-on indicator while a walk is running: lock screen banner + Dynamic Island.
struct GuideLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: GuideActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: context.state.speaking ? "waveform" : "figure.walk")
          .font(.title2)
          .frame(width: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title)
            .font(.headline)
            .lineLimit(1)
          Text(context.state.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if !context.state.badge.isEmpty {
          Text(context.state.badge)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: context.state.speaking ? "waveform" : "figure.walk")
            .font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.badge)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.state.title).font(.headline).lineLimit(1)
            Text(context.state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      } compactLeading: {
        Image(systemName: context.state.speaking ? "waveform" : "figure.walk")
      } compactTrailing: {
        Text(context.state.badge).monospacedDigit()
      } minimal: {
        Image(systemName: context.state.speaking ? "waveform" : "figure.walk")
      }
    }
  }
}
