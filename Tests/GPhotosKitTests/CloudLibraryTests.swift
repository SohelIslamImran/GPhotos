import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Cloud library request fixtures")
struct CloudLibraryRequestTests {
  @Test("The viewer only uses uncropped disk previews")
  func uncroppedDiskPreview() throws {
    let cache = ThumbnailDiskCache(accountEmail: "preview-\(UUID().uuidString)@example.com", byteLimit: 1 << 20)
    defer { cache.removeAll() }
    let preview = Data([1, 2, 3])
    let id = RemoteThumbnailID(mediaKey: "media", contentVersion: 0)
    cache.store(Data([4, 5, 6]), for: .init(id, side: 320, crop: true))
    #expect(cache.largestSmaller(than: 2048, of: id) == nil)
    cache.store(preview, for: .init(id, side: 2048, crop: false))
    #expect(cache.largestSmaller(than: 3072, of: id) == preview)
    #expect(cache.largestSmaller(than: 2048, of: RemoteThumbnailID(mediaKey: "media", contentVersion: 1)) == nil)
  }

  private func fixture(_ base64: String) -> Data { Data(base64Encoded: base64.filter { !$0.isWhitespace })! }

  @Test("Download file names are reduced to a single safe path component")
  func safeFileName() {
    #expect(CloudLibrary.safeFileName("IMG_0001.HEIC", fallback: "KEY.jpg") == "IMG_0001.HEIC")
    #expect(CloudLibrary.safeFileName("nested/dir/IMG_0001.jpg", fallback: "KEY.jpg") == "IMG_0001.jpg")
    #expect(CloudLibrary.safeFileName("../../etc/passwd", fallback: "KEY.jpg") == "passwd")
    #expect(CloudLibrary.safeFileName("/leading/slash/clip.mp4", fallback: "KEY.mp4") == "clip.mp4")
    #expect(CloudLibrary.safeFileName("2024:01:02 12:30.jpg", fallback: "KEY.jpg") == "2024_01_02 12_30.jpg")
    #expect(CloudLibrary.safeFileName("dir/sub:1/a:b.jpg", fallback: "KEY.jpg") == "a_b.jpg")
    #expect(CloudLibrary.safeFileName(nil, fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName(".", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("..", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("dir/.", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("dir/..", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("/", fallback: "KEY.jpg") == "KEY.jpg")
    #expect(CloudLibrary.safeFileName("///", fallback: "KEY.mp4") == "KEY.mp4")
    #expect(CloudLibrary.safeFileName("bad\0name.jpg", fallback: "KEY.jpg") == "KEY.jpg")
  }

