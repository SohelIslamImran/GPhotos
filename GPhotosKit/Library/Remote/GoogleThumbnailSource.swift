import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Thumbnails of Google Photos items for the shared `ThumbnailPipeline`. Ids are
/// `RemoteThumbnailID` strings (media key and content version, so edits get new images).
/// Downloads are limited to a few at a time and cancelled when cells scroll away; JPEGs
/// are kept in a size-capped disk cache per account and decoded, downsampled, off the
/// main thread.
public final class GoogleThumbnailSource: ThumbnailSource, Sendable {
  private let client: GooglePhotosMobileClient
  private let cache: ThumbnailDiskCache
  /// What's on screen has slots of its own: indexing thousands of items in the background
  /// never makes the Library wait for a turn. Each thumbnail takes Google about half a
  /// second, over one HTTP/2 connection, so a Mac window's screenful needs a dozen at once.
  private let limiter = DownloadLimiter(slots: 12)
  private let analysisLimiter = DownloadLimiter(slots: 2)

  private let accountEmail: String

  public init(client: GooglePhotosMobileClient, accountEmail: String) {
    self.client = client
    self.accountEmail = accountEmail
    cache = ThumbnailDiskCache(
      directory: ThumbnailDiskCache.directory(for: accountEmail), byteLimit: ThumbnailDiskCache.defaultByteLimit)
  }

  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let parsed = RemoteThumbnailID(id) else { return .none }
    let side = Self.requestSide(for: pixelSize, quality: quality)
    // Grid cells are square, so their thumbnails come cropped to fill the cell.
    let crop = quality != .display
    let key = "\(parsed.mediaKey)-\(parsed.contentVersion)-\(side)\(crop ? "c" : "")"
    // Only cells and pages on screen ask (nothing prefetches), so they go ahead of indexing.
    let task = Task.detached(priority: .userInitiated) {
      [client, cache, limiter, accountEmail] in
      // A cell flung past cancels before its task starts: nothing is read for it.
      guard !Task.isCancelled else { return }
      if let data = cache.data(for: key), let image = Self.decode(data, maxPixel: side) {
        deliver(image, true)
        return
      }
      // An item cleanup removed from this device keeps a thumbnail: enough for grid cells
      // with no download, and a placeholder for the viewer while the full photo loads.
      if let kept = KeptThumbnails.data(mediaKey: parsed.mediaKey, accountEmail: accountEmail),
        let image = Self.decode(kept, maxPixel: side)
      {
        let isEnough = quality != .display && side <= KeptThumbnails.side
        deliver(Self.cropped(image, square: crop), isEnough)
        if isEnough { return }
      }
      // A smaller cached size stands in while the right one downloads. Opened for the
      // first time, a small whole-photo preview comes first, as in Photos: the photo is
      // there at once, soft, and sharpens.
      if quality == .display {
        let prefix = "\(parsed.mediaKey)-\(parsed.contentVersion)-"
        if let smaller = cache.largestSmaller(than: side, prefix: prefix), let image = Self.decode(smaller, maxPixel: side) {
          deliver(image, false)
        } else if side > Self.previewSide, await limiter.acquire() {
          let preview = try? await client.thumbnail(
            mediaKey: parsed.mediaKey, width: Self.previewSide, height: Self.previewSide,
            contentVersion: parsed.contentVersion, crop: false)
          limiter.release()
          if let preview, !Task.isCancelled, let image = Self.decode(preview, maxPixel: Self.previewSide) {
            cache.store(preview, for: prefix + String(Self.previewSide))
            deliver(image, false)
          }
        }
      }
      // Fast scrolling never touches the network.
      guard quality != .fast else { return }
      // A cell on screen that got nothing would stay empty until it scrolled away, so a
      // failed download (offline for a moment, a busy server) is tried again while the
      // cell still wants it.
      for attempt in 0..<Self.retryDelays.count + 1 {
        guard !Task.isCancelled else { return }
        if attempt > 0 { try? await Task.sleep(for: Self.retryDelays[attempt - 1]) }
        guard await limiter.acquire() else { return }
        do {
          let data = try await client.thumbnail(
            mediaKey: parsed.mediaKey, width: side, height: side, contentVersion: parsed.contentVersion, crop: crop)
          limiter.release()
          guard !Task.isCancelled, let image = Self.decode(data, maxPixel: side) else { return }
          cache.store(data, for: key)
          deliver(image, true)
          return
        } catch {
          limiter.release()
          // Gone or refused for this item alone: asking again won't change it.
          if case GPhotosError.httpError(let status, _) = error, (400..<500).contains(status), status != 429 { return }
        }
      }
    }
    return ImageRequestToken { task.cancel() }
  }

  /// The whole photo, uncropped, about `side` pixels on its longest edge, for on-device
  /// analysis (search labels, faces). Read from the cache when a viewer size is there;
  /// otherwise downloaded and not kept, so indexing a library doesn't push the thumbnails
  /// people look at out of the cache. Waits its turn behind what's on screen. Nil when
  /// the image can't be decoded; throws when it can't be fetched.
  func analysisImage(_ id: RemoteThumbnailID, side: Int) async throws -> CGImage? {
    let prefix = "\(id.mediaKey)-\(id.contentVersion)-"
    for cached in [side, 1024, 1600] where cached >= side {
      if let data = cache.data(for: prefix + String(cached)), let image = Self.decode(data, maxPixel: side) {
        return image
      }
    }
    guard await analysisLimiter.acquire() else { throw CancellationError() }
    defer { analysisLimiter.release() }
    let data = try await client.thumbnail(
      mediaKey: id.mediaKey, width: side, height: side, contentVersion: id.contentVersion, crop: false,
      waitsOutRateLimit: false)
    return Self.decode(data, maxPixel: side)
  }

  static let retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
  /// The quick whole-photo preview a first open shows while the full size downloads.
  static let previewSide = 320

  /// Grid buckets map to themselves; viewer sizes round up to a few steps so zoom levels
  /// share downloads.
  static func requestSide(for pixelSize: CGSize, quality: ImageRequestQuality) -> Int {
    let longest = Int(max(pixelSize.width, pixelSize.height).rounded(.up))
    guard quality == .display else { return max(longest, 1) }
    return [1024, 1600, 2048, 3072, 4096, 6144].first { $0 >= longest } ?? 8192
  }

  /// Grid cells expect square images, as the server's cropped thumbnails are.
  static func cropped(_ image: CGImage, square: Bool) -> CGImage {
    guard square, image.width != image.height else { return image }
    let side = min(image.width, image.height)
    return displayReady(image, cropTo: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
  }

  /// A copy laid out the way the screen draws images (8-bit BGRA, premultiplied alpha, an
  /// RGB colour space), made off the main thread. Decoded JPEGs and cropped images
  /// otherwise get converted by Core Animation on the main thread the first time they're
  /// shown, which is most of a fast scroll's cost.
  static func displayReady(_ image: CGImage, cropTo crop: CGRect? = nil) -> CGImage {
    let rect = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
    guard let space,
      let context = CGContext(
        data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    context.draw(
      image, in: CGRect(x: -rect.minX, y: rect.maxY - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
    return context.makeImage() ?? image
  }

  static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { displayReady($0) }
  }

  public func removeCache() { cache.removeAll() }
}

/// A few download slots, handed to the newest waiting request first: after a fling the
/// cells now on screen load before the ones scrolled past. A waiter that's cancelled
/// leaves the queue at once instead of holding its turn.
final class DownloadLimiter: @unchecked Sendable {
  private let lock = NSLock()
  private var free: Int
  private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
  private var nextID: UInt64 = 0

  init(slots: Int) {
    free = slots
  }

  /// True once a slot is held (release it); false if the task was cancelled first.
  func acquire() async -> Bool {
    if Task.isCancelled { return false }
    let id: UInt64 = lock.withLock {
      nextID &+= 1
      return nextID
    }
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let granted: Bool = lock.withLock {
          if free > 0 {
            free -= 1
            return true
          }
          waiters.append((id, continuation))
          return false
        }
        if granted { continuation.resume(returning: true) }
      }
    } onCancel: {
      let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
      }
      waiter?.resume(returning: false)
    }
    // Cancelled while joining the queue: hand the slot straight back.
    if granted, Task.isCancelled {
      release()
      return false
    }
    return granted
  }

  func release() {
    let next: CheckedContinuation<Bool, Never>? = lock.withLock {
      if let last = waiters.popLast() { return last.continuation }
      free += 1
      return nil
    }
    next?.resume(returning: true)
  }
}

