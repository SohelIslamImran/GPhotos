import CoreGraphics
import Foundation
import os

#if canImport(UIKit)
  import UIKit
#else
  import Dispatch
#endif

/// A source delivers zero or more degraded images, then a final image or an unavailable
/// callback. Callbacks may occur before the request returns, on any thread. Cancelling
/// the request ends the subscription.
public protocol ThumbnailSource: AnyObject, Sendable {
  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void,
    deliver: @escaping @Sendable (CGImage, _ isFinal: Bool) -> Void
  ) -> ImageRequestToken

  func thumbnailIdentity(for id: String) -> ThumbnailIdentity
  func cachingTarget(for id: String) -> ThumbnailCachingTarget?
  func startCaching(ids: [String], pixelSize: CGSize)
  func stopCaching(ids: [String], pixelSize: CGSize)
}

/// The resolved source and identifier whose PhotoKit work must be stopped together.
public struct ThumbnailCachingTarget: Sendable {
  public let source: any ThumbnailSource
  public let id: String

  public init(source: any ThumbnailSource, id: String) {
    self.source = source
    self.id = id
  }
}

extension ThumbnailSource {
  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    deliver: @escaping @Sendable (CGImage, _ isFinal: Bool) -> Void
  ) -> ImageRequestToken {
    requestImage(id: id, pixelSize: pixelSize, quality: quality, onUnavailable: {}, deliver: deliver)
  }

  public func thumbnailIdentity(for id: String) -> ThumbnailIdentity { ThumbnailIdentity(id: id) }
  public func cachingTarget(for id: String) -> ThumbnailCachingTarget? { nil }
  public func startCaching(ids: [String], pixelSize: CGSize) {}
  public func stopCaching(ids: [String], pixelSize: CGSize) {}
}

public enum ImageRequestQuality: Hashable, Sendable {
  /// Grid cells while scrolling fast: whatever is quickest, no network.
  case fast
  /// Grid cells at rest: a sharp thumbnail at the requested size.
  case thumbnail
  /// A bounded aspect-fit thumbnail, such as the full photo behind a People cover.
  case uncroppedThumbnail
  /// The viewer: a screen-sized image, degraded first.
  case display
  /// A fitted viewer image, only if its pixels are already on the device.
  case localDisplay
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

public struct ThumbnailIdentity: Hashable, Sendable {
  public let id: String
  public let version: Int64
  let accountEmail: String?

  public init(id: String, version: Int64 = 0) {
    self.init(id: id, version: version, accountEmail: nil)
  }

  init(id: String, version: Int64, accountEmail: String?) {
    self.id = id
    self.version = version
    self.accountEmail = accountEmail
  }

  var isLocked: Bool {
    guard let key = RemoteThumbnailID(id)?.mediaKey else { return false }
    if let accountEmail { return LockedItems.contains(key, accountEmail: accountEmail) }
    return LockedItems.containsInAnyAccount(key)
  }
}

public struct ThumbnailKey: Hashable, Sendable {
  public let identity: ThumbnailIdentity
  public let bucket: ThumbnailBucket
  public var id: String { identity.id }

  public init(id: String, bucket: ThumbnailBucket, version: Int64 = 0) {
    self.init(identity: ThumbnailIdentity(id: id, version: version), bucket: bucket)
  }

  init(identity: ThumbnailIdentity, bucket: ThumbnailBucket) {
    self.identity = identity
    self.bucket = bucket
  }
}

/// The grid's image cache and request coordinator. Identical requests share one source
/// request, a request is cancelled once nobody wants it, and decoded images are kept in a
/// memory cache sized from the device's RAM and emptied under memory pressure.
@MainActor
public final class ThumbnailPipeline {
  public static let shared = ThumbnailPipeline()

  private typealias RemoteIDs = OSAllocatedUnfairLock<[ThumbnailIdentity: Int]>

  private final class CacheKey: NSObject {
    let identity: ThumbnailIdentity

    init(_ identity: ThumbnailIdentity) { self.identity = identity }

    override var hash: Int { identity.hashValue }
    override func isEqual(_ object: Any?) -> Bool { identity == (object as? CacheKey)?.identity }
  }

