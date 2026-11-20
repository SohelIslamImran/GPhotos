import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

#if os(macOS)
  import AppKit
#endif

@Suite("Photo grid")
struct PhotoGridTests {
  @Test(
    "Backup-filtered collections seed confirmations without publishing an initial unfiltered fetch",
    arguments: [LibraryFilter.notBackedUp, .backedUp])
  @MainActor
  func initialBackupConfirmations(_ filter: LibraryFilter) async {
    let model = PhotoLibraryGridModel(filter: filter)
    let record = TransferRecord(
      id: "me@example.com|asset", filename: "image.jpg", mediaType: "Photo", status: .sent, assetLocalIdentifier: "asset")
    await model.updateBackupStates(from: [record], accountEmail: "me@example.com")
    #expect(!model.isLoaded)
    #expect(model.itemCount == 0)
    #expect(model.badgeToken == 1)
  }

  @Test("Native geometry reports leave the render pass and publish only the latest values")
  @MainActor
  func deferredGeometryReports() async {
    let coordinator = PhotoGridCoordinator()
    var ends: [Bool] = []
    var scrolled: [Bool] = []
    var tops: [Int] = []
    await withCheckedContinuation { continuation in
      coordinator.options.onAtEndChange = { ends.append($0) }
      coordinator.options.onScrolledUnderBarChange = { scrolled.append($0) }
      coordinator.options.onTopIndexChange = {
        tops.append($0)
        continuation.resume()
      }
      coordinator.reportTop(1)
      coordinator.reportTop(2)
      coordinator.reportTop(3)
      coordinator.reportAtEnd(false)
      coordinator.reportAtEnd(true)
      coordinator.reportAtEnd(false)
      coordinator.reportScrolled(false)
      coordinator.reportScrolled(true)
      #expect(ends.isEmpty && scrolled.isEmpty && tops.isEmpty)
    }
    #expect(ends == [false])
    #expect(scrolled == [true])
    #expect(tops == [3])
  }

  #if os(macOS)
    @Test("Image scroll-view focus forwards paging and dismissal to its viewer")
    @MainActor
    func nativeViewerKeys() throws {
      let view = ViewerKeyboardView(frame: .zero)
      var actions: [ViewerKeyboardAction] = []
      view.onAction = { actions.append($0) }
      for code: UInt16 in [123, 124, 53, 49] {
        let event = try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        #expect(view.route(event, firstResponder: ZoomingImageScrollView()))
        #expect(!view.route(event, firstResponder: NSTextView()))
      }
      #expect(actions == [.previous, .next, .escape, .space])
    }

