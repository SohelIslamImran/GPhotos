import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Widgets")
struct WidgetTests {
  @Test("Locked photos leave the widgets on the calling thread")
  func removesLockedPhotos() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "widgets-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let locked = WidgetPhoto(itemID: "g:locked", file: "locked.jpg", date: Date(timeIntervalSince1970: 1))
    let kept = WidgetPhoto(itemID: "g:kept", file: "kept.jpg", date: Date(timeIntervalSince1970: 2))
    let both = WidgetPhotoSet(id: "1", kind: .featured, title: "", subtitle: "", photos: [locked, kept])
    let only = WidgetPhotoSet(id: "2", kind: .person, title: "", subtitle: "", photos: [locked])
    try WidgetStore.write(WidgetPhotoSnapshot(memories: [both], people: [only]), in: directory)
    for file in ["locked.jpg", "kept.jpg"] { try Data([1]).write(to: directory.appending(path: file)) }
    WidgetStore.remove(["g:locked"], in: directory)
    let left = try #require(WidgetStore.photos(in: directory))
    #expect(left.memories.map(\.photos) == [[kept]])
    #expect(left.people.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "locked.jpg").path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "kept.jpg").path))
  }

  @Test("Widget links open photos, people and the backup, and nothing else")
  func links() {
    for link in [WidgetLink.photo("ABC/L0/001"), .photo("g:AF1Qip_x"), .person(42), .backup] {
      #expect(WidgetLink(url: link.url) == link)
    }
    #expect(WidgetLink(url: URL(string: "gphotosapp://activity?kind=failed")!) == nil)
    #expect(WidgetLink(url: URL(string: "gphotosapp://photo")!) == nil)
    #expect(WidgetLink(url: URL(string: "https://photo?id=1")!) == nil)
  }

  @Test("Photos change on the hour, the same one at the same time everywhere")
  func rotation() {
    let hour = Date(timeIntervalSince1970: 3_600 * 1_000)
    #expect(WidgetRotation.index(count: 3, at: hour) == 1_000 % 3)
    #expect(WidgetRotation.index(count: 3, at: hour.addingTimeInterval(3_599)) == 1_000 % 3)
    #expect(WidgetRotation.index(count: 3, at: hour.addingTimeInterval(3_600)) == 1_001 % 3)
    #expect(WidgetRotation.index(count: 0, at: hour) == 0)
    let hours = WidgetRotation.hours(from: hour.addingTimeInterval(600), count: 3)
    #expect(hours.count == 3)
    #expect(hours[0] == hour.addingTimeInterval(600))
    #expect(hours[1] == hour.addingTimeInterval(3_600))
  }

  @Test("A filled photo keeps its focus in view and never leaves a gap")
  func fill() {
    let container = CGSize(width: 364, height: 170)
    // A portrait photo with a face near the top.
    let frame = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 0.2), keepsFocusHigh: true)
    #expect(frame.width == 364 && abs(frame.height - 485.33) < 0.01)
    let faceY = frame.minY + 0.2 * frame.height
    #expect(faceY > 0 && faceY < container.height)
    #expect(frame.minY <= 0 && frame.maxY >= container.height)
    // Without a focus the middle shows.
    let centred = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 0.5), keepsFocusHigh: false)
    #expect(abs(centred.midY - container.height / 2) < 0.01)
    // A focus at the very edge is clamped rather than pulling the photo off the widget.
    let edge = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 1), keepsFocusHigh: false)
    #expect(abs(edge.maxY - container.height) < 0.01)
  }

  @Test("The widget folder keeps what the app wrote and drops images no longer listed")
  func store() throws {
    let directory = TestTemporaryDirectory.root.appending(path: "Widgets-\(UUID().uuidString)")
    let photo = WidgetPhoto(itemID: "a", file: "a.jpg", date: Date(timeIntervalSince1970: 1_000), focus: CGPoint(x: 0.3, y: 0.4))
    let snapshot = WidgetPhotoSnapshot(
      generatedAt: Date(timeIntervalSince1970: 2_000),
      memories: [WidgetPhotoSet(id: "m", kind: .onThisDay, title: "On This Day", subtitle: "", photos: [photo])])
    try WidgetStore.write(snapshot, in: directory)
    #expect(WidgetStore.photos(in: directory) == snapshot)
    let backup = WidgetBackupSnapshot(
      title: "Up to Date", subtitle: "", symbol: "checkmark", tone: "green", isSignedIn: true, isHealthy: true,
      backedUpCount: 12)
    try WidgetStore.write(backup, in: directory)
    #expect(WidgetStore.backup(in: directory)?.sameContent(as: backup) == true)
    for name in ["a.jpg", "old.jpg"] { try Data([1]).write(to: directory.appendingPathComponent(name)) }
    WidgetStore.prune(keeping: ["a.jpg"], in: directory)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.jpg").path))
    #expect(WidgetPublisher.fileName(for: "ABC/L0/001") == WidgetPublisher.fileName(for: "ABC/L0/001"))
    #expect(!WidgetPublisher.fileName(for: "ABC/L0/001").contains("/"))
  }

  @Test("Widget photos come from the best non-utility items, framed on the person's face")
  func indexQueries() async throws {
    let store = LibraryIndexStore(
      directory: TestTemporaryDirectory.root.appending(path: "WidgetIndex-\(UUID().uuidString)"))
    for (id, score, utility) in [("best", Float(0.9), false), ("receipt", 0.95, true), ("okay", 0.4, false)] {
      var analysis = ItemAnalysis()
      analysis.aesthetics = score
      analysis.isUtility = utility
      analysis.faces = [DetectedFace(rect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.3), featurePrint: Data([1]))]
      try await store.save(ItemMetadata(id: id, date: Date(timeIntervalSince1970: 5_000), words: []), analysis: analysis)
    }
    #expect(try await store.featuredIDs(limit: 10) == ["best", "okay"])
    let scores = try await store.photoScores(ids: ["best", "receipt", "missing"])
    #expect(scores["receipt"]?.isUtility == true)
    #expect(scores["best"]?.aesthetics == 0.9)
    #expect(scores["best"]?.date == Date(timeIntervalSince1970: 5_000))
    #expect(scores["missing"] == nil)

    let faces = try await store.faces()
    try await store.assignFaces(Dictionary(uniqueKeysWithValues: faces.map { ($0.id, Int64(7)) }))
    let centers = try await store.faceCenters(person: 7, ids: ["best", "okay"])
    #expect(centers.count == 2)
    #expect(abs((centers["best"]?.x ?? 0) - 0.3) < 0.0001)
    #expect(abs((centers["best"]?.y ?? 0) - 0.22) < 0.0001)
    #expect(try await store.faceCenters(person: 8, ids: ["best"]).isEmpty)
  }

  @Test("Widget photo snapshot equality ignores timestamps")
  func photoSnapshotEquality() {
    let photo = WidgetPhoto(itemID: "a", file: "a.jpg", date: Date(timeIntervalSince1970: 1_000))
    let set = WidgetPhotoSet(id: "m", kind: .featured, title: "Featured", subtitle: "", photos: [photo])
    let first = WidgetPhotoSnapshot(generatedAt: Date(timeIntervalSince1970: 100), memories: [set], people: [])
    let second = WidgetPhotoSnapshot(generatedAt: Date(timeIntervalSince1970: 200), memories: [set], people: [])
    #expect(first.sameContent(as: second))
    let changed = WidgetPhotoSnapshot(generatedAt: Date(timeIntervalSince1970: 200), memories: [], people: [set])
    #expect(!first.sameContent(as: changed))
  }

  @Test("Widget image fetch cancels cleanly and stops at timeout without stalling")
  func imageWaitTimeoutAndCancel() async {
    final class SilentSource: ThumbnailSource, @unchecked Sendable {
      let lock = NSLock()
      private var _cancelled = false
      var cancelled: Bool { lock.withLock { _cancelled } }

      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        ImageRequestToken { [self] in self.lock.withLock { self._cancelled = true } }
      }
    }

    let source = SilentSource()
    let result = await WidgetPublisher.image(id: "g:0:M1", source: source, timeout: .milliseconds(40))
    #expect(result == nil)
    #expect(source.cancelled)

    let cancelSource = SilentSource()
    let task = Task { await WidgetPublisher.image(id: "g:0:M2", source: cancelSource, timeout: .seconds(30)) }
    try? await Task.sleep(for: .milliseconds(30))
    task.cancel()
    #expect(await task.value == nil)
    #expect(cancelSource.cancelled)

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
    #expect(await WidgetPublisher.image(id: "g:0:M3", source: UnavailableSource(), timeout: .seconds(30)) == nil)
    #expect(started.duration(to: .now) < .seconds(2))
  }

  @MainActor
  @Test("WidgetPublisher skips reload when picked photos are unchanged and reloads only changed kinds")
  func skipsUnchangedReloadsAndRespectsNetworkPolicy() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetPub-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: directory.appending(path: "index"))
    let remoteDir = directory.appending(path: "remote")
    let remoteStore = RemoteLibraryStore(accountEmail: "w@example.com", directory: remoteDir)

    let item = RemoteMediaItem(
      mediaKey: "M1", dedupKey: "D1", sha1: nil, fileName: "sunset.jpg", caption: nil, kind: .photo,
      sizeBytes: 100, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: Date(timeIntervalSince1970: 5_000),
      timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
      isFavorite: false, isLocked: false, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
      latitude: nil, longitude: nil, locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil,
      shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t", resumeToken: "", items: [item], deletedMediaKeys: [], triggersNextSync: false, albums: [],
        deletedAlbumKeys: []),
      syncToken: "t")

    var analysis = ItemAnalysis()
    analysis.aesthetics = 0.9
    analysis.isUtility = false
    try await store.save(ItemMetadata(id: "g:M1", date: Date(timeIntervalSince1970: 5_000), words: []), analysis: analysis)

    let context = try #require(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let sampleImage = try #require(context.makeImage())

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
    final class CountingThumbSource: ThumbnailSource, @unchecked Sendable {
      let image: CGImage
      let lock = NSLock()
      private var _requests = 0
      var requests: Int { lock.withLock { _requests } }
      init(_ image: CGImage) { self.image = image }
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        lock.withLock { _requests += 1 }
        deliver(image, true)
        return .none
      }
    }

    let thumbSource = CountingThumbSource(sampleImage)
    let cloud = CloudLibrary(
      accountEmail: "w@example.com", store: remoteStore, fetcher: StubFetcher(), thumbnails: thumbSource, actionClient: nil)
    let library = UnifiedLibraryModel()
    library.setCloudLibrary(cloud)
    await library.start(records: [])
    let deadline = ContinuousClock.now + .seconds(5)
    while library.position(ofIndexID: "g:M1") == nil && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(library.position(ofIndexID: "g:M1") != nil)

    // 1. Disallowed network: never asks the remote thumbnail source for pixels.
    var reloads: [String] = []
    let offlinePublisher = WidgetPublisher(
      directory: directory.appending(path: "offline"),
      reloadTimeline: { reloads.append($0) },
      allowsNetwork: { false })
    await offlinePublisher.publishPhotos(from: library, store: store)
    #expect(thumbSource.requests == 0)
    #expect(reloads.isEmpty)

    // 2. Allowed network: publishes Featured Photos and reloads only memoriesKind (no people).
    let onlineDir = directory.appending(path: "online")
    let onlinePublisher = WidgetPublisher(
      directory: onlineDir,
      reloadTimeline: { reloads.append($0) },
      allowsNetwork: { true })
    await onlinePublisher.publishPhotos(from: library, store: store)
    #expect(thumbSource.requests == 1)
    #expect(reloads == [WidgetStore.memoriesKind])
    let firstGenerated = try #require(WidgetStore.photos(in: onlineDir)).generatedAt

    // 3. Running again with unchanged picks skips write and reload completely.
    reloads.removeAll()
    await onlinePublisher.publishPhotos(from: library, store: store)
    #expect(reloads.isEmpty)
    #expect(WidgetStore.photos(in: onlineDir)?.generatedAt == firstGenerated)
  }

  @MainActor
  @Test("Unindexed memory photos keep their real capture date and deduplicate across refreshes")
  func unindexedMemoryPhotoDateStable() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetMem-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: directory.appending(path: "index"))
    let remoteStore = RemoteLibraryStore(accountEmail: "mem@example.com", directory: directory.appending(path: "remote"))

    // Two years ago today so MemoryFinder.onThisDay picks it even without indexing in LibraryIndexStore.
    let twoYearsAgo = try #require(Calendar.current.date(byAdding: .year, value: -2, to: Date()))
    let item = RemoteMediaItem(
      mediaKey: "MEM1", dedupKey: "DM1", sha1: nil, fileName: "anniversary.jpg", caption: nil, kind: .photo,
      sizeBytes: 100, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: twoYearsAgo,
      timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
      isFavorite: false, isLocked: false, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
      latitude: nil, longitude: nil, locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil,
      shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t", resumeToken: "", items: [item], deletedMediaKeys: [], triggersNextSync: false, albums: [],
        deletedAlbumKeys: []),
      syncToken: "t")

    let context = try #require(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let sampleImage = try #require(context.makeImage())
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
    final class StaticThumbSource: ThumbnailSource, @unchecked Sendable {
      let image: CGImage
      init(_ image: CGImage) { self.image = image }
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        deliver(image, true)
        return .none
      }
    }

    let cloud = CloudLibrary(
      accountEmail: "mem@example.com", store: remoteStore, fetcher: StubFetcher(),
      thumbnails: StaticThumbSource(sampleImage), actionClient: nil)
    let library = UnifiedLibraryModel()
    library.setCloudLibrary(cloud)
    await library.start(records: [])
    let deadline = ContinuousClock.now + .seconds(5)
    while library.position(ofIndexID: "g:MEM1") == nil && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(library.position(ofIndexID: "g:MEM1") != nil)

    var reloads: [String] = []
    let widgetDir = directory.appending(path: "widgets")
    let publisher = WidgetPublisher(
      directory: widgetDir, reloadTimeline: { reloads.append($0) }, allowsNetwork: { true })
    await publisher.publishPhotos(from: library, store: store)

    let firstSnapshot = try #require(WidgetStore.photos(in: widgetDir))
    let pickedPhoto = try #require(firstSnapshot.memories.first?.photos.first)
    #expect(pickedPhoto.itemID == "g:MEM1")
    #expect(abs(pickedPhoto.date.timeIntervalSince(twoYearsAgo)) < 1)
    #expect(reloads == [WidgetStore.memoriesKind])

    // Second run with the item still unindexed must not stamp Date() or trigger another write/reload.
    reloads.removeAll()
    await publisher.publishPhotos(from: library, store: store)
    #expect(reloads.isEmpty)
    #expect(WidgetStore.photos(in: widgetDir)?.generatedAt == firstSnapshot.generatedAt)
  }

  @MainActor
  @Test("WidgetPublisher purges locked items and cloud items on sign-out from App Group storage")
  func purgeLockedAndSignedOutWidgets() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetPurge-\(UUID().uuidString)")
    let cloudFile = WidgetPublisher.fileName(for: "g:M_LOCK")
    let deviceFile = WidgetPublisher.fileName(for: "DEV_1")
    let keepCloudFile = WidgetPublisher.fileName(for: "g:M_KEEP")

    let initial = WidgetPhotoSnapshot(
      generatedAt: Date(),
      accountEmail: "user@example.com",
      memories: [
        WidgetPhotoSet(
          id: "featured", kind: .featured, title: "Featured", subtitle: "",
          photos: [
            WidgetPhoto(itemID: "g:M_LOCK", file: cloudFile, date: Date(timeIntervalSince1970: 1_000)),
            WidgetPhoto(itemID: "g:M_KEEP", file: keepCloudFile, date: Date(timeIntervalSince1970: 2_000)),
            WidgetPhoto(itemID: "DEV_1", file: deviceFile, date: Date(timeIntervalSince1970: 3_000)),
          ])
      ],
      people: [
        WidgetPhotoSet(
          id: "person-1", kind: .person, title: "Ada", subtitle: "1 photo",
          photos: [WidgetPhoto(itemID: "g:M_LOCK", file: cloudFile, date: Date(timeIntervalSince1970: 1_000))],
          personID: 1)
      ])
    try WidgetStore.write(initial, in: directory)
    for name in [cloudFile, keepCloudFile, deviceFile] {
      try Data([0xFF, 0xD8]).write(to: directory.appendingPathComponent(name))
    }

    var reloads: [String] = []
    let publisher = WidgetPublisher(directory: directory, reloadTimeline: { reloads.append($0) }, allowsNetwork: { false })

    // 1. Purging one newly-locked media key removes it from both memories and people, deletes its JPEG, and reloads.
    await publisher.purge(mediaKeys: ["M_LOCK"])
    let afterLock = try #require(WidgetStore.photos(in: directory))
    #expect(afterLock.memories.first?.photos.map(\.itemID) == ["g:M_KEEP", "DEV_1"])
    #expect(afterLock.people.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(cloudFile).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(keepCloudFile).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(deviceFile).path))
    #expect(reloads == [WidgetStore.memoriesKind, WidgetStore.peopleKind])

    // 2. Sign-out purges all remaining cloud items and JPEGs while preserving device items.
    reloads.removeAll()
    await publisher.purgeCloudItems()
    let afterSignOut = try #require(WidgetStore.photos(in: directory))
    #expect(afterSignOut.memories.first?.photos.map(\.itemID) == ["DEV_1"])
    #expect(afterSignOut.accountEmail == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(keepCloudFile).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(deviceFile).path))
    #expect(reloads == [WidgetStore.memoriesKind])
  }

  @MainActor
  @Test("Concurrent widget purges never restore each other's photos or person metadata")
  func overlappingWidgetPurges() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetConcurrent-\(UUID().uuidString)")
    let photos = ["g:A", "g:B", "local"].map {
      WidgetPhoto(itemID: $0, file: WidgetPublisher.fileName(for: $0), date: .distantPast)
    }
    let initial = WidgetPhotoSnapshot(
      accountEmail: "purges@example.com",
      memories: [.init(id: "day", kind: .onThisDay, title: "", subtitle: "", photos: photos)],
      people: [.init(id: "person", kind: .person, title: "Ada", subtitle: "", photos: Array(photos.prefix(2)), personID: 1)])
    try WidgetStore.write(initial, in: directory)
    for photo in photos { try Data([1]).write(to: directory.appendingPathComponent(photo.file)) }
    let publisher = WidgetPublisher(directory: directory, reloadTimeline: { _ in })
    async let a: Void = publisher.purge(mediaKeys: ["A"])
    async let b: Void = publisher.purge(mediaKeys: ["B"])
    _ = await (a, b)

    let snapshot = try #require(WidgetStore.photos(in: directory))
    #expect(snapshot.memories.first?.photos.map(\.itemID) == ["local"])
    #expect(snapshot.people.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") } == [photos[2].file])
  }

  @Test("A lock after the visibility read prevents staged widget JPEGs and metadata from being published")
  func widgetCommitRechecksLocks() throws {
    let email = "widget-lock-\(UUID().uuidString)@example.com"
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetCommit-\(UUID().uuidString)")
    let photos = ["g:secret", "g:visible"].map {
      WidgetPhoto(itemID: $0, file: WidgetPublisher.fileName(for: $0), date: .distantPast)
    }
    let snapshot = WidgetPhotoSnapshot(
      accountEmail: email, memories: [.init(id: "day", kind: .onThisDay, title: "", subtitle: "", photos: photos)],
      people: [.init(id: "person", kind: .person, title: "Ada", subtitle: "", photos: [photos[0]], personID: 1)])
    let visible: Set<String> = ["secret", "visible"]
    defer { LockedItems.forget(accountEmail: email) }
    let commit = WidgetPublisher.commitPhotos(
      snapshot, images: [photos[0].file: Data([1]), photos[1].file: Data([2])], visible: visible, previous: nil,
      directory: directory
    ) { photo in
      // Right after the first was written.
      if photo == photos[1] { LockedItems.insert(["secret"], accountEmail: email) }
    }
    #expect(commit.error == nil)
    let saved = try #require(WidgetStore.photos(in: directory))
    #expect(saved.memories.first?.photos == [photos[1]])
    #expect(saved.people.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") } == [photos[1].file])
  }

  @MainActor
  @Test("WidgetPublisher.libraryChanged purges newly locked cloud photos immediately even within the refresh window")
  func libraryChangedPurgesNewlyLockedBypassingFreshness() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "WidgetFreshLock-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: directory.appending(path: "index"))
    let remoteStore = RemoteLibraryStore(accountEmail: "fresh@example.com", directory: directory.appending(path: "remote"))

    func makeItem(key: String, locked: Bool) -> RemoteMediaItem {
      RemoteMediaItem(
        mediaKey: key, dedupKey: key, sha1: nil, fileName: "\(key).jpg", caption: nil, kind: .photo,
        sizeBytes: 100, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: Date(timeIntervalSince1970: 8_000),
        timezoneOffsetMinutes: nil, uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false,
        isFavorite: false, isLocked: locked, isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100,
        latitude: nil, longitude: nil, locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil,
        shutterSpeed: nil, iso: nil, focalLength: nil, durationMs: nil)
    }

    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t1", resumeToken: "", items: [makeItem(key: "M_FRESH", locked: false)], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "t1")
    var analysis = ItemAnalysis()
    analysis.aesthetics = 0.95
    try await store.save(ItemMetadata(id: "g:M_FRESH", date: Date(timeIntervalSince1970: 8_000), words: []), analysis: analysis)

    let context = try #require(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let sampleImage = try #require(context.makeImage())
    struct DeltaFetcher: RemoteLibraryFetching {
      let lockedItem: RemoteMediaItem
      private static var empty: RemoteLibraryUpdate {
        RemoteLibraryUpdate(
          syncToken: "t2", resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false, albums: [],
          deletedAlbumKeys: [])
      }
      func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate {
        RemoteLibraryUpdate(
          syncToken: "t2", resumeToken: "", items: [lockedItem], deletedMediaKeys: [], triggersNextSync: false,
          albums: [], deletedAlbumKeys: [])
      }
      func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
    }
    final class StaticThumbSource: ThumbnailSource, @unchecked Sendable {
      let image: CGImage
      init(_ image: CGImage) { self.image = image }
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken {
        deliver(image, true)
        return .none
      }
    }

    let cloud = CloudLibrary(
      accountEmail: "fresh@example.com", store: remoteStore,
      fetcher: DeltaFetcher(lockedItem: makeItem(key: "M_FRESH", locked: true)),
      thumbnails: StaticThumbSource(sampleImage), actionClient: nil)
    let library = UnifiedLibraryModel()
    library.setCloudLibrary(cloud)
    await library.start(records: [])
    let deadline = ContinuousClock.now + .seconds(5)
    while library.position(ofIndexID: "g:M_FRESH") == nil && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    let widgetDir = directory.appending(path: "widgets")
    var reloads: [String] = []
    let publisher = WidgetPublisher(
      directory: widgetDir, reloadTimeline: { reloads.append($0) }, allowsNetwork: { true })
    await publisher.publishPhotos(from: library, store: store)
    let jpgFile = WidgetPublisher.fileName(for: "g:M_FRESH")
    #expect(FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(jpgFile).path))
    reloads.removeAll()

    // Delta sync moves M_FRESH into the Locked Folder and bumps cloud.revision while staying signed in.
    cloud.refresh(force: true)
    await cloud.waitForSync()
    publisher.libraryChanged(library)
    let purgeDeadline = ContinuousClock.now + .seconds(5)
    while FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(jpgFile).path)
      && ContinuousClock.now < purgeDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(jpgFile).path))
    #expect(WidgetStore.photos(in: widgetDir)?.memories.isEmpty == true)
    #expect(reloads.contains(WidgetStore.memoriesKind))

    // Also verify sign-out (setCloudLibrary(nil), which flips library.isLoaded = false) purges immediately.
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t3", resumeToken: "", items: [makeItem(key: "M_OTHER", locked: false)], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "t3")
    let secondFile = WidgetPublisher.fileName(for: "g:M_OTHER")
    try WidgetStore.write(
      WidgetPhotoSnapshot(
        generatedAt: Date(), accountEmail: "fresh@example.com",
        memories: [
          WidgetPhotoSet(
            id: "featured", kind: .featured, title: "Featured", subtitle: "",
            photos: [WidgetPhoto(itemID: "g:M_OTHER", file: secondFile, date: Date(timeIntervalSince1970: 9_000))])
        ]),
      in: widgetDir)
    try Data([0xFF, 0xD8]).write(to: widgetDir.appendingPathComponent(secondFile))
    let freshSignOutPublisher = WidgetPublisher(
      directory: widgetDir, reloadTimeline: { reloads.append($0) }, allowsNetwork: { false })
    // Prime with signed-in library where M_OTHER is visible and fresh, then sign out.
    freshSignOutPublisher.libraryChanged(library)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(secondFile).path))
    library.setCloudLibrary(nil)
    freshSignOutPublisher.libraryChanged(library)
    let signOutDeadline = ContinuousClock.now + .seconds(5)
    // The image goes first and the list is written after it.
    while FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(secondFile).path)
      || WidgetStore.photos(in: widgetDir)?.memories.isEmpty != true,
      ContinuousClock.now < signOutDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!FileManager.default.fileExists(atPath: widgetDir.appendingPathComponent(secondFile).path))
    #expect(WidgetStore.photos(in: widgetDir)?.memories.isEmpty == true)
    await remoteStore.close()
  }
}