  @Test("Video playback uses a remote HLS rendition instead of a local playlist")
  func streamingRendition() {
    let manifest = """
      #EXTM3U
      #EXT-X-INDEPENDENT-SEGMENTS
      #EXT-X-STREAM-INF:BANDWIDTH=300000,CODECS="avc1,mp4a"
      https://example.com/low.m3u8?signature=a
      #EXT-X-STREAM-INF:BANDWIDTH=1300000,RESOLUTION=1280x720
      https://example.com/high.m3u8?signature=b
      #EXT-X-STREAM-INF:BANDWIDTH=9000000
      file:///tmp/invalid.m3u8
      """
    #expect(
      CloudLibrary.streamingRendition(in: Data(manifest.utf8))?.absoluteString
        == "https://example.com/high.m3u8?signature=b")
    #expect(CloudLibrary.streamingRendition(in: Data("not a playlist".utf8)) == nil)
    #expect(CloudLibrary.streamingRendition(in: Data("#EXTM3U\n#EXTINF:5\nhttps://example.com/segment.ts".utf8)) == nil)
  }

  @Test("Library state, initial pages and delta pages")
  func syncRequests() {
    #expect(LibraryMessages.libraryState(syncToken: "") == fixture(LibraryRequestFixtures.stateEmpty))
    #expect(LibraryMessages.libraryState(syncToken: "SYNC_TOKEN_A") == fixture(LibraryRequestFixtures.stateToken))
    #expect(LibraryMessages.libraryState(syncToken: String(repeating: "S", count: 300)) == fixture(LibraryRequestFixtures.stateLong))
    #expect(LibraryMessages.initialPage(resumeToken: "RESUME_TOKEN_A") == fixture(LibraryRequestFixtures.initPage))
    #expect(
      LibraryMessages.initialPage(resumeToken: String(repeating: "R", count: 300)) == fixture(LibraryRequestFixtures.initPageLong))
    #expect(
      LibraryMessages.deltaPage(resumeToken: "RESUME_TOKEN_A", syncToken: "SYNC_TOKEN_A")
        == fixture(LibraryRequestFixtures.deltaPage))
    #expect(
      LibraryMessages.deltaPage(
        resumeToken: String(repeating: "R", count: 300), syncToken: String(repeating: "S", count: 200))
        == fixture(LibraryRequestFixtures.deltaPageLong))
  }

  @Test("Item actions")
  func actionRequests() {
    let device = DeviceProfile.metered
    #expect(LibraryMessages.trash(dedupKeys: ["DEDUP_A", "DEDUP_B"], device: device) == fixture(LibraryRequestFixtures.trash))
    #expect(LibraryMessages.restore(dedupKeys: ["DEDUP_A", "DEDUP_B"], device: device) == fixture(LibraryRequestFixtures.restore))
    #expect(LibraryMessages.deleteForever(dedupKeys: ["DEDUP_A", "DEDUP_B"]) == fixture(LibraryRequestFixtures.deleteForever))
    #expect(LibraryMessages.favorite(dedupKey: "DEDUP_A", isFavorite: true) == fixture(LibraryRequestFixtures.favoriteOn))
    #expect(LibraryMessages.favorite(dedupKey: "DEDUP_A", isFavorite: false) == fixture(LibraryRequestFixtures.favoriteOff))
    #expect(LibraryMessages.archive(dedupKeys: ["DEDUP_A", "DEDUP_B"], isArchived: true) == fixture(LibraryRequestFixtures.archiveOn))
    #expect(LibraryMessages.archive(dedupKeys: ["DEDUP_A"], isArchived: false) == fixture(LibraryRequestFixtures.archiveOff))
    #expect(LibraryMessages.caption(dedupKey: "DEDUP_A", caption: "Hello") == fixture(LibraryRequestFixtures.caption))
    #expect(LibraryMessages.downloadURLs(mediaKey: "MEDIA_KEY_A") == fixture(LibraryRequestFixtures.downloadUrls))
  }

  @Test("Thumbnail and stream URLs")
  func mediaURLs() {
    #expect(
      GPhotosEndpoints.thumbnail(mediaKey: "MEDIA_KEY_A", width: 320, height: 320, contentVersion: 3).absoluteString
        == "https://ap2.googleusercontent.com/gpa/MEDIA_KEY_A=k-sg-w320-h320-rj-iv3-no")
    #expect(
      GPhotosEndpoints.thumbnail(mediaKey: "K", width: 96, height: 96, contentVersion: 0, crop: true).absoluteString
        == "https://ap2.googleusercontent.com/gpa/K=k-sg-w96-h96-rj-no-c")
    #expect(
      GPhotosEndpoints.streamManifest(mediaKey: "MEDIA_KEY_A", contentVersion: 3).absoluteString
        == "https://lh3.googleusercontent.com/p/MEDIA_KEY_A%3Dmm%2Chls-vm-iv3")
  }
}

/// Builds sync responses with the mobile protocol field layout.
enum SyncResponseBuilder {
  struct Item {
    var key: String
    var takenMs: Int64 = 1_760_000_000_000
    var favorite = false
    var archived = false
    var trashedMs: Int64?
    var video = false
    var charged: Int64 = 0
    var sha1 = Data(repeating: 7, count: 20)
    var dedup: String?
    var collection: String?
    /// A shared album's own copy of a library photo.
    var sharedAlbumCopy = false
    var locked = false
  }

  struct Album {
    var key: String
    var title: String
    var count: Int64
    var cover: String
  }