/// A thumbnail id for a Google Photos item: `g:<content version>:<media key>`.
public struct RemoteThumbnailID: Equatable, Sendable {
  public let mediaKey: String
  public let contentVersion: Int

  public init(mediaKey: String, contentVersion: Int) {
    self.mediaKey = mediaKey
    self.contentVersion = contentVersion
  }

  init?(_ string: String) {
    let parts = string.split(separator: ":", maxSplits: 2)
    guard parts.count == 3, parts[0] == "g", let version = Int(parts[1]) else { return nil }
    mediaKey = String(parts[2])
    contentVersion = version
  }

  public var string: String { "g:\(contentVersion):\(mediaKey)" }
}

/// Files named by key hash, written atomically, trimmed oldest-first past the limit.
/// Thread-safe through the file system; the size estimate is advisory.
final class ThumbnailDiskCache: @unchecked Sendable {
  let directory: URL
  private let byteLimit: Int64
  private let lock = NSLock()
  private var approximateBytes: Int64 = 0
  private var isTrimming = true
  /// Files read this run, whose dates were moved up so trimming keeps what is viewed.
  private var touched = Set<String>()

  static let defaultByteLimit: Int64 = 1 << 30

  static func directory(for accountEmail: String) -> URL {
    URL.cachesDirectory.appending(path: "GoogleThumbnails", directoryHint: .isDirectory)
      .appending(path: RemoteLibraryStore.fileName(for: accountEmail).replacingOccurrences(of: ".sqlite", with: ""))
  }

