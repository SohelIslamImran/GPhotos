import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

#if os(iOS)
  import SwiftUI
  import UIKit
#endif

@Suite("Viewer first frames")
struct FilmstripPreviewTests {
  @Test func prefersWholeViewerPreviewThenMatchingThumbnail() throws {
    let whole = try image(64, 96)
    let gridCrop = try image(128, 128)
    let slice = try image(32, 48)
    let portrait = CGSize(width: 2, height: 3)
    #expect(ViewerImage.preview(whole: whole, thumbnail: gridCrop, slice: slice, pixels: portrait) === whole)
    #expect(ViewerImage.preview(whole: nil, thumbnail: gridCrop, slice: slice, pixels: portrait) === slice)
    #expect(ViewerImage.preview(whole: nil, thumbnail: gridCrop, slice: nil, pixels: portrait) === gridCrop)
    #expect(!ViewerImage.matchesAspect(gridCrop, portrait))
  }

  @Test func smallerOrEqualDegradedImageDoesNotReplaceFirstFrame() throws {
    let small = try image(32, 48)
    let larger = try image(64, 96)
    #expect(!ViewerImage.accepts(small, over: larger, isFinal: false))
    #expect(!ViewerImage.accepts(small, over: larger, isFinal: true))
    #expect(!ViewerImage.accepts(larger, over: larger, isFinal: false))
    #expect(ViewerImage.accepts(larger, over: larger, isFinal: true))
    #expect(ViewerImage.accepts(larger, over: small, isFinal: false))
  }

  #if os(iOS)
    @Test @MainActor func aContextPreviewDoesNotDisplayLockedPixels() throws {
      let email = "preview-\(UUID().uuidString)@example.com"
      let key = "preview-\(UUID().uuidString)"
      defer { LockedItems.forget(accountEmail: email) }
      let identity = ThumbnailIdentity(id: RemoteThumbnailID(mediaKey: key, contentVersion: 1).string, version: 0, accountEmail: email)
      LockedItems.insert([key], accountEmail: email)
      let preview = PhotoPreviewController(image: try image(16, 16), size: CGSize(width: 16, height: 16), identity: identity)
      #expect((preview.view as? UIImageView)?.image == nil)
    }

    @Test @MainActor func movingTheSelectedItemKeepsTheExistingUIKitPage() {
      let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
      let coordinator = PagedViewerRepresentable<EmptyView>.Coordinator()
      coordinator.count = 2
      coordinator.pageID = { ["playing", "next"][$0] }
      let original = coordinator.host(0)
      controller.setViewControllers([original], direction: .forward, animated: false)
      coordinator.count = 3
      coordinator.pageID = { ["inserted", "playing", "next"][$0] }

      // PageSelection has already resolved the moved index before the representable updates.
      #expect(coordinator.relocateDisplayedPage(in: controller, to: 1, locate: nil) == 1)
      #expect(controller.viewControllers?.first === original)
      #expect(original.index == 1)
      #expect(original.itemID == "playing")
      #expect(coordinator.relocateDisplayedPage(in: controller, to: 2, locate: nil) == nil)
    }

    @Test @MainActor func aMissKeepsTheFrameAndOnlyTheTargetCanReleaseTheHandoff() throws {
      let preview = ScrubPreviewView()
      let current = try image(32, 48)
      let incoming = try image(64, 96)
      let source = NoImages()
      let pixels = CGSize(width: 2, height: 3)
      preview.show(identity: ThumbnailIdentity(id: "initial"), pixels: pixels, slice: current, source: source, dwell: false, onDwell: {})
      preview.show(identity: ThumbnailIdentity(id: "next"), pixels: pixels, slice: nil, source: source, dwell: false, onDwell: {})
      #expect(!preview.isHidden)
      let shown = try #require(preview.layer.sublayers?.first?.contents)
      #expect(shown as AnyObject === current)
      preview.commit(id: "next", alreadyReady: false)
      preview.pageImageReady("initial")
      #expect(!preview.isHidden)
      #expect(preview.handoffImage(for: "next") == nil)
      preview.receive(incoming, identity: ThumbnailIdentity(id: "next"), isFinal: true, isWhole: false)
      #expect(preview.handoffImage(for: "next") === incoming)
      preview.pageImageReady("next")
      #expect(preview.isHidden)
    }

    @Test @MainActor func coldMissLeavesTheNativePageVisible() throws {
      let overlay = ScrubPreviewView()
      let identity = ThumbnailIdentity(id: "cold")
      overlay.show(identity: identity, pixels: .zero, slice: nil, source: NoImages(), dwell: false, onDwell: {})
      #expect(overlay.isHidden)
      let frame = try image(48, 32)
      overlay.receive(frame, identity: identity, isFinal: true, isWhole: true)
      #expect(!overlay.isHidden)
      #expect(overlay.layer.sublayers?.first?.contents as AnyObject? === frame)
      #expect(ScrubPreviewView.dwellPixels(.zero, in: CGSize(width: 300, height: 500)) == CGSize(width: 500, height: 500))
    }

    private final class NoImages: ThumbnailSource {
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        onUnavailable()
        return .none
      }
    }
  #endif

  private func image(_ width: Int, _ height: Int) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }
}
