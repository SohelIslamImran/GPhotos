import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import os

/// Small thumbnails kept for items cleanup removed from this device, keyed by their
/// Google Photos media key. The library keeps showing them instantly and offline, and the
/// viewer loads the full photo from Google, like Optimize Storage in iCloud Photos.
///
/// Saving one is best effort and happens before the removal: it never blocks, delays or
/// changes a deletion.
public enum KeptThumbnails {
  /// Big enough for every grid size and a viewer placeholder; about 15 KB each.
  static let side = 384

  static func directory(for accountEmail: String) -> URL {
    URL.applicationSupportDirectory.appending(path: "KeptThumbnails", directoryHint: .isDirectory)
      .appending(path: RemoteLibraryStore.fileName(for: accountEmail).replacingOccurrences(of: ".sqlite", with: ""))
  }

  static func url(mediaKey: String, accountEmail: String) -> URL {
    directory(for: accountEmail).appending(path: ThumbnailDiskCache.itemName(for: mediaKey) + ".jpg")
  }

  /// File names kept per account, listed once, so the many grid cells without a kept
  /// thumbnail don't each try to open a file.
  private static let index = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

  private static func names(for email: String) -> Set<String> {
    let accountEmail = email.lowercased()
    if let names = index.withLock({ $0[accountEmail] }) { return names }
    let listed = Set((try? FileManager.default.contentsOfDirectory(atPath: directory(for: accountEmail).path)) ?? [])
    return index.withLock { state in
      if let existing = state[accountEmail] { return existing }
      state[accountEmail] = listed
      return listed
    }
  }

  public static func data(mediaKey: String, accountEmail: String) -> Data? {
    guard !LockedItems.contains(mediaKey, accountEmail: accountEmail) else { return nil }
    let names = names(for: accountEmail)
    guard !names.isEmpty else { return nil }
    let file = url(mediaKey: mediaKey, accountEmail: accountEmail)
    guard names.contains(file.lastPathComponent) else { return nil }
    return try? Data(contentsOf: file, options: .mappedIfSafe)
  }

  /// Keeps a thumbnail of the item a record uploaded, from the file about to be removed or
  /// from its photo-library asset.
  public static func keep(_ record: TransferRecord, accountEmail: String, fileURL: URL? = nil) async {
    guard record.resourceRole == .primary, let mediaKey = record.mediaKeysByAccount[accountEmail],
      let lifetime = LockedItems.unlockedLifetime(mediaKey, accountEmail: accountEmail)
    else { return }
    let destination = url(mediaKey: mediaKey, accountEmail: accountEmail)
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    let image: CGImage? =
      if let fileURL {
        await thumbnail(file: fileURL, isVideo: record.mediaType.localizedCaseInsensitiveContains("video"))
      } else if let assetID = record.assetLocalIdentifier {
        await thumbnail(assetID: assetID)
      } else { nil }
    guard !Task.isCancelled, let image, let jpeg = encode(image) else { return }
    write(jpeg, mediaKey: mediaKey, accountEmail: accountEmail, lifetime: lifetime)
  }

  static func write(_ jpeg: Data, mediaKey: String, accountEmail: String, lifetime: UUID) {
    LockedItems.withKnownState(for: accountEmail) { currentLifetime, locked in
      guard !Task.isCancelled, currentLifetime == lifetime, !locked.contains(mediaKey) else { return }
      let destination = url(mediaKey: mediaKey, accountEmail: accountEmail)
      try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard (try? jpeg.write(to: destination, options: .atomic)) != nil else { return }
      _ = names(for: accountEmail)
      index.withLock { _ = $0[accountEmail.lowercased(), default: []].insert(destination.lastPathComponent) }
    }
  }

  /// The same, for the account the record's id is scoped to, giving up after `timeout`
  /// so a removal is never held up for long.
  public static func keep(_ record: TransferRecord, fileURL: URL? = nil, timeout: Duration = .seconds(2)) async {
    guard let email = TransferRecord.accountEmail(fromScopedID: record.id) else { return }
    await withinTime(timeout) { await keep(record, accountEmail: email, fileURL: fileURL) }
  }

  /// Keeps thumbnails for a batch of library records, six at a time, for at most
  /// `timeout` in all; whatever isn't done by then is skipped.
  public static func keepAll(_ records: [TransferRecord], accountEmail: String, timeout: Duration = .seconds(5)) async {
    await withinTime(timeout) {
      await withTaskGroup(of: Void.self) { group in
        var next = records.makeIterator()
        for _ in 0..<6 {
          guard let record = next.next() else { break }
          group.addTask { await keep(record, accountEmail: accountEmail) }
        }
        while await group.next() != nil {
          guard !Task.isCancelled, let record = next.next() else { continue }
          group.addTask { await keep(record, accountEmail: accountEmail) }
        }
      }
    }
  }

