import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Testing
import os

@testable import GPhotosKit

@Suite("Cloud library: changes, account switches and the Locked Folder")
@MainActor
struct CloudLibraryLifecycleTests {
  private typealias Page = SyncResponseBuilder

  private let folder = TestTemporaryDirectory.root.appending(path: "Lifecycle-\(UUID().uuidString)")

  private func makeStore(email: String = "test@example.com") -> RemoteLibraryStore {
    RemoteLibraryStore(accountEmail: email, directory: folder)
  }

  private func update(_ data: Data) throws -> RemoteLibraryUpdate { try LibraryMessages.decodeLibraryUpdate(data) }

  /// A mirror that finished its first sync at token S1 with one item.
  private func syncedStore() async throws -> RemoteLibraryStore {
    let store = makeStore()
    try await store.apply(try update(Page.page(sync: "S1", items: [.init(key: "a")])), syncToken: "S1")
    try await store.markInitialSyncDone()
    return store
  }

  private func makeLibrary(
    store: RemoteLibraryStore, email: String = "test@example.com", fetcher: any RemoteLibraryFetching,
    client: GooglePhotosMobileClient? = nil
  ) -> CloudLibrary {
    CloudLibrary(accountEmail: email, store: store, fetcher: fetcher, thumbnails: NoThumbnails(), actionClient: client)
  }

  @Test("A page repeating what the mirror has changes nothing")
  func repeatedPagesChangeNothing() async throws {
    let store = makeStore()
    let page = try update(
      Page.page(
        sync: "S1", items: [.init(key: "a"), .init(key: "b", favorite: true)],
        albums: [.init(key: "ALBUM", title: "Trip", count: 1, cover: "a")]))
    #expect(try await store.apply(page, syncToken: "S1") == .init(items: 2, albums: 1, removals: 0))
    #expect(try await store.apply(page, syncToken: "S1").isEmpty)
    #expect(try await store.apply(try update(Page.page(deleted: ["missing"])), syncToken: nil).isEmpty)

    let favorite = try update(Page.page(items: [.init(key: "a", favorite: true)]))
    #expect(try await store.apply(favorite, syncToken: nil) == .init(items: 1, albums: 0, removals: 0))
    let renamed = try update(Page.page(albums: [.init(key: "ALBUM", title: "Holiday", count: 1, cover: "a")]))
    #expect(try await store.apply(renamed, syncToken: nil) == .init(items: 0, albums: 1, removals: 0))
    let locked = try update(Page.page(items: [.init(key: "b", favorite: true, locked: true)]))
    #expect(try await store.apply(locked, syncToken: nil) == .init(items: 1, albums: 0, removals: 1, hidden: 1))
    let deleted = try update(Page.page(deleted: ["a"]))
    #expect(try await store.apply(deleted, syncToken: nil) == .init(items: 1, albums: 0, removals: 1))
  }

  @Test("A delta that brings nothing new leaves the revision alone; one that does bumps it once")
  func noOpDeltaKeepsRevision() async throws {
    let store = try await syncedStore()
    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    let library = makeLibrary(store: store, fetcher: fetcher)
    library.refresh(force: true)
    await library.waitForSync()
    #expect(await fetcher.calls == ["state:S1"])
    #expect(library.revision == 0)
    #expect(library.albumsRevision == 0)
    #expect(library.stats.items == 1)
    #expect(library.status == .idle)

    await fetcher.set(
      states: [
        "S1": Page.page(sync: "S2", items: [.init(key: "b")], albums: [.init(key: "ALBUM", title: "Trip", count: 1, cover: "b")])
      ])
    library.refresh(force: true)
    await library.waitForSync()
    #expect(library.revision == 1)
    #expect(library.albumsRevision == 1)
    #expect(library.albumList.map(\.mediaKey) == ["ALBUM"])
    #expect(library.stats.items == 2)

    // The same page again (Google repeating itself) reloads nothing.
    await fetcher.set(
      states: [
        "S2": Page.page(sync: "S2", items: [.init(key: "b")], albums: [.init(key: "ALBUM", title: "Trip", count: 1, cover: "b")])
      ])
    library.refresh(force: true)
    await library.waitForSync()
    #expect(library.revision == 1)
    #expect(library.albumsRevision == 1)
  }

  @Test("A grid joining a load waits for it, and marks a revision loaded only once its items are in")
  func gridLoadsAreJoined() async throws {
    let store = try await syncedStore()
    let library = makeLibrary(store: store, fetcher: CloudLibrarySyncTests.FakeFetcher())
    let grid = RemoteLibraryGridModel(library: library, scope: .library)
    async let first: Void = grid.reloadIfNeeded()
    async let second: Void = grid.reloadIfNeeded()
    _ = await (first, second)
    #expect(grid.items.map(\.mediaKey) == ["a"])
    #expect(grid.isLoaded)
    // Only a grid that shows month titles builds them.
    #expect(grid.timeline.months.isEmpty)
    let titled = RemoteLibraryGridModel(library: library, scope: .library, buildsTimeline: true)
    await titled.reloadIfNeeded()
    #expect(titled.timeline.months.count == 1)
  }

  @Test("Switching accounts stops the sync: a response that arrives after is never written")
  func accountSwitchCancelsSync() async throws {
    let store = try await syncedStore()
    let fetcher = GatedFetcher(page: Page.page(sync: "S2", items: [.init(key: "late")]), ignoresCancellation: true)
    let library = makeLibrary(store: store, fetcher: fetcher)
    library.refresh(force: true)
    await fetcher.waitUntilRequested()

    library.cancelSync()
    await fetcher.release()
    await library.retire()
    #expect(library.isRetired)
    #expect(library.status == .idle)
    #expect(await fetcher.requests == 1)
    // The old account's mirror doesn't take the page, and the store is closed for good.
    let reopened = makeStore()
    #expect(try await reopened.summaries(.library).map(\.mediaKey) == ["a"])
    await #expect(throws: RemoteLibraryStore.ClosedError.self) { try await store.syncState() }

    // Nothing starts it again, with whatever credential the shared client has now.
    library.refresh(force: true)
    library.refreshAfterUpload()
    await library.waitForSync()
    #expect(await fetcher.requests == 1)
    await #expect(throws: CancellationError.self) { try await library.setArchived([sampleSummary], archived: true) }
  }

  @Test("A removed account's mirror stays deleted, even with its sync still running")
  func removedMirrorStaysDeleted() async throws {
    let store = try await syncedStore()
    let file = folder.appending(path: RemoteLibraryStore.fileName(for: "test@example.com"))
    #expect(FileManager.default.fileExists(atPath: file.path))
    let fetcher = GatedFetcher(page: Page.page(sync: "S2", items: [.init(key: "late")]), ignoresCancellation: false)
    let library = makeLibrary(store: store, fetcher: fetcher)
    let grid = RemoteLibraryGridModel(library: library, scope: .library)
    await grid.reloadIfNeeded()
    #expect(grid.itemCount == 1)
    library.refresh(force: true)
    await fetcher.waitUntilRequested()

    await library.removeLocalData()
    // Its rows leave the screen too, unlike those of a mirror that can't be read.
    await grid.reloadIfNeeded()
    #expect(grid.items.isEmpty && !grid.loadFailed)
    await fetcher.release()
    library.refresh(force: true)
    await library.waitForSync()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: RemoteLibraryStore.ClosedError.self) {
      try await store.apply(try update(Page.page(items: [.init(key: "x")])), syncToken: "S3")
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(library.stats == RemoteLibraryStats())
  }

