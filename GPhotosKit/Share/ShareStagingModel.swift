import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Share Item

public struct ShareItem: Identifiable, Sendable {
  public enum ShareMediaType: Sendable {
    case photo
    case video
    case raw

    var systemImage: String {
      switch self {
      case .photo: return "photo.fill"
      case .video: return "video.fill"
      case .raw: return "camera.aperture"
      }
    }
  }

  public let id: UUID = UUID()
  public let url: URL
  public let filename: String
  public let byteCount: Int64
  public let mediaType: ShareMediaType

  public init(url: URL, filename: String, byteCount: Int64, mediaType: ShareMediaType) {
    self.url = url
    self.filename = filename
    self.byteCount = byteCount
    self.mediaType = mediaType
  }
}

// MARK: - Share Staging Model

/// Copies the host's attachments into the shared incoming queue and records them so the
/// main app can pick them up. Shared by the iOS and macOS share extensions so both
/// present identical behaviour.
@MainActor
@Observable
public final class ShareStagingModel {
  public private(set) var items: [ShareItem] = []
  public private(set) var statusMessage = "Preparing files..."
  public private(set) var isProcessing = false
  public private(set) var isFinished = false
  public private(set) var progress: Double = 0.0
  public private(set) var processedBytes: Int64 = 0
  public private(set) var totalBytes: Int64 = 0
  public private(set) var errorMessage: String?
  /// Distinguishes "not started" from "started and found nothing", so a host that
  /// re-appears cannot kick off a second scan.
  public private(set) var hasLoadedAttachments = false

  public var canQueue: Bool {
    !items.isEmpty && !isProcessing && !isFinished
  }

  public init() {}

  public func loadAttachments(from context: NSExtensionContext?) async {
    guard !hasLoadedAttachments else { return }
    hasLoadedAttachments = true
    isProcessing = true
    defer { isProcessing = false }
    guard let inputItems = context?.inputItems as? [NSExtensionItem],
      !inputItems.isEmpty
    else {
      statusMessage = "No shareable items found."
      return
    }

    let providers = inputItems.compactMap { $0.attachments }.flatMap { $0 }
    guard !providers.isEmpty else {
      statusMessage = "No items attached."
      return
    }

    statusMessage = "Scanning \(providers.count) item\(providers.count == 1 ? "" : "s")..."
    var loaded: [ShareItem] = []
    var skippedForSpace = 0
    for provider in providers {
      switch await loadItem(from: provider) {
      case .loaded(let item): loaded.append(item)
      case .insufficientSpace: skippedForSpace += 1
      case .unsupported: break
      }
    }

    items = loaded
    totalBytes = loaded.reduce(0) { $0 + $1.byteCount }

    if skippedForSpace > 0 {
      errorMessage =
        "Not enough free space to prepare \(skippedForSpace) item\(skippedForSpace == 1 ? "" : "s"). "
        + "Free up storage and share again."
    }
    if loaded.isEmpty {
      statusMessage =
        skippedForSpace > 0 ? "Not enough free space." : "No compatible photo or video files found."
    } else {
      statusMessage = "\(loaded.count) item\(loaded.count == 1 ? "" : "s") ready to upload."
    }
  }

  public func queueUploads() async -> Bool {
    guard canQueue else { return false }

    isProcessing = true
    errorMessage = nil
    progress = 0.0
    processedBytes = 0

    var stagedURLs: [URL] = []
    do {
      // Staging into a private container would report success and lose every file,
      // so refuse rather than silently degrade.
      guard AppGroupConstants.isUsingSharedContainer() else {
        throw CocoaError(
          .fileNoSuchFile,
          userInfo: [
            NSLocalizedDescriptionKey:
              "This build cannot reach the shared upload queue. The App Group "
              + "\(AppGroupConstants.identifier) is not enabled for this platform, "
              + "so the extension and the app are given separate private folders."
          ])
      }
      try SharedQueueBridge.ensureDirectories()
      statusMessage = "Preparing files..."

      let incomingDirectory = SharedQueueBridge.incomingDirectory
      let sourceItems = items
      // Moving within a volume needs no space, but across volumes it is a full copy.
      if let first = sourceItems.first, !Self.isSameVolume(first.url, incomingDirectory) {
        try Self.ensureFreeSpace(for: totalBytes, at: incomingDirectory)
      }
      // Moving and hashing multi-gigabyte media must stay off the main actor.
      let prepared = try await Task.detached(priority: .utility) {
        try Self.prepare(items: sourceItems, incomingDirectory: incomingDirectory)
      }.value

      stagedURLs = prepared.stagedURLs
      // Use the re-measured total so the byte readout cannot exceed 100%.
      if prepared.bytes > 0 { totalBytes = prepared.bytes }
      progress = 1.0
      processedBytes = prepared.bytes

      // `appendEntries` already posts the notification the host observes.
      try SharedQueueBridge.appendEntries(prepared.entries)
      statusMessage = "Added to Pending."
      isProcessing = false
      isFinished = true
      progress = 1.0

      cleanupTempFiles()

      ShareSuccessFeedback.perform()

      // Brief beat so the success state is visible before the host dismisses us.
      try? await Task.sleep(for: .milliseconds(600))
      return true
    } catch {
      for url in stagedURLs {
        try? FileManager.default.removeItem(at: url)
      }
      cleanupTempFiles()
      errorMessage = error.localizedDescription
      statusMessage = "Failed to prepare items."
      isProcessing = false
      return false
    }
  }

