import CoreGraphics
import Foundation
import Photos
import os

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Images for photo-library assets, by local identifier. Uses one caching image manager so
/// the cells about to appear are already decoded by PhotoKit when they're asked for.
public final class PhotoKitImageSource: ThumbnailSource, @unchecked Sendable {
  public static let shared = PhotoKitImageSource()

  // PHCachingImageManager is documented as thread-safe; the asset cache is guarded.
  private let manager = PHCachingImageManager()
  private let assets = NSCache<NSString, PHAsset>()
  private let requests = DispatchQueue(label: "PhotoKitImageSource.requests", qos: .userInitiated)
  private let warming = DispatchQueue(label: "PhotoKitImageSource.warming", qos: .utility)
  // Accessed only on the warming queue. Other grids can warm the same asset and size.
  private var warmed: [CGSize: [String: WarmedAsset]] = [:]

  private struct WarmedAsset {
    let asset: PHAsset
    var users = 1
  }

  public init() {
    assets.countLimit = 4_000
  }

  public func asset(for id: String) -> PHAsset? {
    if let cached = assets.object(forKey: id as NSString) { return cached }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
    assets.setObject(asset, forKey: id as NSString)
    return asset
  }

  /// The grid hands over assets it already fetched, so lookups never hit the database.
  public func remember(_ asset: PHAsset) {
    assets.setObject(asset, forKey: asset.localIdentifier as NSString)
  }

  static func identity(for asset: PHAsset) -> ThumbnailIdentity {
    ThumbnailIdentity(
      id: asset.localIdentifier, version: pixelVersion(modifiedAt: asset.modificationDate, adjustedAt: asset.adjustmentTimestamp))
  }

  static func pixelVersion(modifiedAt: Date?, adjustedAt: Date?) -> Int64 {
    var hasher = Hasher()
    hasher.combine(modifiedAt)
    hasher.combine(adjustedAt)
    return Int64(hasher.finalize())
  }

  private static func options(for quality: ImageRequestQuality) -> PHImageRequestOptions {
    let options = PHImageRequestOptions()
    options.isSynchronous = false
    switch quality {
    case .fast:
      options.deliveryMode = .fastFormat
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = false
    case .thumbnail:
      // Matches the prefetch options so PhotoKit's warm cache answers it; an item only
      // in iCloud is asked for again with network access (see `requestImage`).
      options.deliveryMode = .opportunistic
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = false
    case .display, .localDisplay, .uncroppedThumbnail:
      options.deliveryMode = quality == .localDisplay ? .highQualityFormat : .opportunistic
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = quality != .localDisplay
    }
    return options
  }