  init(directory: URL, byteLimit: Int64) {
    self.directory = directory
    self.byteLimit = byteLimit
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Listing every file competes with the first screen's thumbnail reads, so it waits.
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [self] in trim() }
  }

  private func url(for key: String) -> URL {
    let digest = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appending(path: digest)
  }

  func data(for key: String) -> Data? {
    let url = url(for: key)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    if lock.withLock({ touched.insert(url.lastPathComponent).inserted }) {
      DispatchQueue.global(qos: .background).async {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      }
    }
    return data
  }

  /// The biggest uncropped cached size of one item below `side`.
  func largestSmaller(than side: Int, prefix: String) -> Data? {
    let steps = [6144, 4096, 3072, 2048, 1600, 1024, 800, 512, 320, 192, 96]
    for step in steps where step < side {
      if let data = data(for: prefix + String(step)) { return data }
    }
    return nil
  }

  func store(_ data: Data, for key: String) {
    try? data.write(to: url(for: key), options: .atomic)
    let shouldTrim = lock.withLock {
      approximateBytes += Int64(data.count)
      guard approximateBytes > byteLimit, !isTrimming else { return false }
      isTrimming = true
      return true
    }
    if shouldTrim { DispatchQueue.global(qos: .background).async { [self] in trim() } }
  }

  func removeAll() {
    try? FileManager.default.removeItem(at: directory)
    lock.withLock { approximateBytes = 0 }
  }

  /// Deletes the least recently used files until the cache is under 80% of its limit.
  private func trim() {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
    var entries = files.compactMap { url -> (URL, Int64, Date)? in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }
    var total = entries.reduce(0) { $0 + $1.1 }
    if total > byteLimit {
      entries.sort { $0.2 < $1.2 }
      for (url, size, _) in entries where total > byteLimit * 8 / 10 {
        try? FileManager.default.removeItem(at: url)
        total -= size
      }
    }
    lock.withLock {
      approximateBytes = total
      isTrimming = false
    }
  }
}
