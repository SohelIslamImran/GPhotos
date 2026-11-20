import CoreGraphics
import Foundation
import QuickLookThumbnailing
import SwiftUI
#if os(iOS)
  import Photos
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Concurrency limiter bounding simultaneous background thumbnail generations.
public actor AsyncSemaphore {
  public let maxPermits: Int
  public private(set) var availablePermits: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(maxPermits: Int) {
    let limit = max(1, maxPermits)
    self.maxPermits = limit
    self.availablePermits = limit
  }

  public func wait() async {
    if availablePermits > 0 {
      availablePermits -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  public func signal() {
    if !waiters.isEmpty {
      let next = waiters.removeFirst()
      next.resume()
    } else if availablePermits < maxPermits {
      availablePermits += 1
    }
  }

  public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
    await wait()
    defer { signal() }
    return try await operation()
  }
}

/// In-memory thumbnail cache and loader with request coalescing, concurrency limits,
/// and security-scoped folder access.
@MainActor
public final class MediaThumbnailLoader {
  public static let shared = MediaThumbnailLoader()

  public static let countLimit = 400
  public static let totalCostLimit = 24 * 1024 * 1024  // 24 MB
  public static let maxConcurrentJobs = 4

  /// Opens security-scoped access to the folder holding a file. The app picks the
  /// folder on the main actor from cached roots and returns an opener; the opener runs
  /// off the main actor (it resolves a bookmark) and returns the matching stop closure.
  public var fileAccess: (@MainActor (URL) -> FileAccessOpener?)?

  public typealias FileAccessOpener = @Sendable () -> (@Sendable () -> Void)?

  private let cache: NSCache<NSString, CachedThumbnail> = {
    let cache = NSCache<NSString, CachedThumbnail>()
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
    return cache
  }()

  private let semaphore = AsyncSemaphore(maxPermits: maxConcurrentJobs)
  private var inFlightTasks: [String: Task<CGImage?, Never>] = [:]
  /// Rows waiting on each in-flight key. Generation is cancelled only when the last one
  /// leaves, so one row scrolling away does not blank another showing the same item.
  private var waiterCounts: [String: Int] = [:]

  public init() {
    #if os(iOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didReceiveMemoryWarning),
        name: UIApplication.didReceiveMemoryWarningNotification,
        object: nil
      )
      // A suspended app holding less memory is less likely to be ended; the visible
      // rows reload cheaply on return.
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didReceiveMemoryWarning),
        name: UIApplication.didEnterBackgroundNotification,
        object: nil
      )
    #endif
  }

  #if os(iOS)
    @objc private func didReceiveMemoryWarning() {
      cache.removeAllObjects()
    }
  #endif

  nonisolated public static func cacheKey(for record: TransferRecord, pixelSize: Int) -> String {
    let modified = record.assetModifiedAt ?? record.sourceModifiedAt
    let seconds = Int64(modified?.timeIntervalSince1970 ?? 0)
    return "\(record.id)|\(pixelSize)|\(seconds)"
  }

  nonisolated public static func cost(pixelWidth: Int, pixelHeight: Int) -> Int {
    pixelWidth * pixelHeight * 4
  }

  public func cachedImage(for key: String) -> CGImage? {
    cache.object(forKey: key as NSString)?.cgImage
  }

  public func loadThumbnail(
    for record: TransferRecord,
    pointSize: CGFloat,
    scale: CGFloat
  ) async -> CGImage? {
    let pixelSize = max(1, Int(pointSize * scale))
    let key = Self.cacheKey(for: record, pixelSize: pixelSize)

    if let cached = cache.object(forKey: key as NSString) {
      return cached.cgImage
    }

    let task: Task<CGImage?, Never>
    if let inFlight = inFlightTasks[key] {
      task = inFlight
    } else {
      task = Task<CGImage?, Never> { [weak self, record] in
        guard let self else { return nil }
        return await self.semaphore.withPermit {
          guard !Task.isCancelled else { return nil }
          return await self.generate(for: record, pointSize: pointSize, scale: scale, pixelSize: pixelSize)
        }
      }
      inFlightTasks[key] = task
    }
    waiterCounts[key, default: 0] += 1

    let image = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      Task { @MainActor in self.leave(key, task: task, cancelled: true) }
    }
    leave(key, task: task, cancelled: false)

    if let image, cache.object(forKey: key as NSString) == nil {
      let cost = Self.cost(pixelWidth: image.width, pixelHeight: image.height)
      cache.setObject(CachedThumbnail(cgImage: image), forKey: key as NSString, cost: cost)
    }
    return image
  }

  /// A cancelled waiter gives up its share; the first waiter to receive the value
  /// clears the entry for everyone.
  private func leave(_ key: String, task: Task<CGImage?, Never>, cancelled: Bool) {
    guard inFlightTasks[key] == task, let count = waiterCounts[key] else { return }
    if cancelled {
      if count <= 1 {
        task.cancel()
        inFlightTasks[key] = nil
        waiterCounts[key] = nil
      } else {
        waiterCounts[key] = count - 1
      }
    } else if !task.isCancelled {
      inFlightTasks[key] = nil
      waiterCounts[key] = nil
    }
  }

  private func generate(
    for record: TransferRecord,
    pointSize: CGFloat,
    scale: CGFloat,
    pixelSize: Int
  ) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    guard record.status != .deleted else { return nil }

    #if os(iOS)
      // (a) iOS only: PHAsset by assetLocalIdentifier
      if let identifier = record.assetLocalIdentifier, !identifier.isEmpty {
        if let image = await Self.fetchPhotoKitThumbnail(identifier: identifier, pixelSize: pixelSize) {
          return image
        }
      }
    #endif

    guard !Task.isCancelled else { return nil }

    // (b) File at sourcePath (if it exists)
    if let sourcePath = record.sourcePath, !sourcePath.isEmpty {
      let fileURL = URL(fileURLWithPath: sourcePath)
      let opener = fileAccess?(fileURL)
      let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
        let stopAccess = opener?()
        defer { stopAccess?() }
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return await Self.generateQuickLookThumbnail(for: fileURL, pointSize: pointSize, scale: scale)
      }
      if let image = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() }) {
        return image
      }
    }

    // (c) Nothing -> placeholder
    return nil
  }

  #if os(iOS)
    private static func fetchPhotoKitThumbnail(identifier: String, pixelSize: Int) async -> CGImage? {
      await Task.detached(priority: .userInitiated) { () -> CGImage? in
        guard !Task.isCancelled else { return nil }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let targetSize = CGSize(width: pixelSize, height: pixelSize)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        nonisolated(unsafe) var requestID: PHImageRequestID?
        let manager = PHImageManager.default()

        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            let id = manager.requestImage(
              for: asset,
              targetSize: targetSize,
              contentMode: .aspectFill,
              options: options
            ) { image, info in
              let isCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
              let isError = info?[PHImageErrorKey] != nil
              if isCancelled || isError {
                continuation.resume(returning: nil)
              } else {
                continuation.resume(returning: image?.cgImage)
              }
            }
            requestID = id
          }
        } onCancel: {
          if let requestID {
            manager.cancelImageRequest(requestID)
          }
        }
      }.value
    }
  #endif

  nonisolated private static func generateQuickLookThumbnail(
    for url: URL,
    pointSize: CGFloat,
    scale: CGFloat
  ) async -> CGImage? {
    nonisolated(unsafe) let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: pointSize, height: pointSize),
      scale: scale,
      representationTypes: .thumbnail
    )
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

