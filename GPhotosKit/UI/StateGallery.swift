#if DEBUG
  import SwiftUI

  /// Every status and row state rendered with the real components, for design review of
  /// states that need an account or a running transfer to reach. Debug builds only.
  public struct StateGallery: View {
    public init() {}

    private static let statuses: [BackupStatus] = [
      .signedOut, .credentialsUnavailable("This build can’t access the keychain. Reinstall a signed build."),
      .needsSource(.photosAccessNeeded(canPrompt: true)), .needsSource(.photosAccessNeeded(canPrompt: false)),
      .needsSource(.noFolders), .needsSource(.foldersBlocked(count: 2)), .scanning(.folders),
      .syncing(itemCount: 12), .waitingForNetwork, .rateLimited, .paused, .stopping, .failed(count: 3), .waiting(count: 5),
      .albumsNeedAttention("Uploaded, but 2 albums could not be updated."), .autoSyncOff, .stopped,
      .needsSource(.limitedPhotosAccess), .cleanedUp("Clean Up complete: 14 files removed."), .upToDate,
    ]

    private static let records: [TransferRecord] = [
      TransferRecord(id: "1", filename: "IMG_4021.HEIC", mediaType: "photo", status: .sent, byteCount: 3_200_000, sentAt: .now),
      TransferRecord(
        id: "2", filename: "IMG_4022.MOV", mediaType: "video", status: .sent, byteCount: 88_000_000, sentAt: .now,
        lastError: "Already in Google Photos"),
      TransferRecord(
        id: "3", filename: "Vacation-Highlights-Final-Export.mp4", mediaType: "video", status: .sending, byteCount: 512_000_000),
      TransferRecord(id: "4", filename: "IMG_4023.JPG", mediaType: "photo", status: .pending, byteCount: 2_100_000),
      TransferRecord(
        id: "5", filename: "DSC_0098.NEF", mediaType: "photo", status: .failed, byteCount: 24_000_000,
        lastError: "The network connection was lost."),
      TransferRecord(id: "6", filename: "IMG_3990.HEIC", mediaType: "photo", status: .deleted, byteCount: 2_900_000, sentAt: .now),
    ]

    public var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(Self.statuses.enumerated()), id: \.offset) { _, status in
            let showsProgress = status.isActive || status == .waitingForNetwork || status == .rateLimited
            StatusCard(status: status, progress: showsProgress ? Self.progress : nil) {
              Button("Action") {}
                .buttonStyle(.glassProminent)
            }
          }
          GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
              StatTile("In Progress", value: 12, detail: "12 waiting", symbol: "clock.arrow.circlepath", tint: .blue) {}
              StatTile("Uploaded", value: 1_204, detail: "47.6 GB", symbol: "checkmark.circle.fill", tint: .green) {}
              StatTile("Failed", value: 0, detail: "None", symbol: "exclamationmark.triangle", tint: .secondary) {}
            }
          }
          VStack(spacing: 12) {
            ForEach(Self.records) { record in
              ActivityRow(record: record, worker: nil, onRetry: {})
            }
          }
          .padding()
          .glassCard()
          InlineMessage("The clipboard doesn’t contain a Google token.")
          InlineMessage("macOS needs your approval in Login Items.", style: .info)
        }
        .padding(20)
      }
      .background { AmbientBackground(tint: .blue) }
    }

    private static var progress: TransferProgressSummary {
      TransferProgressSummary(fraction: 0.42, filename: "IMG_4022.MOV", remaining: "2 min left", speed: "8.4 MB/s")
    }
  }
#endif