  public func cleanupTempFiles() {
    for item in items {
      try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
    }
  }

  // MARK: - Staging

  private struct PreparedBatch: Sendable {
    let entries: [SharedUploadEntry]
    let stagedURLs: [URL]
    let bytes: Int64
  }

  nonisolated private static func prepare(
    items: [ShareItem],
    incomingDirectory: URL
  ) throws -> PreparedBatch {
    var entries: [SharedUploadEntry] = []
    var stagedURLs: [URL] = []
    var bytes: Int64 = 0

    do {
      for item in items {
        let entryID = UUID()
        let ext = item.url.pathExtension
        let storedName = entryID.uuidString + (ext.isEmpty ? ".dat" : ".\(ext)")
        let destinationURL = incomingDirectory.appendingPathComponent(storedName)
        // The item is already a private copy made while loading, so it is moved, not
        // copied a second time.
        try FileManager.default.moveItem(at: item.url, to: destinationURL)
        stagedURLs.append(destinationURL)

        let sha1Base64 = try SharedQueueBridge.sha1Fingerprint(forFileAt: destinationURL)
        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        let bytesTotal = values.fileSize.map(Int64.init) ?? item.byteCount
        entries.append(
          SharedUploadEntry(
            id: entryID,
            fileName: item.filename,
            relativePath: storedName,
            bytesTotal: bytesTotal,
            sha1Base64: sha1Base64
          ))
        bytes += bytesTotal
      }
      return PreparedBatch(entries: entries, stagedURLs: stagedURLs, bytes: bytes)
    } catch {
      for url in stagedURLs {
        try? FileManager.default.removeItem(at: url)
      }
      throw error
    }
  }

  // MARK: - Free Space

  /// Kept free beyond the payload so staging cannot fill the disk completely.
  private nonisolated static let freeSpaceHeadroom: Int64 = 200 * 1024 * 1024

  nonisolated static func hasFreeSpace(for bytes: Int64, at url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
    return available >= bytes + freeSpaceHeadroom
  }

  nonisolated private static func ensureFreeSpace(for bytes: Int64, at url: URL) throws {
    guard hasFreeSpace(for: bytes, at: url) else {
      throw CocoaError(
        .fileWriteOutOfSpace,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Not enough free space to add these items. Free up "
            + ByteCountFormatter.string(fromByteCount: bytes + freeSpaceHeadroom, countStyle: .file)
            + " and try again."
        ])
    }
  }

  nonisolated private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
    let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    guard let left, let right else { return false }
    return left.isEqual(right)
  }

  // MARK: - File Extraction

  /// Reduces a host-supplied name to a single safe path component.
  ///
  /// The result is only ever used as a display name and as the remote filename, never
  /// as a path, but it still must not be able to carry a separator or control character
  /// out of the shared queue.
  nonisolated static func sanitizedFilename(_ raw: String) -> String {
    // `lastPathComponent` collapses any path, so no traversing name can survive it.
    let base = URL(fileURLWithPath: raw).lastPathComponent
    let cleaned = String(
      base.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar) && scalar != "/"
      }
    )
    return cleaned.isEmpty ? "shared-media" : cleaned
  }

  private enum LoadOutcome {
    case loaded(ShareItem)
    case insufficientSpace
    case unsupported
  }

  private func loadItem(from provider: NSItemProvider) async -> LoadOutcome {
    // Ordered most specific first: a Live Photo is also an image, and a raw file is
    // also an image, so the general cases must come last.
    let supportedTypeIdentifiers: [(UTType, ShareItem.ShareMediaType)] = [
      (.movie, .video),
      (.video, .video),
      (.quickTimeMovie, .video),
      (.mpeg4Movie, .video),
      (.livePhoto, .photo),
      (.rawImage, .raw),
      (.image, .photo),
      (.heic, .photo),
      (.png, .photo),
      (.jpeg, .photo),
    ]

    for (type, _) in supportedTypeIdentifiers
    where provider.hasItemConformingToTypeIdentifier(
      type.identifier)
    {
      let outcome = await loadItemRepresentation(from: provider, typeIdentifier: type.identifier)
      if case .unsupported = outcome { continue }
      return outcome
    }
    return .unsupported
  }

  private func loadItemRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> LoadOutcome {
    let suggestedName = provider.suggestedName
    return await withCheckedContinuation { (continuation: CheckedContinuation<LoadOutcome, Never>) in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
        guard let sourceURL, error == nil else {
          continuation.resume(returning: .unsupported)
          return
        }

        let sourceExtension = sourceURL.pathExtension
        let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName: String
        if let suggested, !suggested.isEmpty {
          if URL(fileURLWithPath: suggested).pathExtension.isEmpty && !sourceExtension.isEmpty {
            originalName = "\(suggested).\(sourceExtension)"
          } else {
            originalName = suggested
          }
        } else {
          originalName = sourceURL.lastPathComponent
        }
        // Eligibility is decided by the file on disk: `suggestedName` is a label the
        // host app controls, so trusting it would let a host pass off an unsupported
        // payload under a supported-looking name.
        guard SupportedMediaFormats.isSupported(filename: sourceURL.lastPathComponent) else {
          continuation.resume(returning: .unsupported)
          return
        }

        let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
          continuation.resume(returning: .unsupported)
          return
        }

        guard SupportedMediaFormats.isMediaContent(fileURL: sourceURL) else {
          continuation.resume(returning: .unsupported)
          return
        }
        // The provider deletes `sourceURL` when this handler returns, so a copy is
        // unavoidable; refuse up front rather than fail halfway through a large video.
        let temporaryRoot = FileManager.default.temporaryDirectory
        guard Self.hasFreeSpace(for: Int64(values?.fileSize ?? 0), at: temporaryRoot) else {
          continuation.resume(returning: .insufficientSpace)
          return
        }
        let tempDir = temporaryRoot.appendingPathComponent("GPhotosShare-\(UUID().uuidString)", isDirectory: true)

        do {
          try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
          let storedName = UUID().uuidString + (sourceExtension.isEmpty ? ".dat" : ".\(sourceExtension)")
          let destinationURL = tempDir.appendingPathComponent(storedName)
          try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

          let copiedValues = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
          let size = Int64(copiedValues.fileSize ?? 0)
          let extensionName = sourceExtension.lowercased()
          let mediaType: ShareItem.ShareMediaType
          if SupportedMediaFormats.isVideo(filename: sourceURL.lastPathComponent) {
            mediaType = .video
          } else if SupportedMediaFormats.rawExtensions.contains(extensionName) {
            mediaType = .raw
          } else {
            mediaType = .photo
          }

          continuation.resume(
            returning: .loaded(
              ShareItem(
                url: destinationURL,
                filename: Self.sanitizedFilename(originalName),
                byteCount: size,
                mediaType: mediaType
              )))
        } catch {
          try? FileManager.default.removeItem(at: tempDir)
          let outOfSpace = (error as? CocoaError)?.code == .fileWriteOutOfSpace
          continuation.resume(returning: outOfSpace ? .insufficientSpace : .unsupported)
        }
      }
    }
  }
}