  static func page(
    sync: String = "", resume: String = "", items: [Item] = [], deleted: [String] = [], next: Bool = false,
    albums: [Album] = [], deletedAlbums: [String] = []
  ) -> Data {
    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { root in
      if !resume.isEmpty { root.writeString(fieldNumber: 1, resume) }
      for item in items { root.writeMessage(fieldNumber: 2) { encode(item, &$0) } }
      for album in albums {
        root.writeMessage(fieldNumber: 3) { collection in
          collection.writeString(fieldNumber: 1, album.key)
          collection.writeMessage(fieldNumber: 2) { info in
            info.writeString(fieldNumber: 5, album.title)
            info.writeInt64(fieldNumber: 7, album.count)
            info.writeMessage(fieldNumber: 10) { range in
              range.writeInt64(fieldNumber: 10, 1_760_000_000_000)
            }
            info.writeMessage(fieldNumber: 17) { $0.writeString(fieldNumber: 1, album.cover) }
          }
        }
      }
      if !sync.isEmpty { root.writeString(fieldNumber: 6, sync) }
      if next { root.writeInt64(fieldNumber: 7, 2) }
      for key in deletedAlbums {
        root.writeMessage(fieldNumber: 9) { deletion in
          deletion.writeMessage(fieldNumber: 1) { inner in
            inner.writeInt64(fieldNumber: 1, 4)
            inner.writeMessage(fieldNumber: 5) { $0.writeString(fieldNumber: 2, key) }
          }
        }
      }
      for key in deleted {
        root.writeMessage(fieldNumber: 9) { deletion in
          deletion.writeMessage(fieldNumber: 1) { inner in
            inner.writeInt64(fieldNumber: 1, 1)
            inner.writeMessage(fieldNumber: 2) { $0.writeString(fieldNumber: 1, key) }
          }
        }
      }
    }
    return writer.data
  }

  static func encode(_ item: Item, _ writer: inout ProtobufWriter) {
    writer.writeString(fieldNumber: 1, item.key)
    writer.writeMessage(fieldNumber: 2) { info in
      if let collection = item.collection { info.writeMessage(fieldNumber: 1) { $0.writeString(fieldNumber: 1, collection) } }
      info.writeString(fieldNumber: 3, "A caption")
      if item.sharedAlbumCopy { info.writeMessage(fieldNumber: 5) { $0.writeInt64(fieldNumber: 1, 27) } }
      info.writeString(fieldNumber: 4, "\(item.key).jpg")
      info.writeInt64(fieldNumber: 7, item.takenMs)
      info.writeInt64(fieldNumber: 8, 3_600_000 * 6)
      info.writeInt64(fieldNumber: 10, 2_000_000)
      info.writeMessage(fieldNumber: 13) { $0.writeBytes(fieldNumber: 1, item.sha1) }
      if let trashed = item.trashedMs { info.writeMessage(fieldNumber: 16) { $0.writeInt64(fieldNumber: 3, trashed) } }
      if let dedup = item.dedup { info.writeMessage(fieldNumber: 21) { $0.writeString(fieldNumber: 1, dedup) } }
      info.writeInt64(fieldNumber: 26, 2)
      if item.archived { info.writeMessage(fieldNumber: 29) { $0.writeInt64(fieldNumber: 1, 1) } }
      info.writeMessage(fieldNumber: 31) { $0.writeInt64(fieldNumber: 1, item.favorite ? 1 : 2) }
      if item.locked { info.writeMessage(fieldNumber: 39) { $0.writeInt64(fieldNumber: 1, 1) } }
      info.writeMessage(fieldNumber: 35) { quota in
        quota.writeInt64(fieldNumber: 2, item.charged)
        quota.writeInt64(fieldNumber: 3, item.charged == 0 ? 2 : 1)
      }
    }
    writer.writeMessage(fieldNumber: 5) { media in
      if item.video {
        media.writeMessage(fieldNumber: 3) { video in
          video.writeMessage(fieldNumber: 4) { details in
            details.writeInt64(fieldNumber: 1, 12_500)
            details.writeInt64(fieldNumber: 4, 1920)
            details.writeInt64(fieldNumber: 5, 1080)
          }
        }
      } else {
        media.writeMessage(fieldNumber: 2) { photo in
          photo.writeMessage(fieldNumber: 1) { first in
            first.writeMessage(fieldNumber: 9) { details in
              details.writeInt64(fieldNumber: 1, 4032)
              details.writeInt64(fieldNumber: 2, 3024)
              details.writeMessage(fieldNumber: 5) { camera in
                camera.writeString(fieldNumber: 1, "Apple")
                camera.writeString(fieldNumber: 2, "iPhone 17 Pro")
                camera.writeInt64(fieldNumber: 4, Int64(Float(1.8).bitPattern))
                camera.writeInt64(fieldNumber: 6, 80)
              }
            }
          }
        }
      }
    }
    writer.writeMessage(fieldNumber: 17) { location in
      location.writeMessage(fieldNumber: 1) { point in
        // Negative coordinates arrive as unsigned 32-bit patterns.
        point.writeInt64(fieldNumber: 1, 488_566_000)
        point.writeInt64(fieldNumber: 2, Int64(UInt32(bitPattern: Int32(-22_000_000))))
      }
      location.writeMessage(fieldNumber: 5) { place in
        place.writeMessage(fieldNumber: 2) { $0.writeString(fieldNumber: 1, "Paris") }
      }
    }
  }
}