  // Never mutated after initialization. Prefetching warms only what's already on the
  // device; a cell that comes on screen is the one that may download from iCloud.
  nonisolated(unsafe) private static let cachingOptions: PHImageRequestOptions = {
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    return options
  }()

  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    requestImage(id: id, pixelSize: pixelSize, quality: quality, allowsHidden: true, onUnavailable: onUnavailable, deliver: deliver)
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, allowsHidden: Bool,
    expectedVersion: PhotoBackupEvidence.Version? = nil,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    let token = RequestIDs(manager: manager)
    let matchesVersion: @Sendable (PHAsset) -> Bool = { asset in
      guard let expectedVersion else { return true }
      return LocalAssetHashes.Evidence.sameContent(.init(AssetExportService.version(of: asset)), expectedVersion)
    }
    let request: @Sendable (PHAsset?) -> Void = { [self] asset in
      guard !token.isCancelled else { return }
      guard let asset, allowsHidden || !asset.isHidden else {
        onUnavailable()
        return
      }
      // The viewer shows whole photos; aspect fill with an exact size would crop them.
      let contentMode: PHImageContentMode =
        (quality == .display || quality == .localDisplay || quality == .uncroppedThumbnail) ? .aspectFit : .aspectFill
      let stage = OSAllocatedUnfairLock(initialState: Stage.local)
      let result: @Sendable (CGImage?, Bool, Stage) -> Void = { image, isFinal, expected in
        guard !token.isCancelled else { return }
        let current = stage.withLock { value in
          guard value == expected || (!isFinal && expected == .local && value == .cloud) else { return false }
          if isFinal { value = .finished }
          return true
        }
        guard current else { return }
        if let image { deliver(image, isFinal) } else if isFinal { onUnavailable() }
      }
      let first = manager.requestImage(
        for: asset, targetSize: pixelSize, contentMode: contentMode, options: Self.options(for: quality)
      ) { image, info in
        guard !token.isCancelled else { return }
        let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
        let needsCloud = quality == .thumbnail && !cancelled && inCloud && (image == nil || degraded)
        let isFinal = cancelled || (quality == .localDisplay && inCloud && image == nil) || (!needsCloud && (quality == .fast || !degraded))
        if let image, !cancelled {
          Self.upright(image) { result($0, isFinal, .local) }
        } else if isFinal {
          result(nil, true, .local)
        }
        if needsCloud,
          stage.withLock({ value in
            guard value == .local else { return false }
            value = .cloud
            return true
          })
        {
          let options = Self.options(for: .thumbnail)
          options.isNetworkAccessAllowed = true
          token.add(
            self.manager.requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode, options: options) {
              image, info in
              guard !token.isCancelled else { return }
              let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
              let isFinal = cancelled || (info?[PHImageResultIsDegradedKey] as? Bool) != true
              if let image, !cancelled {
                Self.upright(image) { result($0, isFinal, .cloud) }
              } else if isFinal {
                result(nil, true, .cloud)
              }
            })
        }
      }
      token.add(first)
    }
    if let asset = assets.object(forKey: id as NSString), matchesVersion(asset) {
      request(asset)
    } else {
      requests.async { [self] in
        guard !token.isCancelled else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject, matchesVersion(asset)
        else {
          onUnavailable()
          return
        }
        remember(asset)
        request(asset)
      }
    }
    return ImageRequestToken {
      for id in token.cancel() { self.manager.cancelImageRequest(id) }
    }
  }

  private enum Stage: Sendable { case local, cloud, finished }

  /// The requests behind one image (the local one and, if needed, the iCloud one).
  private final class RequestIDs: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var ids: [PHImageRequestID] = []
    private var cancelled = false

    init(manager: PHImageManager) {
      self.manager = manager
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func add(_ id: PHImageRequestID) {
      let cancelNow = lock.withLock {
        ids.append(id)
        return cancelled
      }
      if cancelNow { manager.cancelImageRequest(id) }
    }

    func cancel() -> [PHImageRequestID] {
      lock.withLock {
        cancelled = true
        return ids
      }
    }
  }

  public func cachingTarget(for id: String) -> ThumbnailCachingTarget? {
    ThumbnailCachingTarget(source: self, id: id)
  }

  public func startCaching(ids: [String], pixelSize: CGSize) {
    warming.async { [self] in
      var window = warmed.removeValue(forKey: pixelSize) ?? [:]
      var start: [PHAsset] = []
      var missing: [String: Int] = [:]
      for id in ids {
        if window[id] != nil {
          window[id]?.users += 1
        } else if let asset = assets.object(forKey: id as NSString) {
          window[id] = WarmedAsset(asset: asset)
          start.append(asset)
        } else {
          missing[id, default: 0] += 1
        }
      }
      if !missing.isEmpty {
        PHAsset.fetchAssets(withLocalIdentifiers: Array(missing.keys), options: nil).enumerateObjects { asset, _, _ in
          let id = asset.localIdentifier
          self.assets.setObject(asset, forKey: id as NSString)
          window[id] = WarmedAsset(asset: asset, users: missing[id, default: 1])
          start.append(asset)
        }
      }
      if !window.isEmpty { warmed[pixelSize] = window }
      guard !start.isEmpty else { return }
      manager.startCachingImages(
        for: start, targetSize: pixelSize, contentMode: .aspectFill, options: Self.cachingOptions)
    }
  }

  public func stopCaching(ids: [String], pixelSize: CGSize) {
    warming.async { [self] in
      guard var window = warmed.removeValue(forKey: pixelSize) else { return }
      var stop: [PHAsset] = []
      for id in ids {
        guard let entry = window[id] else { continue }
        if entry.users == 1 {
          window[id] = nil
          stop.append(entry.asset)
        } else {
          window[id]?.users -= 1
        }
      }
      if !window.isEmpty { warmed[pixelSize] = window }
      guard !stop.isEmpty else { return }
      manager.stopCachingImages(
        for: stop, targetSize: pixelSize, contentMode: .aspectFill, options: Self.cachingOptions)
    }
  }

  public func stopCachingAll() {
    warming.async { [self] in
      warmed.removeAll()
      manager.stopCachingImagesForAllAssets()
    }
  }

  private static let redrawQueue = DispatchQueue(label: "PhotoKitImageSource.redraw", qos: .userInitiated)

  #if canImport(UIKit)
    /// Layers ignore `imageOrientation`, so a rotated result is redrawn upright.
    static func cgImage(_ image: UIImage) -> CGImage? {
      guard image.imageOrientation != .up else { return image.cgImage }
      let format = UIGraphicsImageRendererFormat.preferred()
      format.scale = image.scale
      return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    /// The image as a layer can show it. One stored on its side is redrawn upright off the
    /// main thread, where PhotoKit delivers, so cells scrolling in don't each draw there.
    static func upright(_ image: UIImage, deliver: @escaping @Sendable (CGImage?) -> Void) {
      if image.imageOrientation == .up {
        deliver(image.cgImage)
        return
      }
      redrawQueue.async {
        deliver(cgImage(image))
      }
    }
  #else
    static func cgImage(_ image: NSImage) -> CGImage? {
      image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func upright(_ image: NSImage, deliver: @escaping @Sendable (CGImage?) -> Void) {
      redrawQueue.async { deliver(cgImage(image)) }
    }
  #endif
}
