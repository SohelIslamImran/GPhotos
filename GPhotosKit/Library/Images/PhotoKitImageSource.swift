import CoreGraphics
import Foundation
import Photos

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
    case .display:
      options.deliveryMode = .opportunistic
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = true
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
    deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    requestImage(id: id, pixelSize: pixelSize, quality: quality, onUnavailable: nil, deliver: deliver)
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, onUnavailable: (@Sendable () -> Void)?,
    deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let asset = asset(for: id), onUnavailable == nil || !asset.isHidden else {
      onUnavailable?()
      return .none
    }
    // The viewer shows whole photos; aspect fill with an exact size would crop them.
    let contentMode: PHImageContentMode = quality == .display ? .aspectFit : .aspectFill
    let manager = self.manager
    let token = RequestIDs(manager: manager)
    let first = manager.requestImage(
      for: asset, targetSize: pixelSize, contentMode: contentMode, options: Self.options(for: quality)
    ) { image, info in
      if let image {
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        Self.upright(image) { deliver($0, !degraded) }
        if !degraded || quality != .thumbnail { return }
      }
      // Not on this device yet: a thumbnail on screen may download.
      guard quality == .thumbnail, (info?[PHImageResultIsInCloudKey] as? Bool) == true,
        (info?[PHImageCancelledKey] as? Bool) != true, !token.isCancelled
      else {
        if image == nil, (info?[PHImageCancelledKey] as? Bool) != true, (info?[PHImageResultIsDegradedKey] as? Bool) != true {
          onUnavailable?()
        }
        return
      }
      let options = Self.options(for: .thumbnail)
      options.isNetworkAccessAllowed = true
      token.add(
        manager.requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode, options: options) {
          image, info in
          let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
          guard let image else {
            if !degraded, (info?[PHImageCancelledKey] as? Bool) != true { onUnavailable?() }
            return
          }
          Self.upright(image) { deliver($0, !degraded) }
        })
    }
    token.add(first)
    return ImageRequestToken {
      for id in token.cancel() { manager.cancelImageRequest(id) }
    }
  }

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

  public func startCaching(ids: [String], pixelSize: CGSize) {
    let list = ids.compactMap(asset(for:))
    guard !list.isEmpty else { return }
    manager.startCachingImages(
      for: list, targetSize: pixelSize, contentMode: .aspectFill, options: Self.cachingOptions)
  }

  public func stopCaching(ids: [String], pixelSize: CGSize) {
    // Assets the small asset cache already evicted are fetched again, or PhotoKit would
    // keep their pre-decoded images for good.
    var list: [PHAsset] = []
    var missing: [String] = []
    for id in ids {
      if let asset = assets.object(forKey: id as NSString) { list.append(asset) } else { missing.append(id) }
    }
    if !missing.isEmpty {
      // A database fetch; off the main thread so a fast scroll doesn't wait for it. Arriving
      // late at worst stops warming an item scrolled back to, which then loads on demand.
      let manager = manager
      DispatchQueue.global(qos: .utility).async { [missing] in
        var evicted: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
          evicted.append(asset)
        }
        manager.stopCachingImages(
          for: evicted, targetSize: pixelSize, contentMode: .aspectFill, options: Self.cachingOptions)
      }
    }
    guard !list.isEmpty else { return }
    manager.stopCachingImages(
      for: list, targetSize: pixelSize, contentMode: .aspectFill, options: Self.cachingOptions)
  }

  public func stopCachingAll() {
    manager.stopCachingImagesForAllAssets()
  }

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
    private static let redrawQueue = DispatchQueue(label: "PhotoKitImageSource.redraw", qos: .userInitiated)

    static func upright(_ image: UIImage, deliver: @escaping @Sendable (CGImage) -> Void) {
      if image.imageOrientation == .up {
        if let cgImage = image.cgImage { deliver(cgImage) }
        return
      }
      redrawQueue.async {
        if let cgImage = cgImage(image) { deliver(cgImage) }
      }
    }
  #else
    static func cgImage(_ image: NSImage) -> CGImage? {
      image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func upright(_ image: NSImage, deliver: @escaping @Sendable (CGImage) -> Void) {
      if let cgImage = cgImage(image) { deliver(cgImage) }
    }
  #endif
}