@Suite("Cloud library: decoding, store and sync")
struct CloudLibrarySyncTests {
  @Test("Pages decode with the mobile protocol field layout")
  func decodeUpdate() throws {
    let data = SyncResponseBuilder.page(
      sync: "NEXT", resume: "MORE",
      items: [.init(key: "a", favorite: true), .init(key: "v", video: true, charged: 5_000, dedup: "SERVER_DEDUP")],
      deleted: ["gone"], next: true)
    let update = try LibraryMessages.decodeLibraryUpdate(data)
    #expect(update.syncToken == "NEXT")
    #expect(update.resumeToken == "MORE")
    #expect(update.triggersNextSync)
    #expect(update.deletedMediaKeys == ["gone"])
    let photo = try #require(update.items.first)
    #expect(photo.kind == .photo)
    #expect(photo.isFavorite)
    #expect(photo.caption == "A caption")
    #expect(photo.width == 4032 && photo.height == 3024)
    #expect(photo.cameraModel == "iPhone 17 Pro")
    #expect(abs((photo.aperture ?? 0) - 1.8) < 0.001)
    #expect(photo.iso == 80)
    #expect(abs((photo.latitude ?? 0) - 48.8566) < 0.00001)
    #expect(abs((photo.longitude ?? 0) + 2.2) < 0.00001)
    #expect(photo.locationName == "Paris")
    #expect(photo.takenAt == Date(timeIntervalSince1970: 1_760_000_000))
    #expect(photo.timezoneOffsetMinutes == 360)
    #expect(photo.isOriginalQuality)
    // Without a server dedup key, the URL-safe base64 of the SHA-1 is used.
    #expect(photo.dedupKey == Data(repeating: 7, count: 20).base64EncodedString().replacingOccurrences(of: "=", with: ""))
    let video = update.items[1]
    #expect(video.kind == .video)
    #expect(video.durationMs == 12_500)
    #expect(video.dedupKey == "SERVER_DEDUP")
    #expect(video.quotaChargedBytes == 5_000)
  }

  private func makeStore() -> RemoteLibraryStore {
    RemoteLibraryStore(
      accountEmail: "test@example.com",
      directory: TestTemporaryDirectory.root.appending(path: "RemoteLibraryTests-\(UUID().uuidString)"))
  }

