import Foundation
import Testing

@testable import GPhotosKit

@Suite("Album 20,000-item rollover and count tracking")
struct AlbumRolloverTests {
  @Test func rolloverPartNaming() {
    #expect(AlbumRollover.partName(for: "Travel", part: 1) == "Travel")
    #expect(AlbumRollover.partName(for: "Travel", part: 2) == "Travel (2)")
    #expect(AlbumRollover.partName(for: "Travel", part: 3) == "Travel (3)")
  }

  @Test func rolloverAlbumNameForIndex() {
    #expect(AlbumRollover.albumName(for: "Family", itemIndex: 0) == "Family")
    #expect(AlbumRollover.albumName(for: "Family", itemIndex: 19_999) == "Family")
    #expect(AlbumRollover.albumName(for: "Family", itemIndex: 20_000) == "Family (2)")
    #expect(AlbumRollover.albumName(for: "Family", itemIndex: 39_999) == "Family (2)")
    #expect(AlbumRollover.albumName(for: "Family", itemIndex: 40_000) == "Family (3)")
  }

  @Test func planAdditionsSinglePart() {
    let slices = AlbumRollover.planAdditions(baseName: "Vacation", itemCount: 100) { _ in 0 }
    #expect(slices.count == 1)
    #expect(slices[0].albumName == "Vacation")
    #expect(slices[0].range == 0..<100)
    #expect(slices[0].newCount == 100)
  }

  @Test func planAdditionsSpanningRollover() {
    let counts: [String: Int] = ["Vacation": 19_990]
    let slices = AlbumRollover.planAdditions(baseName: "Vacation", itemCount: 25) { counts[$0] ?? 0 }

    #expect(slices.count == 2)
    #expect(slices[0].albumName == "Vacation")
    #expect(slices[0].range == 0..<10)
    #expect(slices[0].newCount == 20_000)

    #expect(slices[1].albumName == "Vacation (2)")
    #expect(slices[1].range == 10..<25)
    #expect(slices[1].newCount == 15)
  }

  @Test func planAdditionsWhenFirstPartFull() {
    let counts: [String: Int] = ["Vacation": 20_000, "Vacation (2)": 500]
    let slices = AlbumRollover.planAdditions(baseName: "Vacation", itemCount: 50) { counts[$0] ?? 0 }

    #expect(slices.count == 1)
    #expect(slices[0].albumName == "Vacation (2)")
    #expect(slices[0].range == 0..<50)
    #expect(slices[0].newCount == 550)
  }

  @Test func albumKeyStoreTracksAndResetsCounts() throws {
    let tempURL = TestTemporaryDirectory.root
      .appendingPathComponent("AlbumKeyStoreTests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let store = AlbumKeyStore(fileURL: tempURL)
    let email = "user@example.com"
    let album = "Events"

    #expect(store.count(forAlbumNamed: album, accountEmail: email) == 0)
    #expect(store.key(forAlbumNamed: album, accountEmail: email) == nil)

    store.remember(key: "key-123", forAlbumNamed: album, accountEmail: email)
    store.incrementCount(by: 50, forAlbumNamed: album, accountEmail: email)

    #expect(store.key(forAlbumNamed: album, accountEmail: email) == "key-123")
    #expect(store.count(forAlbumNamed: album, accountEmail: email) == 50)

    store.incrementCount(by: 30, forAlbumNamed: album, accountEmail: email)
    #expect(store.count(forAlbumNamed: album, accountEmail: email) == 80)

    store.forget(albumNamed: album, accountEmail: email)
    #expect(store.key(forAlbumNamed: album, accountEmail: email) == nil)
    #expect(store.count(forAlbumNamed: album, accountEmail: email) == 0)
  }

  @Test func settingsDecodeDefaultsForExcludedAlbums() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(settings.excludedAlbumIDs.isEmpty)

    var updated = AppSettings()
    updated.excludedAlbumIDs = ["album-abc"]

    let encoded = try JSONEncoder().encode(updated)
    let roundTripped = try JSONDecoder().decode(AppSettings.self, from: encoded)

    #expect(roundTripped.excludedAlbumIDs == ["album-abc"])
  }
}
