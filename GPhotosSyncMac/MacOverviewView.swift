import GPhotosKit
import SwiftUI

struct MacOverviewView: View {
  let store: MacSyncStore
  let router: MacRouter
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DisplayedBackupStatus(store.backupStatus) { shown in
      content(shown)
    }
    .navigationTitle("Backup")
  }

  private func content(_ shown: BackupStatus) -> some View {
    ScrollView {
      VStack(spacing: 20) {
        MacStatusCard(store: store, router: router, status: shown)
        GlassEffectContainer(spacing: 12) {
          HStack(spacing: 12) {
            let counts = store.accountRecordCounts
            let queued = counts.queued + counts.uploading
            StatTile(
              "In Progress", value: queued,
              detail: queued == 0 ? String(localized: "Up to date") : String(localized: "\(queued) remaining"),
              symbol: "clock.arrow.circlepath", tint: .blue, isActive: queued > 0 && store.isRunning
            ) {
              router.show(.activity, filter: .pending)
            }
            .contextMenu {
              Button("Back Up Now") { store.requestSyncNow() }
                .disabled(store.selectedAccount == nil || !store.hasUsableEnabledFolder)
            }
            StatTile(
              "Uploaded", value: counts.sent, detail: ByteFormat.string(counts.completedBytes),
              symbol: "checkmark.circle.fill", tint: .green
            ) {
              router.show(.activity, filter: .uploaded)
            }
            .contextMenu {
              Button("Clean Up Backed-Up Files…") {
                router.show(.settings)
                router.isConfirmingCleanup = true
              }
              .disabled(!store.canCleanUp)
              .help(
                ProductCopy.cleanupDetail(
                  isSignedIn: store.selectedAccount != nil, deleteDelay: store.settings.autoDeleteDelay,
                  isBackingUp: store.isRunning))
            }
            StatTile(
              "Failed", value: counts.failed,
              detail: counts.failed == 0 ? String(localized: "None") : String(localized: "Needs retry"),
              symbol: counts.failed == 0 ? "exclamationmark.triangle" : "exclamationmark.triangle.fill",
              tint: counts.failed == 0 ? .secondary : .red, isActive: counts.failed > 0 && store.isRunning
            ) {
              router.show(.activity, filter: .failed)
            }
            .contextMenu {
              Button("Retry All Failed Items") { Task { await store.retryFailedForUser() } }
                .disabled(counts.failed == 0)
            }
          }
        }
        // Live uploads lead, above the drop area, where they're seen without scrolling.
        if store.isRunning {
          NowUploadingList(pool: store.workerPool, record: store.uploadingRecord(for:))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        UploadDropZone(store: store, router: router)
      }
      .animation(reduceMotion ? nil : .smooth, value: store.isRunning)
      .frame(maxWidth: 720)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
  }
}

extension MacSyncStore {
  /// The record a worker is sending. Only a file just finished, still on screen for a
  /// moment, needs the full search.
  func uploadingRecord(for worker: WorkerState) -> TransferRecord? {
    guard !worker.itemID.isEmpty else { return nil }
    return sendingAccountRecords[worker.itemID]
      ?? sendingAccountRecords.values.first { $0.filename == worker.filename }
      ?? accountRecords.first { $0.id == worker.itemID }
  }
}

/// Kept separate so per-tick progress re-renders only the card.
private struct MacStatusCard: View {
  let store: MacSyncStore
  let router: MacRouter
  let status: BackupStatus

  var body: some View {
    let pool = store.workerPool
    StatusCard(
      status: status,
      progress: progress(pool)
    ) {
      actions
    }
  }

  /// The file name is left to Now Uploading below, so it isn't shown twice.
  private func progress(_ pool: UploadWorkerPool) -> TransferProgressSummary? {
    guard store.isRunning, pool.currentTotalBytes > 0 else { return nil }
    var summary = TransferProgressSummary(pool)
    summary.filename = nil
    return summary
  }

  @ViewBuilder
  private var actions: some View {
    if store.isRunning || status.isScan || store.isStarting {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          if store.isRunning {
            Button(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill") {
              store.isPaused ? store.resumeTransfer() : store.pauseTransfer()
            }
          }
          Button("Stop", systemImage: "stop.fill") { store.stopTransfer() }
            .tint(.red)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(store.workerPool.isStopping)
      }
    } else if case .credentialsUnavailable = status {
      // Signing in again would hit the same keychain failure, so offer a re-read instead.
      Button("Try Again") { Task { await store.loadAccounts() } }
        .buttonStyle(.glass)
        .controlSize(.large)
    } else if store.selectedAccount == nil {
      Button("Sign In…") { router.isSigningIn = true }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    } else {
      switch status {
      case .needsSource(.noFolders):
        Button("Add Folder…") {
          router.show(.folders)
          router.isAddingFolder = true
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
      case .needsSource(.foldersBlocked):
        Button("Review Folders") { router.show(.folders) }
          .buttonStyle(.glassProminent)
          .controlSize(.large)
      case .failed:
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            Button("Retry", systemImage: "arrow.clockwise") { Task { await store.retryFailedForUser() } }
              .buttonStyle(.glassProminent)
            Button("Sync Now") { store.requestSyncNow() }
              .buttonStyle(.glass)
              .disabled(store.selectedAccount == nil || !store.hasUsableEnabledFolder)
          }
          .controlSize(.large)
        }
      default:
        Button("Sync Now", systemImage: "arrow.clockwise") { store.requestSyncNow() }
          .buttonStyle(.glassProminent)
          .controlSize(.large)
          .disabled(store.selectedAccount == nil || !store.hasUsableEnabledFolder)
      }
    }
  }
}

private struct UploadDropZone: View {
  let store: MacSyncStore
  let router: MacRouter
  @State private var isTargeted = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 12) {
      IconTile(symbol: "square.and.arrow.up", colors: [.blue, .cyan], size: 44)
        .symbolEffect(.bounce, value: isTargeted && !reduceMotion)
      VStack(spacing: 4) {
        Text("Upload Photos or Files")
          .font(.headline)
        Text("Drop photos, videos, or folders here.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Text("JPG · HEIC · PNG · RAW · MP4 · MOV · Live Photos")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Choose Photos or Files…", systemImage: "folder.badge.plus") { router.isChoosingMedia = true }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 22)
    .padding(.horizontal, 28)
    .glassCard()
    .overlay {
      // A faint dashed edge at rest says "drop here"; it lights up while targeted.
      RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        .strokeBorder(
          isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
          style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [6, 5])
        )
        .padding(6)
        .allowsHitTesting(false)
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isTargeted)
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard !files.isEmpty else { return false }
      store.importFiles(files)
      return true
    } isTargeted: {
      isTargeted = $0
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Upload drop area")
  }
}
