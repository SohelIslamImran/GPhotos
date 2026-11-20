import CoreGraphics
import Foundation
import os

#if canImport(UIKit)
  import UIKit
#endif

/// Something that can produce images for item identifiers: the photo library, files on
/// disk, or (later) Google Photos thumbnails. Implementations deliver on any thread and
/// may deliver a degraded image before the final one.
public protocol ThumbnailSource: AnyObject, Sendable {
  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    deliver: @escaping @Sendable (CGImage, _ isFinal: Bool) -> Void
  ) -> ImageRequestToken

  /// Warms the source's own cache for items about to scroll into view.
  func startCaching(ids: [String], pixelSize: CGSize)
  func stopCaching(ids: [String], pixelSize: CGSize)
}

extension ThumbnailSource {
  public func startCaching(ids: [String], pixelSize: CGSize) {}
  public func stopCaching(ids: [String], pixelSize: CGSize) {}
}

public enum ImageRequestQuality: Sendable {
  /// Grid cells while scrolling fast: whatever is quickest, no network.
  case fast
  /// Grid cells at rest: a sharp thumbnail at the requested size.
  case thumbnail
  /// The viewer: a screen-sized image, degraded first.
  case display
}

public final class ImageRequestToken: Sendable {
  private let onCancel: (@Sendable () -> Void)?
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  public init(onCancel: (@Sendable () -> Void)? = nil) {
    self.onCancel = onCancel
  }

  public static let none = ImageRequestToken()

  public func cancel() {
    let first = cancelled.withLock { state -> Bool in
      defer { state = true }
      return !state
    }
    if first { onCancel?() }
  }

  public var isCancelled: Bool { cancelled.withLock { $0 } }
}

public struct ThumbnailKey: Hashable, Sendable {
  public let id: String
  public let bucket: ThumbnailBucket

  public init(id: String, bucket: ThumbnailBucket) {
    self.id = id
    self.bucket = bucket
  }
}

/// The grid's image cache and request coordinator. Identical requests share one source
/// request, a request is cancelled once nobody wants it, and decoded images are kept in a
/// memory cache sized from the device's RAM and emptied under memory pressure.
@MainActor
public final class ThumbnailPipeline {
  public static let shared = ThumbnailPipeline()

  private final class Entry {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private final class InFlight {
    let requestID: UInt64
    init(requestID: UInt64) { self.requestID = requestID }

    var token: ImageRequestToken = .none
    var handlers: [UInt64: (CGImage, Bool) -> Void] = [:]
  }

  private let cache = NSCache<NSString, Entry>()
  private let viewerPreviews = NSCache<NSString, Entry>()
  /// Which buckets are cached per item, so a smaller one can stand in for a larger.
  private var cachedBuckets: [String: Set<ThumbnailBucket>] = [:]
  private var storesSinceSweep = 0
  private var inFlight: [ThumbnailKey: InFlight] = [:]
  private var nextHandlerID: UInt64 = 0
  private var memoryObserver: (any NSObjectProtocol)?