    @Test("The native viewer preserves portrait proportions and zoom during sharper image delivery")
    @MainActor
    func nativeViewerGeometry() throws {
      let context = try #require(
        CGContext(
          data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let image = try #require(context.makeImage())
      let view = ZoomingImageScrollView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
      let size = AspectFit.orientedSize(decoded: CGSize(width: 100, height: 200), metadata: CGSize(width: 4000, height: 2250))
      view.setContent(image: image, pixelSize: size)
      view.layoutSubtreeIfNeeded()
      let content = try #require(view.documentView)
      #expect(content.frame.size == CGSize(width: 450, height: 900))
      #expect(content.layer?.contentsGravity == .resizeAspect)
      view.magnification = 2
      view.setContent(image: image, pixelSize: CGSize(width: 4000, height: 8000))
      #expect(view.magnification == 2)
    }
  #endif

  @Test("Viewer sizing follows the decoded image orientation instead of stretching to metadata")
  func decodedViewerAspect() {
    let size = AspectFit.orientedSize(decoded: CGSize(width: 100, height: 200), metadata: CGSize(width: 4000, height: 2250))
    #expect(size == CGSize(width: 2000, height: 4000))
    #expect(AspectFit.size(for: size, in: CGSize(width: 1600, height: 900)) == CGSize(width: 450, height: 900))
    #expect(AspectFit.orientedSize(decoded: .zero, metadata: CGSize(width: 10, height: 20)) == CGSize(width: 10, height: 20))
  }

  @Test("Missing viewer metadata falls back to the decoded size")
  func missingViewerDimensions() {
    let decoded = CGSize(width: 300, height: 400)
    #expect(AspectFit.orientedSize(decoded: decoded, metadata: .zero) == decoded)
    #expect(AspectFit.orientedSize(decoded: .zero, metadata: CGSize(width: 4000, height: 0)) == .zero)
  }

  @Test("EXIF preserves or swaps display dimensions", arguments: 1...8)
  func exifViewerDimensions(orientation: Int) {
    let size = CGSize(width: 4000, height: 3000)
    let expected = orientation < 5 ? size : CGSize(width: 3000, height: 4000)
    #expect(AspectFit.uprightSize(size, exifOrientation: orientation) == expected)
  }

  @Test("A translated, quarter-turned video fits upright")
  func rotatedVideoDimensions() {
    let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let size = AspectFit.uprightSize(CGSize(width: 1920, height: 1080), videoTransform: transform)
    #expect(size == CGSize(width: 1080, height: 1920))
  }

  @Test("A pinch's own steps echoed back by SwiftUI are not applied again")
  @MainActor
  func zoomStepEchoes() {
    let coordinator = PhotoGridCoordinator()
    coordinator.zoomStepChanged(to: 3)
    // A pinch steps 3 → 4 → 5 while SwiftUI still hands back 3 and 4.
    coordinator.zoomStepChanged(to: 4)
    coordinator.zoomStepChanged(to: 5)
    #expect(!coordinator.shouldApplyZoomStep(3, current: 5))
    #expect(!coordinator.shouldApplyZoomStep(4, current: 5))
    // Caught up: only the shown step is expected back now, and anything else is a command.
    #expect(!coordinator.shouldApplyZoomStep(5, current: 5))
    #expect(coordinator.shouldApplyZoomStep(4, current: 5))
    #expect(coordinator.shouldApplyZoomStep(6, current: 5))
  }

  @Test("Zoom In followed by Zoom Out works without an extra SwiftUI acknowledgement")
  @MainActor
  func toolbarZoomRoundTrip() {
    let coordinator = PhotoGridCoordinator()
    var current = 4
    coordinator.zoomStepChanged(to: current)
    for target in [3, 4, 3, 4] {
      #expect(coordinator.shouldApplyZoomStep(target, current: current))
      current = target
      // The native grid reports the same value the toolbar just set. SwiftUI can
      // coalesce this assignment, so there may be no update at the new step.
      coordinator.zoomStepChanged(to: target)
    }
  }

  @Test("Frames tile the width and rows follow the item count")
  func layoutGeometry() {
    let layout = PhotoGridLayout(columns: 4, spacing: 2, width: 402, itemCount: 10)
    #expect(layout.itemSide == 99)
    #expect(layout.rowCount == 3)
    #expect(layout.frame(at: 0).minX == 0)
    #expect(layout.frame(at: 3).maxX == 402)
    #expect(layout.frame(at: 4).minY == 101)
    #expect(layout.contentHeight == 301)
  }

  @Test("Indices in a rect cover exactly the intersecting rows")
  func indicesInRect() {
    let layout = PhotoGridLayout(columns: 3, spacing: 0, width: 300, itemCount: 100)
    #expect(layout.indices(in: CGRect(x: 0, y: 0, width: 300, height: 100)) == 0..<6)
    #expect(layout.indices(in: CGRect(x: 0, y: 150, width: 300, height: 10)) == 3..<6)
    #expect(layout.indices(in: CGRect(x: 0, y: 3_350, width: 300, height: 500)) == 99..<100)
    #expect(layout.indices(in: CGRect(x: 0, y: 99_999, width: 300, height: 10)).isEmpty)
  }

  @Test("Transient and extreme AppKit bounds never overflow grid index conversion")
  func extremeVisibleBounds() {
    let layout = PhotoGridLayout(columns: 3, spacing: 0, width: 300, itemCount: 100)
    #expect(layout.indices(in: .infinite).isEmpty)
    #expect(layout.indices(in: .null).isEmpty)
    #expect(layout.indices(in: CGRect(x: 0, y: CGFloat.nan, width: 300, height: 100)).isEmpty)
    #expect(layout.indices(in: CGRect(x: 0, y: 1e300, width: 300, height: 100)).isEmpty)
    #expect(layout.indices(in: CGRect(x: 0, y: -1e300, width: 300, height: 100)).isEmpty)
    #expect(layout.indices(in: CGRect(x: 0, y: -1e300, width: 300, height: 1e300)) == 0..<3)
    #expect(layout.indices(in: CGRect(x: 0, y: 0, width: 300, height: 1e300)) == 0..<100)
    for point in [
      CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: CGFloat.infinity),
      CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 1e300, y: 1e300),
    ] {
      #expect(layout.index(at: point) == nil)
    }
    let huge = PhotoGridLayout(columns: 3, spacing: 0, width: 300, itemCount: Int.max)
    #expect(huge.rowCount == Int.max / 3 + 1)
    #expect(huge.indices(in: CGRect(x: 0, y: 0, width: 300, height: 1e300)) == 0..<Int.max)
  }

  @Test("Hit testing finds cells and ignores gaps")
  func hitTesting() {
    let layout = PhotoGridLayout(columns: 2, spacing: 10, width: 210, itemCount: 3)
    #expect(layout.index(at: CGPoint(x: 50, y: 50)) == 0)
    #expect(layout.index(at: CGPoint(x: 150, y: 50)) == 1)
    #expect(layout.index(at: CGPoint(x: 105, y: 50)) == nil)
    #expect(layout.index(at: CGPoint(x: 150, y: 150)) == nil)
  }

  @Test("Pinching keeps the anchored item at the same height on screen")
  func zoomAnchor() {
    let dense = PhotoGridLayout(columns: 7, spacing: 1, width: 400, itemCount: 1_000)
    let offset = dense.offsetKeeping(index: 300, atViewportY: 200)
    #expect(dense.frame(at: 300).midY - offset == 200)
  }

  @Test("Thumbnail buckets round up and stop at the largest")
  func buckets() {
    #expect(ThumbnailBucket.forPixelSide(90) == .tiny)
    #expect(ThumbnailBucket.forPixelSide(300) == .medium)
    #expect(ThumbnailBucket.forPixelSide(5_000) == .huge)
  }

  @Test("Prefetch windows send only what entered or left")
  func rangeSubtraction() {
    #expect(PhotoGridRenderer.subtract(0..<10, 5..<15) == [0..<5])
    #expect(PhotoGridRenderer.subtract(5..<15, 0..<10) == [10..<15])
    #expect(PhotoGridRenderer.subtract(0..<20, 5..<10) == [0..<5, 10..<20])
    #expect(PhotoGridRenderer.subtract(0..<5, 10..<20) == [0..<5])
    #expect(PhotoGridRenderer.subtract(5..<10, 0..<20).isEmpty)
  }

  @Test("An asset shows its worst backup state")
  func backupBadges() {
    func record(_ id: String, _ asset: String, _ status: TransferStatus) -> TransferRecord {
      TransferRecord(id: id, filename: id, mediaType: "Photo", status: status, assetLocalIdentifier: asset)
    }
    let states = PhotoLibraryGridModel.backupStates(from: [
      record("1", "a", .sent), record("2", "a", .pending),
      record("3", "b", .failed), record("4", "b", .sent),
      record("5", "c", .deleted),
      TransferRecord(id: "6", filename: "f", mediaType: "Photo", status: .sent),
    ])
    #expect(states == ["a": .pending, "b": .failed, "c": .backedUp])
  }

  private final class CountingSource: ThumbnailSource, @unchecked Sendable {
    let lock = NSLock()
    var requests = 0
    var cancels = 0
    var pending: [@Sendable (CGImage, Bool) -> Void] = []

    func requestImage(
      id: String, pixelSize: CGSize, quality: ImageRequestQuality, deliver: @escaping @Sendable (CGImage, Bool) -> Void
    ) -> ImageRequestToken {
      lock.withLock {
        requests += 1
        pending.append(deliver)
      }
      return ImageRequestToken { [self] in lock.withLock { cancels += 1 } }
    }
  }

  private static func image() -> CGImage {
    let context = CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    return context.makeImage()!
  }

  @MainActor
  @Test("Identical requests share one source request and cancel only when all do")
  func coalescing() {
    let pipeline = ThumbnailPipeline(costLimit: 1 << 20)
    let source = CountingSource()
    let key = ThumbnailKey(id: "x", bucket: .small)
    let first = pipeline.load(key, from: source) { _, _ in }
    let second = pipeline.load(key, from: source) { _, _ in }
    #expect(source.requests == 1)
    first.cancel()
    #expect(source.cancels == 0)
    second.cancel()
    #expect(source.cancels == 1)
  }

  @MainActor
  @Test("A cancelled thumbnail cannot satisfy a replacement request for the same key")
  func replacedThumbnailRequest() {
    let pipeline = ThumbnailPipeline(costLimit: 1 << 20)
    let source = CountingSource()
    let key = ThumbnailKey(id: "remote", bucket: .small)
    let first = pipeline.load(key, from: source) { _, _ in }
    first.cancel()
    var received = 0
    _ = pipeline.load(key, from: source) { _, _ in received += 1 }
    source.pending[0](Self.image(), true)
    #expect(received == 0)
    #expect(pipeline.cachedImage(for: key) == nil)
    source.pending[1](Self.image(), true)
    #expect(received == 1)
  }

  @MainActor
  @Test("A delivered image is cached and stands in for other sizes")
  func cachingAndPlaceholders() async {
    let pipeline = ThumbnailPipeline(costLimit: 1 << 20)
    let source = CountingSource()
    let key = ThumbnailKey(id: "x", bucket: .small)
    var received = 0
    let ticket = pipeline.load(key, from: source) { _, _ in received += 1 }
    // The request can start a moment after `load` returns.
    for _ in 0..<200 where source.pending.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    source.pending.first?(Self.image(), true)
    // Delivery hops to the main actor; give a busy machine time.
    for _ in 0..<200 where pipeline.cachedImage(for: key) == nil { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(received == 1)
    #expect(pipeline.cachedImage(for: key) != nil)
    #expect(pipeline.placeholder(for: ThumbnailKey(id: "x", bucket: .huge)) != nil)
    #expect(pipeline.placeholder(for: ThumbnailKey(id: "y", bucket: .huge)) == nil)
    _ = pipeline.load(key, from: source) { _, _ in received += 1 }
    #expect(source.requests == 1)
    #expect(received == 2)
    ticket.cancel()
  }
}
