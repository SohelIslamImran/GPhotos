import QuickLookThumbnailing
import SwiftUI

/// The share-extension UI, one implementation for iOS and macOS.
public struct ShareStagingView: View {
  @Bindable private var model: ShareStagingModel
  private let complete: () -> Void
  private let cancel: () -> Void
  #if os(macOS)
    @ScaledMetric(relativeTo: .title2) private var emblem: CGFloat = 40
  #else
    @ScaledMetric(relativeTo: .title2) private var emblem: CGFloat = 48
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(model: ShareStagingModel, complete: @escaping () -> Void, cancel: @escaping () -> Void) {
    self.model = model
    self.complete = complete
    self.cancel = cancel
  }

  public var body: some View {
    #if os(macOS)
      compactBody
    #else
      listBody
    #endif
  }

  #if os(macOS)
    /// A Mac share sheet is small and sized to its content, like the system's own
    /// (Notes, Reminders): a header, a strip of previews, a summary and the buttons.
    private var compactBody: some View {
      VStack(alignment: .leading, spacing: 14) {
        compactHeader
        if let error = model.errorMessage {
          InlineMessage(error)
        }
        if model.items.isEmpty {
          if model.errorMessage == nil {
            HStack(spacing: 8) {
              if model.isProcessing {
                ProgressView()
                  .controlSize(.small)
              }
              Text(model.statusMessage)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          ShareThumbnailStrip(items: model.items)
          Text("^[\(model.items.count) item](inflect: true) · \(ByteFormat.string(model.totalBytes))")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        HStack {
          Spacer()
          if model.isFinished {
            Button("Done", action: complete)
              .buttonStyle(.glassProminent)
              .keyboardShortcut(.defaultAction)
          } else {
            Button("Cancel", action: cancelShare)
              .keyboardShortcut(.cancelAction)
              .disabled(model.isProcessing)
            uploadButton
              .keyboardShortcut(.defaultAction)
          }
        }
        .controlSize(.large)
        .padding(.top, 4)
      }
      .padding(20)
      .frame(width: 380, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: model.errorMessage) { _, message in
        if let message { AccessibilityNotification.Announcement(message).post() }
      }
    }

    private var compactHeader: some View {
      HStack(spacing: 12) {
        headerEmblem
        VStack(alignment: .leading, spacing: 3) {
          Text(model.isFinished ? "Added to \(ProductCopy.name)" : "Upload to Google Photos")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          if model.isProcessing, model.totalBytes > 0 {
            ProgressView(value: model.progress)
              .controlSize(.small)
            Text("\(ByteFormat.string(model.processedBytes)) of \(ByteFormat.string(model.totalBytes))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          } else {
            Text(model.isFinished ? "They’ll upload in original quality." : ProductCopy.originalQuality)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.isFinished)
    }
  #endif

  private var listBody: some View {
    NavigationStack {
      List {
        Section {
          header
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)

        if let error = model.errorMessage {
          Section {
            InlineMessage(error)
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          .listRowSeparator(.hidden)
        }

        Section {
          if model.items.isEmpty, model.errorMessage == nil {
            HStack(spacing: 10) {
              if model.isProcessing {
                ProgressView()
                  .controlSize(.small)
              }
              Text(model.statusMessage)
                .foregroundStyle(.secondary)
            }
          }
          ForEach(model.items) { item in
            ShareItemRow(item: item)
          }
        } header: {
          if !model.items.isEmpty {
            HStack {
              Text("Ready to Upload")
              Spacer()
              Text("^[\(model.items.count) item](inflect: true) · \(ByteFormat.string(model.totalBytes))")
                .monospacedDigit()
            }
          }
        }
      }
      .navigationTitle(ProductCopy.name)
      .onChange(of: model.errorMessage) { _, message in
        if let message { AccessibilityNotification.Announcement(message).post() }
      }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if model.isFinished {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done", systemImage: "checkmark", action: complete)
                .buttonStyle(.glassProminent)
            }
          } else {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", systemImage: "xmark", action: cancelShare)
                .disabled(model.isProcessing)
            }
            ToolbarItem(placement: .confirmationAction) {
              uploadButton
            }
          }
        }
      #endif
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      headerEmblem
      VStack(alignment: .leading, spacing: 4) {
        Text(model.isFinished ? "Added to \(ProductCopy.name)" : "Upload to Google Photos")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        if model.isProcessing {
          if model.totalBytes > 0 {
            ProgressView(value: model.progress)
            Text("\(ByteFormat.string(model.processedBytes)) of \(ByteFormat.string(model.totalBytes))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          } else {
            Text(model.statusMessage)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(model.isFinished ? "They’ll upload in original quality." : ProductCopy.originalQuality)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard()
    .accessibilityElement(children: .combine)
    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.isFinished)
  }

  /// The Google Photos logo, replaced by a green check that draws on once the items are queued.
  private var headerEmblem: some View {
    let size = min(emblem, 64)
    return ZStack {
      Image("GooglePhotosLogo", bundle: .main)
        .resizable()
        .scaledToFit()
        .frame(width: size * 0.64, height: size * 0.64)
        .frame(width: size, height: size)
        .background {
          RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(.white)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .opacity(model.isFinished ? 0 : 1)
        .scaleEffect(model.isFinished ? 0.85 : 1)
      Circle()
        .fill(.green)
        .frame(width: size, height: size)
        .opacity(model.isFinished ? 1 : 0)
        .scaleEffect(model.isFinished ? 1 : 0.85)
      if model.isFinished {
        Image(systemName: "checkmark")
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(.white)
          .transition(.symbolEffect(.drawOn))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var uploadButton: some View {
    Button {
      Task {
        if await model.queueUploads() { complete() }
      }
    } label: {
      Text("Upload")
        .opacity(model.isProcessing ? 0 : 1)
        .overlay {
          if model.isProcessing {
            ProgressView()
              .controlSize(.small)
          }
        }
    }
    .buttonStyle(.glassProminent)
    .disabled(!model.canQueue)
    .accessibilityValue(model.isProcessing ? "Preparing" : "")
  }

  private func cancelShare() {
    model.cleanupTempFiles()
    cancel()
  }
}

private struct ShareItemRow: View {
  let item: ShareItem
  @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 44

  var body: some View {
    HStack(spacing: 12) {
      preview
      VStack(alignment: .leading, spacing: 2) {
        Text(item.filename)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("\(item.mediaType.title) · \(ByteFormat.string(item.byteCount))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if item.mediaType == .raw {
        Text("RAW")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: .capsule)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("\(item.filename), \(item.mediaType.title), \(ByteFormat.string(item.byteCount))"))
  }

  private var preview: some View {
    ShareThumbnailTile(item: item, size: tileSize)
  }
}

/// One shared item's Quick Look thumbnail, or its media icon until (or unless) one loads.
private struct ShareThumbnailTile: View {
  let item: ShareItem
  let size: CGFloat
  @Environment(\.displayScale) private var displayScale
  @State private var thumbnail: CGImage?

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
    Group {
      if let thumbnail {
        Image(decorative: thumbnail, scale: displayScale)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(shape)
          .overlay(alignment: .bottomTrailing) {
            if item.mediaType == .video {
              Image(systemName: "video.fill")
                .font(.system(size: size * 0.2, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .padding(4)
            }
          }
      } else {
        IconTile(symbol: item.mediaType.systemImage, colors: item.mediaType.colors, size: size)
      }
    }
    .accessibilityHidden(true)
    // `.task` is cancelled when the tile disappears, which cancels the request.
    .task(id: item.id) {
      guard thumbnail == nil else { return }
      thumbnail = await ShareThumbnail.load(for: item.url, scale: displayScale)
    }
  }
}

/// A row of previews for the compact Mac sheet; extra items collapse into a "+N" tile.
private struct ShareThumbnailStrip: View {
  let items: [ShareItem]
  private let size: CGFloat = 56
  private let maxTiles = 5

  var body: some View {
    let shown = items.count > maxTiles ? Array(items.prefix(maxTiles - 1)) : items
    HStack(spacing: 8) {
      ForEach(shown) { item in
        ShareThumbnailTile(item: item, size: size)
      }
      if items.count > shown.count {
        Text("+\(items.count - shown.count)")
          .font(.headline)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
          .background(.quaternary, in: .rect(cornerRadius: size * 0.18, style: .continuous))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("^[\(items.count) item](inflect: true)"))
  }
}

/// Quick Look thumbnails for the shared files, which are already private copies on disk.
private enum ShareThumbnail {
  /// Twice the 44 pt tile, so a non-square image still fills it after cropping.
  private static let size = CGSize(width: 88, height: 88)

  static func load(for url: URL, scale: CGFloat) async -> CGImage? {
    // Both are used from the cancellation handler too; the generator is documented as
    // thread-safe and the request is not mutated after creation.
    nonisolated(unsafe) let request = QLThumbnailGenerator.Request(
      fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
    nonisolated(unsafe) let generator = QLThumbnailGenerator.shared
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
        generator.generateBestRepresentation(for: request) { representation, _ in
          continuation.resume(returning: representation?.cgImage)
        }
      }
    } onCancel: {
      generator.cancel(request)
    }
  }
}

extension ShareItem.ShareMediaType {
  fileprivate var title: String {
    switch self {
    case .photo: String(localized: "Photo")
    case .video: String(localized: "Video")
    case .raw: String(localized: "RAW Photo")
    }
  }

  fileprivate var colors: [Color] {
    switch self {
    case .photo: [.blue, .cyan]
    case .video: [.purple, .pink]
    case .raw: [.orange, .yellow]
    }
  }
}