  // Track both caches by entry lifetime, so eviction drops the ID from the index.
  private final class RemoteCacheMembership: Sendable {
    private let id: ThumbnailIdentity
    private let ids: RemoteIDs

    init?(_ id: ThumbnailIdentity, in ids: RemoteIDs) {
      guard RemoteThumbnailID(id.id) != nil else { return nil }
      self.id = id
      self.ids = ids
      ids.withLock { $0[id, default: 0] += 1 }
    }

    deinit {
      ids.withLock {
        let count = $0[id, default: 1]
        $0[id] = count > 1 ? count - 1 : nil
      }
    }
  }

  private final class Entry {
    let image: CGImage
    let membership: RemoteCacheMembership?

    let fileRequestSide: CGFloat

    init(_ image: CGImage, membership: RemoteCacheMembership?, fileRequestSide: CGFloat) {
      self.image = image
      self.membership = membership
      self.fileRequestSide = fileRequestSide
    }
  }

  private struct Rendition: Hashable {
    let bucket: ThumbnailBucket
    let quality: ImageRequestQuality
  }

  private struct FlightKey: Hashable {
    let identity: ThumbnailIdentity
    let bucket: ThumbnailBucket?
    let pixels: CGSize
    let quality: ImageRequestQuality
    let source: ObjectIdentifier

    var rendition: Rendition? { bucket.map { Rendition(bucket: $0, quality: quality) } }
  }

  private final class CachedRenditions {
    var images: [Rendition: CGImage] = [:]
    var cost = 0
    let membership: RemoteCacheMembership?

    init(membership: RemoteCacheMembership?) { self.membership = membership }

    func store(_ image: CGImage, for rendition: Rendition) {
      if let previous = images.updateValue(image, forKey: rendition) {
        cost -= previous.bytesPerRow * previous.height
      }
      cost += image.bytesPerRow * image.height
    }
  }

  private struct Subscriber {
    let image: (CGImage, Bool) -> Void
    let unavailable: () -> Void
  }

  private final class InFlight {
    let requestID: UInt64
    // Retain the source while its identity is used as a flight key.
    let source: any ThumbnailSource
    var token: ImageRequestToken = .none
    var handlers: [UInt64: Subscriber] = [:]
    var latest: CGImage?

    init(requestID: UInt64, source: any ThumbnailSource) {
      self.requestID = requestID
      self.source = source
    }
  }

  private let remoteIDs = RemoteIDs(initialState: [:])
  private let cache = NSCache<CacheKey, CachedRenditions>()
  private let viewerPreviews = NSCache<CacheKey, Entry>()
  private var inFlight: [FlightKey: InFlight] = [:]
  private var nextHandlerID: UInt64 = 0
  #if canImport(UIKit)
    private var memoryObserver: (any NSObjectProtocol)?
  #else
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
  #endif

