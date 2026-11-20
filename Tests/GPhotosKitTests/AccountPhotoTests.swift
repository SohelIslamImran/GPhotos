import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import GPhotosKit

@Suite("Account photos")
struct AccountPhotoTests {
  @Test func emailKeys() {
    #expect(AccountPhotoStore.emailKey(" User@Example.COM \n") == "user@example.com")
    #expect(AccountPhotoStore.emailKey("  ").isEmpty)
  }

  @Test(arguments: [
    "https://lh3.googleusercontent.com/a/photo=s96-c",
    "https://lh3.googleusercontent.com/a/photo=s96-c-no",
    "https://lh3.googleusercontent.com/a/photo",
  ])
  func googleSizeOptions(_ value: String) throws {
    let url = try #require(URL(string: value))
    #expect(
      GoogleAuthService.sizedPhotoURL(url, pixelSize: 192).absoluteString
        == "https://lh3.googleusercontent.com/a/photo=s192-c")
  }

  @Test func preservesQueryAndFragment() throws {
    let url = try #require(URL(string: "https://lh3.googleusercontent.com/a/photo=s96-c?token=test#image"))
    #expect(
      GoogleAuthService.sizedPhotoURL(url, pixelSize: 192).absoluteString
        == "https://lh3.googleusercontent.com/a/photo=s192-c?token=test#image")
    let other = try #require(URL(string: "https://example.com/photo?size=96"))
    #expect(GoogleAuthService.sizedPhotoURL(other, pixelSize: 192) == other)
  }

  @Test(arguments: [
    "{}", "{\"picture\":null}", "{\"picture\":\"\"}",
    "{\"picture\":\"http://example.com/a\"}", "{\"picture\":\"relative\"}",
    "{\"picture\":\"https://example.com/a b\"}",
  ])
  func missingOrInvalidPicture(_ json: String) throws {
    #expect(try GoogleAuthService.profilePhotoURL(from: Data(json.utf8)) == nil)
  }

  @Test func userInfoPicture() throws {
    let json = Data(#"{"picture":"https://lh3.googleusercontent.com/default=s96-c","name":"Test"}"#.utf8)
    #expect(try GoogleAuthService.profilePhotoURL(from: json)?.host == "lh3.googleusercontent.com")
    #expect(throws: (any Error).self) {
      try GoogleAuthService.profilePhotoURL(from: Data(#"{"picture":42}"#.utf8))
    }
  }

  @Test func refreshAndRetry() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var state = AccountPhotoRefresh()
    #expect(state.isDue(at: now))
    state.failed(at: now)
    #expect(!state.isDue(at: now.addingTimeInterval(59)))
    #expect(state.isDue(at: now.addingTimeInterval(60)))
    state.failed(at: now.addingTimeInterval(60))
    #expect(state.retryAt == now.addingTimeInterval(180))
    for _ in 0..<20 { state.failed(at: now) }
    #expect(state.retryAt == now.addingTimeInterval(6 * 60 * 60))
    state = AccountPhotoRefresh(refreshedAt: now)
    #expect(!state.isDue(at: now.addingTimeInterval(AccountPhotoRefresh.maxAge - 1)))
    #expect(state.isDue(at: now.addingTimeInterval(AccountPhotoRefresh.maxAge)))
    #expect(state.isDue(at: now.addingTimeInterval(-1)))
  }

  @Test func cachedPhotoAndCorruptFile() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = AccountPhotoCache(directory: directory)
    let context = try #require(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    await cache.keep(["user@example.com"], generation: 1)
    await cache.store(data as Data, for: "user@example.com", generation: 1)
    let cached = await cache.load(" USER@EXAMPLE.COM ")
    #expect(cached?.image.width == 2)
    #expect(cached.map { !AccountPhotoRefresh(refreshedAt: $0.date).isDue(at: .now) } == true)
    let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let stale = Date.now.addingTimeInterval(-AccountPhotoRefresh.maxAge - 1)
    try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: file.path)
    let old = await cache.load("user@example.com")
    #expect(old?.image.width == 2)
    #expect(old.map { AccountPhotoRefresh(refreshedAt: $0.date).isDue(at: .now) } == true)
    await cache.store(Data([1]), for: "user@example.com", generation: 1)
    #expect(await cache.load("user@example.com") == nil)
  }

  @Test func removedAccountCannotWriteCache() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = AccountPhotoCache(directory: directory)
    await cache.keep(["user@example.com"], generation: 1)
    await cache.store(Data([1]), for: "user@example.com", generation: 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    await cache.keep([], generation: 2)
    await cache.keep(["user@example.com"], generation: 1)
    await cache.store(Data([2]), for: "user@example.com", generation: 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(await cache.load("user@example.com") == nil)
  }
}
