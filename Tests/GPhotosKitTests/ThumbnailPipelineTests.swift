import CoreGraphics
import Foundation
import Testing
import os

@testable import GPhotosKit

@MainActor
@Suite("Thumbnail pipeline")
struct ThumbnailPipelineTests {
  private final class Source: ThumbnailSource, Sendable {
    typealias Request =
      @Sendable (
        String, ImageRequestQuality, @escaping @Sendable () -> Void, @escaping @Sendable (CGImage, Bool) -> Void
      ) -> Void
    let request: Request

    init(_ request: @escaping Request) { self.request = request }

    func requestImage(
      id: String, pixelSize: CGSize, quality: ImageRequestQuality,
      onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
    ) -> ImageRequestToken {
      request(id, quality, onUnavailable, deliver)
      return ImageRequestToken()
    }
  }

  private func image(width: Int = 8, height: Int = 8) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  @Test("An equal-size fast miss and sharp request complete independently")
  func fastMiss() throws {
    let image = try image()
    let pipeline = ThumbnailPipeline()
    let key = ThumbnailKey(id: "photo", bucket: .tiny)
    let miss = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    // Save the fast miss until after the sharp subscriber has attached.
    let source = Source { _, quality, unavailable, deliver in
      if quality == .fast {
        miss.withLock { $0 = unavailable }
      } else {
        deliver(image, true)
      }
    }
    var unavailable = 0
    var sharp: CGImage?
    _ = pipeline.load(
      key, from: source, quality: .fast, onUnavailable: { unavailable += 1 },
      handler: { _, _ in Issue.record("The fast request should miss") })
    _ = pipeline.load(key, from: source) { image, _ in sharp = image }
    let finish = try #require(miss.withLock { $0 })
    finish()
    #expect(sharp === image)
    #expect(unavailable == 1)
  }