// MARK: - Previews

#if DEBUG
  extension ShareStagingModel {
    public enum PreviewState: Sendable {
      case loading
      case ready
      case preparing
      case finished
      case error

      /// The state for a `-UIScreen` review hook (`share`, `shareLoading`, `sharePreparing`,
      /// `shareDone`, `shareError`), or nil for any other screen.
      public init?(screen: String?) {
        switch screen {
        case "share": self = .ready
        case "shareLoading": self = .loading
        case "sharePreparing": self = .preparing
        case "shareDone": self = .finished
        case "shareError": self = .error
        default: return nil
        }
      }
    }

    /// A model in a fixed state for UI review. The files do not exist, so rows fall back
    /// to their icon tiles.
    public static func preview(_ state: PreviewState) -> ShareStagingModel {
      let model = ShareStagingModel()
      model.hasLoadedAttachments = true
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GPhotosSharePreview", isDirectory: true)
      let samples: [(String, Int64, ShareItem.ShareMediaType)] = [
        ("IMG_0001.HEIC", 2_412_000, .photo),
        ("IMG_0002.HEIC", 3_087_000, .photo),
        ("IMG_0004.JPG", 4_560_000, .photo),
        ("IMG_0003.MOV", 12_400_000, .video),
        ("DSC_0142.DNG", 24_800_000, .raw),
      ]
      let items = samples.map { name, bytes, type in
        ShareItem(url: folder.appendingPathComponent(name), filename: name, byteCount: bytes, mediaType: type)
      }

      switch state {
      case .loading:
        model.isProcessing = true
        model.statusMessage = "Scanning 5 items..."
      case .ready:
        model.load(items)
      case .preparing:
        model.load(items)
        model.isProcessing = true
        model.statusMessage = "Preparing files..."
        model.progress = 0.4
        model.processedBytes = Int64(Double(model.totalBytes) * 0.4)
      case .finished:
        model.load(items)
        model.statusMessage = "Added to Pending."
        model.isFinished = true
        model.progress = 1
        model.processedBytes = model.totalBytes
      case .error:
        model.load(Array(items.prefix(2)))
        model.errorMessage =
          "Not enough free space to prepare 3 items. Free up storage and share again."
      }
      return model
    }

    private func load(_ items: [ShareItem]) {
      self.items = items
      totalBytes = items.reduce(0) { $0 + $1.byteCount }
      statusMessage = "\(items.count) item\(items.count == 1 ? "" : "s") ready to upload."
    }
  }
#endif

// MARK: - Success Feedback

private enum ShareSuccessFeedback {
  @MainActor
  static func perform() {
    #if os(macOS)
      // AppKit has no success pattern — only generic, alignment and level change — so
      // `.generic` is the closest confirmation the platform offers.
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    #else
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }
}
