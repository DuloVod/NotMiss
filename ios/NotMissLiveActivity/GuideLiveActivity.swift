import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The app's own palette (see lib/ui/theme/app_theme.dart).
private enum Brand {
  static let ink = Color(red: 0x1B / 255, green: 0x1A / 255, blue: 0x17 / 255)
  static let cream = Color(red: 0xEF / 255, green: 0xEB / 255, blue: 0xE0 / 255)
  static let line = Color(red: 0xE4 / 255, green: 0xDF / 255, blue: 0xD3 / 255)
  static let muted = Color(red: 0x5E / 255, green: 0x5A / 255, blue: 0x52 / 255)
  static let ochre = Color(red: 0xC9 / 255, green: 0x92 / 255, blue: 0x28 / 255)
}

private func modeSymbol(_ state: GuideActivityAttributes.ContentState) -> String {
  if state.speaking { return state.paused ? "pause.fill" : "waveform" }
  return "figure.walk"
}

/// One round button; a real button (runs in the app) on iOS 17+, a plain icon before that.
private struct ControlButton: View {
  let command: String
  let symbol: String
  var filled: Bool = false
  var onDark: Bool = false

  private var label: some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(filled ? Brand.cream : (onDark ? Brand.cream : Brand.ink))
      .frame(width: 36, height: 36)
      .background(
        Circle().fill(filled ? Brand.ink : (onDark ? Color.white.opacity(0.16) : Brand.line))
      )
  }

  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: GuideCommandIntent(command: command)) { label }
        .buttonStyle(.plain)
    } else {
      label
    }
  }
}

private struct Controls: View {
  let state: GuideActivityAttributes.ContentState
  var onDark: Bool = false

  var body: some View {
    HStack(spacing: 8) {
      ControlButton(
        command: "toggle",
        symbol: state.paused ? "play.fill" : "pause.fill",
        filled: !onDark,
        onDark: onDark
      )
      ControlButton(
        command: "skip",
        symbol: state.canSkipNext ? "forward.end.fill" : "stop.fill",
        onDark: onDark
      )
    }
  }
}

/// Lock-screen block: one solid card, two modes — narrating (with controls) and walking.
private struct LockScreenView: View {
  let state: GuideActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(state.speaking && !isStale ? Brand.ochre : Brand.ink)
        Image(systemName: isStale ? "moon.zzz.fill" : modeSymbol(state))
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(state.speaking && !isStale ? Brand.ink : Brand.cream)
      }
      .frame(width: 40, height: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(isStale ? "Гід зараз не активний" : state.title)
          .font(.system(size: 17, weight: .semibold, design: .serif))
          .foregroundStyle(Brand.ink)
          .lineLimit(1)
        Text(isStale ? "Відкрийте NotMiss, щоб продовжити" : state.subtitle)
          .font(.system(size: 13))
          .foregroundStyle(Brand.muted)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      if !isStale {
        if state.controls {
          Controls(state: state)
        } else if !state.badge.isEmpty {
          Text(state.badge)
            .font(.system(size: 20, weight: .semibold, design: .serif))
            .foregroundStyle(Brand.ink)
            .monospacedDigit()
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

/// Always-on indicator while a walk is running: lock-screen card + Dynamic Island.
struct GuideLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: GuideActivityAttributes.self) { context in
      LockScreenView(state: context.state, isStale: context.isStale)
        .activityBackgroundTint(Brand.cream)
        .activitySystemActionForegroundColor(Brand.ink)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: modeSymbol(context.state))
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Brand.ochre)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.badge)
            .font(.system(size: 18, weight: .semibold, design: .serif))
            .foregroundStyle(Brand.cream)
            .monospacedDigit()
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.state.title)
              .font(.system(size: 16, weight: .semibold, design: .serif))
              .foregroundStyle(Brand.cream)
              .lineLimit(1)
            Text(context.state.subtitle)
              .font(.system(size: 12))
              .foregroundStyle(Brand.cream.opacity(0.7))
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if context.state.controls {
            Controls(state: context.state, onDark: true)
          }
        }
      } compactLeading: {
        Image(systemName: modeSymbol(context.state))
          .foregroundStyle(Brand.ochre)
      } compactTrailing: {
        Text(context.state.badge)
          .foregroundStyle(Brand.cream)
          .monospacedDigit()
      } minimal: {
        Image(systemName: modeSymbol(context.state))
          .foregroundStyle(Brand.ochre)
      }
      .keylineTint(Brand.ochre)
    }
  }
}
