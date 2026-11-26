import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os

/// Thumbnails of Google Photos items for the shared `ThumbnailPipeline`. Ids are
/// `RemoteThumbnailID` strings (media key and content version, so edits get new images).
/// Downloads are limited to a few at a time and cancelled when cells scroll away; JPEGs
/// are kept in a size-capped disk cache per account and decoded, downsampled, off the
/// main thread.
public final class GoogleThumbnailSource: ThumbnailSource, Sendable {
  typealias Fetch =
    @Sendable (_ id: RemoteThumbnailID, _ side: Int, _ crop: Bool, _ waitsOutRateLimit: Bool) async throws -> Data

  private let fetch: Fetch
  private let decodeImage: @Sendable (Data, Int) -> CGImage?
  private let cache: ThumbnailDiskCache
  /// Closed once the library is switched away from or removed: the shared client may
  /// already hold another account's credential, so nothing more is requested.
  private let requests = AccountRequests()
  /// What's on screen has slots of its own: indexing thousands of items in the background
  /// never makes the Library wait for a turn. Each thumbnail takes Google about half a
  /// second, over one HTTP/2 connection, so a Mac window's screenful needs a dozen at once.
  private let limiter = DownloadLimiter(slots: 12)
  private let analysisLimiter = DownloadLimiter(slots: 2)

  private let accountEmail: String

  public convenience init(client: GooglePhotosMobileClient, accountEmail: String) {
    self.init(accountEmail: accountEmail) { id, side, crop, waitsOutRateLimit in
      try await client.thumbnail(
        mediaKey: id.mediaKey, width: side, height: side, contentVersion: id.contentVersion, crop: crop,
        waitsOutRateLimit: waitsOutRateLimit)
    }
  }

  init(
    accountEmail: String, decode: @escaping @Sendable (Data, Int) -> CGImage? = GoogleThumbnailSource.decode,
    fetch: @escaping Fetch
  ) {
    decodeImage = decode
    self.fetch = fetch
    self.accountEmail = accountEmail
    cache = ThumbnailDiskCache(accountEmail: accountEmail, byteLimit: ThumbnailDiskCache.defaultByteLimit)
  }

  /// Requests nothing more and cancels what's out; `drain` returns once that has ended.
  func retire() { requests.close() }

  func drain() async { await requests.drain() }

  public func thumbnailIdentity(for id: String) -> ThumbnailIdentity {
    ThumbnailIdentity(id: id, version: 0, accountEmail: accountEmail)
  }

  private func isLocked(_ id: RemoteThumbnailID) -> Bool {
    LockedItems.contains(id.mediaKey, accountEmail: accountEmail)
  }