  @Test("Locked Folder items stay out of every scope, lookup and count but their own")
  func lockedItemsAreFiltered() async throws {
    let store = makeStore()
    let hash = Data(repeating: 4, count: 20)
    try await store.apply(
      try update(
        Page.page(
          sync: "S1",
          items: [
            .init(key: "open", favorite: true, video: true, sha1: hash),
            .init(key: "secret", favorite: true, video: true, charged: 10, sha1: hash, locked: true),
          ],
          albums: [.init(key: "ALBUM", title: "Trip", count: 1, cover: "secret")])),
      syncToken: "S1")
    for scope in [RemoteScope.library, .favorites, .videos, .usesStorage, .archive, .trash] {
      #expect(!(try await store.summaries(scope).map(\.mediaKey).contains("secret")))
    }
    #expect(try await store.summary(mediaKey: "secret") == nil)
    #expect(try await store.item(mediaKey: "secret") == nil)
    #expect(try await store.summary(mediaKey: "open") != nil)
    #expect(try await store.allMediaKeys() == ["open"])
    #expect(try await store.searchWords(mediaKeys: ["open", "secret"]).keys.sorted() == ["open"])
    #expect(try await store.siriDetails(mediaKeys: ["open", "secret"]).keys.sorted() == ["open"])
    #expect(try await store.duplicateGroups().isEmpty)
    #expect(try await store.albums().first?.coverMediaKey == nil)
    let stats = try await store.stats()
    #expect(stats.items == 1 && stats.chargedItems == 0 && stats.locked == 1)
    #expect(try await store.lockedSummaries().map(\.mediaKey) == ["secret"])
  }

  @Test("Locked Folder images use an ephemeral client and leave nothing on disk")
  func lockedImagesStayOffDisk() async throws {
    let email = "locked-\(UUID().uuidString)@example.com"
    let store = makeStore(email: email)
    try await store.apply(try update(Page.page(sync: "S1", items: [.init(key: "secret", locked: true)])), syncToken: "S1")
    let library = makeLibrary(
      store: store, email: email, fetcher: CloudLibrarySyncTests.FakeFetcher(),
      client: GooglePhotosMobileClient(authService: GoogleAuthService()))
    let item = try #require(try await library.lockedItems().first)
    // Signed out: the request fails before anything is fetched, and the screen says so.
    await #expect(throws: (any Error).self) { try await library.lockedImage(item, side: 256, crop: true) }
    #expect(!FileManager.default.fileExists(atPath: ThumbnailDiskCache.directory(for: email).path))
    #expect(!FileManager.default.fileExists(atPath: KeptThumbnails.directory(for: email).path))
    library.cancelSync()
    await #expect(throws: CancellationError.self) { try await library.lockedImage(item, side: 256, crop: true) }
  }

  @Test("The thumbnail cache names files after their item and stops writing once removed")
  func thumbnailDiskCache() throws {
    let email = "cache-\(UUID().uuidString)@example.com"
    let key = cacheKey("abc")
    #expect(key.fileName == "a9993e364706816aba3e25717850c26c9cd0d89d-1-128c")
    let cache = ThumbnailDiskCache(accountEmail: email, byteLimit: 1 << 20)
    cache.store(Data([1, 2, 3]), for: key)
    #expect(cache.data(for: key) == Data([1, 2, 3]))
    cache.removeAll()
    cache.store(Data([4]), for: key)
    #expect(cache.data(for: key) == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
  }

  // MARK: Moving to the Locked Folder

