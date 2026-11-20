import ActivityKit
import GPhotosKit
import SwiftUI
import WidgetKit

@main
struct BackupWidgetsBundle: WidgetBundle {
  var body: some Widget {
    BackupActivityWidget()
    MemoriesWidget()
    PeopleWidget()
    BackupStatusWidget()
  }
}

struct BackupActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: BackupActivityAttributes.self) { context in
      LockScreenBannerView(state: context.state, isStale: context.isStale)
        .activityBackgroundTint(nil)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            Image(systemName: iconName(for: context.state, isStale: context.isStale))
              .font(.title3)
              .foregroundStyle(iconColor(for: context.state, isStale: context.isStale))
              .widgetAccentable()
            Text(title(for: context.state, isStale: context.isStale))
              .font(.headline)
              .lineLimit(1)
          }
          .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if !context.isStale, !context.state.etaText.isEmpty {
            Text(context.state.etaText)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .contentTransition(.numericText())
              .padding(.trailing, 4)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("\(context.state.completedCount) of \(context.state.totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
              Spacer()
              if let bytes = byteProgress(for: context.state) {
                Text(bytes)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            ProgressView(value: context.state.progress)
              .tint(.blue)
          }
          .padding(.horizontal, 4)
          .padding(.bottom, 4)
        }
      } compactLeading: {
        Image(systemName: iconName(for: context.state, isStale: context.isStale))
          .foregroundStyle(iconColor(for: context.state, isStale: context.isStale))
          .widgetAccentable()
      } compactTrailing: {
        Text(context.isStale ? "…" : "\(Int(context.state.progress * 100))%")
          .font(.caption2)
          .fontWeight(.medium)
          .monospacedDigit()
          .contentTransition(.numericText())
      } minimal: {
        Image(systemName: iconName(for: context.state, isStale: context.isStale))
          .foregroundStyle(iconColor(for: context.state, isStale: context.isStale))
          .accessibilityLabel(title(for: context.state, isStale: context.isStale))
          .widgetAccentable()
      }
    }
  }
}

private struct LockScreenBannerView: View {
  let state: BackupActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 12) {
      iconTile
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(title(for: state, isStale: isStale))
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
          Spacer()
          if !isStale, !state.etaText.isEmpty {
            Text(state.etaText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .contentTransition(.numericText())
          }
        }
        Text(subtitle(for: state))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
        ProgressView(value: state.progress)
          .tint(.blue)
      }
    }
    .padding(14)
  }

  private var iconTile: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(iconColor(for: state, isStale: isStale).opacity(0.15))
        .frame(width: 44, height: 44)
      Image(systemName: iconName(for: state, isStale: isStale))
        .font(.title3)
        .foregroundStyle(iconColor(for: state, isStale: isStale))
        .widgetAccentable()
    }
  }
}

private func iconName(for state: BackupActivityAttributes.ContentState, isStale: Bool) -> String {
  if isStale { return "clock" }
  switch state.phase {
  case .uploading: return "arrow.up.circle.fill"
  case .finishing, .waitingForGoogle: return "clock"
  case .ended: return state.outcome == .complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
  case .paused: return "pause.circle.fill"
  case .waitingForNetwork, .offline: return "wifi.circle.fill"
  }
}

private func iconColor(for state: BackupActivityAttributes.ContentState, isStale: Bool) -> Color {
  if isStale { return .secondary }
  switch state.phase {
  case .uploading, .finishing: return .blue
  case .ended: return state.outcome == .complete ? .green : .orange
  case .paused, .waitingForNetwork, .offline, .waitingForGoogle: return .orange
  }
}

private func title(for state: BackupActivityAttributes.ContentState, isStale: Bool) -> String {
  if isStale { return "Backup Status Out of Date" }
  switch state.phase {
  case .uploading: return "Backing Up"
  case .paused: return "Paused"
  case .waitingForNetwork: return "Waiting for Wi‑Fi"
  case .offline: return "Waiting for a Connection"
  case .waitingForGoogle: return "Waiting for Google Photos"
  case .finishing: return "Finishing Backup"
  case .ended:
    switch state.outcome {
    case .complete: return "Backup Complete"
    case .stopped: return "Backup Stopped"
    case .incomplete, nil: return "Backup Incomplete"
    }
  }
}

private func byteProgress(for state: BackupActivityAttributes.ContentState) -> String? {
  guard state.bytesTotal > 0 else { return nil }
  return "\(ByteFormat.string(state.bytesSent)) of \(ByteFormat.string(state.bytesTotal))"
}

private func subtitle(for state: BackupActivityAttributes.ContentState) -> String {
  let countText = "\(state.completedCount) of \(state.totalCount) items"
  guard let bytes = byteProgress(for: state) else { return countText }
  return "\(countText) · \(bytes)"
}

#Preview("Lock Screen Banner - Uploading", as: .content, using: BackupActivityAttributes(title: "Google Photos")) {
  BackupActivityWidget()
} contentStates: {
  BackupActivityAttributes.ContentState(
    phase: .uploading,
    completedCount: 123,
    totalCount: 456,
    bytesSent: 120_000_000,
    bytesTotal: 450_000_000,
    etaText: "2 min left",
    currentFilename: "IMG_2048.heic"
  )
  BackupActivityAttributes.ContentState(
    phase: .paused,
    completedCount: 123,
    totalCount: 456,
    bytesSent: 120_000_000,
    bytesTotal: 450_000_000,
    etaText: "Paused",
    currentFilename: "IMG_2048.heic"
  )
  BackupActivityAttributes.ContentState(
    phase: .ended,
    completedCount: 456,
    totalCount: 456,
    bytesSent: 450_000_000,
    bytesTotal: 450_000_000,
    etaText: "",
    outcome: .complete
  )
}

#Preview(
  "Dynamic Island - Expanded", as: .dynamicIsland(.expanded), using: BackupActivityAttributes(title: "Google Photos")
) {
  BackupActivityWidget()
} contentStates: {
  BackupActivityAttributes.ContentState(
    phase: .uploading,
    completedCount: 123,
    totalCount: 456,
    bytesSent: 120_000_000,
    bytesTotal: 450_000_000,
    etaText: "2 min left",
    currentFilename: "IMG_2048.heic"
  )
}

#Preview(
  "Dynamic Island - Compact", as: .dynamicIsland(.compact), using: BackupActivityAttributes(title: "Google Photos")
) {
  BackupActivityWidget()
} contentStates: {
  BackupActivityAttributes.ContentState(
    phase: .uploading,
    completedCount: 123,
    totalCount: 456,
    bytesSent: 120_000_000,
    bytesTotal: 450_000_000,
    etaText: "2 min left"
  )
}

#Preview(
  "Dynamic Island - Minimal", as: .dynamicIsland(.minimal), using: BackupActivityAttributes(title: "Google Photos")
) {
  BackupActivityWidget()
} contentStates: {
  BackupActivityAttributes.ContentState(
    phase: .uploading,
    completedCount: 123,
    totalCount: 456,
    bytesSent: 120_000_000,
    bytesTotal: 450_000_000,
    etaText: "2 min left"
  )
}