  @Test("The store keeps scopes, stats and tokens")
  func store() async throws {
    let store = makeStore()
    let update = try LibraryMessages.decodeLibraryUpdate(
      SyncResponseBuilder.page(
        sync: "T1",
        items: [
          .init(key: "new", takenMs: 1_760_000_000_000, favorite: true),
          .init(key: "old", takenMs: 1_700_000_000_000, archived: true),
          .init(key: "bin", trashedMs: 1_760_000_000_000),
          .init(key: "vid", video: true, charged: 100),
        ]))
    try await store.apply(update, syncToken: update.syncToken)
    #expect(try await store.summaries(.library).map(\.mediaKey) == ["new", "vid"])
    #expect(try await store.summaries(.favorites).map(\.mediaKey) == ["new"])
    #expect(try await store.summaries(.archive).map(\.mediaKey) == ["old"])
    #expect(try await store.summaries(.trash).map(\.mediaKey) == ["bin"])
    #expect(try await store.summaries(.usesStorage).map(\.mediaKey) == ["vid"])
    let stats = try await store.stats()
    #expect(stats.items == 3 && stats.videos == 1 && stats.trashed == 1 && stats.chargedBytes == 100)
    #expect(try await store.syncState().syncToken == "T1")

    try await store.update(mediaKeys: ["new"], favorite: false, trashedAt: .some(Date()))
    #expect(try await store.summaries(.favorites).isEmpty)
    #expect(try await store.summaries(.trash).count == 2)

    let deletion = try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(deleted: ["old"]))
    try await store.apply(deletion, syncToken: nil)
    #expect(try await store.summaries(.archive).isEmpty)
    #expect(try await store.syncState().syncToken == "T1")
    let item = try #require(try await store.item(mediaKey: "vid"))
    #expect(item.kind == .video && item.fileName == "vid.jpg")
    try await store.reset()
    #expect(try await store.summaries(.library).isEmpty)
  }

  @Test("Shared album copies stay in their album, out of the library, stats and duplicates")
  func sharedAlbumCopies() async throws {
    let store = makeStore()
    let hash = Data(repeating: 9, count: 20)
    let update = try LibraryMessages.decodeLibraryUpdate(
      SyncResponseBuilder.page(
        sync: "T1",
        items: [
          .init(key: "original", favorite: true, video: true, sha1: hash, collection: "uploads"),
          .init(key: "copy", favorite: true, video: true, sha1: hash, collection: "shared", sharedAlbumCopy: true),
        ]))
    try await store.apply(update, syncToken: update.syncToken)
    for scope in [RemoteScope.library, .favorites, .videos] {
      #expect(try await store.summaries(scope).map(\.mediaKey) == ["original"])
    }
    #expect(try await store.summaries(.album(key: "shared", title: "Trip")).map(\.mediaKey) == ["copy"])
    #expect(try await store.duplicateGroups().isEmpty)
    #expect(try await store.stats().items == 1)

    // Google marks a trashed item not canonical as well: Trash still lists it.
    let trashed = try LibraryMessages.decodeLibraryUpdate(
      SyncResponseBuilder.page(
        sync: "T2", items: [.init(key: "binned", trashedMs: 1_763_000_000_000, sha1: Data(repeating: 3, count: 20), sharedAlbumCopy: true)])
    )
    try await store.apply(trashed, syncToken: trashed.syncToken)
    #expect(try await store.summaries(.trash).map(\.mediaKey) == ["binned"])
    #expect(try await store.stats().trashed == 1)
  }

  /// Serves scripted pages and records the requests made.
  actor FakeFetcher: RemoteLibraryFetching {
    var states: [String: Data] = [:]
    var initialPages: [String: Data] = [:]
    var deltaPages: [String: Data] = [:]
    var calls: [String] = []
    var failOnInitialPage: String?
    var failOnDeltaPage: String?
    var deltaError: any Error = URLError(.networkConnectionLost)

    func set(states: [String: Data] = [:], initialPages: [String: Data] = [:], deltaPages: [String: Data] = [:]) {
      self.states.merge(states) { $1 }
      self.initialPages.merge(initialPages) { $1 }
      self.deltaPages.merge(deltaPages) { $1 }
    }

    func setDeltaFailure(_ token: String?, error: any Error = URLError(.networkConnectionLost)) {
      failOnDeltaPage = token
      deltaError = error
    }

    func setFailure(_ token: String?) { failOnInitialPage = token }

    func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
      calls.append("state:\(syncToken)")
      return try LibraryMessages.decodeLibraryUpdate(states[syncToken] ?? SyncResponseBuilder.page(sync: syncToken))
    }

    func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate {
      calls.append("init:\(resumeToken)")
      if resumeToken == failOnInitialPage { throw URLError(.networkConnectionLost) }
      return try LibraryMessages.decodeLibraryUpdate(initialPages[resumeToken]!)
    }

    func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate {
      calls.append("delta:\(resumeToken):\(syncToken)")
      if resumeToken == failOnDeltaPage { throw deltaError }
      return try LibraryMessages.decodeLibraryUpdate(deltaPages[resumeToken]!)
    }
  }

  @Test("A full sync pages through, resumes after a failure, then runs deltas")
  func fullSyncResumesAndDeltas() async throws {
    let store = makeStore()
    let fetcher = FakeFetcher()
    await fetcher.set(
      states: [
        "": SyncResponseBuilder.page(sync: "S1", resume: "R1", items: [.init(key: "a")]),
        "S1": SyncResponseBuilder.page(sync: "S2", items: [.init(key: "b")]),
      ],
      initialPages: [
        "R1": SyncResponseBuilder.page(resume: "R2", items: [.init(key: "c")]),
        "R2": SyncResponseBuilder.page(items: [.init(key: "d")]),
      ])
    await fetcher.setFailure("R2")
    let sync = RemoteLibrarySync(store: store, fetcher: fetcher)
    await #expect(throws: URLError.self) { try await sync.sync() }
    // The pages before the failure are kept, with the token to resume from.
    #expect(try await store.syncState().resumeToken == "R2")
    #expect(try await store.syncState().initialSyncDone == false)

    await fetcher.setFailure(nil)
    let progress = try await sync.sync()
    #expect(try await store.syncState().initialSyncDone)
    #expect(Set(try await store.summaries(.library).map(\.mediaKey)) == ["a", "b", "c", "d"])
    #expect(try await store.syncState().syncToken == "S2")
    #expect(progress.updated == 2)
    // Finish paging, ask for the state with the stored token, then request a delta.
    #expect(await fetcher.calls == ["state:", "init:R1", "init:R2", "init:R2", "state:S1", "state:S2"])
  }

  @Test("An interrupted delta resumes its failed page with the original cycle token")
  func interruptedDeltaResumesWithLockChange() async throws {
    let store = RemoteLibraryStore(
      accountEmail: "delta@example.com", directory: TestTemporaryDirectory.root.appending(path: UUID().uuidString))
    typealias Page = SyncResponseBuilder
    try await store.apply(
      LibraryMessages.decodeLibraryUpdate(Page.page(sync: "S1", items: [.init(key: "secret")])), syncToken: "S1")
    try await store.markInitialSyncDone()
    let fetcher = FakeFetcher()
    await fetcher.set(
      states: ["S1": Page.page(sync: "S2", resume: "D1", next: true)],
      deltaPages: [
        "D1": Page.page(resume: "D2", items: [.init(key: "new")]),
        "D2": Page.page(items: [.init(key: "secret", locked: true)]),
      ])
    await fetcher.setDeltaFailure("D2")
    let first = RemoteLibrarySync(store: store, fetcher: fetcher)
    await #expect(throws: URLError.self) { _ = try await first.sync() }
    #expect(try await store.syncState().resumeToken == "D2")
    #expect(try await store.lockedKeys().isEmpty)

    await fetcher.setDeltaFailure(nil)
    let resumed = RemoteLibrarySync(store: store, fetcher: fetcher)
    let progress = try await resumed.sync()
    #expect(progress.changes.hidden == 1)
    #expect(await fetcher.calls == ["state:S1", "delta:D1:S1", "delta:D2:S1", "delta:D2:S1", "state:S2"])
    #expect(try await store.lockedKeys() == ["secret"])
    #expect(try await store.summaries(.library).map(\.mediaKey) == ["new"])
    #expect(try await store.syncState().deltaToken == nil)
  }

  @Test("A repeated media key keeps the final lock state when a delta page commits")
  func duplicatePageItemsKeepFinalLockState() async throws {
    let email = "duplicate-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let store = makeStore()
    typealias Page = SyncResponseBuilder
    try await store.markInitialSyncDone()
    let fetcher = FakeFetcher()
    await fetcher.set(states: [
      "": Page.page(
        sync: "S2",
        items: [
          .init(key: "ends-locked"), .init(key: "ends-locked", locked: true),
          .init(key: "ends-unlocked", locked: true), .init(key: "ends-unlocked"),
        ])
    ])
    let sync = RemoteLibrarySync(
      store: store, fetcher: fetcher, willLock: { LockedItems.insert($0, accountEmail: email) },
      didRelease: { LockedItems.release($0, accountEmail: email) })
    _ = try await sync.sync()
    #expect(try await store.lockedKeys() == ["ends-locked"])
    #expect(LockedItems.keys(accountEmail: email) == ["ends-locked"])
  }

  @Test("Only a definite refusal rewinds a resumed delta and replays its lock changes")
  func refusesExpiredResume() async throws {
    let store = makeStore()
    typealias Page = SyncResponseBuilder
    try await store.apply(
      LibraryMessages.decodeLibraryUpdate(Page.page(items: [.init(key: "secret"), .init(key: "deleted")])),
      syncToken: "S1")
    try await store.markInitialSyncDone()
    try await store.apply(LibraryMessages.decodeLibraryUpdate(Page.page(resume: "expired")), syncToken: "S2", deltaToken: "S1")
    let fetcher = FakeFetcher()
    await fetcher.set(
      states: ["S1": Page.page(sync: "S2", resume: "new-page")],
      deltaPages: ["new-page": Page.page(items: [.init(key: "secret", locked: true)], deleted: ["deleted"])])
    let sync = RemoteLibrarySync(store: store, fetcher: fetcher)

    for status in [401, 403, 408, 429, 503] {
      let error = GPhotosError.httpError(status: status, body: "")
      await fetcher.setDeltaFailure("expired", error: error)
      await #expect(throws: error) { _ = try await sync.sync() }
      #expect(try await store.syncState().resumeToken == "expired")
    }
    await fetcher.setDeltaFailure("expired", error: GPhotosError.httpError(status: 410, body: ""))
    _ = try await sync.sync()
    #expect(await fetcher.calls == Array(repeating: "delta:expired:S1", count: 6) + ["state:S1", "delta:new-page:S1"])
    #expect(try await store.syncState().syncToken == "S2")
    #expect(try await store.syncState().deltaToken == nil)
    #expect(try await store.lockedKeys() == ["secret"])
    #expect(try await store.summaries(.library).isEmpty)
  }

  @Test("A refused resumed delta makes at most one replay per sync")
  func refusesReplayOnce() async throws {
    let store = makeStore()
    typealias Page = SyncResponseBuilder
    try await store.markInitialSyncDone()
    try await store.apply(LibraryMessages.decodeLibraryUpdate(Page.page(resume: "expired")), syncToken: "S2", deltaToken: "S1")
    let fetcher = FakeFetcher()
    await fetcher.set(states: ["S1": Page.page(sync: "S2", resume: "expired")])
    let error = GPhotosError.httpError(status: 400, body: "")
    await fetcher.setDeltaFailure("expired", error: error)
    await #expect(throws: error) { _ = try await RemoteLibrarySync(store: store, fetcher: fetcher).sync() }
    #expect(await fetcher.calls == ["delta:expired:S1", "state:S1", "delta:expired:S1"])
    #expect(try await store.syncState().deltaToken == "S1")
  }

  @Test("Delta syncs page with both tokens and stop when the token stops moving")
  func deltaCycles() async throws {
    let store = makeStore()
    try await store.apply(
      try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(sync: "S1", items: [.init(key: "x")])),
      syncToken: "S1")
    try await store.markInitialSyncDone()
    let fetcher = FakeFetcher()
    await fetcher.set(
      states: ["S1": SyncResponseBuilder.page(sync: "S2", resume: "D1", items: [.init(key: "y")], next: true)],
      deltaPages: ["D1": SyncResponseBuilder.page(deleted: ["x"])])
    let sync = RemoteLibrarySync(store: store, fetcher: fetcher)
    _ = try await sync.sync()
    #expect(try await store.summaries(.library).map(\.mediaKey) == ["y"])
    #expect(await fetcher.calls == ["state:S1", "delta:D1:S1", "state:S2"])

    // The server keeps asking for more without moving the token.
    await fetcher.set(states: ["S2": SyncResponseBuilder.page(next: true)])
    await #expect(throws: RemoteLibrarySyncError.cycleWithoutProgress) { try await sync.sync() }
  }

  @Test("Albums decode, store and list their items")
  func albums() async throws {
    let store = makeStore()
    let page = try LibraryMessages.decodeLibraryUpdate(
      SyncResponseBuilder.page(
        items: [.init(key: "in", collection: "ALBUM"), .init(key: "out")],
        albums: [.init(key: "ALBUM", title: "Trip", count: 1, cover: "in")]))
    #expect(page.albums.first?.title == "Trip")
    #expect(page.albums.first?.coverMediaKey == "in")
    #expect(page.albums.first?.lastActivity == Date(timeIntervalSince1970: 1_760_000_000))
    try await store.apply(page, syncToken: "S")
    #expect(try await store.albums().map(\.mediaKey) == ["ALBUM"])
    #expect(try await store.summaries(.album(key: "ALBUM", title: "Trip")).map(\.mediaKey) == ["in"])
    let deletion = try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(deletedAlbums: ["ALBUM"]))
    #expect(deletion.deletedAlbumKeys == ["ALBUM"])
    try await store.apply(deletion, syncToken: nil)
    #expect(try await store.albums().isEmpty)
  }

  @Test("Thumbnail ids and request sizes")
  func thumbnailIDs() {
    let id = RemoteThumbnailID(mediaKey: "AF1Q:abc", contentVersion: 4)
    #expect(RemoteThumbnailID(id.string) == id)
    #expect(RemoteThumbnailID("local-id") == nil)
    #expect(GoogleThumbnailSource.requestSide(for: CGSize(width: 320, height: 320), quality: .thumbnail) == 320)
    #expect(GoogleThumbnailSource.requestSide(for: CGSize(width: 1290, height: 2796), quality: .display) == 3072)
    #expect(GoogleThumbnailSource.requestSide(for: CGSize(width: 9000, height: 10), quality: .display) == 8192)
  }

  @Test("Trash shows the days left")
  func trashDaysLeft() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    #expect(RemoteLibraryGridModel.daysLeft(trashedAt: now, now: now) == "60 days left")
    #expect(RemoteLibraryGridModel.daysLeft(trashedAt: now.addingTimeInterval(-59.5 * 86_400), now: now) == "1 day left")
  }
}