  private func cacheKey(_ mediaKey: String, version: Int = 1, side: Int = 128, crop: Bool = true) -> ThumbnailDiskCache.Key {
    ThumbnailDiskCache.Key(RemoteThumbnailID(mediaKey: mediaKey, contentVersion: version), side: side, crop: crop)
  }

  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    return try #require(context.makeImage())
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }

  @Test("An item moved to the Locked Folder leaves the disk, the memory cache and the launch snapshot")
  func lockingPurgesCaches() async throws {
    let email = "purge-\(UUID().uuidString)@example.com"
    let secret = "secret-\(UUID().uuidString)"
    let store = makeStore(email: email)
    let open = Page.page(sync: "S1", items: [.init(key: secret), .init(key: "open"), .init(key: "other")])
    try await store.apply(try update(open), syncToken: "S1")
    try await store.markInitialSyncDone()
    let cache = ThumbnailDiskCache(accountEmail: email, byteLimit: 1 << 20)
    let downloads = FileManager.default.temporaryDirectory.appending(
      path: "Downloads/\(ThumbnailDiskCache.itemName(for: secret))-\(UUID().uuidString)")
    defer {
      cache.removeAll()
      KeptThumbnails.removeAll(accountEmail: email)
      LockedItems.forget(accountEmail: email)
      try? FileManager.default.removeItem(at: downloads)
    }
    // Every size and version of it, and a file that could be anything's.
    let copies = [cacheKey(secret), cacheKey(secret, version: 7, side: 2048, crop: false), cacheKey(secret, side: 320)]
    for key in copies { cache.store(Data([1]), for: key) }
    cache.store(Data([2]), for: cacheKey("open"))
    let unnamed = cache.directory.appending(path: "a9993e364706816aba3e25717850c26c9cd0d89d")
    try Data([3]).write(to: unnamed)
    let kept = KeptThumbnails.url(mediaKey: secret, accountEmail: email)
    try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([4]).write(to: kept)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try Data([5]).write(to: downloads.appending(path: "IMG_1.HEIC"))
    let thumbnailID = RemoteThumbnailID(mediaKey: secret, contentVersion: 1).string
    ThumbnailPipeline.shared.rememberViewerPreview(try image(), for: thumbnailID)
    #expect(ThumbnailPipeline.shared.viewerPreview(for: thumbnailID) != nil)

    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    await fetcher.set(states: ["S1": Page.page(sync: "S2", items: [.init(key: secret, locked: true)])])
    let invalidations = OSAllocatedUnfairLock(initialState: 0)
    let library = CloudLibrary(
      accountEmail: email, store: store, fetcher: fetcher, thumbnails: NoThumbnails(), actionClient: nil,
      invalidateSnapshot: { invalidations.withLock { $0 += 1 } })
    library.refresh(force: true)
    await library.waitForSync()

    for key in copies { #expect(cache.data(for: key) == nil) }
    #expect(cache.data(for: cacheKey("open")) == Data([2]))
    #expect(!FileManager.default.fileExists(atPath: unnamed.path))
    #expect(!FileManager.default.fileExists(atPath: kept.path))
    #expect(!FileManager.default.fileExists(atPath: downloads.path))
    #expect(invalidations.withLock { $0 } == 1)
    #expect(await eventually { ThumbnailPipeline.shared.viewerPreview(for: thumbnailID) == nil })
    #expect(library.revision == 1)

    // A response on its way when it was locked isn't written back.
    cache.store(Data([6]), for: cacheKey(secret))
    #expect(cache.data(for: cacheKey(secret)) == nil)

    // Back out of the Locked Folder, it's an item like any other.
    await fetcher.set(states: ["S2": Page.page(sync: "S3", items: [.init(key: secret)])])
    library.refresh(force: true)
    await library.waitForSync()
    cache.store(Data([7]), for: cacheKey(secret))
    #expect(cache.data(for: cacheKey(secret)) == Data([7]))
    #expect(invalidations.withLock { $0 } == 1)
    await library.retire()
  }

  private func indexStore() -> LibraryIndexStore {
    LibraryIndexStore(directory: folder.appending(path: "index-\(UUID().uuidString)"))
  }

  private func fill(_ index: LibraryIndexStore, keys: [String]) async throws {
    var analysis = ItemAnalysis()
    analysis.labels = [("mountain", 0.9)]
    analysis.text = "Summit"
    analysis.faces = [DetectedFace(rect: CGRect(x: 0, y: 0, width: 1, height: 1), featurePrint: Data(count: 16))]
    let ids = keys.map(LibraryIndexer.searchID(cloudMediaKey:))
    try await index.saveAll(ids.map { (ItemMetadata(id: $0, date: Date(), words: ["Rome"]), analysis) })
    try await index.saveSiri(
      ids.map {
        let record = SiriItemRecord(
          id: $0, source: .google, fileName: "IMG.jpg", date: Date(), isVideo: false, isFavorite: true, place: "Rome",
          caption: "Private", labels: ["mountain"], text: "Summit", people: ["Sam"])
        return (record: record, key: 1)
      })
  }

  private final class FakeSpotlight: Sendable {
    let indexed = OSAllocatedUnfairLock(initialState: Set<String>())
    let deletions = OSAllocatedUnfairLock(initialState: 0)
    let deletionEvents = Gate(isOpen: true)
    let attempted = OSAllocatedUnfairLock(initialState: Set<String>())
    let fails = OSAllocatedUnfairLock(initialState: false)
    let indexing = OneShotSignal()
    let finishIndexing = OSAllocatedUnfairLock<OneShotSignal?>(initialState: nil)

    var backend: SiriSpotlightIndexer.Backend {
      .init(
        indexPhotos: { [self] photos in
          let ids = photos.map(\.id)
          attempted.withLock { $0.formUnion(ids) }
          indexing.resume()
          await finishIndexing.withLock { $0 }?.wait()
          indexed.withLock { $0.formUnion(ids) }
        },
        deletePhotos: { [self] ids in
          deletions.withLock { $0 += 1 }
          await deletionEvents.pass()
          if fails.withLock({ $0 }) { throw CocoaError(.featureUnsupported) }
          indexed.withLock { $0.subtract(ids) }
        }, indexPeople: { _ in }, deleteAllPeople: {})
    }
  }

  @Test("A Spotlight error while switching accounts doesn't cost the new account's index at the next launch")
  func switchSurvivesSpotlightError() async throws {
    let suite = "Switch-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("a@example.com", forKey: "SiriIndexedAccount")
    let store = indexStore()
    let spotlight = FakeSpotlight()
    try await fill(store, keys: ["from-a"])
    spotlight.fails.withLock { $0 = true }
    let indexer = SiriSpotlightIndexer(store: store, backend: spotlight.backend, defaultsSuite: suite)
    await indexer.browsedAccountChanged(to: "b@example.com")
    #expect(spotlight.deletions.withLock { $0 } > 0)
    #expect(try await store.analyzedIDs().isEmpty)

    try await store.save(ItemMetadata(id: "g:from-b", date: nil, words: []), analysis: ItemAnalysis())
    let relaunched = SiriSpotlightIndexer(store: store, backend: spotlight.backend, defaultsSuite: suite)
    await relaunched.browsedAccountChanged(to: "b@example.com")
    #expect(try await store.analyzedIDs().contains("g:from-b"))
  }

  @Test("Signed-out startup removes stale cloud rows, and a retired pass cannot write them back")
  func startupEvictsRetiredAccountRows() async throws {
    let suite = "SignedOut-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("", forKey: "SiriIndexedAccount")
    let store = indexStore()
    let spotlight = FakeSpotlight()
    let indexer = SiriSpotlightIndexer(store: store, backend: spotlight.backend, defaultsSuite: suite)
    try await fill(store, keys: ["old-indexed"])
    try await store.save(ItemMetadata(id: "local", date: nil, words: []), analysis: nil)
    spotlight.indexed.withLock { $0 = ["g:old-indexed"] }

    let cloud = makeLibrary(store: makeStore(), fetcher: CloudLibrarySyncTests.FakeFetcher())
    await cloud.retire()
    await indexer.browsedAccountChanged(to: nil)
    let stale = ItemMetadata(id: "g:late", date: nil, words: ["private"])
    try await store.saveAll([(stale, nil)], pixelsPending: true, cloud: cloud)
    try await store.saveAll([(stale, ItemAnalysis())], cloud: cloud)
    let siri = SiriItemRecord(id: "g:late", source: .google, date: nil, isVideo: false, isFavorite: false)
    try await store.saveSiri([(siri, 1)], cloud: cloud)

    #expect(try await store.analyzedIDs() == ["local"])
    #expect(try await store.allSiriIDs().isEmpty)
    #expect(spotlight.indexed.withLock { $0 }.isEmpty)
  }

  @Test("Locked media refuse downloads and stream URLs, and a staged download is discarded")
  func lockedMediaCannotDownloadOrStream() async throws {
    let email = "download-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let key = "download-\(UUID().uuidString)"
    let store = makeStore(email: email)
    try await store.apply(try update(Page.page(items: [.init(key: key)])), syncToken: "S1")
    let item = try #require(try await store.summary(mediaKey: key))
    let library = makeLibrary(store: store, email: email, fetcher: CloudLibrarySyncTests.FakeFetcher())
    let temporary = TestTemporaryDirectory.root.appending(path: "\(key).jpg")
    try Data([42]).write(to: temporary)

    LockedItems.insert([key], accountEmail: email)
    await #expect(throws: CancellationError.self) { _ = try await library.download(item) }
    await #expect(throws: CancellationError.self) { _ = try await library.streamingPlaylist(item) }
    await #expect(throws: CancellationError.self) { _ = try await library.videoURL(item) }
    #expect(throws: CancellationError.self) { _ = try library.publishDownload(temporary, mediaKey: key, name: "private.jpg") }
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    await library.retire()
  }

  @Test("Stopping a locked viewer video detaches the item and its controls")
  func stopsLockedVideo() {
    let controls = VideoPlayback()
    let current = AVPlayerItem(url: URL(fileURLWithPath: "/unplayed.mp4"))
    let player = AVPlayer(playerItem: current)
    controls.attach(player)
    controls.stop(player)
    #expect(player.currentItem == nil)
    #expect(player.rate == 0)
    #expect(controls.player == nil)
  }

  @Test func playbackRotationRefitsWithoutReplacingThePlayer() {
    let controls = VideoPlayback()
    let player = AVPlayer()
    controls.attach(player)
    let size = CGSize(width: 1080, height: 1920)
    for turns in [1, 2, 3, 0] {
      controls.setOrientation(turns)
      #expect(controls.quarterTurns == turns)
      #expect(controls.player === player)
      let expected = turns.isMultiple(of: 2) ? size : CGSize(width: 1920, height: 1080)
      #expect(PlaybackOrientation.size(size, quarterTurns: controls.quarterTurns) == expected)
    }
    controls.setOrientation(1)
    controls.attach(AVPlayer())
    #expect(controls.quarterTurns == 0)
    controls.attach(nil)
  }

  @Test("Viewer positions use the Google ID map beyond the old search window and after a delete")
  func remoteViewerLooksUpMovedAndDeletedItems() async throws {
    let store = makeStore()
    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    let items: [Page.Item] = (0..<280).map { .init(key: "viewer-\($0)") }
    try await store.apply(try update(Page.page(items: items)), syncToken: "S1")
    try await store.markInitialSyncDone()
    let library = makeLibrary(store: store, fetcher: fetcher)
    let grid = RemoteLibraryGridModel(library: library, scope: .library)
    await grid.reloadIfNeeded()
    let id = grid.itemID(at: 279)
    #expect(grid.index(ofItemID: id, near: 0) == 279)
    let selection = MediaViewer.PageSelection(index: 279, source: grid)
    let key = try #require(grid.items.last?.mediaKey)
    await fetcher.set(states: ["S1": Page.page(sync: "S2", deleted: [key])])
    library.refresh(force: true)
    await library.waitForSync()
    await grid.reloadIfNeeded()
    #expect(grid.index(ofItemID: id, near: 279) == nil)
    #expect(selection.position(in: grid) == 278)
    await library.retire()
  }

  @Test("A locked crop cannot repopulate the face cache, including with an accountless thumbnail ID")
  func lateFaceCropIsRejected() throws {
    let email = "face-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let key = "face-\(UUID().uuidString)"
    let identity = ThumbnailIdentity(id: RemoteThumbnailID(mediaKey: key, contentVersion: 1).string)
    let crop = try image()
    LockedItems.insert([key], accountEmail: email)
    #expect(identity.isLocked)
    FaceCropCache.setObject(crop, forKey: key as NSString, identity: identity)
    #expect(FaceCropCache.object(forKey: key as NSString) == nil)
  }

  @Test("Siri drops a degraded thumbnail when its item locks before delivery finishes")
  func siriRejectsDegradedFrameOnLock() async throws {
    final class Source: ThumbnailSource {
      let frame: CGImage
      let email: String
      let key: String
      init(frame: CGImage, email: String, key: String) {
        self.frame = frame
        self.email = email
        self.key = key
      }
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality, onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        deliver(frame, false)
        LockedItems.insert([key], accountEmail: email)
        onUnavailable()
        return .none
      }
    }

    let email = "siri-degraded-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let key = "degraded-\(UUID().uuidString)"
    let library = makeLibrary(store: makeStore(email: email), email: email, fetcher: CloudLibrarySyncTests.FakeFetcher())
    let id = RemoteThumbnailID(mediaKey: key, contentVersion: 1).string
    let source = Source(frame: try image(), email: email, key: key)
    let data = await SiriLibrary.cloudThumbnailData(from: source, id: id, side: 80, timeout: .seconds(2), cloud: library, key: key)
    #expect(data == nil)
    await library.retire()
  }

  @Test("Startup reconciles already locked rows, including IDs found only in Spotlight")
  func reconcilesExistingLocksOnce() async throws {
    let email = "existing-locks-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let store = makeStore(email: email)
    let index = indexStore()
    let spotlight = FakeSpotlight()
    let indexed = "indexed-\(UUID().uuidString)"
    let spotlightOnly = "spotlight-\(UUID().uuidString)"
    let visible = "visible-\(UUID().uuidString)"
    try await fill(index, keys: [indexed, visible])
    spotlight.indexed.withLock { $0 = Set([indexed, spotlightOnly, visible].map { "g:\($0)" }) }
    try await store.apply(
      try update(
        Page.page(items: [
          .init(key: indexed, locked: true), .init(key: spotlightOnly, locked: true), .init(key: visible),
        ])), syncToken: "S1")
    // The mirror has the lock state, but no queued work from when those locks were recorded.
    try await store.finishLockedPurges([indexed, spotlightOnly])

    let indexer = SiriSpotlightIndexer(store: index, backend: spotlight.backend)
    let library = CloudLibrary(
      accountEmail: email, store: store, fetcher: CloudLibrarySyncTests.FakeFetcher(), thumbnails: NoThumbnails(),
      actionClient: nil, purgeIndex: { await indexer.purge(lockedKeys: $0) })
    #expect(
      await eventually {
        let pending = try? await store.pendingLockedPurges()
        return pending == [] && spotlight.indexed.withLock { $0 } == ["g:\(visible)"]
      })
    #expect(try await index.analyzedIDs() == ["g:\(visible)"])
    #expect(try await index.allSiriIDs() == ["g:\(visible)"])
    await library.retire()
    let reopened = makeStore(email: email)
    try await reopened.enqueueExistingLockedKeys()
    #expect(try await reopened.pendingLockedPurges().isEmpty)
  }

  @Test("Sign-out evicts an in-flight Spotlight write and rejects the old account's queued write", .timeLimit(.minutes(1)))
  func accountEvictionOrdersPublication() async throws {
    let suite = "Spotlight-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let email = "queued-\(UUID().uuidString)@example.com"
    let store = makeStore(email: email)
    let index = indexStore()
    let spotlight = FakeSpotlight()
    let finish = OneShotSignal()
    let accountChanged = OneShotSignal()
    spotlight.finishIndexing.withLock { $0 = finish }
    defer { finish.resume() }
    let indexer = SiriSpotlightIndexer(store: index, backend: spotlight.backend, defaultsSuite: suite) { email in
      if email == nil { accountChanged.resume() }
    }
    await indexer.browsedAccountChanged(to: email)
    let library = CloudLibrary(
      accountEmail: email, store: store, fetcher: CloudLibrarySyncTests.FakeFetcher(), thumbnails: NoThumbnails(),
      actionClient: nil)
    try await store.apply(try update(Page.page(items: [.init(key: "in-flight"), .init(key: "queued")])), syncToken: "S1")
    func snapshot(_ id: String) async throws -> UnifiedLibraryModel.IndexSnapshot {
      let summary = try #require(try await store.summary(mediaKey: id))
      return .init(entries: [.cloud(0)], device: [], cloud: [summary], folder: [], cloudLibrary: library)
    }
    let first = try await snapshot("in-flight")
    let second = try await snapshot("queued")
    let indexing = Task { await indexer.sync(first) }
    await spotlight.indexing.wait()

    let inFlightWork = await indexer.lastWork
    let queued = Task { await indexer.sync(second) }
    try #require(await eventually { await indexer.lastWork != inFlightWork })
    let signOut = Task { await indexer.browsedAccountChanged(to: nil) }
    await accountChanged.wait()
    finish.resume()
    await indexing.value
    await queued.value
    await signOut.value

    #expect(spotlight.attempted.withLock { $0 } == ["g:in-flight"])
    #expect(spotlight.indexed.withLock { $0 }.isEmpty)
    #expect(try await index.allSiriIDs().isEmpty)
    await library.retire()
  }

  @Test("An item moved to the Locked Folder leaves the index, Siri and Spotlight at once")
  func lockingPurgesIndex() async throws {
    let email = "index-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let secret = "secret-\(UUID().uuidString)"
    let open = "open-\(UUID().uuidString)"
    let store = makeStore(email: email)
    try await store.apply(
      try update(Page.page(sync: "S1", items: [.init(key: secret), .init(key: open)])), syncToken: "S1")
    try await store.markInitialSyncDone()
    let index = indexStore()
    try await fill(index, keys: [secret, open])
    let spotlight = FakeSpotlight()
    spotlight.indexed.withLock { $0 = ["g:\(secret)", "g:\(open)"] }
    let indexer = SiriSpotlightIndexer(store: index, backend: spotlight.backend)
    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    await fetcher.set(states: ["S1": Page.page(sync: "S2", items: [.init(key: secret, locked: true)])])
    let people = try await index.peopleDirtyVersion()
    let library = CloudLibrary(
      accountEmail: email, store: store, fetcher: fetcher, thumbnails: NoThumbnails(), actionClient: nil,
      invalidateSnapshot: {}, purgeIndex: { await indexer.purge(lockedKeys: $0) })
    library.refresh(force: true)
    await library.waitForSync()

    #expect(await eventually { (try? await store.pendingLockedPurges()) == [] && spotlight.deletions.withLock { $0 } > 0 })
    #expect(spotlight.indexed.withLock { $0 } == ["g:\(open)"])
    #expect(try await index.analyzedIDs() == ["g:\(open)"])
    #expect(try await index.search([["mountain"]]) == ["g:\(open)"])
    #expect(try await index.search([["summit"]]) == ["g:\(open)"])
    #expect(try await index.faces().map(\.itemID) == ["g:\(open)"])
    #expect(try await index.allSiriIDs() == ["g:\(open)"])
    #expect(try await index.peopleDirtyVersion() > people)

    // An analysis that was under way isn't written back.
    try await fill(index, keys: [secret])
    #expect(try await index.analyzedIDs() == ["g:\(open)"])
    await library.retire()
  }

  @Test("A purge Spotlight refuses is tried again, after a quit too, with nothing left to read meanwhile", .timeLimit(.minutes(1)))
  func lockedPurgeIsRetried() async throws {
    let email = "retry-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let keys = (0..<1_200).map { "k\($0)-\(UUID().uuidString)" }
    let store = makeStore(email: email)
    let index = indexStore()
    try await fill(index, keys: keys)
    let spotlight = FakeSpotlight()
    spotlight.fails.withLock { $0 = true }
    spotlight.indexed.withLock { $0 = Set(keys.map { "g:\($0)" }) }
    let indexer = SiriSpotlightIndexer(store: index, backend: spotlight.backend)
    try await store.apply(
      try update(Page.page(sync: "S1", items: keys.map { .init(key: $0, locked: true) })), syncToken: "S1")
    #expect(try await store.pendingLockedPurges() == Set(keys))

    let failing = LockedIndexPurge(store: store, retryDelay: .milliseconds(5)) { await indexer.purge(lockedKeys: $0) }
    let attempted = await failing.start()
    await spotlight.deletionEvents.waitUntilEntered(6)
    #expect(spotlight.deletions.withLock { $0 } >= 6)
    await failing.close()
    await attempted?.value
    #expect(try await index.analyzedIDs().isEmpty)
    // The ids stay, to tell what's still in Spotlight, and nothing else.
    let left = try await index.siriRecords(ids: ["g:\(keys[0])"])
    #expect(
      left == [SiriItemRecord(id: "g:\(keys[0])", source: .google, date: nil, isVideo: false, isFavorite: false)])
    #expect(try await store.pendingLockedPurges() == Set(keys))
    await store.close()

    // The next launch: the mirror, opened again, starts with one item unlocked meanwhile.
    let reopened = makeStore(email: email)
    try await reopened.apply(try update(Page.page(sync: "S2", items: [.init(key: keys[0])])), syncToken: "S2")
    spotlight.fails.withLock { $0 = false }
    let retry = LockedIndexPurge(store: reopened) { await indexer.purge(lockedKeys: $0) }
    await retry.start(reconcileExisting: true)?.value
    #expect(try await reopened.pendingLockedPurges().isEmpty)
    #expect(spotlight.indexed.withLock { $0 } == ["g:\(keys[0])"])
    #expect(try await index.allSiriIDs() == ["g:\(keys[0])"])
    await reopened.close()
  }

  @Test("An item locked while Spotlight is indexing it leaves once that's done, and isn't indexed again")
  func lockedWhileIndexing() async throws {
    let email = "indexing-\(UUID().uuidString)@example.com"
    defer { LockedItems.forget(accountEmail: email) }
    let secret = "secret-\(UUID().uuidString)"
    let store = makeStore(email: email)
    try await store.apply(try update(Page.page(sync: "S1", items: [.init(key: secret)])), syncToken: "S1")
    let summary = try #require(try await store.summary(mediaKey: secret))
    let index = indexStore()
    let spotlight = FakeSpotlight()
    let finish = OneShotSignal()
    spotlight.finishIndexing.withLock { $0 = finish }
    let indexer = SiriSpotlightIndexer(store: index, backend: spotlight.backend)
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.cloud(0)], device: [], cloud: [summary], folder: [], cloudLibrary: nil)
    let defaultsKey = "SiriIndexedAccount"
    let previousAccount = UserDefaults.standard.string(forKey: defaultsKey)
    UserDefaults.standard.removeObject(forKey: defaultsKey)
    defer { if let previousAccount { UserDefaults.standard.set(previousAccount, forKey: defaultsKey) } }

    let pass = Task { await indexer.sync(snapshot) }
    await spotlight.indexing.wait()
    LockedItems.insert([secret], accountEmail: email)
    let purge = Task { await indexer.purge(lockedKeys: [secret]) }
    try await Task.sleep(for: .milliseconds(50))
    finish.resume()
    await pass.value
    #expect(await purge.value)
    #expect(spotlight.indexed.withLock { $0 }.isEmpty)
    #expect(try await index.allSiriIDs().isEmpty)

    // A pass over a list read before the lock.
    spotlight.finishIndexing.withLock { $0 = nil }
    await indexer.sync(snapshot)
    #expect(spotlight.indexed.withLock { $0 }.isEmpty)
    #expect(try await index.allSiriIDs().isEmpty)
  }

  @Test("What's kept of an item is deleted before the page that locks it is committed")
  func purgesBeforeCommit() async throws {
    let store = try await syncedStore()
    let seen = OSAllocatedUnfairLock(initialState: [Set<String>]())
    let locked = try update(Page.page(sync: "S2", items: [.init(key: "a", locked: true), .init(key: "new", locked: true)]))
    let changes = try await store.apply(locked, syncToken: "S2") { keys in seen.withLock { $0.append(keys) } }
    // A row that's new here may have been listed before the mirror was rebuilt.
    #expect(seen.withLock { $0 } == [["a", "new"]])
    #expect(changes == .init(items: 2, albums: 0, removals: 2, hidden: 1))
    #expect(try await store.lockedKeys() == ["a", "new"])
    // Already locked: nothing more to delete.
    let again = try update(Page.page(sync: "S3", items: [.init(key: "a", favorite: true, locked: true)]))
    #expect(try await store.apply(again, syncToken: "S3") { keys in seen.withLock { $0.append(keys) } }.hidden == 0)
    #expect(seen.withLock { $0.count } == 1)
  }

  @Test("A confirmed web move scrubs the mirror and queues its purge without advancing sync")
  func confirmedWebMove() async throws {
    let store = try await syncedStore()
    let before = try await store.syncState()
    let purged = OSAllocatedUnfairLock(initialState: Set<String>())
    try await store.markLocked(["a"]) { keys in purged.withLock { $0 = keys } }

    #expect(purged.withLock { $0 } == ["a"])
    #expect(try await store.lockedKeys() == ["a"])
    #expect(try await store.pendingLockedPurges() == ["a"])
    #expect(try await store.syncState().syncToken == before.syncToken)
    #expect(try await store.syncState().lastSyncedAt == before.lastSyncedAt)
    #expect(try await store.summary(mediaKey: "a") == nil)
    let locked = try #require(try await store.lockedSummaries().first)
    #expect(locked.dedupKey.isEmpty)
    #expect(locked.fileName.isEmpty)
    #expect(locked.sha1 == nil)
  }

  @Test("The mirror keeps no details of a locked item, including those stored before")
  func lockedDetails() async throws {
    let store = try await syncedStore()
    #expect(try await store.item(mediaKey: "a")?.fileName.isEmpty == false)
    _ = try await store.apply(try update(Page.page(sync: "S2", items: [.init(key: "a", locked: true)])), syncToken: "S2")
    let locked = try #require(try await store.lockedSummaries().first { $0.mediaKey == "a" })
    #expect(locked.fileName.isEmpty)
    #expect(locked.dedupKey.isEmpty)
    #expect(locked.sha1 == nil)
    #expect(locked.sizeBytes == 0)
    #expect(locked.latitude == nil)
    // Unlocked, the server's next page brings them back.
    _ = try await store.apply(try update(Page.page(sync: "S3", items: [.init(key: "a")])), syncToken: "S3")
    #expect(try await store.item(mediaKey: "a")?.fileName.isEmpty == false)
  }

  @Test("A thumbnail still downloading when its item is locked is neither shown nor kept")
  func lockedWhileDownloading() async throws {
    let email = "inflight-\(UUID().uuidString)@example.com"
    let data = try #require(KeptThumbnails.encode(try image()))
    let gate = Gate()
    let source = GoogleThumbnailSource(accountEmail: email) { _, _, _, _ in
      await gate.pass()
      return data
    }
    defer {
      source.removeCache()
      LockedItems.forget(accountEmail: email)
    }
    let delivered = OSAllocatedUnfairLock(initialState: 0)
    let unavailable = OSAllocatedUnfairLock(initialState: 0)
    let id = RemoteThumbnailID(mediaKey: "secret", contentVersion: 1)
    let token = source.requestImage(
      id: id.string, pixelSize: CGSize(width: 128, height: 128), quality: .thumbnail,
      onUnavailable: { unavailable.withLock { $0 += 1 } }, deliver: { _, _ in delivered.withLock { $0 += 1 } })
    defer { token.cancel() }
    await gate.waitUntilEntered(1)
    LockedItems.insert(["secret"], accountEmail: email)
    ThumbnailDiskCache.remove(["secret"], accountEmail: email)
    await gate.open()
    #expect(await eventually { unavailable.withLock { $0 } == 1 })
    #expect(delivered.withLock { $0 } == 0)
    let folder = ThumbnailDiskCache.directory(for: email)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    // Asked for again, it isn't requested at all.
    _ = source.requestImage(
      id: id.string, pixelSize: CGSize(width: 128, height: 128), quality: .thumbnail,
      onUnavailable: { unavailable.withLock { $0 += 1 } }, deliver: { _, _ in delivered.withLock { $0 += 1 } })
    #expect(unavailable.withLock { $0 } == 2)
    await #expect(throws: CancellationError.self) { _ = try await source.analysisImage(id, side: 64) }
    #expect(await gate.entered == 1)
  }

  // MARK: Locking while something is on its way

  @Test("An unlock that finishes after locking again opens nothing")
  func lateUnlockStaysLocked() async throws {
    let library = makeLibrary(store: try await syncedStore(), fetcher: CloudLibrarySyncTests.FakeFetcher())
    let gate = Gate()
    let finished = OSAllocatedUnfairLock(initialState: 0)
    let access = LockedFolderAccess {
      await gate.pass()
      finished.withLock { $0 += 1 }
      return true
    }
    access.unlock(library)
    await gate.waitUntilEntered(1)
    #expect(access.isAuthenticating)
    access.lock()
    #expect(!access.isAuthenticating)
    await gate.open()
    #expect(await eventually { finished.withLock { $0 } == 1 })
    try await Task.sleep(for: .milliseconds(20))
    #expect(access.session == nil)

    access.unlock(library)
    #expect(await eventually { access.session != nil })
    let session = try #require(access.session)
    access.lock()
    #expect(access.session == nil)
    #expect(session.isClosed)

    // An account switched away from stays locked.
    let retiring = LockedFolderAccess {
      library.cancelSync()
      return true
    }
    retiring.unlock(library)
    #expect(await eventually { !retiring.isAuthenticating })
    #expect(retiring.session == nil)
    retiring.unlock(library)
    #expect(!retiring.isAuthenticating)
  }

  @Test("A video still loading when the folder locks, or is covered, never plays")
  func latePlaybackStaysStopped() async throws {
    let library = makeLibrary(store: try await syncedStore(), fetcher: CloudLibrarySyncTests.FakeFetcher())
    let gate = Gate()
    let made = OSAllocatedUnfairLock(initialState: 0)
    let makePlayer: @MainActor (RemoteItemSummary) async throws -> AVPlayer = { _ in
      await gate.pass()
      made.withLock { $0 += 1 }
      return AVPlayer()
    }
    let covered = LockedFolderSession(library: library, makePlayer: makePlayer)
    covered.play(sampleSummary)
    let closed = LockedFolderSession(library: library, makePlayer: makePlayer)
    closed.play(sampleSummary)
    await gate.waitUntilEntered(2)
    covered.pauseVideo()
    closed.close()
    await gate.open()
    #expect(await eventually { made.withLock { $0 } == 2 })
    try await Task.sleep(for: .milliseconds(20))
    #expect(covered.player == nil && covered.playingKey == nil)
    #expect(closed.player == nil && closed.playingKey == nil)

    covered.play(sampleSummary)
    #expect(await eventually { covered.player != nil })
    let player = try #require(covered.player)
    #expect(!player.allowsExternalPlayback)
    #expect(covered.playingKey == sampleSummary.mediaKey)
    covered.close()
    #expect(covered.player == nil && covered.playback.player == nil)
    #expect(player.rate == 0)
    covered.play(sampleSummary)
    #expect(made.withLock { $0 } == 3)
    #expect(await covered.image(sampleSummary, side: 64, crop: true) == nil)
    await library.retire()
  }

  // MARK: Retiring

  @Test("Retiring waits for the page a sync fetched ahead")
  func retireDrainsAheadFetch() async throws {
    let store = try await syncedStore()
    let fetcher = AheadFetcher(
      state: Page.page(sync: "S2", resume: "R1", items: [.init(key: "b")]),
      pages: ["R1": Page.page(resume: "R2", items: [.init(key: "c")])], gated: "R2")
    let library = makeLibrary(store: store, fetcher: fetcher)
    library.refresh(force: true)
    await fetcher.gate.waitUntilEntered(1)

    let retired = OSAllocatedUnfairLock(initialState: false)
    let retiring = Task {
      await library.retire()
      retired.withLock { $0 = true }
    }
    #expect(await eventually { library.isRetired })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!retired.withLock { $0 })
    await fetcher.gate.open()
    await retiring.value
    #expect(await fetcher.running == 0)
    #expect(await fetcher.requests == 3)
  }

  @Test("A write that fails ends the page fetched ahead before the sync does")
  func failedCommitDrainsAheadFetch() async throws {
    let store = try await syncedStore()
    let fetcher = AheadFetcher(
      state: Page.page(sync: "S2", resume: "R1", items: [.init(key: "b")]),
      pages: ["R1": Page.page(resume: "R2", items: [.init(key: "c")])], gated: "R2")
    let sync = RemoteLibrarySync(store: store, fetcher: fetcher)
    // The page that can't be written arrives after the store closed; the next is asked for.
    await fetcher.setOnPage { if $0 == "R1" { await store.close() } }
    let ended = OSAllocatedUnfairLock(initialState: false)
    let running = Task {
      defer { ended.withLock { $0 = true } }
      _ = try await sync.sync()
    }
    await fetcher.gate.waitUntilEntered(1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!ended.withLock { $0 })
    await fetcher.gate.open()
    await #expect(throws: RemoteLibraryStore.ClosedError.self) { try await running.value }
    #expect(await fetcher.running == 0)
  }

  @Test("A queued thumbnail never sends after its library is retired, and retiring waits for those sent")
  func queuedThumbnailsAreRetired() async throws {
    let email = "queued-\(UUID().uuidString)@example.com"
    let data = try #require(KeptThumbnails.encode(try image()))
    let gate = Gate()
    let source = GoogleThumbnailSource(accountEmail: email) { _, _, _, _ in
      await gate.pass()
      return data
    }
    defer { source.removeCache() }
    let unavailable = OSAllocatedUnfairLock(initialState: 0)
    let delivered = OSAllocatedUnfairLock(initialState: 0)
    var tokens: [ImageRequestToken] = []
    for index in 0..<20 {
      tokens.append(
        source.requestImage(
          id: RemoteThumbnailID(mediaKey: "k\(index)", contentVersion: 1).string, pixelSize: CGSize(width: 128, height: 128),
          quality: index.isMultiple(of: 2) ? .thumbnail : .display,
          onUnavailable: { unavailable.withLock { $0 += 1 } }, deliver: { _, _ in delivered.withLock { $0 += 1 } }))
    }
    let analyses = (0..<4).map { index in
      Task { try await source.analysisImage(RemoteThumbnailID(mediaKey: "a\(index)", contentVersion: 1), side: 64) }
    }
    // Twelve slots on screen and two for analysis.
    await gate.waitUntilEntered(14)
    let library = CloudLibrary(
      accountEmail: email, store: makeStore(email: email), fetcher: CloudLibrarySyncTests.FakeFetcher(), thumbnails: source,
      actionClient: nil)
    let retired = OSAllocatedUnfairLock(initialState: false)
    let retiring = Task {
      await library.retire()
      retired.withLock { $0 = true }
    }
    #expect(await eventually { library.isRetired })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!retired.withLock { $0 })
    await gate.open()
    await retiring.value
    for analysis in analyses { await #expect(throws: CancellationError.self) { _ = try await analysis.value } }
    #expect(await eventually { unavailable.withLock { $0 } == 20 })
    #expect(await gate.entered == 14)
    #expect(delivered.withLock { $0 } == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: ThumbnailDiskCache.directory(for: email).path).isEmpty)
    for token in tokens { token.cancel() }
    LockedItems.forget(accountEmail: email)
  }

  @Test("People covers fetch one bounded, uncropped thumbnail")
  func boundedFaceCover() async throws {
    let email = "face-cover-\(UUID().uuidString)@example.com"
    let requests = OSAllocatedUnfairLock(initialState: [(side: Int, crop: Bool)]())
    let data = try #require(KeptThumbnails.encode(try image()))
    let source = GoogleThumbnailSource(accountEmail: email) { _, side, crop, _ in
      requests.withLock { $0.append((side, crop)) }
      return data
    }
    defer { source.removeCache() }
    let id = RemoteThumbnailID(mediaKey: "face", contentVersion: 1)
    let ready = OSAllocatedUnfairLock(initialState: false)
    let token = source.requestImage(
      id: id.string, pixelSize: CGSize(width: 600, height: 600), quality: .uncroppedThumbnail
    ) { _, final in ready.withLock { $0 = final } }
    defer { token.cancel() }
    #expect(await eventually { ready.withLock { $0 } })
    #expect(requests.withLock { $0.map(\.side) } == [600])
    #expect(requests.withLock { $0.map(\.crop) } == [false])
  }

  @Test("Locked Folder cells change request identity when their size bucket changes")
  func lockedCellResize() {
    let smaller = LockedFolderCell.Request(side: 128, attempt: 0, version: 0)
    #expect(smaller != .init(side: 256, attempt: 0, version: 0))
    #expect(smaller != .init(side: 128, attempt: 1, version: 0))
  }

  @Test("Unlocking a photo refreshes its cached album cover")
  func unlockedAlbumCover() async throws {
    let store = try await syncedStore()
    try await store.apply(
      update(Page.page(items: [.init(key: "a", locked: true)], albums: [.init(key: "album", title: "Trip", count: 1, cover: "a")])),
      syncToken: nil)
    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    await fetcher.set(states: ["S1": Page.page(sync: "S2", items: [.init(key: "a")])])
    let library = makeLibrary(store: store, fetcher: fetcher)
    #expect(await eventually { library.isStateLoaded })
    #expect(library.albumList.count == 1)
    #expect(library.albumList.first?.coverMediaKey == nil)
    library.refresh(force: true)
    await library.waitForSync()
    #expect(library.albumList.first?.coverMediaKey == "a")
    await library.retire()
  }

  @Test("Locked Folder uses the concurrent executor to decode display images")
  func lockedImageDecodesOffMain() async throws {
    let sample = try image()
    let data = try #require(KeptThumbnails.encode(sample))
    let decoded = try await CloudLibrary.decodeLockedImage(data, side: 1024) { data, side in
      #expect(!Thread.isMainThread)
      return GoogleThumbnailSource.decode(data, maxPixel: side)
    }
    #expect(decoded.width == sample.width)
  }

  @Test("A thumbnail whose decode ends after retirement cannot write the cache")
  func retirementDuringThumbnailDecode() async throws {
    let email = "retired-decode-\(UUID().uuidString)@example.com"
    let data = try #require(KeptThumbnails.encode(try image()))
    let decoding = OSAllocatedUnfairLock(initialState: false)
    let releaseDecode = DispatchSemaphore(value: 0)
    let source = GoogleThumbnailSource(
      accountEmail: email,
      decode: { data, side in
        decoding.withLock { $0 = true }
        _ = releaseDecode.wait(timeout: .now() + 10)
        return GoogleThumbnailSource.decode(data, maxPixel: side)
      },
      fetch: { _, _, _, _ in data })
    defer { source.removeCache() }
    let library = CloudLibrary(
      accountEmail: email, store: makeStore(email: email), fetcher: CloudLibrarySyncTests.FakeFetcher(),
      thumbnails: source, actionClient: nil)
    let finished = OSAllocatedUnfairLock(initialState: false)
    let delivered = OSAllocatedUnfairLock(initialState: false)
    let id = RemoteThumbnailID(mediaKey: "late", contentVersion: 1)
    let token = source.requestImage(
      id: id.string, pixelSize: CGSize(width: 128, height: 128), quality: .thumbnail,
      onUnavailable: { finished.withLock { $0 = true } },
      deliver: { _, _ in
        delivered.withLock { $0 = true }
        finished.withLock { $0 = true }
      })
    defer { token.cancel() }
    #expect(await eventually { decoding.withLock { $0 } })
    await library.retire()
    releaseDecode.signal()
    #expect(await eventually { finished.withLock { $0 } })
    #expect(!delivered.withLock { $0 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: ThumbnailDiskCache.directory(for: email).path).isEmpty)
  }

  // MARK: A mirror that can't be read

  @Test("A failed mirror read keeps the rows and is tried again")
  func failedReadKeepsRows() async throws {
    let store = try await syncedStore()
    let fetcher = CloudLibrarySyncTests.FakeFetcher()
    let library = makeLibrary(store: store, fetcher: fetcher)
    let grid = RemoteLibraryGridModel(library: library, scope: .library)
    await grid.reloadIfNeeded()
    let merged = UnifiedLibraryModel()
    merged.setCloudLibrary(library)
    await merged.start(records: [])
    #expect(await eventually { merged.itemCount == 1 })
    let token = grid.reloadToken
    await fetcher.set(states: ["S1": Page.page(sync: "S2", items: [.init(key: "b")])])
    library.refresh(force: true)
    await library.waitForSync()

    let mirror = try SQLiteDatabase(url: folder.appending(path: RemoteLibraryStore.fileName(for: "test@example.com")))
    try mirror.execute("ALTER TABLE items RENAME TO unreadable")
    async let first: Void = grid.reloadIfNeeded()
    async let second: Void = grid.reloadIfNeeded()
    _ = await (first, second)
    await merged.cloudChanged()
    #expect(merged.itemCount == 1)
    #expect(merged.mirrorRetry == .banner)
    #expect(grid.loadFailed)
    #expect(grid.isLoaded)
    #expect(grid.items.map(\.mediaKey) == ["a"])
    #expect(grid.reloadToken == token)
    let fresh = RemoteLibraryGridModel(library: library, scope: .library)
    await fresh.reloadIfNeeded()
    #expect(fresh.loadFailed && !fresh.isLoaded)

    try mirror.execute("ALTER TABLE unreadable RENAME TO items")
    await grid.reloadIfNeeded()
    await fresh.reloadIfNeeded()
    await merged.cloudChanged()
    #expect(merged.mirrorRetry == nil)
    #expect(!grid.loadFailed && !fresh.loadFailed && fresh.isLoaded)
    #expect(Set(grid.items.map(\.mediaKey)) == ["a", "b"])
    #expect(grid.reloadToken == token + 1)
    await library.retire()
  }

  @Test("The statement cache stays bounded with generated IN lists")
  func statementCacheIsBounded() throws {
    let url = TestTemporaryDirectory.root.appending(path: "Statements-\(UUID().uuidString).sqlite")
    let database = try SQLiteDatabase(url: url)
    try database.execute("CREATE TABLE t (v INTEGER)")
    try database.run("INSERT INTO t VALUES (1)")
    for count in 1...300 {
      var rows = 0
      try database.query(
        "SELECT v FROM t WHERE v IN (\(Array(repeating: "?", count: count).joined(separator: ",")))",
        Array(repeating: .int(1), count: count)
      ) { _ in
        rows += 1
        // A nested query never finalizes the one still stepping.
        try database.query("SELECT \(count)") { _ in }
      }
      #expect(rows == 1)
    }
    #expect(database.cachedStatementCount <= SQLiteDatabase.statementLimit)
  }

  @Test("Collections publishes only what changed")
  func collectionsSkipEqualSnapshots() {
    let model = PhotoCollectionsModel()
    let snapshot = PhotoCollectionsModel.Snapshot(
      albums: [AlbumSummary(id: "1", title: "Trip", count: 3, keyAssetID: "k")],
      kinds: [MediaKindSummary(kind: .videos, count: 2, keyAssetID: nil)], photos: 10, videos: 2,
      recentlyAddedKeyID: "k")
    model.apply(snapshot)
    #expect(model.isLoaded)

    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = model.albums
      _ = model.mediaKinds
      _ = model.photoCount
      _ = model.videoCount
      _ = model.recentlyAddedKeyID
      _ = model.isLoaded
    } onChange: {
      changed.withLock { $0 = true }
    }
    model.apply(snapshot)
    #expect(!changed.withLock { $0 })

    var updated = snapshot
    updated.photos = 11
    model.apply(updated)
    #expect(changed.withLock { $0 })
    #expect(model.photoCount == 11)
  }

  private var sampleSummary: RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: "a", dedupKey: "d", sha1: nil, kind: .photo, takenAt: Date(), contentVersion: 0, durationMs: nil,
      isFavorite: false, trashedAt: nil, width: nil, height: nil)
  }
}

