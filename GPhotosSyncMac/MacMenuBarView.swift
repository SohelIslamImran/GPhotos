import AppKit
import GPhotosKit
import SwiftUI

struct MacMenuBarView: View {
  let store: MacSyncStore
  let router: MacRouter
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss

  var tracksPopoverVisibility = false
  @State private var isWindowVisible = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .frame(height: 34, alignment: .leading)
        .padding(.bottom, 12)

      Divider()

      if !tracksPopoverVisibility || isWindowVisible {
        MacMenuBarStatus(store: store, counts: { counts }, actions: actions(for:))
      } else {
        // Keep the popover's initial window size while its live views are detached.
        Color.clear.frame(height: 218)
      }

      Divider()

      VStack(spacing: 0) {
        MenuRow("Open \(ProductCopy.name)", systemImage: "macwindow") { open { router.show(.overview) } }
        MenuRow("Show Watched Folders in Finder", systemImage: "folder") {
          for folder in store.folders where folder.isEnabled { store.openFolderInFinder(url: folder.url) }
        }
        .disabled(!store.folders.contains { $0.isEnabled })
        MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") { open { router.show(.settings) } }
          .keyboardShortcut(",")
        MenuRow("Quit \(ProductCopy.name)", systemImage: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
          .keyboardShortcut("q")
      }
      .padding(.top, 6)
    }
    .padding(14)
    .frame(width: 320)
    .background {
      if tracksPopoverVisibility { MenuBarWindowVisibility(isVisible: $isWindowVisible) }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      AccountAvatar(email: store.selectedAccount?.email, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(ProductCopy.name)
          .font(.subheadline.weight(.semibold))
        Group {
          if let account = store.selectedAccount {
            Text(account.email)
          } else {
            Text("Sign in to Google Photos")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var counts: some View {
    let counts = store.accountRecordCounts
    return GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        CountPill("In Progress", value: counts.queued + counts.uploading, symbol: "clock.arrow.circlepath", tint: .blue) {
          open { router.show(.activity, filter: .pending) }
        }
        CountPill("Uploaded", value: counts.sent, symbol: "checkmark.circle.fill", tint: .green) {
          open { router.show(.activity, filter: .uploaded) }
        }
        CountPill(
          "Failed", value: counts.failed,
          symbol: counts.failed == 0 ? "exclamationmark.triangle" : "exclamationmark.triangle.fill",
          tint: counts.failed == 0 ? .secondary : .red
        ) {
          open { router.show(.activity, filter: .failed) }
        }
      }
    }
  }

  @ViewBuilder
  private func actions(for status: BackupStatus) -> some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        if store.isRunning || store.isScanning || store.isStarting {
          if store.isRunning {
            secondary(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill") {
              store.isPaused ? store.resumeTransfer() : store.pauseTransfer()
            }
          }
          secondary("Stop", systemImage: "stop.fill") { store.stopTransfer() }
            .tint(.red)
        } else if case .credentialsUnavailable = status {
          secondary("Try Again", systemImage: "arrow.clockwise") { Task { await store.loadAccounts() } }
        } else if store.selectedAccount == nil {
          primary("Sign In…") { open { router.isSigningIn = true } }
        } else {
          switch status {
          case .needsSource(.noFolders):
            primary("Add Folder…") {
              open {
                router.show(.folders)
                router.isAddingFolder = true
              }
            }
          case .needsSource(.foldersBlocked):
            primary("Review Folders") { open { router.show(.folders) } }
          case .failed:
            primary("Retry", systemImage: "arrow.clockwise") { Task { await store.retryFailedForUser() } }
            // Shown only when it can run; a dimmed second button beside Retry reads as broken.
            if store.hasUsableEnabledFolder {
              secondary("Sync Now", systemImage: "arrow.triangle.2.circlepath") { store.requestSyncNow() }
            }
          default:
            primary("Sync Now", systemImage: "arrow.clockwise") { store.requestSyncNow() }
              .disabled(store.selectedAccount == nil || !store.hasUsableEnabledFolder)
          }
        }
      }
      .disabled(store.workerPool.isStopping)
    }
  }

  private func primary(
    _ title: LocalizedStringKey, systemImage: String? = nil, action: @escaping () -> Void
  )
    -> some View
  {
    Button(action: action) {
      label(title, systemImage: systemImage)
    }
    .buttonStyle(.glassProminent)
    .controlSize(.large)
  }

  private func secondary(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      label(title, systemImage: systemImage)
    }
    .buttonStyle(.glass)
    .controlSize(.large)
  }

  private func label(_ title: LocalizedStringKey, systemImage: String?) -> some View {
    Group {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// Brings the main window forward, then closes this panel.
  private func open(_ route: () -> Void) {
    route()
    openWindow(id: MacRouter.mainWindowID)
    NSApp.activate()
    MacRouter.restoreMainWindow()
    dismiss()
  }
}

/// One count in the panel, opening Activity with its filter. Matches the Overview tiles.
private struct CountPill: View {
  private let title: LocalizedStringKey
  private let value: Int
  private let symbol: String
  private let tint: Color
  private let action: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(_ title: LocalizedStringKey, value: Int, symbol: String, tint: Color, action: @escaping () -> Void) {
    self.title = title
    self.value = value
    self.symbol = symbol
    self.tint = tint
    self.action = action
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    Button(action: action) {
      VStack(spacing: 2) {
        Image(systemName: symbol)
          .font(.body)
          .foregroundStyle(tint)
          .padding(.bottom, 2)
        Text(value, format: .number)
          .font(.title3.weight(.semibold))
          .fontDesign(.rounded)
          .monospacedDigit()
          .lineLimit(1)
          .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
          .animation(reduceMotion ? nil : .smooth, value: value)
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .background(isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear), in: shape)
      .contentShape(shape)
    }
    .buttonStyle(PressableButtonStyle())
    .glassEffect(.regular.interactive(), in: shape)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(Text(value, format: .number))
    .accessibilityHint("Shows these items in Activity")
    .accessibilityAddTraits(.isButton)
  }
}

/// A full-width row that highlights on hover with the selection color, like a menu item.
private struct MenuRow: View {
  private let title: LocalizedStringKey
  private let systemImage: String
  private let shortcut: String?
  private let action: () -> Void
  @State private var isHovered = false
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: LocalizedStringKey, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.shortcut = shortcut
    self.action = action
  }

  var body: some View {
    let isHighlighted = isHovered && isEnabled
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .frame(width: 18)
          .accessibilityHidden(true)
        Text(title)
          .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        Spacer(minLength: 8)
        if let shortcut {
          Text(shortcut)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 28)
      .background(
        isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.clear),
        in: .rect(cornerRadius: 6, style: .continuous)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.5)
    .onHover { isHovered = $0 }
  }
}