  @Test("A cached fast result remains a placeholder when sharp pixels are requested")
  func fastCache() throws {
    let fast = try image()
    let sharp = try image(width: 64, height: 64)
    let pipeline = ThumbnailPipeline()
    let key = ThumbnailKey(id: "photo", bucket: .small)
    let source = Source { _, quality, _, deliver in deliver(quality == .fast ? fast : sharp, true) }
    _ = pipeline.load(key, from: source, quality: .fast) { _, _ in }
    #expect(pipeline.placeholder(for: key) === fast)
    #expect(pipeline.cachedImage(for: key) == nil)
    _ = pipeline.load(key, from: source) { image, _ in #expect(image === sharp) }
    #expect(pipeline.cachedImage(for: key) === sharp)
  }

  @Test("A synchronous miss removes the flight before the next request")
  func failedFlight() {
    let pipeline = ThumbnailPipeline()
    let key = ThumbnailKey(id: "photo", bucket: .small)
    let source = Source { _, _, unavailable, _ in
      unavailable()
      unavailable()
    }
    var misses = 0
    for _ in 0..<2 {
      _ = pipeline.load(
        key, from: source, onUnavailable: { misses += 1 },
        handler: { _, _ in Issue.record("This source delivers no image") })
    }
    #expect(misses == 2)
  }

  @Test("Late subscribers get the active flight's degraded image until a miss ends it")
  func degradedReplay() throws {
    let preview = try image()
    let pipeline = ThumbnailPipeline()
    let key = ThumbnailKey(id: "photo", bucket: .small)
    let miss = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    let source = Source { _, _, unavailable, deliver in
      miss.withLock { $0 = unavailable }
      deliver(preview, false)
    }
    let preload = pipeline.load(key, from: source) { _, _ in }
    var images = 0
    var misses = 0
    let visible = pipeline.load(
      key, from: source, onUnavailable: { misses += 1 },
      handler: { image, final in
        #expect(image === preview && !final)
        images += 1
      })
    #expect(images == 1)
    preload.cancel()
    let finish = try #require(miss.withLock { $0 })
    finish()
    #expect(misses == 1)
    #expect(pipeline.cachedImage(for: key) == nil)
    visible.cancel()
  }

  @Test("Route invalidation removes all renditions, including viewer-only previews")
  func invalidateRemoteRoute() throws {
    let image = try image()
    let pipeline = ThumbnailPipeline()
    let affected = RemoteThumbnailID(mediaKey: "changed", contentVersion: 1).string
    let viewerOnly = RemoteThumbnailID(mediaKey: "changed", contentVersion: 2).string
    let unaffected = RemoteThumbnailID(mediaKey: "unchanged", contentVersion: 1).string
    let key = ThumbnailKey(id: affected, bucket: .tiny)
    let source = Source { _, _, _, deliver in deliver(image, true) }
    _ = pipeline.load(key, from: source, quality: .fast) { _, _ in }
    _ = pipeline.load(key, from: source) { _, _ in }
    pipeline.rememberViewerPreview(image, for: viewerOnly)
    pipeline.rememberViewerPreview(image, for: unaffected)
    let pending = Source { _, _, _, _ in }
    var misses = 0
    _ = pipeline.load(
      ThumbnailKey(id: affected, bucket: .large), from: pending,
      onUnavailable: { misses += 1 }, handler: { _, _ in })

    pipeline.invalidateRemoteImages(where: { $0 == "changed" })

    #expect(pipeline.placeholder(for: key) == nil)
    #expect(pipeline.viewerPreview(for: viewerOnly) == nil)
    #expect(pipeline.viewerPreview(for: unaffected) === image)
    #expect(misses == 1)
  }

  @Test("A current asset joins the local fitted request and can fall back to iCloud", arguments: [false, true])
  func activePageJoinsNeighbor(localMiss: Bool) throws {
    let identity = ThumbnailIdentity(id: UUID().uuidString, version: 1)
    let pixels = CGSize(width: 32, height: 64)
    let frame = try image(width: 32, height: 64)
    let requests = OSAllocatedUnfairLock(initialState: [ImageRequestQuality]())
    typealias Finish = @Sendable () -> Void
    let local = OSAllocatedUnfairLock<Finish?>(initialState: nil)
    let source = Source { _, quality, unavailable, deliver in
      requests.withLock { $0.append(quality) }
      if quality == .localDisplay {
        local.withLock { $0 = { if localMiss { unavailable() } else { deliver(frame, true) } } }
      } else {
        deliver(frame, true)
      }
    }
    let neighbor = ViewerImage.request(source, identity: identity, pixels: pixels, quality: .localDisplay) { _, _ in }
    var received: CGImage?
    let active = ViewerImage.requestCurrentAsset(source, identity: identity, pixels: pixels) { image, final in
      if final { received = image }
    }
    #expect(requests.withLock { $0 } == [.localDisplay])
    neighbor.cancel()
    let finish = try #require(local.withLock { $0 })
    finish()
    #expect(received === frame)
    #expect(requests.withLock { $0 } == (localMiss ? [.localDisplay, .display] : [.localDisplay]))
    active.cancel()
  }

  @Test("A small file decoded at a screen-sized target is still ready at that target")
  func smallFilePreview() throws {
    let identity = ThumbnailIdentity(id: "f:" + UUID().uuidString, version: 1)
    let pixels = CGSize(width: 800, height: 800)
    let frame = try image()
    let source = Source { _, _, _, deliver in deliver(frame, true) }
    _ = ViewerImage.request(source, identity: identity, pixels: pixels, isFile: true) { _, _ in }
    #expect(ViewerImage.hasFittedPreview(for: identity, target: pixels, isFile: true))
    #expect(!ViewerImage.hasFittedPreview(for: identity, target: pixels))
  }

  @Test("Purging a media key drops its versions, sizes and viewer flights before late callbacks")
  func purgeDropsLatePixels() throws {
    let key = UUID().uuidString
    let email = "purge-pipeline@example.com"
    let old = ThumbnailIdentity(
      id: RemoteThumbnailID(mediaKey: key, contentVersion: 5).string, version: 42, accountEmail: email)
    let next = ThumbnailIdentity(
      id: RemoteThumbnailID(mediaKey: key, contentVersion: 6).string, version: 15, accountEmail: email)
    let cached = ThumbnailKey(identity: old, bucket: .tiny)
    let pendingKey = ThumbnailKey(identity: next, bucket: .large)
    let image = try image()
    let pipeline = ThumbnailPipeline.shared
    let ready = Source { _, _, _, deliver in deliver(image, true) }
    _ = pipeline.load(cached, from: ready) { _, _ in }
    pipeline.rememberViewerPreview(image, for: old)
    let deliveries = OSAllocatedUnfairLock(initialState: [@Sendable (CGImage, Bool) -> Void]())
    let pending = Source { _, _, _, deliver in deliveries.withLock { $0.append(deliver) } }
    var received = 0
    _ = pipeline.load(pendingKey, from: pending) { _, _ in received += 1 }
    _ = ViewerImage.request(pending, identity: next, pixels: CGSize(width: 320, height: 240)) { _, _ in received += 1 }
    #expect(deliveries.withLock { $0.count } == 2)
    pipeline.purge(ids: [key])
    for deliver in deliveries.withLock({ $0 }) { deliver(image, true) }
    #expect(received == 0)
    #expect(pipeline.cachedImage(for: cached) == nil)
    #expect(pipeline.cachedImage(for: pendingKey) == nil)
    #expect(pipeline.viewerPreview(for: old) == nil)
    #expect(pipeline.viewerPreview(for: next) == nil)
  }

  @Test("Retina viewer previews fit in the separate decoded cache")
  func viewerPreview() throws {
    let preview = try image(width: 2752, height: 2064)
    let pipeline = ThumbnailPipeline(costLimit: 48 << 20)
    pipeline.rememberViewerPreview(preview, for: "photo")
    #expect(pipeline.viewerPreview(for: "photo") === preview)
    pipeline.removeAll()
    #expect(pipeline.viewerPreview(for: "photo") == nil)
  }

  @Test("Cancel before or during slot registration while the sole slot is held")
  func limiterCancellation() async {
    let limiter = DownloadLimiter(slots: 1)
    guard await limiter.acquire() else {
      Issue.record("The initial slot should be free")
      return
    }
    let gate = AsyncStream<Void>.makeStream()
    let cancelledBeforeRegistration = Task.detached {
      for await _ in gate.stream {}
      return await limiter.acquire()
    }
    cancelledBeforeRegistration.cancel()
    gate.continuation.finish()
    #expect(await !cancelledBeforeRegistration.value)
    let contenders = (0..<64).map { _ in Task.detached { await limiter.acquire() } }
    for contender in contenders { contender.cancel() }
    for contender in contenders { #expect(await !contender.value) }
    limiter.release()
    #expect(await limiter.acquire())
    limiter.release()
  }
}