/// Holds whoever passes until it's opened, whether or not they're cancelled.
private actor Gate {
  private(set) var entered = 0
  private var isOpen: Bool
  private var held: [CheckedContinuation<Void, Never>] = []
  private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(isOpen: Bool = false) { self.isOpen = isOpen }

  func pass() async {
    entered += 1
    for watcher in watchers where watcher.count <= entered { watcher.continuation.resume() }
    watchers.removeAll { $0.count <= entered }
    if !isOpen { await withCheckedContinuation { held.append($0) } }
  }

  func waitUntilEntered(_ count: Int) async {
    if entered < count { await withCheckedContinuation { watchers.append((count, $0)) } }
  }

  func open() {
    isOpen = true
    for waiter in held { waiter.resume() }
    held = []
  }
}

/// Pages by resume token, one of them held at a gate.
private actor AheadFetcher: RemoteLibraryFetching {
  nonisolated let gate = Gate()
  private let state: Data
  private let pages: [String: Data]
  private let gated: String
  private(set) var requests = 0
  private(set) var running = 0
  private var onPage: (@Sendable (String) async -> Void)?

  func setOnPage(_ action: @escaping @Sendable (String) async -> Void) { onPage = action }

  init(state: Data, pages: [String: Data], gated: String) {
    self.state = state
    self.pages = pages
    self.gated = gated
  }

  func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
    requests += 1
    return try LibraryMessages.decodeLibraryUpdate(state)
  }

  func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate { try await page(resumeToken) }

  func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate {
    try await page(resumeToken)
  }

  private func page(_ token: String) async throws -> RemoteLibraryUpdate {
    requests += 1
    running += 1
    defer { running -= 1 }
    await onPage?(token)
    if token == gated { await gate.pass() }
    return try LibraryMessages.decodeLibraryUpdate(pages[token] ?? SyncResponseBuilder.page())
  }
}