@Suite("Optimized storage")
struct OptimizedStorageTests {
  private func jpeg(width: Int, height: Int) throws -> URL {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = try #require(KeptThumbnails.encode(image))
    let url = TestTemporaryDirectory.root.appending(path: "\(UUID().uuidString).jpg")
    try data.write(to: url)
    return url
  }

  @Test("A removed file leaves a small thumbnail under its media key, pruned with the item")
  func keepsAndPrunes() async throws {
    let email = "kept-\(UUID().uuidString)@example.com"
    defer {
      KeptThumbnails.removeAll(accountEmail: email)
      LockedItems.forget(accountEmail: email)
    }
    var record = TransferRecord(id: "\(email)|1", filename: "a.jpg", mediaType: "Photo", status: .sent)
    record.mediaKeysByAccount = [email: "KEY"]
    // Until the mirror says what's in the Locked Folder, nothing is kept.
    await KeptThumbnails.keep(record, fileURL: try jpeg(width: 20, height: 10))
    #expect(KeptThumbnails.data(mediaKey: "KEY", accountEmail: email) == nil)
    LockedItems.load(["LOCKED"], accountEmail: email)
    var locked = record
    locked.mediaKeysByAccount = [email: "LOCKED"]
    await KeptThumbnails.keep(locked, fileURL: try jpeg(width: 20, height: 10))
    #expect(!FileManager.default.fileExists(atPath: KeptThumbnails.url(mediaKey: "LOCKED", accountEmail: email).path))
    await KeptThumbnails.keep(record, fileURL: try jpeg(width: 2000, height: 1000))
    let data = try #require(KeptThumbnails.data(mediaKey: "KEY", accountEmail: email))
    let image = try #require(GoogleThumbnailSource.decode(data, maxPixel: 1000))
    #expect(max(image.width, image.height) == KeptThumbnails.side)
    #expect(GoogleThumbnailSource.cropped(image, square: true).width == image.height)

    // Parts other than the primary (a RAW, an unedited original) don't keep one.
    var raw = record
    raw.mediaKeysByAccount = [email: "RAW"]
    raw.resourceRole = .alternatePhoto
    await KeptThumbnails.keep(raw, fileURL: try jpeg(width: 10, height: 10))
    #expect(KeptThumbnails.data(mediaKey: "RAW", accountEmail: email) == nil)

    KeptThumbnails.prune(keeping: ["KEY"], accountEmail: email)
    #expect(KeptThumbnails.data(mediaKey: "KEY", accountEmail: email) != nil)
    KeptThumbnails.prune(keeping: [], accountEmail: email)
    #expect(KeptThumbnails.data(mediaKey: "KEY", accountEmail: email) == nil)
  }