  public init(costLimit: Int = ThumbnailPipeline.defaultCostLimit) {
    cache.totalCostLimit = costLimit
    viewerPreviews.countLimit = 6
    viewerPreviews.totalCostLimit = min(costLimit, 96 << 20)
    #if canImport(UIKit)
      memoryObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleMemoryPressure() }
      }
    #else
      // A busy Mac sits at warning for hours; emptying the cache then reloads every thumbnail.
      let pressure = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
      pressure.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.handleMemoryPressure() }
      }
      pressure.activate()
      memoryPressure = pressure
    #endif
  }

  isolated deinit {
    #if canImport(UIKit)
      if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    #else
      memoryPressure?.cancel()
    #endif
  }

  private func handleMemoryPressure() {
    removeAll()
    PhotoKitImageSource.shared.stopCachingAll()
    NotificationCenter.default.post(name: Self.didClearWarmCache, object: nil)
  }

  static let didClearWarmCache = Notification.Name("ThumbnailPipeline.didClearWarmCache")

  /// About 1/24 of RAM, between 48 and 320 MB: a few screens of thumbnails at every
  /// zoom level without pressuring the system.
  public nonisolated static var defaultCostLimit: Int {
    let share = Int(ProcessInfo.processInfo.physicalMemory / 24)
    return min(max(share, 48 << 20), 320 << 20)
  }

  public func removeAll() {
    cache.removeAllObjects()
    viewerPreviews.removeAllObjects()
  }

  func invalidateRemoteImages(
    where changed: (String) -> Bool, retrying: (String) -> Bool = { _ in false }
  ) {
    let ids = remoteIDs.withLock { Array($0.keys) }
    for id in ids {
      guard let key = RemoteThumbnailID(id.id)?.mediaKey, changed(key) else { continue }
      cache.removeObject(forKey: CacheKey(id))
      viewerPreviews.removeObject(forKey: CacheKey(id))
    }
    let invalidated = inFlight.keys.filter { key in
      guard let mediaKey = RemoteThumbnailID(key.identity.id)?.mediaKey else { return false }
      return changed(mediaKey) || retrying(mediaKey)
    }
    let flights = invalidated.compactMap { inFlight.removeValue(forKey: $0) }
    for flight in flights {
      flight.token.cancel()
      for handler in flight.handlers.values { handler.unavailable() }
    }
  }

  /// Drops all cached and in-flight renditions of these Google media keys.
  func purge(ids: Set<String>) {
    guard !ids.isEmpty else { return }
    invalidateRemoteImages(where: ids.contains)
  }

  func viewerPreview(for id: String) -> CGImage? {
    viewerPreview(for: ThumbnailIdentity(id: id))
  }

  func viewerPreview(for identity: ThumbnailIdentity) -> CGImage? {
    guard !identity.isLocked else { return nil }
    return viewerPreviews.object(forKey: CacheKey(identity))?.image
  }

  func rememberedFileRequest(for identity: ThumbnailIdentity) -> CGFloat {
    viewerPreviews.object(forKey: CacheKey(identity))?.fileRequestSide ?? 0
  }

  func rememberViewerPreview(_ image: CGImage, for id: String) {
    rememberViewerPreview(image, for: ThumbnailIdentity(id: id))
  }

  func rememberViewerPreview(_ image: CGImage, for identity: ThumbnailIdentity, fileRequestSide: CGFloat = 0) {
    let cost = image.bytesPerRow * image.height
    guard !identity.id.isEmpty, !identity.isLocked, cost <= min(viewerPreviews.totalCostLimit, 64 << 20) else { return }
    let key = CacheKey(identity)
    let previousSide = viewerPreviews.object(forKey: key)?.fileRequestSide ?? 0
    let entry = Entry(
      image, membership: RemoteCacheMembership(identity, in: remoteIDs), fileRequestSide: max(previousSide, fileRequestSide))
    viewerPreviews.setObject(entry, forKey: key, cost: cost)
  }

  public func cachedImage(for key: ThumbnailKey) -> CGImage? {
    guard !key.identity.isLocked else { return nil }
    return cache.object(forKey: CacheKey(key.identity))?.images[Rendition(bucket: key.bucket, quality: .thumbnail)]
  }

  /// The best cached grid stand-in: an exact sharp image, the largest smaller sharp
  /// image, a larger sharp image, or a fast image while the sharp request runs.
  public func placeholder(for key: ThumbnailKey) -> CGImage? {
    guard !key.identity.isLocked, let images = cache.object(forKey: CacheKey(key.identity))?.images else { return nil }
    for quality: ImageRequestQuality in [.thumbnail, .fast] {
      if let exact = images[Rendition(bucket: key.bucket, quality: quality)] { return exact }
      for bucket in ThumbnailBucket.allCases.reversed() where bucket < key.bucket {
        if let image = images[Rendition(bucket: bucket, quality: quality)] { return image }
      }
      for bucket in ThumbnailBucket.allCases where bucket > key.bucket {
        if let image = images[Rendition(bucket: bucket, quality: quality)] { return image }
      }
    }
    return nil
  }

  /// Calls `handler` with each image as it arrives (degraded first). Cancel the returned
  /// ticket when the image is no longer wanted.
  public func load(
    _ key: ThumbnailKey, from source: any ThumbnailSource, quality: ImageRequestQuality = .thumbnail,
    onUnavailable: @escaping () -> Void = {}, handler: @escaping (CGImage, _ isFinal: Bool) -> Void
  ) -> ThumbnailTicket {
    let flightKey = FlightKey(
      identity: key.identity, bucket: key.bucket, pixels: key.bucket.pixelSize, quality: quality, source: ObjectIdentifier(source))
    guard !key.identity.isLocked else {
      onUnavailable()
      return ThumbnailTicket()
    }
    let images = cache.object(forKey: CacheKey(key.identity))?.images
    if let cached = (quality == .fast ? images?[Rendition(bucket: key.bucket, quality: .thumbnail)] : nil)
      ?? images?[Rendition(bucket: key.bucket, quality: quality)]
    {
      handler(cached, true)
      return ThumbnailTicket()
    }
    return subscribe(flightKey, source: source, onUnavailable: onUnavailable, handler: handler)
  }

  func loadPreview(
    _ identity: ThumbnailIdentity, pixels: CGSize, from source: any ThumbnailSource, quality: ImageRequestQuality,
    joiningOnly: Bool = false, onUnavailable: @escaping () -> Void = {}, handler: @escaping (CGImage, Bool) -> Void
  ) -> ThumbnailTicket? {
    let key = FlightKey(identity: identity, bucket: nil, pixels: pixels, quality: quality, source: ObjectIdentifier(source))
    guard !identity.isLocked else {
      onUnavailable()
      return ThumbnailTicket()
    }
    guard !joiningOnly || inFlight[key] != nil else { return nil }
    return subscribe(key, source: source, onUnavailable: onUnavailable, handler: handler)
  }

  private func subscribe(
    _ flightKey: FlightKey, source: any ThumbnailSource,
    onUnavailable: @escaping () -> Void, handler: @escaping (CGImage, Bool) -> Void
  ) -> ThumbnailTicket {
    nextHandlerID &+= 1
    let handlerID = nextHandlerID
    let subscriber = Subscriber(image: handler, unavailable: onUnavailable)
    if let existing = inFlight[flightKey] {
      existing.handlers[handlerID] = subscriber
      if let latest = existing.latest { handler(latest, false) }
    } else {
      let flight = InFlight(requestID: handlerID, source: source)
      flight.handlers[handlerID] = subscriber
      inFlight[flightKey] = flight
      let receive: @Sendable (CGImage?, Bool) -> Void = { [weak self] image, isFinal in
        if Thread.isMainThread {
          MainActor.assumeIsolated { self?.deliver(image, isFinal: isFinal, for: flightKey, requestID: handlerID) }
        } else {
          Task { @MainActor in self?.deliver(image, isFinal: isFinal, for: flightKey, requestID: handlerID) }
        }
      }
      flight.token = source.requestImage(
        id: flightKey.identity.id, pixelSize: flightKey.pixels, quality: flightKey.quality,
        onUnavailable: { receive(nil, true) }, deliver: { receive($0, $1) })
    }
    return ThumbnailTicket { [weak self] in self?.removeHandler(handlerID, for: flightKey) }
  }

  private func deliver(_ image: CGImage?, isFinal: Bool, for key: FlightKey, requestID: UInt64) {
    guard let flight = inFlight[key], flight.requestID == requestID else { return }
    let image = key.identity.isLocked ? nil : image
    let isFinal = isFinal || image == nil
    if isFinal {
      inFlight[key] = nil
      if let image, let rendition = key.rendition {
        let id = CacheKey(key.identity)
        let entry = cache.object(forKey: id) ?? CachedRenditions(membership: RemoteCacheMembership(key.identity, in: remoteIDs))
        entry.store(image, for: rendition)
        cache.setObject(entry, forKey: id, cost: entry.cost)
      }
    } else {
      flight.latest = image
    }
    for handler in flight.handlers.values {
      if let image { handler.image(image, isFinal) } else { handler.unavailable() }
    }
  }

  private func removeHandler(_ handlerID: UInt64, for key: FlightKey) {
    guard let flight = inFlight[key], flight.handlers.removeValue(forKey: handlerID) != nil else { return }
    if flight.handlers.isEmpty {
      inFlight[key] = nil
      flight.token.cancel()
    }
  }
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
