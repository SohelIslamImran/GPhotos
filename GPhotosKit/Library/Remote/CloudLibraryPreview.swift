#if DEBUG
  import CoreGraphics
  import Foundation

  /// A Google Photos library made of generated pages and drawn thumbnails, for the
  /// `-UIScreen cloud` review hook. It goes through the real sync, store and grid; nothing
  /// touches the network.
  extension CloudLibrary {
    /// `cloudLarge` makes 100,000 items, for checking speed at scale.
    public static func preview(itemCount: Int = 600) -> CloudLibrary {
      let directory = FileManager.default.temporaryDirectory.appending(path: "CloudLibraryPreview-\(UUID().uuidString)")
      return CloudLibrary(
        accountEmail: "preview@example.com", store: RemoteLibraryStore(accountEmail: "preview", directory: directory),
        fetcher: PreviewFetcher(pages: max(1, itemCount / PreviewFetcher.perPage)), thumbnails: PreviewThumbnailSource(), actionClient: nil)
    }
  }

  private struct PreviewFetcher: RemoteLibraryFetching {
    static let perPage = 150
    let pages: Int

    func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
      syncToken.isEmpty
        ? page(0) : RemoteLibraryUpdate(syncToken: syncToken, resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false)
    }

    func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate {
      try await Task.sleep(for: .milliseconds(pages > 10 ? 20 : 250))
      return page(Int(resumeToken) ?? 1)
    }

    func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate {
      RemoteLibraryUpdate(syncToken: "", resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false)
    }

    private func page(_ number: Int) -> RemoteLibraryUpdate {
      let start = Date().timeIntervalSince1970
      let items = (0..<Self.perPage).map { offset -> RemoteMediaItem in
        let index = number * Self.perPage + offset
        let kind: RemoteMediaItem.Kind = index % 9 == 4 ? .video : (index % 7 == 3 ? .motionPhoto : .photo)
        return RemoteMediaItem(
          mediaKey: "preview-\(index)", dedupKey: "dedup-\(index)", sha1: nil, fileName: "IMG_\(1000 + index).HEIC",
          caption: nil, kind: kind, sizeBytes: Int64(2_000_000 + index * 1_000),
          quotaChargedBytes: index % 23 == 0 ? 3_000_000 : 0, isOriginalQuality: index % 23 != 0,
          takenAt: Date(timeIntervalSince1970: start - Double(index) * 36_000), timezoneOffsetMinutes: 360,
          uploadedAt: nil, contentVersion: 1, trashedAt: index % 41 == 0 ? Date() : nil, isArchived: index % 37 == 0,
          isFavorite: index % 11 == 0, isLocked: false, isCanonical: true, isEdited: false, origin: 1,
          width: index % 5 == 0 ? 3024 : 4032, height: index % 5 == 0 ? 4032 : 3024, latitude: 48.85, longitude: 2.35,
          locationName: "Paris", cameraMake: "Apple", cameraModel: "iPhone 17 Pro", aperture: 1.8, shutterSpeed: 0.008,
          iso: 80, focalLength: 24, durationMs: kind == .video ? 14_000 : nil)
      }
      return RemoteLibraryUpdate(
        syncToken: number == 0 ? "preview-sync" : "", resumeToken: number + 1 < pages ? String(number + 1) : "",
        items: items, deletedMediaKeys: [], triggersNextSync: false)
    }
  }

  /// Soft gradients keyed by item, drawn at the requested size.
  private final class PreviewThumbnailSource: ThumbnailSource, Sendable {
    func requestImage(
      id: String, pixelSize: CGSize, quality: ImageRequestQuality, deliver: @escaping @Sendable (CGImage, Bool) -> Void
    ) -> ImageRequestToken {
      let side = max(16, min(Int(max(pixelSize.width, pixelSize.height)), 1024))
      let hue = CGFloat(abs(id.hashValue % 360)) / 360
      DispatchQueue.global(qos: .userInitiated).async {
        let index = RemoteThumbnailID(id).flatMap { Int($0.mediaKey.replacingOccurrences(of: "preview-", with: "")) } ?? 0
        let portrait = index % 5 == 0
        let width = quality == .display && portrait ? side * 3 / 4 : side
        let height = quality == .display && !portrait ? side * 3 / 4 : side
        guard
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let colors = [
          Self.color(hue: hue, brightness: 0.95), Self.color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), brightness: 0.6),
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
          context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        if let image = context.makeImage() { deliver(image, true) }
      }
      return .none
    }

    private static func color(hue: CGFloat, brightness: CGFloat) -> CGColor {
      // HSB to RGB, enough for previews.
      let i = Int(hue * 6) % 6
      let f = hue * 6 - CGFloat(Int(hue * 6))
      let p = brightness * 0.45
      let q = brightness * (1 - 0.55 * f)
      let t = brightness * (1 - 0.55 * (1 - f))
      let (r, g, b): (CGFloat, CGFloat, CGFloat) =
        switch i {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
      return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r, g, b, 1])!
    }
  }
#endif