  /// One request, in its turn. The library can be retired or the item moved to the Locked
  /// Folder while it waits or while it's out: then nothing is sent, or nothing comes back.
  private func download(
    _ id: RemoteThumbnailID, side: Int, crop: Bool, waitsOutRateLimit: Bool = true, limiter: DownloadLimiter
  ) async throws -> Data {
    guard !requests.isClosed, await limiter.acquire() else { throw CancellationError() }
    defer { limiter.release() }
    guard !isLocked(id) else { throw CancellationError() }
    let data = try await requests.run { [fetch] in try await fetch(id, side, crop, waitsOutRateLimit) }
    guard !requests.isClosed, !isLocked(id) else { throw CancellationError() }
    return data
  }

  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let parsed = RemoteThumbnailID(id), !requests.isClosed, !isLocked(parsed) else {
      onUnavailable()
      return .none
    }
    let side = Self.requestSide(for: pixelSize, quality: quality)
    // Grid cells are square, so their thumbnails come cropped to fill the cell.
    let crop = quality == .fast || quality == .thumbnail
    let key = ThumbnailDiskCache.Key(parsed, side: side, crop: crop)
    // Only cells and pages on screen ask (nothing prefetches), so they go ahead of indexing.
    let task = Task.detached(priority: .userInitiated) {
      [self, cache, limiter, accountEmail] in
      var succeeded = false
      defer { if !succeeded, !Task.isCancelled { onUnavailable() } }
      // A cell flung past cancels before its task starts: nothing is read for it.
      guard !Task.isCancelled else { return }
      if let data = cache.data(for: key), let image = decodeImage(data, side) {
        guard !Task.isCancelled, !requests.isClosed, !isLocked(parsed) else { return }
        succeeded = true
        deliver(image, true)
        return
      }
      // An item cleanup removed from this device keeps a thumbnail: enough for grid cells
      // with no download, and a placeholder for the viewer while the full photo loads.
      if let kept = KeptThumbnails.data(mediaKey: parsed.mediaKey, accountEmail: accountEmail),
        let image = Self.decode(kept, maxPixel: side)
      {
        guard !Task.isCancelled, !requests.isClosed, !isLocked(parsed) else { return }
        let isEnough = quality != .display && side <= KeptThumbnails.side
        succeeded = isEnough
        deliver(Self.cropped(image, square: crop), isEnough)
        if isEnough { return }
      }
      // A smaller cached size stands in while the right one downloads. Opened for the
      // first time, a small whole-photo preview comes first, as in Photos: the photo is
      // there at once, soft, and sharpens.
      if quality == .display {
        if let smaller = cache.largestSmaller(than: side, of: parsed), let image = Self.decode(smaller, maxPixel: side) {
          guard !Task.isCancelled, !requests.isClosed, !isLocked(parsed) else { return }
          deliver(image, false)
        } else if side > Self.previewSide,
          let preview = try? await download(parsed, side: Self.previewSide, crop: false, limiter: limiter),
          !Task.isCancelled, !requests.isClosed, !isLocked(parsed),
          let image = decodeImage(preview, Self.previewSide)
        {
          guard await storeIfActive(preview, for: ThumbnailDiskCache.Key(parsed, side: Self.previewSide, crop: false), id: parsed)
          else { return }
          deliver(image, false)
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
        do {
          let data = try await download(parsed, side: side, crop: crop, limiter: limiter)
          guard !Task.isCancelled, !requests.isClosed, !isLocked(parsed), let image = decodeImage(data, side),
            await storeIfActive(data, for: key, id: parsed)
          else { return }
          succeeded = true
          deliver(image, true)
          return
        } catch is CancellationError {
          return
        } catch {
          // Gone or refused for this item alone: asking again won't change it.
          if case GPhotosError.httpError(let status, _) = error, (400..<500).contains(status), status != 429 { return }
        }
      }
    }
    return ImageRequestToken { task.cancel() }
  }

  private func storeIfActive(_ data: Data, for key: ThumbnailDiskCache.Key, id: RemoteThumbnailID) async -> Bool {
    do {
      try await requests.run { [self] in
        try Task.checkCancellation()
        guard !isLocked(id) else { throw CancellationError() }
        cache.store(data, for: key)
      }
      return !Task.isCancelled && !requests.isClosed && !isLocked(id)
    } catch {
      return false
    }
  }