/// A library state request that waits to be released, to hold a sync mid-request.
private actor GatedFetcher: RemoteLibraryFetching {
  private let page: Data
  private let ignoresCancellation: Bool
  private(set) var requests = 0
  private var isReleased = false
  private var released: [CheckedContinuation<Void, Never>] = []
  private var requested: [CheckedContinuation<Void, Never>] = []

  init(page: Data, ignoresCancellation: Bool) {
    self.page = page
    self.ignoresCancellation = ignoresCancellation
  }

  func waitUntilRequested() async {
    guard requests == 0 else { return }
    await withCheckedContinuation { requested.append($0) }
  }

  func release() {
    isReleased = true
    for waiter in released { waiter.resume() }
    released = []
  }

  func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
    requests += 1
    for waiter in requested { waiter.resume() }
    requested = []
    if ignoresCancellation {
      if !isReleased { await withCheckedContinuation { released.append($0) } }
    } else {
      while !isReleased {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    return try LibraryMessages.decodeLibraryUpdate(page)
  }

  func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate {
    try LibraryMessages.decodeLibraryUpdate(page)
  }

  func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate {
    try LibraryMessages.decodeLibraryUpdate(page)
  }
}

private final class NoThumbnails: ThumbnailSource, Sendable {
  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, onUnavailable: @escaping @Sendable () -> Void,
    deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken { .none }
}