/// Reads the pool itself so per-tick progress re-renders only this block.
private struct MacMenuBarStatus<Counts: View, Actions: View>: View {
  let store: MacSyncStore
  @ViewBuilder let counts: () -> Counts
  @ViewBuilder let actions: (BackupStatus) -> Actions

  var body: some View {
    DisplayedBackupStatus(store.backupStatus) { status in
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          StatusEmblem(status, size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text(status.title)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(status.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2, reservesSpace: true)
          }
        }
        .frame(height: 52, alignment: .leading)
        .accessibilityElement(children: .combine)

        // All phases share a slot so the actions and menu rows stay in place.
        Group {
          if store.isRunning {
            MenuBarProgress(pool: store.workerPool)
          } else if store.selectedAccount != nil {
            counts()
          } else {
            Color.clear.accessibilityHidden(true)
          }
        }
        .frame(height: 82)

        actions(status)
          .frame(height: 36)
      }
      .padding(.vertical, 12)
    }
  }
}

private struct MenuBarWindowVisibility: NSViewRepresentable {
  @Binding var isVisible: Bool

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.visibilityChanged = { isVisible = $0 }
    return probe
  }

  func updateNSView(_ view: Probe, context: Context) {
    view.visibilityChanged = { isVisible = $0 }
  }

  final class Probe: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      if let window {
        observer = NotificationCenter.default.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: nil
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.reportVisibility() }
        }
      }
      reportVisibility()
    }

    private func reportVisibility() {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.visibilityChanged?(self.window?.occlusionState.contains(.visible) == true)
      }
    }

    private func stopObserving() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
    }

    isolated deinit { stopObserving() }
  }
}

private struct MenuBarProgress: View {
  let pool: UploadWorkerPool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: pool.currentProgress)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: pool.currentProgress)
      HStack {
        Text(pool.currentFilename.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Preparing…"))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Text(pool.overallFormattedSpeed)
          .monospacedDigit()
          .frame(width: 76, alignment: .trailing)
        Text(pool.currentProgress.formatted(.percent.precision(.fractionLength(0))))
          .monospacedDigit()
          .contentTransition(reduceMotion ? .identity : .numericText())
          .frame(width: 36, alignment: .trailing)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
  }
}