/// A thumbnail tile for a transfer record with media badges and placeholder fallback.
public struct MediaThumbnailView: View {
  public let record: TransferRecord
  public let size: CGFloat

  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var image: CGImage?

  public init(record: TransferRecord, size: CGFloat) {
    self.record = record
    self.size = size
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    let pixelSize = max(1, Int(size * displayScale))
    let key = MediaThumbnailLoader.cacheKey(for: record, pixelSize: pixelSize)

    ZStack {
      if let image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(shape)
      } else {
        shape
          .fill(.quaternary)
          .frame(width: size, height: size)
          .overlay {
            Image(systemName: record.mediaSymbol)
              .font(.system(size: size * 0.42, weight: .regular))
              .foregroundStyle(.secondary)
          }
      }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
    .overlay(alignment: .bottomLeading) {
      if record.isLivePhoto {
        Image(systemName: "livephoto")
          .font(.system(size: max(8, size * 0.26), weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
          .padding(size * 0.08)
      } else if record.isVideo {
        Image(systemName: "play.fill")
          .font(.system(size: max(8, size * 0.26), weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
          .padding(size * 0.08)
      }
    }
    .animation(reduceMotion ? nil : .smooth, value: image != nil)
    .accessibilityHidden(true)
    .task(id: key) {
      image = MediaThumbnailLoader.shared.cachedImage(for: key)
      guard record.status != .deleted else {
        image = nil
        return
      }
      let loaded = await MediaThumbnailLoader.shared.loadThumbnail(
        for: record,
        pointSize: size,
        scale: displayScale
      )
      if !Task.isCancelled {
        image = loaded
      }
    }
  }
}

/// A file in flight: its thumbnail once the record is known, a media placeholder until then.
struct UploadThumbnail: View {
  let record: TransferRecord?
  let filename: String
  let size: CGFloat

  var body: some View {
    if let record {
      MediaThumbnailView(record: record, size: size)
    } else {
      RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        .fill(.quaternary)
        .frame(width: size, height: size)
        .overlay {
          Image(systemName: SupportedMediaFormats.isVideo(filename: filename) ? "video.fill" : "photo.fill")
            .font(.system(size: size * 0.42))
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
  }
}

extension TransferRecord {
  public var isVideo: Bool {
    SupportedMediaFormats.isVideo(filename: filename) || mediaType.caseInsensitiveCompare("Video") == .orderedSame
  }

  public var isLivePhoto: Bool {
    mediaType == "Live Photo" || pairedSourcePath != nil
  }

  public var mediaSymbol: String {
    isVideo ? "video.fill" : "photo.fill"
  }
}

// MARK: - Internal Helpers

private final class CachedThumbnail: @unchecked Sendable {
  let cgImage: CGImage
  init(cgImage: CGImage) {
    self.cgImage = cgImage
  }
}