  /// Runs `work` until it finishes or `timeout` passes, whichever is first.
  private static func withinTime(_ timeout: Duration, _ work: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await work() }
      group.addTask { try? await Task.sleep(for: timeout) }
      await group.next()
      group.cancelAll()
    }
  }

  /// Drops the thumbnails of items moved to the Locked Folder.
  static func remove(_ mediaKeys: Set<String>, accountEmail: String) {
    let files = mediaKeys.map { url(mediaKey: $0, accountEmail: accountEmail) }
    for file in files { try? FileManager.default.removeItem(at: file) }
    index.withLock { $0[accountEmail.lowercased()]?.subtract(files.map(\.lastPathComponent)) }
  }

  public static func removeAll(accountEmail: String) {
    LockedItems.forget(accountEmail: accountEmail)
    try? FileManager.default.removeItem(at: directory(for: accountEmail))
    index.withLock { $0[accountEmail.lowercased()] = [] }
  }

  /// Drops thumbnails of items no longer in Google Photos.
  public static func prune(keeping mediaKeys: Set<String>, accountEmail: String) {
    let folder = directory(for: accountEmail)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
    let wanted = Set(mediaKeys.map { url(mediaKey: $0, accountEmail: accountEmail).lastPathComponent })
    for file in files where !wanted.contains(file) {
      try? FileManager.default.removeItem(at: folder.appending(path: file))
    }
    index.withLock { $0[accountEmail.lowercased()] = Set(files).intersection(wanted) }
  }

  private static func thumbnail(file: URL, isVideo: Bool) async -> CGImage? {
    if isVideo {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: side, height: side)
      return try? await generator.image(at: .zero).image
    }
    guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: side,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Local only: an iCloud asset without a local thumbnail simply isn't kept.
  private static func thumbnail(assetID: String) async -> CGImage? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(
        for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options
      ) { image, _ in
        continuation.resume(returning: image.flatMap(PhotoKitImageSource.cgImage))
      }
    }
  }

  static func encode(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

/// Device photos opened in the viewer recently, so automatic cleanup can leave the ones
/// in use. Kept in the app's defaults, trimmed to the last 60 days.
public enum RecentlyViewed {
  private static let key = "RecentlyViewedAssets"
  private static let horizon: TimeInterval = 60 * 24 * 60 * 60

  private static let pending = OSAllocatedUnfairLock(initialState: [String: Double]())
  private static let writer = DispatchQueue(label: "RecentlyViewed", qos: .utility)

  private static func recordInViewer(_ assetID: String, now: Date = Date()) {
    let startWriter = pending.withLock { viewed in
      let wasEmpty = viewed.isEmpty
      viewed[assetID] = max(viewed[assetID] ?? -.infinity, now.timeIntervalSince1970)
      return wasEmpty
    }
    if startWriter { writer.async(execute: persistPending) }
  }

  private static func persistPending() {
    let batch = pending.withLock { $0 }
    let defaults = UserDefaults.standard
    var viewed = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    viewed.merge(batch, uniquingKeysWith: max)
    save(viewed, now: Date(), defaults: defaults)
    let more = pending.withLock { viewed in
      for (id, time) in batch where viewed[id] == time {
        viewed[id] = nil
      }
      return !viewed.isEmpty
    }
    if more { writer.async(execute: persistPending) }
  }

  public static func record(_ assetID: String, now: Date = Date(), defaults: UserDefaults = .standard) {
    if defaults === UserDefaults.standard {
      recordInViewer(assetID, now: now)
      return
    }
    var viewed = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    viewed[assetID] = now.timeIntervalSince1970
    save(viewed, now: now, defaults: defaults)
  }

  private static func save(_ viewed: [String: Double], now: Date, defaults: UserDefaults) {
    let cutoff = now.timeIntervalSince1970 - horizon
    defaults.set(viewed.count > 2_000 ? viewed.filter { $0.value > cutoff } : viewed, forKey: key)
  }

  public static func assetIDs(
    within interval: TimeInterval, now: Date = Date(), defaults: UserDefaults = .standard
  )
    -> Set<String>
  {
    // Read pending first: the writer only removes an entry after it is in defaults.
    let recent = defaults === UserDefaults.standard ? pending.withLock { $0 } : [:]
    var viewed = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    viewed.merge(recent, uniquingKeysWith: max)
    let cutoff = now.timeIntervalSince1970 - interval
    return Set(viewed.filter { $0.value >= cutoff }.keys)
  }
}
