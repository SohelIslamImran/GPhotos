import CoreGraphics
import Foundation
import Observation

enum ViewerImage {
  static func size(_ image: CGImage) -> CGSize { CGSize(width: image.width, height: image.height) }

  static func longSide(_ image: CGImage?) -> Int {
    image.map { max($0.width, $0.height) } ?? 0
  }

  static func matchesAspect(_ image: CGImage, _ pixels: CGSize) -> Bool {
    guard pixels.width > 0, pixels.height > 0 else { return true }
    return abs(Double(image.width) * pixels.height / (Double(image.height) * pixels.width) - 1) < 0.02
  }

  static func preview(whole: CGImage?, thumbnail: CGImage?, slice: CGImage?, pixels: CGSize) -> CGImage? {
    if let whole { return whole }
    if let thumbnail, matchesAspect(thumbnail, pixels) { return thumbnail }
    if let slice, matchesAspect(slice, pixels) { return slice }
    return thumbnail ?? slice
  }

  @MainActor
  static func preview(for identity: ThumbnailIdentity, pixels: CGSize, slice: CGImage? = nil) -> (image: CGImage, cropped: Bool)? {
    guard !identity.id.isEmpty, !identity.isLocked else { return nil }
    let pipeline = ThumbnailPipeline.shared
    if let whole = pipeline.viewerPreview(for: identity) { return (whole, false) }
    let thumbnail = pipeline.placeholder(for: ThumbnailKey(identity: identity, bucket: .huge))
    guard let image = preview(whole: nil, thumbnail: thumbnail, slice: slice, pixels: pixels) else { return nil }
    return (image, !matchesAspect(image, pixels))
  }

  static func accepts(_ candidate: CGImage, over current: CGImage?, isFinal: Bool) -> Bool {
    let incoming = longSide(candidate)
    let shown = longSide(current)
    return current == nil || incoming > shown || (isFinal && incoming == shown)
  }

  static func fittedPixels(_ pixels: CGSize, in container: CGSize, scale: CGFloat) -> CGSize {
    guard container.width > 0, container.height > 0 else { return .zero }
    let screen = CGSize(width: container.width * scale, height: container.height * scale)
    guard pixels.width > 0, pixels.height > 0 else { return screen }
    let fitted = AspectFit.size(for: pixels, in: screen)
    return fitted.width >= pixels.width ? pixels : fitted
  }

  static func isFitted(_ image: CGImage, target: CGSize) -> Bool {
    // PhotoKit and the file decoder can round the result to a nearby size.
    matchesAspect(image, target) && CGFloat(longSide(image)) >= max(target.width, target.height) * 0.95
  }

  @MainActor
  static func hasFittedPreview(for identity: ThumbnailIdentity, target: CGSize, isFile: Bool = false) -> Bool {
    let pipeline = ThumbnailPipeline.shared
    guard let image = pipeline.viewerPreview(for: identity) else { return false }
    if isFile {
      let side = max(target.width, target.height)
      return pipeline.rememberedFileRequest(for: identity) >= side || isFitted(image, target: CGSize(width: side, height: 0))
    }
    return isFitted(image, target: target)
  }

  @MainActor
  static func request(
    _ source: any ThumbnailSource, identity: ThumbnailIdentity, pixels: CGSize,
    quality: ImageRequestQuality = .display, isFile: Bool = false, joining preferredSize: CGSize? = nil,
    onEnd: @escaping () -> Void = {}, deliver: @escaping (CGImage, Bool) -> Void
  ) -> ThumbnailTicket {
    let pipeline = ThumbnailPipeline.shared
    let receive: (CGImage, Bool) -> Void = { image, isFinal in
      if isFinal {
        let current = pipeline.viewerPreview(for: identity)
        let side = isFile ? max(pixels.width, pixels.height) : 0
        if accepts(image, over: current, isFinal: true) {
          pipeline.rememberViewerPreview(image, for: identity, fileRequestSide: side)
        } else if let current, side > pipeline.rememberedFileRequest(for: identity) {
          pipeline.rememberViewerPreview(current, for: identity, fileRequestSide: side)
        }
      }
      deliver(image, isFinal)
      if isFinal { onEnd() }
    }
    if let preferredSize, preferredSize != pixels,
      let ticket = pipeline.loadPreview(
        identity, pixels: preferredSize, from: source, quality: quality, joiningOnly: true, onUnavailable: onEnd, handler: receive)
    {
      return ticket
    }
    return pipeline.loadPreview(identity, pixels: pixels, from: source, quality: quality, onUnavailable: onEnd, handler: receive)
      ?? ThumbnailTicket()
  }

  /// A current PhotoKit page first joins its neighbour's local-only request. If that
  /// request misses or returns a smaller rendition, only the current page may use iCloud.
  @MainActor
  static func requestCurrentAsset(
    _ source: any ThumbnailSource, identity: ThumbnailIdentity, pixels: CGSize,
    onEnd: @escaping () -> Void = {}, deliver: @escaping (CGImage, Bool) -> Void
  ) -> ThumbnailTicket {
    var display: ThumbnailTicket?
    let upgrade = { display = request(source, identity: identity, pixels: pixels, onEnd: onEnd, deliver: deliver) }
    guard
      let local = ThumbnailPipeline.shared.loadPreview(
        identity, pixels: pixels, from: source, quality: .localDisplay, joiningOnly: true, onUnavailable: upgrade,
        handler: { image, isFinal in
          deliver(image, isFinal)
          guard isFinal else { return }
          if isFitted(image, target: pixels) { onEnd() } else { upgrade() }
        })
    else { return request(source, identity: identity, pixels: pixels, onEnd: onEnd, deliver: deliver) }
    return ThumbnailTicket {
      local.cancel()
      display?.cancel()
    }
  }
}

/// Keeps local requests close to the settled page, including one the current page can join.
@MainActor
@Observable
final class ViewerNeighborRequests {
  struct Target: Equatable {
    let identity: ThumbnailIdentity
    let pixels: CGSize
    let isFile: Bool
  }

  private(set) var revision = 0
  @ObservationIgnored private var requests: [(Target, ThumbnailTicket)] = []

  func update(_ targets: [Target], keeping current: Target? = nil) {
    for (target, token) in requests where target != current && !targets.contains(target) { token.cancel() }
    requests.removeAll { $0.0 != current && !targets.contains($0.0) }
    for target in targets where !requests.contains(where: { $0.0 == target }) {
      guard !ViewerImage.hasFittedPreview(for: target.identity, target: target.pixels, isFile: target.isFile) else { continue }
      let source: any ThumbnailSource = target.isFile ? FolderLibrary.shared.thumbnails : PhotoKitImageSource.shared
      let token = ViewerImage.request(
        source, identity: target.identity, pixels: target.pixels, quality: target.isFile ? .display : .localDisplay,
        isFile: target.isFile
      ) { [weak self] _, isFinal in
        if isFinal { self?.revision &+= 1 }
      }
      requests.append((target, token))
    }
  }
}