  public init(costLimit: Int = ThumbnailPipeline.defaultCostLimit) {
    cache.totalCostLimit = costLimit
    viewerPreviews.countLimit = 6
    viewerPreviews.totalCostLimit = min(costLimit, 32 << 20)
    #if canImport(UIKit)
      memoryObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.removeAll() }
      }
    #endif
  }

  /// About 1/24 of RAM, between 48 and 320 MB: a few screens of thumbnails at every
  /// zoom level without pressuring the system.
  public nonisolated static var defaultCostLimit: Int {
    let share = Int(ProcessInfo.processInfo.physicalMemory / 24)
    return min(max(share, 48 << 20), 320 << 20)
  }

  /// Forgets buckets the cache has evicted, so the index doesn't grow with every item
  /// ever shown.
  private func sweepBuckets() {
    storesSinceSweep = 0
    for (id, buckets) in cachedBuckets {
      let alive = buckets.filter { cache.object(forKey: Self.cacheKey(ThumbnailKey(id: id, bucket: $0)) as NSString) != nil }
      cachedBuckets[id] = alive.isEmpty ? nil : alive
    }
  }

  public func removeAll() {
    cache.removeAllObjects()
    viewerPreviews.removeAllObjects()
    cachedBuckets.removeAll()
  }

  func viewerPreview(for id: String) -> CGImage? {
    viewerPreviews.object(forKey: id as NSString)?.image
  }

  func rememberViewerPreview(_ image: CGImage, for id: String) {
    let cost = image.bytesPerRow * image.height
    guard !id.isEmpty, cost <= 12 << 20 else { return }
    viewerPreviews.setObject(Entry(image), forKey: id as NSString, cost: cost)
  }

  public func cachedImage(for key: ThumbnailKey) -> CGImage? {
    cache.object(forKey: Self.cacheKey(key) as NSString)?.image
  }

  /// The best cached stand-in for `key`: the exact bucket, else the largest smaller one,
  /// else any larger one.
  public func placeholder(for key: ThumbnailKey) -> CGImage? {
    if let exact = cachedImage(for: key) { return exact }
    guard let buckets = cachedBuckets[key.id], !buckets.isEmpty else { return nil }
    let ordered = buckets.filter { $0 < key.bucket }.sorted(by: >) + buckets.filter { $0 > key.bucket }.sorted()
    for bucket in ordered {
      if let image = cachedImage(for: ThumbnailKey(id: key.id, bucket: bucket)) { return image }
      cachedBuckets[key.id]?.remove(bucket)
    }
    return nil
  }

  /// Calls `handler` with each image as it arrives (degraded first). Cancel the returned
  /// ticket when the image is no longer wanted.
  public func load(
    _ key: ThumbnailKey, from source: any ThumbnailSource, quality: ImageRequestQuality = .thumbnail,
    handler: @escaping (CGImage, _ isFinal: Bool) -> Void
  ) -> ThumbnailTicket {
    if let cached = cachedImage(for: key) {
      handler(cached, true)
      return ThumbnailTicket()
    }
    nextHandlerID &+= 1
    let handlerID = nextHandlerID
    if let existing = inFlight[key] {
      existing.handlers[handlerID] = handler
    } else {
      let flight = InFlight(requestID: handlerID)
      flight.handlers[handlerID] = handler
      inFlight[key] = flight
      flight.token = source.requestImage(id: key.id, pixelSize: key.bucket.pixelSize, quality: quality) {
        [weak self] image, isFinal in
        // PhotoKit delivers on the main thread; delivering right away saves a blank frame.
        if Thread.isMainThread {
          MainActor.assumeIsolated { self?.deliver(image, isFinal: isFinal, for: key, requestID: handlerID) }
        } else {
          Task { @MainActor in self?.deliver(image, isFinal: isFinal, for: key, requestID: handlerID) }
        }
      }
    }
    return ThumbnailTicket { [weak self] in self?.removeHandler(handlerID, for: key) }
  }

  private func deliver(_ image: CGImage, isFinal: Bool, for key: ThumbnailKey, requestID: UInt64) {
    guard let flight = inFlight[key], flight.requestID == requestID else { return }
    if isFinal {
      inFlight[key] = nil
      store(image, for: key)
    }
    for handler in flight.handlers.values { handler(image, isFinal) }
  }

  private func store(_ image: CGImage, for key: ThumbnailKey) {
    cache.setObject(Entry(image), forKey: Self.cacheKey(key) as NSString, cost: image.bytesPerRow * image.height)
    cachedBuckets[key.id, default: []].insert(key.bucket)
    storesSinceSweep += 1
    if storesSinceSweep >= 2_000 { sweepBuckets() }
  }

  private func removeHandler(_ handlerID: UInt64, for key: ThumbnailKey) {
    guard let flight = inFlight[key] else { return }
    flight.handlers[handlerID] = nil
    if flight.handlers.isEmpty {
      inFlight[key] = nil
      flight.token.cancel()
    }
  }

  private static func cacheKey(_ key: ThumbnailKey) -> String { "\(key.bucket.rawValue)|\(key.id)" }
}

@MainActor
public final class ThumbnailTicket {
  private var onCancel: (() -> Void)?

  init(onCancel: (() -> Void)? = nil) {
    self.onCancel = onCancel
  }

  public func cancel() {
    onCancel?()
    onCancel = nil
  }
}