  @Test("Recently viewed photos are remembered for the chosen time")
  func recentlyViewed() throws {
    let defaults = try #require(UserDefaults(suiteName: "RecentlyViewedTests-\(UUID().uuidString)"))
    let now = Date()
    RecentlyViewed.record("old", now: now.addingTimeInterval(-10 * 86_400), defaults: defaults)
    RecentlyViewed.record("new", now: now, defaults: defaults)
    #expect(RecentlyViewed.assetIDs(within: 7 * 86_400, now: now, defaults: defaults) == ["new"])
    #expect(RecentlyViewed.assetIDs(within: 30 * 86_400, now: now, defaults: defaults) == ["old", "new"])
  }

  @Test("Settings saved before the option existed keep a month")
  func settingDefault() throws {
    let data = try JSONEncoder().encode(["autoDeleteDelay": "never"])
    let settings = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(settings.keepsRecentlyViewed == .month)
    #expect(RecentlyViewedRetention.off.interval == nil)
  }
}

@Suite("Download limiter")
struct DownloadLimiterTests {
  @Test("Cancelled waiters leave the queue and the newest waiter goes next")
  func newestFirstAndCancellation() async throws {
    let limiter = DownloadLimiter(slots: 1)
    #expect(await limiter.acquire())
    let order = OrderLog()
    let old = Task {
      if await limiter.acquire() {
        await order.append("old")
        limiter.release()
      }
    }
    try await Task.sleep(for: .milliseconds(50))
    let cancelled = Task { await limiter.acquire() }
    try await Task.sleep(for: .milliseconds(50))
    let new = Task {
      if await limiter.acquire() {
        await order.append("new")
        limiter.release()
      }
    }
    try await Task.sleep(for: .milliseconds(50))
    cancelled.cancel()
    #expect(await cancelled.value == false)
    limiter.release()
    _ = await (old.value, new.value)
    #expect(await order.items == ["new", "old"])
  }

  actor OrderLog {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
  }
}
