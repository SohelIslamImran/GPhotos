import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Siri and Spotlight")
struct SiriLibraryTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func makeStore() -> LibraryIndexStore {
    LibraryIndexStore(directory: TestTemporaryDirectory.root.appending(path: "Siri-\(UUID().uuidString)"))
  }

  // MARK: Queries

  @Test("Words that say what to show are dropped; what's in the photo is kept")
  func queryTerms() {
    let query = SiriSearchQuery("Show me photos of my dog at the beach", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms == ["dog", "beach"])
    #expect(query.period == nil)
    #expect(!query.videosOnly)
    #expect(!query.favoritesOnly)
  }

  @Test("A month and year narrow to that month")
  func queryMonthAndYear() {
    let query = SiriSearchQuery("videos from July 2024", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms.isEmpty)
    #expect(query.videosOnly)
    #expect(query.period == date(2024, 7, 1)..<date(2024, 8, 1))
  }

  @Test("A year alone is the whole year; favorites are a filter")
  func queryYear() {
    let query = SiriSearchQuery("favorite sunsets 2019", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms == ["sunsets"])
    #expect(query.favoritesOnly)
    #expect(query.period == date(2019, 1, 1)..<date(2020, 1, 1))
  }

  @Test("A month alone is its latest occurrence")
  func queryMonthOnly() {
    let december = SiriSearchQuery("snow in december", now: date(2026, 11, 8), calendar: calendar)
    #expect(december.period == date(2025, 12, 1)..<date(2026, 1, 1))
    let march = SiriSearchQuery("march", now: date(2026, 11, 8), calendar: calendar)
    #expect(march.period == date(2026, 3, 1)..<date(2026, 4, 1))
  }

  @Test("Relative periods: today, yesterday, last month, this year")
  func queryRelative() {
    let now = date(2026, 11, 8).addingTimeInterval(15 * 3600)
    #expect(SiriSearchQuery("today", now: now, calendar: calendar).period == date(2026, 11, 8)..<date(2026, 11, 9))
    #expect(SiriSearchQuery("yesterday", now: now, calendar: calendar).period == date(2026, 11, 7)..<date(2026, 11, 8))
    let lastMonth = SiriSearchQuery("receipts from last month", now: now, calendar: calendar)
    #expect(lastMonth.terms == ["receipts"])
    #expect(lastMonth.period == date(2026, 10, 1)..<date(2026, 11, 1))
    #expect(
      SiriSearchQuery("this year", now: now, calendar: calendar).period == date(2026, 1, 1)..<date(2027, 1, 1))
  }

  @Test("Only filler words leave nothing to search")
  func queryEmpty() {
    #expect(SiriSearchQuery("show me my photos", now: date(2026, 11, 8), calendar: calendar).isEmpty)
    #expect(!SiriSearchQuery("google", now: date(2026, 11, 8), calendar: calendar).isEmpty)
  }

  @Test("Typed search completes structured terms and falls back only for searches with plain words")
  @MainActor
  func typedSearchFallback() async {
    var plainCalls = 0
    var structuredCompletions: [Bool] = []
    func plain() async -> [String] {
      plainCalls += 1
      return ["plain match"]
    }
    let partial = await SearchView.matches(
      for: "2024 bea", named: { false },
      structured: { completing in
        structuredCompletions.append(completing)
        return completing ? ["beach in 2024"] : []
      }, plain: plain)
    #expect(partial == ["beach in 2024"])
    #expect(structuredCompletions == [true])
    #expect(plainCalls == 0)

    for text in ["video game", "favorite mug", "movie ticket"] {
      let matches = await SearchView.matches(for: text, named: { false }, structured: { _ in [] }, plain: plain)
      #expect(matches == ["plain match"])
    }
    for text in ["videos from July 2024", "favorites", "2024"] {
      let matches = await SearchView.matches(for: text, named: { false }, structured: { _ in [] }, plain: plain)
      #expect(matches.isEmpty)
    }
    #expect(plainCalls == 3)
  }

  @Test("Results found by more of the words come first, ties in the order found")
  func ranking() {
    let ranked = SiriLibrary.rankedByMatches([["a", "b", "c"], ["c", "d"], ["c", "b", "b"]])
    #expect(ranked == ["c", "b", "a", "d"])
    #expect(SiriLibrary.rankedByMatches([]).isEmpty)
  }

  // MARK: Records

  @Test("The digest changes with what Spotlight shows and is stable otherwise")
  func digest() {
    let record = SiriItemRecord(
      id: "a", source: .device, date: date(2024, 5, 1), isVideo: false, isFavorite: false, labels: ["dog"])
    #expect(record.digest() == record.digest())
    var favorite = record
    favorite.isFavorite = true
    #expect(favorite.digest() != record.digest())
    var labeled = record
    labeled.labels = ["dog", "beach"]
    #expect(labeled.digest() != record.digest())
    // Fields are delimited: moving text between fields changes the digest.
    let split = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false, labels: ["do", "g"])
    let joined = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false, labels: ["dog"])
    #expect(split.digest() != joined.digest())
    #expect(record.digest(including: ["1"]) != record.digest(including: ["2"]))
  }

  @Test("Records follow the timeline: device items, Google items, and folder files as their Google copy")
  func recordsFromSnapshot() {
    let device = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: true,
      latitude: 51.5, longitude: -0.1)
    let cloud = RemoteItemSummary(
      mediaKey: "M1", dedupKey: "M1", sha1: nil, kind: .video, takenAt: date(2025, 2, 3), contentVersion: 0,
      durationMs: 1_000, isFavorite: false, trashedAt: nil, width: nil, height: nil, fileName: "clip.mov")
    let backedUpFile = RemoteItemSummary(
      mediaKey: "M2", dedupKey: "M2", sha1: nil, kind: .photo, takenAt: date(2025, 3, 4), contentVersion: 0,
      durationMs: nil, isFavorite: false, trashedAt: nil, width: nil, height: nil, fileName: "scan.jpg")
    let file = FolderItemInfo(path: "/f/notes.png", date: date(2025, 4, 5), size: 1, isVideo: false)
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.device(0, cloud: nil), .cloud(0), .folder(1, cloud: 1), .folder(0, cloud: nil)], device: [device],
      cloud: [cloud, backedUpFile], folder: [file, file], cloudLibrary: nil)

    let records = SiriItemRecord.records(
      from: snapshot, facts: ["D1": SiriItemFacts(labels: ["dog"], text: "Hello", people: ["Sam"])],
      googleDetails: ["M1": RemoteSiriDetails(place: "Paris", caption: "Eiffel")])

    #expect(records.map(\.id) == ["D1", "g:M1", "g:M2", file.id])
    #expect(records.map(\.source) == [.device, .google, .google, .folder])
    #expect(records[0].labels == ["dog"])
    #expect(records[0].people == ["Sam"])
    #expect(records[0].isFavorite)
    #expect(records[0].latitude == 51.5)
    #expect(records[1].isVideo)
    #expect(records[1].place == "Paris")
    #expect(records[1].title.hasPrefix("Paris, "))
    #expect(records[3].fileName == "notes.png")
  }

  @Test("Spotlight gets the whole Library while the grid shows a filter")
  func unfilteredSnapshot() {
    let favorite = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: true)
    let other = DeviceItemInfo(
      localIdentifier: "D2", date: date(2025, 1, 3), width: 4, height: 3, isVideo: false, isFavorite: false)
    let device = [favorite, other]
    let filtered = TimelineMerge.merge(device: device, cloud: [], uploadedMediaKeys: [:], filter: .favorites)
    #expect(filtered.count == 1)
    var inputs = UnifiedLibraryModel.MergeInputs()
    inputs.isFiltered = true
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: filtered, device: device, cloud: [], folder: [], cloudLibrary: nil, inputs: inputs)
    let all = snapshot.unfiltered()
    #expect(!all.inputs.isFiltered)
    #expect(Set(SiriItemRecord.records(from: all, facts: [:], googleDetails: [:]).map(\.id)) == ["D1", "D2"])
    // Unfiltered entries are used as they are.
    let plain = UnifiedLibraryModel.IndexSnapshot(entries: filtered, device: device, cloud: [], folder: [], cloudLibrary: nil)
    #expect(plain.unfiltered().entries == filtered)
  }

  @Test("A pass re-indexes changed items and removes those that left")
  func plan() {
    let plan = SiriSpotlightIndexer.Plan(
      current: [("a", 1), ("b", 2), ("c", 3), ("a", 1)], stored: ["a": 1, "b": 9, "gone": 4])
    #expect(plan.changed == ["b", "c"])
    #expect(plan.removed == ["gone"])
  }

  @Test("The change key follows analysis and people, not only metadata")
  func changeKey() {
    let base = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false)
    let key = SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: ["Sam"])
    #expect(key == SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: ["Sam"]))
    #expect(key != SiriSpotlightIndexer.changeKey(base, analyzedAt: 11, people: ["Sam"]))
    #expect(key != SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: []))
  }

  // MARK: Store

  @Test("Records round-trip through the index database and are found by date")
  func storeRoundTrip() async throws {
    let store = makeStore()
    let older = SiriItemRecord(
      id: "a", source: .device, date: date(2024, 1, 1), isVideo: false, isFavorite: true, latitude: 1, longitude: 2,
      labels: ["dog", "beach"], text: "Hi", people: ["Sam", "Alex"])
    let newer = SiriItemRecord(
      id: "g:b", source: .google, fileName: "b.mov", date: date(2025, 1, 1), isVideo: true, isFavorite: false,
      place: "Rome", caption: "Trip")
    try await store.saveSiri([(older, 1), (newer, 2)])

    #expect(try await store.siriRecords(ids: ["g:b", "missing", "a"]) == [newer, older])
    #expect(try await store.siriDigests() == ["a": 1, "g:b": 2])
    #expect(try await store.recentSiriRecords(limit: 10).map(\.id) == ["g:b", "a"])
    #expect(try await store.recentSiriRecords(limit: 10, favoritesOnly: true).map(\.id) == ["a"])
    #expect(try await store.siriIDs(takenIn: date(2023, 6, 1)..<date(2024, 6, 1), limit: 10) == ["a"])
    #expect(try await store.allSiriIDs() == ["g:b", "a"])

    try await store.deleteSiri(["a"])
    #expect(try await store.siriRecordCount() == 1)
  }

  @Test("Periods, videos and favorites filter before the limit, so older matches aren't lost")
  func storeFilteredIDs() async throws {
    let store = makeStore()
    // The newest items are photos; the one video is the oldest.
    var records: [(SiriItemRecord, Int64)] = (1...20).map { day in
      (SiriItemRecord(id: "p\(day)", source: .device, date: date(2024, 3, day), isVideo: false, isFavorite: day == 1), 0)
    }
    records.append((SiriItemRecord(id: "v", source: .device, date: date(2023, 1, 1), isVideo: true, isFavorite: true), 0))
    try await store.saveSiri(records)

    #expect(try await store.siriIDs(period: nil, videosOnly: true, limit: 1) == ["v"])
    #expect(try await store.siriIDs(period: nil, favoritesOnly: true, limit: 5) == ["p1", "v"])
    #expect(try await store.siriIDs(period: date(2024, 3, 1)..<date(2024, 3, 3), limit: 10) == ["p2", "p1"])
    #expect(try await store.siriIDs(period: date(2024, 1, 1)..<date(2025, 1, 1), videosOnly: true, limit: 10).isEmpty)
  }

  @Test("Facts come from the analysis: confident labels, text and named people")
  func facts() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("sea_ocean", 0.9), ("blurry", 0.2)]
    analysis.text = "Welcome to Brighton"
    try await store.save(ItemMetadata(id: "a", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "b", date: Date(), words: []), analysis: ItemAnalysis())

    let facts = try await store.siriFacts(for: ["a", "b"])
    #expect(facts["a"]?.labels == ["sea ocean"])
    #expect(facts["a"]?.text == "Welcome to Brighton")
    #expect(facts["b"] == nil)
    #expect(try await store.analyzedStamps().keys.sorted() == ["a", "b"])
  }

  @Test("Spotlight fingerprint skips unchanged passes and wakes on device edits, analysis and errors")
  func spotlightFingerprint() async throws {
    let store = makeStore()
    let indexCalls = LockedBox<Int>(0)
    let shouldFail = LockedBox<Bool>(false)
    let indexedPhotos = LockedBox<[PhotoEntity]>([])
    let indexedPeopleCalls = LockedBox<Int>(0)
    let backend = SiriSpotlightIndexer.Backend(
      indexPhotos: { entities in
        indexCalls.withLock { $0 += 1 }
        if shouldFail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
        indexedPhotos.withLock { $0 = entities }
      },
      deletePhotos: { _ in },
      indexPeople: { _ in indexedPeopleCalls.withLock { $0 += 1 } },
      deleteAllPeople: {}
    )
    let indexer = SiriSpotlightIndexer(store: store, backend: backend)

    let device = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: false)
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.device(0, cloud: nil)], device: [device], cloud: [], folder: [], cloudLibrary: nil)
    let context = SiriSpotlightIndexer.SyncContext(
      libraryReloadToken: 1, deviceReloadToken: 1, deviceBadgeToken: 1, cloudRevision: 0)

    // Pass 1 fails: must NOT record fingerprint so pass 2 retries.
    shouldFail.withLock { $0 = true }
    #expect(await indexer.sync(snapshot, context: context) == true)
    #expect(indexCalls.withLock { $0 } == 1)

    shouldFail.withLock { $0 = false }
    #expect(await indexer.sync(snapshot, context: context) == true)
    #expect(indexCalls.withLock { $0 } == 2)
    #expect(indexedPhotos.withLock { $0.first?.isFavorite } == false)

    // Unchanged pass skips completely without re-planning.
    #expect(await indexer.sync(snapshot, context: context) == false)
    #expect(indexCalls.withLock { $0 } == 2)

    // Device-side favorite edit bumps deviceBadgeToken and updates Spotlight.
    let favorited = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: true)
    let editedSnapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.device(0, cloud: nil)], device: [favorited], cloud: [], folder: [], cloudLibrary: nil)
    let editedContext = SiriSpotlightIndexer.SyncContext(
      libraryReloadToken: 1, deviceReloadToken: 1, deviceBadgeToken: 2, cloudRevision: 0)
    #expect(await indexer.sync(editedSnapshot, context: editedContext) == true)
    #expect(indexCalls.withLock { $0 } == 3)
    #expect(indexedPhotos.withLock { $0.first?.isFavorite } == true)

    // Same edited context skips again.
    #expect(await indexer.sync(editedSnapshot, context: editedContext) == false)

    // Analysis write wakes Spotlight even with the same library tokens.
    var dog = ItemAnalysis()
    dog.labels = [("dog", 0.95)]
    try await store.save(ItemMetadata(id: "D1", date: date(2025, 1, 2), words: []), analysis: dog)
    #expect(await indexer.sync(editedSnapshot, context: editedContext) == true)
    #expect(indexCalls.withLock { $0 } == 4)
    #expect(indexedPhotos.withLock { $0.first?.labels } == ["dog"])
    #expect(indexedPeopleCalls.withLock { $0 } == 0)
  }

  @Test("Siri thumbnail fetch bounds timeouts and honors cancellation instead of hanging")
  func thumbnailFetchTimeoutAndCancellation() async {
    final class HangingSource: ThumbnailSource, @unchecked Sendable {
      let cancelled = LockedBox<Bool>(false)

      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        ImageRequestToken { [cancelled] in cancelled.withLock { $0 = true } }
      }
    }

    let source = HangingSource()
    let timedOut = await SiriLibrary.image(from: source, id: "g:0:M1", side: 240, timeout: .milliseconds(50))
    #expect(timedOut == nil)
    #expect(source.cancelled.withLock { $0 } == true)

    let cancelSource = HangingSource()
    let task = Task {
      await SiriLibrary.image(from: cancelSource, id: "g:0:M2", side: 240, timeout: .seconds(30))
    }
    try? await Task.sleep(for: .milliseconds(30))
    task.cancel()
    let cancelledResult = await task.value
    #expect(cancelledResult == nil)
    #expect(cancelSource.cancelled.withLock { $0 } == true)

    final class UnavailableSource: ThumbnailSource, @unchecked Sendable {
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        onUnavailable()
        return .none
      }
    }
    let started = ContinuousClock.now
    let unavailable = await SiriLibrary.image(from: UnavailableSource(), id: "g:0:M3", side: 240, timeout: .seconds(30))
    #expect(unavailable == nil)
    #expect(started.duration(to: .now) < .seconds(2))
  }

  @MainActor
  @Test("Locked Google Photos items are excluded from Siri entity queries, export and thumbnails")
  func lockedItemsExcludedFromSiri() async throws {
    let dir = TestTemporaryDirectory.root.appending(path: "SiriLocked-\(UUID().uuidString)")
    let remoteStore = RemoteLibraryStore(accountEmail: "locked@example.com", directory: dir)
    let lockedItem = RemoteMediaItem(
      mediaKey: "LOCKED1", dedupKey: "D1", sha1: nil, fileName: "secret.jpg", caption: nil, kind: .photo,
      sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: date(2025, 5, 1),
      timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
      isFavorite: false, isLocked: true, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
      latitude: nil, longitude: nil, locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil,
      shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    let visibleItem = RemoteMediaItem(
      mediaKey: "PUBLIC1", dedupKey: "D2", sha1: nil, fileName: "beach.jpg", caption: nil, kind: .photo,
      sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: date(2025, 5, 2),
      timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
      isFavorite: false, isLocked: false, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
      latitude: nil, longitude: nil, locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil,
      shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "tok", resumeToken: "", items: [lockedItem, visibleItem], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "tok")

    struct StubFetcher: RemoteLibraryFetching {
      private static var empty: RemoteLibraryUpdate {
        RemoteLibraryUpdate(
          syncToken: "", resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false, albums: [],
          deletedAlbumKeys: [])
      }
      func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
    }
    final class EmptyThumbSource: ThumbnailSource, @unchecked Sendable {
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken { .none }
    }
    let cloud = CloudLibrary(
      accountEmail: "locked@example.com", store: remoteStore, fetcher: StubFetcher(), thumbnails: EmptyThumbSource(),
      actionClient: nil)
    let previousCloud = SiriLibrary.shared.cloud
    SiriLibrary.shared.cloud = cloud
    defer { SiriLibrary.shared.cloud = previousCloud }

    let records = [
      SiriItemRecord(id: "g:LOCKED1", source: .google, date: date(2025, 5, 1), isVideo: false, isFavorite: false),
      SiriItemRecord(id: "g:PUBLIC1", source: .google, date: date(2025, 5, 2), isVideo: false, isFavorite: false),
      SiriItemRecord(id: "D_LOCAL", source: .device, date: date(2025, 5, 3), isVideo: false, isFavorite: false),
    ]
    let visible = await SiriLibrary.shared.excludingLocked(records)
    #expect(visible.map(\.id) == ["g:PUBLIC1", "D_LOCAL"])
    #expect(await SiriLibrary.shared.thumbnailData(id: "g:LOCKED1") == nil)
    var threw = false
    do {
      _ = try await SiriLibrary.shared.exportFile(id: "g:LOCKED1")
    } catch {
      threw = true
    }
    #expect(threw)

    // Batched lookup excludes locked and missing keys.
    let visibleKeys = try await remoteStore.visibleMediaKeys(in: ["LOCKED1", "PUBLIC1", "MISSING"])
    #expect(visibleKeys == ["PUBLIC1"])

    // Fails closed when browsedCloud() is nil (e.g. locked keychain or signed out).
    let previousLoadAccounts = SiriLibrary.shared.loadAccounts
    SiriLibrary.shared.loadAccounts = nil
    SiriLibrary.shared.cloud = nil
    defer { SiriLibrary.shared.loadAccounts = previousLoadAccounts }
    let failClosed = await SiriLibrary.shared.excludingLocked(records)
    #expect(failClosed.map(\.id) == ["D_LOCAL"])
    let failClosedIDs = await SiriLibrary.shared.excludingLockedIDs(["g:PUBLIC1", "g:LOCKED1", "D_LOCAL"])
    #expect(failClosedIDs == ["D_LOCAL"])

    // Fails closed when the cloud library has been retired.
    SiriLibrary.shared.cloud = cloud
    await cloud.retire()
    #expect(await SiriLibrary.shared.excludingLocked(records).map(\.id) == ["D_LOCAL"])
    #expect(await SiriLibrary.shared.thumbnailData(id: "g:PUBLIC1") == nil)
  }

  @MainActor
  @Test("Spotlight details cache keys by snapshot revision, uses single-scan siriDetails, and prunes on account change")
  func spotlightDetailsCacheAndAccountChange() async throws {
    let dir = TestTemporaryDirectory.root.appending(path: "SiriDetails-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: dir.appending(path: "index"))
    let remoteStore = RemoteLibraryStore(accountEmail: "siri@example.com", directory: dir.appending(path: "remote"))

    func makeItem(key: String, place: String?, caption: String?, locked: Bool = false) -> RemoteMediaItem {
      RemoteMediaItem(
        mediaKey: key, dedupKey: key, sha1: nil, fileName: "\(key).jpg", caption: caption, kind: .photo,
        sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: date(2025, 6, 1),
        timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
        isFavorite: false, isLocked: locked, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
        latitude: nil, longitude: nil, locationName: place, cameraMake: nil, cameraModel: nil, aperture: nil,
        shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    }

    let item1 = makeItem(key: "M1", place: "Rome", caption: "Colosseum")
    let locked = makeItem(key: "LOCKED", place: "Secret", caption: "Hidden", locked: true)
    let plain = makeItem(key: "PLAIN", place: nil, caption: nil)
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t1", resumeToken: "", items: [item1, locked, plain], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "t1")

    // Single-scan siriDetails returns only non-locked items with place or caption.
    let singleScan = try await remoteStore.siriDetails()
    #expect(singleScan == ["M1": RemoteSiriDetails(place: "Rome", caption: "Colosseum")])

    struct StubFetcher: RemoteLibraryFetching {
      private static var empty: RemoteLibraryUpdate {
        RemoteLibraryUpdate(
          syncToken: "", resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false, albums: [],
          deletedAlbumKeys: [])
      }
      func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
    }
    final class EmptyThumbSource: ThumbnailSource, @unchecked Sendable {
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken { .none }
    }
    let cloud = CloudLibrary(
      accountEmail: "siri@example.com", store: remoteStore, fetcher: StubFetcher(), thumbnails: EmptyThumbSource(),
      actionClient: nil)

    let indexedByID = LockedBox<[String: PhotoEntity]>([:])
    let accountCallbackEmail = LockedBox<String?>(nil)
    let callbackFired = LockedBox<Bool>(false)
    let backend = SiriSpotlightIndexer.Backend(
      indexPhotos: { entities in
        indexedByID.withLock { dict in
          for entity in entities { dict[entity.id] = entity }
        }
      },
      deletePhotos: { _ in },
      indexPeople: { _ in },
      deleteAllPeople: {})
    let indexer = SiriSpotlightIndexer(
      store: store, backend: backend,
      onAccountChanged: { email in
        accountCallbackEmail.withLock { $0 = email }
        callbackFired.withLock { $0 = true }
      })

    let summary1 = try #require(try await remoteStore.summary(mediaKey: "M1"))
    let snapRev1 = UnifiedLibraryModel.IndexSnapshot(
      entries: [.cloud(0)], device: [], cloud: [summary1], folder: [], cloudLibrary: cloud)
    // Pass 1 uses snapshot revision 1 (even though cloud.revision is 0).
    let ctx1 = SiriSpotlightIndexer.SyncContext(
      libraryReloadToken: 1, deviceReloadToken: 0, deviceBadgeToken: 0, cloudRevision: 1)
    #expect(await indexer.sync(snapRev1, context: ctx1) == true)
    #expect(indexedByID.withLock { $0["g:M1"]?.place } == "Rome")

    // Now a new item M2 arrives in the mirror and snapshot revision advances to 2 while cloud.revision stays 0.
    // Because cachedDetails is keyed by context.cloudRevision (1 != 2), pass 2 re-reads M2's place and caption.
    let item2 = makeItem(key: "M2", place: "Tokyo", caption: "Shibuya")
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t2", resumeToken: "", items: [item2], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "t2")
    let summary2 = try #require(try await remoteStore.summary(mediaKey: "M2"))
    let snapRev2 = UnifiedLibraryModel.IndexSnapshot(
      entries: [.cloud(0), .cloud(1)], device: [], cloud: [summary1, summary2], folder: [], cloudLibrary: cloud)
    let ctx2 = SiriSpotlightIndexer.SyncContext(
      libraryReloadToken: 2, deviceReloadToken: 0, deviceBadgeToken: 0, cloudRevision: 2)
    #expect(await indexer.sync(snapRev2, context: ctx2) == true)
    #expect(indexedByID.withLock { $0["g:M2"]?.place } == "Tokyo")
    #expect(indexedByID.withLock { $0["g:M2"]?.caption } == "Shibuya")

    // Account change prunes cloud entries from LibraryIndexStore and fires callback.
    try await store.save(ItemMetadata(id: "g:M1", date: date(2025, 6, 1), words: ["Rome"]), analysis: nil)
    try await store.save(ItemMetadata(id: "DEV1", date: date(2025, 6, 1), words: ["Home"]), analysis: nil)
    let defaultsKey = "SiriIndexedAccount"
    let previousAccount = UserDefaults.standard.string(forKey: defaultsKey)
    UserDefaults.standard.set("siri@example.com", forKey: defaultsKey)
    defer {
      if let previousAccount {
        UserDefaults.standard.set(previousAccount, forKey: defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
      }
    }
    await indexer.browsedAccountChanged(to: nil)
    #expect(callbackFired.withLock { $0 } == true)
    #expect(accountCallbackEmail.withLock { $0 } == nil)
    let remaining = try await store.analyzedIDs()
    #expect(!remaining.contains("g:M1"))
    #expect(remaining.contains("DEV1"))
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