  /// The whole photo, uncropped, about `side` pixels on its longest edge, for on-device
  /// analysis (search labels, faces). Read from the cache when a viewer size is there;
  /// otherwise downloaded and not kept, so indexing a library doesn't push the thumbnails
  /// people look at out of the cache. Waits its turn behind what's on screen. Nil when
  /// the image can't be decoded; throws when it can't be fetched.
  func analysisImage(_ id: RemoteThumbnailID, side: Int) async throws -> CGImage? {
    guard !isLocked(id) else { throw CancellationError() }
    for cached in [side, 1024, 1600] where cached >= side {
      if let data = cache.data(for: ThumbnailDiskCache.Key(id, side: cached, crop: false)), let image = Self.decode(data, maxPixel: side) {
        return image
      }
    }
    let data = try await download(id, side: side, crop: false, waitsOutRateLimit: false, limiter: analysisLimiter)
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
        let acquired: Bool? = lock.withLock {
          // Cancellation may run before the continuation has been registered.
          if Task.isCancelled { return false }
          if free > 0 {
            free -= 1
            return true
          }
          waiters.append((id, continuation))
          return nil
        }
        if let acquired { continuation.resume(returning: acquired) }
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

/// Files named by media key hash, content version and size, written atomically, trimmed
/// oldest-first past the limit. Thread-safe through the file system; the size estimate is
/// advisory. Nothing in the Locked Folder is kept.
final class ThumbnailDiskCache: @unchecked Sendable {
  struct Key: Sendable {
    let mediaKey: String
    let fileName: String

    init(_ id: RemoteThumbnailID, side: Int, crop: Bool) {
      mediaKey = id.mediaKey
      fileName = ThumbnailDiskCache.itemName(for: id.mediaKey) + "-\(id.contentVersion)-\(side)\(crop ? "c" : "")"
    }
  }

  let directory: URL
  private let accountEmail: String
  private let byteLimit: Int64
  private let lock = NSLock()
  private var approximateBytes: Int64 = 0
  private var isTrimming = false
  /// Deleted with its account: nothing is read or written again.
  private var isRemoved = false
  /// Files read lately, whose dates were moved up so trimming keeps what is viewed.
  private var touched = Set<String>()
  private static let touchedLimit = 10_000

  static let defaultByteLimit: Int64 = 1 << 30

  static func directory(for accountEmail: String) -> URL {
    URL.cachesDirectory.appending(path: "GoogleThumbnails", directoryHint: .isDirectory)
      .appending(path: RemoteLibraryStore.fileName(for: accountEmail).replacingOccurrences(of: ".sqlite", with: ""))
  }

  init(accountEmail: String, byteLimit: Int64) {
    self.accountEmail = accountEmail
    directory = Self.directory(for: accountEmail)
    self.byteLimit = byteLimit
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Listing every file competes with the first screen's thumbnail reads, so it waits. A
    // cache dropped (its account switched away) in the meantime isn't listed.
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [weak self] in self?.startTrim() }
  }

  /// Lowercase hex of the media key's SHA-1, which its files' names start with.
  static func itemName(for key: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(40)
    for byte in Insecure.SHA1.hash(data: Data(key.utf8)) {
      bytes.append(digits[Int(byte >> 4)])
      bytes.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func url(for key: Key) -> URL {
    directory.appending(path: key.fileName)
  }

  func data(for key: Key) -> Data? {
    guard !lock.withLock({ isRemoved }) else { return nil }
    let url = url(for: key)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    let isFirstRead = lock.withLock {
      if touched.count >= Self.touchedLimit { touched.removeAll(keepingCapacity: true) }
      return touched.insert(url.lastPathComponent).inserted
    }
    if isFirstRead {
      DispatchQueue.global(qos: .background).async {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      }
    }
    return data
  }

  /// The biggest uncropped cached size of one item below `side`.
  func largestSmaller(than side: Int, of id: RemoteThumbnailID) -> Data? {
    let steps = [6144, 4096, 3072, 2048, 1600, 1024, 800, 512, 320, 192, 96]
    for step in steps where step < side {
      if let data = data(for: Key(id, side: step, crop: false)) { return data }
    }
    return nil
  }

  func store(_ data: Data, for key: Key) {
    guard !lock.withLock({ isRemoved }), !LockedItems.contains(key.mediaKey, accountEmail: accountEmail) else { return }
    let url = url(for: key)
    try? data.write(to: url, options: .atomic)
    // Locked while it was being written, after `remove` looked.
    if LockedItems.contains(key.mediaKey, accountEmail: accountEmail) { try? FileManager.default.removeItem(at: url) }
    let shouldTrim = lock.withLock {
      approximateBytes += Int64(data.count)
      return approximateBytes > byteLimit && !isTrimming
    }
    if shouldTrim { DispatchQueue.global(qos: .background).async { [weak self] in self?.startTrim() } }
  }

  /// Deletes the cache with its account; later reads and writes do nothing.
  func removeAll() {
    lock.withLock {
      isRemoved = true
      approximateBytes = 0
      touched.removeAll()
    }
    try? FileManager.default.removeItem(at: directory)
  }

  /// Deletes every size and version of these items. A file whose name doesn't say whose it
  /// is could be one of them, so it goes too.
  static func remove(_ mediaKeys: Set<String>, accountEmail: String) {
    let directory = directory(for: accountEmail)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    let items = Set(mediaKeys.map(itemName))
    for file in files where belongs(file, to: items) {
      try? FileManager.default.removeItem(at: directory.appending(path: file))
    }
  }

  private static func belongs(_ file: String, to items: Set<String>) -> Bool {
    guard let dash = file.firstIndex(of: "-") else { return true }
    return items.contains(String(file[..<dash]))
  }

  private func startTrim() {
    let starts = lock.withLock {
      guard !isTrimming, !isRemoved else { return false }
      isTrimming = true
      return true
    }
    if starts { trim() }
  }

  /// Deletes the least recently used files until the cache is under 80% of its limit.
  private func trim() {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
    let locked = Set(LockedItems.keys(accountEmail: accountEmail).map(Self.itemName))
    var entries = files.compactMap { url -> (URL, Int64, Date)? in
      // What an earlier run couldn't delete.
      if Self.belongs(url.lastPathComponent, to: locked) {
        try? FileManager.default.removeItem(at: url)
        return nil
      }
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
