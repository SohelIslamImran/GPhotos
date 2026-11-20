import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Launch shortcuts")
struct LaunchPathTests {
  @Test(
    "A standard path skips building a URL and still matches the URL's own standard form",
    arguments: [
      "/Users/me/Pictures/IMG_0001.HEIC",
      "/Users/me/Pictures/Café/vidéo 1.mov",
      "/Users/me/Pictures/100%/a#b?.jpg",
      "/Users/me/Pictures/./a.jpg",
      "/Users/me/Pictures/../Pictures/a.jpg",
      "/Users/me//Pictures/a.jpg",
      "/Users/me/Pictures/.hidden/a.jpg",
      "/Users/me/Pictures/",
      "/private/var/mobile/a.jpg",
      "/tmp/a.jpg",
      "/",
      "relative/a.jpg",
      "/Users/me/a\0b.jpg",
    ])
  func standardizedPathMatchesURL(path: String) {
    #expect(TransferManifestStore.standardizedPath(path) == URL(fileURLWithPath: path).standardizedFileURL.path)
  }

  @Test("Removing a snapshot invalidates the completed load too")
  func snapshotRemovalInvalidatesLoad() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let info = LibrarySnapshot.Info(
      width: 2, height: 2, scale: 1, isDark: false, itemCount: 1, isScrolledUnderBar: false)
    LibrarySnapshot.saveNow(image, info: info)
    defer { LibrarySnapshot.remove() }
    #expect(await LibrarySnapshot.load()?.info == info)
    LibrarySnapshot.remove()
    #expect(LibrarySnapshot.ready == nil)
    #expect(await LibrarySnapshot.load() == nil)
  }

  @Test("The saved folder read comes back only for the same folders")
  func folderCacheRoundTrip() {
    let folders = [LibraryFolder(id: "a", path: "/Users/me/Pictures", bookmarkData: nil)]
    let items = [
      FolderItemInfo(
        path: "/Users/me/Pictures/a.mov", date: Date(timeIntervalSince1970: 900), size: 12, isVideo: true,
        duration: 3.5),
      FolderItemInfo(
        path: "/Users/me/Pictures/b.heic", date: Date(timeIntervalSince1970: 100), size: 4, isVideo: false,
        isLivePhoto: true),
    ]
    FolderLibrary.saveCache(items, for: folders)
    #expect(FolderLibrary.cachedItems(for: folders) == items)
    #expect(FolderLibrary.cachedItems(for: [LibraryFolder(id: "b", path: "/Users/me/Movies", bookmarkData: nil)]) == nil)
  }

  @Test("A large manifest decodes in pieces to the same records, in the same order")
  func manifestDecodesInPieces() throws {
    let tricky = ["a,b.jpg", "[x]{y}.heic", "quote \"q\".mov", "back\\slash.png", "café 日本.jpg"]
    let records = (0..<6_000).map { index in
      TransferRecord(
        id: "id-\(index)", filename: tricky[index % tricky.count] + "\(index)", mediaType: "image",
        creationDate: Date(timeIntervalSince1970: TimeInterval(index)), status: index % 3 == 0 ? .sent : .pending,
        byteCount: Int64(index))
    }
    let data = try JSONEncoder().encode(records)
    #expect(data.count >= 1_000_000)
    let pieces = try #require(TransferManifestStore.splitArray(data, into: 8))
    #expect(pieces.count > 1)
    let decoded = try #require(TransferManifestStore.decodeSnapshot(data))
    #expect(decoded.map(\.id) == records.map(\.id))
    #expect(decoded.map(\.filename) == records.map(\.filename))
  }

  @Test("Something other than an array isn't split")
  func manifestSplitNeedsAnArray() {
    #expect(TransferManifestStore.splitArray(Data(#"{"a": [1, 2]}"#.utf8), into: 4) == nil)
    #expect(TransferManifestStore.splitArray(Data(#"[1, "unterminated]"#.utf8), into: 4) == nil)
    #expect(TransferManifestStore.decodeSnapshot(Data("not json".utf8)) == nil)
  }
}
