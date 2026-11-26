import CoreGraphics
import Foundation
import Photos
import Testing

@testable import GPhotosKit

@Suite("Unified timeline matching")
struct TimelineMatchingTests {
  @Test("Local content hashes survive reopening, invalidate edits, and defer unavailable resources")
  func localHashCache() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LibraryIndexStore(directory: directory)
    let now = Date(timeIntervalSince1970: 100_000)
    let digest = Data(repeating: 5, count: 20)
    try await store.saveResourceHash(id: "asset", fingerprint: "original", digest: digest, now: now)
    let reopened = LibraryIndexStore(directory: directory)
    let persisted = try await reopened.recentResourceHashChecks(now: now.addingTimeInterval(86400 * 365))
    #expect(persisted["asset"]?.fingerprint == "original")
    #expect(persisted["asset"]?.digest == digest)
    try await store.saveResourceHash(id: "unavailable", fingerprint: "v1", digest: nil, now: now)
    #expect(try await reopened.recentResourceHashChecks(now: now.addingTimeInterval(60))["unavailable"]?.fingerprint == "v1")
    #expect(try await reopened.recentResourceHashChecks(now: now.addingTimeInterval(86401))["unavailable"] == nil)
  }

  @Test("Paused probes ignore dimension matches, with or without a saved size")
  func persistedSizeMismatch() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = device()
    var remote = cloud(hash: hash)
    remote.sizeBytes = 1_000
    let store = LibraryIndexStore(directory: directory)
    try await store.saveResourceSizes([
      asset.localIdentifier: .init(version: LocalAssetHashes.resourceVersion(asset), bytes: 2_000)
    ])
    let reopened = LibraryIndexStore(directory: directory)
    #expect(try await reopened.resourceSizes()[asset.localIdentifier]?.bytes == 2_000)
    let unchanged = await LocalAssetHashes.prepare(
      device: [asset], folder: [], cloud: [remote], store: reopened, previous: .init(), receipts: [:], allowsProbes: false)
    #expect(unchanged.pendingKeys.isEmpty)
    remote.sizeBytes = 2_000
    let changed = await LocalAssetHashes.prepare(
      device: [asset], folder: [], cloud: [remote], store: reopened, previous: .init(), receipts: [:], allowsProbes: false)
    #expect(changed.pendingKeys.isEmpty)
    let unsized = await LocalAssetHashes.prepare(
      device: [device("unsized")], folder: [], cloud: [remote], store: reopened,
      previous: .init(), receipts: [:], allowsProbes: false)
    #expect(unsized.pendingKeys.isEmpty)
  }

  @Test("Warm launch waits for the folder list and cached matching, then publishes one timeline")
  @MainActor
  func warmLaunchAndProbeToggles() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RemoteLibraryStore(accountEmail: "warm@example.com", directory: directory)
    let update = try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(sync: "S1", items: [.init(key: "warm")]))
    try await store.apply(update, syncToken: "S1")
    try await store.markInitialSyncDone()
    let cloud = CloudLibrary(
      accountEmail: "warm@example.com", store: store, fetcher: CloudLibrarySyncTests.FakeFetcher(),
      thumbnails: NeverRequestImage(), actionClient: nil)
    for _ in 0..<50 {
      if cloud.isStateLoaded { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(cloud.syncState.initialSyncDone)
    let model = UnifiedLibraryModel(waitsForInitialFolders: true)
    model.setCloudLibrary(cloud)
    let source = cloud.localFirstThumbnails
    #expect(source.needsRegistration)
    let id = RemoteThumbnailID(mediaKey: "warm", contentVersion: 1)
    #expect(source.route(for: id.mediaKey) == .remote)
    await model.start(records: [])
    #expect(model.reloadToken == 0)
    await model.setFolders([])
    for _ in 0..<50 {
      if model.hasPublishedCompleteTimeline { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.hasPublishedCompleteTimeline)
    #expect(model.position(ofIndexID: "g:warm") != nil)
    #expect(model.reloadToken == 1)
    #expect(source.route(for: id.mediaKey) == .remote)
    let metadata = model.indexMetadataToken
    #if DEBUG
      let merges = model.mergeCount
    #endif
    for _ in 0..<3 {
      model.updateContentProbePermission(false)
      model.updateContentProbePermission(true)
      await model.setBackupActive(true)
      await model.setBackupActive(false)
    }
    cloud.refresh(force: true)
    for _ in 0..<50 {
      if cloud.isSyncing { break }
      await Task.yield()
    }
    await model.contentProbeConditionsChanged()
    await cloud.waitForSync()
    await model.contentProbeConditionsChanged()
    await model.cloudChanged()
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.hasMerged)
    #expect(model.reloadToken == 1)
    #expect(model.indexMetadataToken == metadata)
    #if DEBUG
      #expect(model.mergeCount == merges)
    #endif
    await cloud.retire()
  }

  @Test("Local byte identity fixes shifted capture times and collapses every cloud duplicate")
  func localHashWithShiftedTime() {
    let remote = [cloud("one", time: 700, hash: hash), cloud("two", time: 701, hash: hash)]
    let evidence: [String: Set<Data>] = ["device": [hash]]
    #expect(
      TimelineMerge.merge(device: [device()], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: evidence) == [.device(0, cloud: 0)])
    #expect(
      TimelineMerge.merge(device: [device()], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: evidence, filter: .notBackedUp).isEmpty)
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud("different", time: 700, hash: Data(repeating: 1, count: 20))], uploadedMediaKeys: [:],
        uploadedSHA1s: evidence, filter: .notBackedUp) == [.device(0, cloud: nil)])
  }

  @Test("Cloud confirmations fill missing device backup badges without hiding unfinished uploads")
  func cloudConfirmsDeviceCollection() {
    let pending = TransferRecord(
      id: "me@example.com|queued", filename: "photo.jpg", mediaType: "Photo", status: .pending,
      assetLocalIdentifier: "unfinished")
    let states = PhotoLibraryGridModel.backupStates(
      from: [pending], confirmedCloudIDs: ["uploaded-by-phone", "unfinished"], accountEmail: email)
    #expect(states["uploaded-by-phone"] == .backedUp)
    #expect(states["unfinished"] == .pending)
    #expect(states["unknown"] == nil)
    let otherAccount = TransferRecord(
      id: "other@example.com|asset", filename: "photo.jpg", mediaType: "Photo", status: .sent,
      assetLocalIdentifier: "only-in-other-account")
    #expect(PhotoLibraryGridModel.backupStates(from: [otherAccount], accountEmail: "current@example.com").isEmpty)
  }

  @Test("Recorded uploads remain backed up while the cloud mirror has not loaded their items")
  func backupBeforeMirrorArrives() {
    let keys: [String: Set<String>] = ["device": ["not-synced-yet"]]
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: keys, filter: .notBackedUp).isEmpty)
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: keys, filter: .backedUp).count == 1)
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: [:], filter: .notBackedUp).count == 1)
  }

  @Test("File evidence standardizes stored paths and rejects a replacement at the same path")
  func folderRecordVersion() throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "a.heic")
    try Data([1]).write(to: file)
    let path = file.standardizedFileURL.path
    let modified = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let record = TransferRecord(
      id: "\(email)|file", filename: "a.heic", mediaType: "Photo", status: .sent,
      mediaKeysByAccount: [email: "copy"], sourcePath: "/private/var/mobile/F/a.heic",
      sourceFileSize: 1, sourceModifiedAt: modified)
    let normalized = URL(fileURLWithPath: "/private/var/mobile/F/a.heic").standardizedFileURL.path
    #expect(UnifiedLibraryModel.folderRecordsByPath([record])[normalized] == [record])
    var current = record
    current.sourcePath = file.path
    let item = FolderItemInfo(path: path, date: modified, size: 1, isVideo: false)
    let byPath = UnifiedLibraryModel.folderRecordsByPath([current])
    #expect(UnifiedLibraryModel.fileUploads(byPath, email: email, folder: [item]).keys == [path: "copy"])
    #expect(UnifiedLibraryModel.fileUploads(byPath, email: "other@example.com", folder: [item]).keys.isEmpty)
    #expect(!UnifiedLibraryModel.matchesFile(current, size: 1, modified: modified.addingTimeInterval(2), isLivePhoto: false))
    #expect(!UnifiedLibraryModel.matchesFile(current, size: 1, modified: modified, isLivePhoto: true))
  }

  @Test("Aliases are independent of the filter and include all known cloud copies")
  func aliasesIgnoreFilter() {
    let file = FolderItemInfo(path: "/f/a.jpg", date: .distantPast, size: 1, isVideo: false)
    let result = TimelineMerge.project(
      device: [device()], cloud: [cloud("one", hash: hash), cloud("two", hash: hash), cloud("file")],
      uploadedMediaKeys: [:], uploadedSHA1s: ["device": [hash]], folder: [file],
      uploadedFileKeys: [file.path: "file"], filter: .videos, hidesScreenshots: false)
    #expect(result.entries.isEmpty)
    #expect(result.copies.assets == ["one": "device", "two": "device"])
    #expect(result.copies.files == ["file": file])
    #expect(result.copies.confirmedAssetIDs == ["device"])
  }

  @Test("Unknown Google thumbnails can start immediately and known file copies take priority")
  func lateAlias() {
    let source = LocalFirstThumbnailSource(remote: NeverRequestImage(allowsRequests: true))
    let id = RemoteThumbnailID(mediaKey: "key", contentVersion: 0).string
    let item = FolderItemInfo(path: "/missing.jpg", date: .distantPast, size: 1, isVideo: false)
    #expect(source.route(for: "key") == .remote)
    source.requestImage(id: id, pixelSize: .init(width: 120, height: 120), quality: .thumbnail) { _, _ in }.cancel()
    #expect(source.remoteRequestCount == 1)
    #expect(source.replace(with: .init(files: ["key": item])))
    #expect(source.route(for: "key") == .file(item.id))
    source.requestImage(id: id, pixelSize: .init(width: 120, height: 120), quality: .thumbnail) { _, _ in }.cancel()
    #expect(source.remoteRequestCount == 1)
  }

  @Test("Missing files repair their aliases, while readable files with failed decodes stay local")
  func repairsStaleFileAlias() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "corrupt.jpg")
    try Data([0]).write(to: url)
    let file = FolderItemInfo(path: url.path, date: .distantPast, size: 1, isVideo: false)
    let source = LocalFirstThumbnailSource(remote: NeverRequestImage())
    let id = RemoteThumbnailID(mediaKey: "key", contentVersion: 0).string
    let copies = LocalFirstThumbnailSource.LocalCopies(files: ["key": file])
    #expect(source.replace(with: copies))
    func request() async {
      await withCheckedContinuation { continuation in
        _ = source.requestImage(
          id: id, pixelSize: CGSize(width: 64, height: 64), quality: .thumbnail,
          onUnavailable: { continuation.resume() },
          deliver: { _, _ in
            Issue.record("Expected a failed decode")
            continuation.resume()
          })
      }
    }
    await request()
    #expect(source.route(for: "key") == .file(file.id))
    try FileManager.default.removeItem(at: url)
    await request()
    #expect(source.route(for: "key") == .remote)

    let replacement = FolderItemInfo(path: directory.appending(path: "replacement.jpg").path, date: .distantPast, size: 1, isVideo: false)
    #expect(source.replace(with: .init(files: ["key": replacement])))
    source.discardAlias(for: "key", route: .file(file.id), checked: copies)
    #expect(source.route(for: "key") == .file(replacement.id))
  }

  @Test("A folder row and a device row sharing a Google copy keep separate action targets across a reload")
  func exactSelectionAcrossReload() throws {
    let account = NSObject()
    let remote = [cloud("shared", hash: hash), cloud("cloud-only", time: 700)]
    let photos = [device(), device("other", time: 600)]
    let file = FolderItemInfo(path: "/f/shared.jpg", date: photos[0].date, size: 42, isVideo: false)
    let receipts: [String: Set<String>] = ["device": ["shared"]]
    let project: ([DeviceItemInfo], [FolderItemInfo]) -> UnifiedLibraryModel.IndexedTimeline = { photos, files in
      let projection = TimelineMerge.project(
        device: photos, cloud: remote, uploadedMediaKeys: receipts, uploadedSHA1s: [:],
        folder: files, uploadedFileKeys: [file.path: "shared"], filter: .all, hidesScreenshots: false)
      return UnifiedLibraryModel.index(projection.entries, device: photos, cloud: remote, folder: files, copies: projection.copies)
    }
    let indexed = project(photos, [file])
    let folderPosition = try #require(indexed.entries.firstIndex(of: .folder(0, cloud: 0)))
    let devicePosition = try #require(indexed.entries.firstIndex(of: .device(0, cloud: 0)))
    let otherPosition = try #require(indexed.entries.firstIndex(of: .device(1, cloud: nil)))
    func identity(_ entry: UnifiedEntry, in photos: [DeviceItemInfo], files: [FolderItemInfo]) -> UnifiedLibraryModel.SelectionID? {
      UnifiedLibraryModel.selectionID(for: entry, device: photos, cloud: remote, folder: files, account: ObjectIdentifier(account))
    }
    let folderID = try #require(identity(indexed.entries[folderPosition], in: photos, files: [file]))
    let otherID = try #require(identity(indexed.entries[otherPosition], in: photos, files: [file]))
    #expect(folderID == .folder(file.thumbnailIdentity))
    #expect(identity(indexed.entries[devicePosition], in: photos, files: [file]) == .device("device"))
    let selected = Set([folderID, otherID])
    #expect(
      UnifiedLibraryModel.selectionPositions(selected, in: indexed.positions) {
        identity(indexed.entries[$0], in: photos, files: [file])
      } == [folderPosition, otherPosition])

    let reloaded = [device("new", time: 10), photos[0], photos[1]]
    let moved = project(reloaded, [file])
    let confirmation = UnifiedLibraryModel.selectionPositions(selected, in: moved.positions) {
      identity(moved.entries[$0], in: reloaded, files: [file])
    }
    #expect(Set(confirmation.map { moved.entries[$0] }) == [.folder(0, cloud: 0), .device(2, cloud: nil)])

    let removed = project(reloaded, [])
    let beforeCollapse = UnifiedLibraryModel.SelectionID.cloud(ObjectIdentifier(account), "shared")
    let surviving = UnifiedLibraryModel.selectionPositions(selected.union([beforeCollapse]), in: removed.positions) {
      identity(removed.entries[$0], in: reloaded, files: [])
    }
    #expect(surviving.map { removed.entries[$0] } == [.device(2, cloud: nil)])
  }

  @Test("A loaded Google mirror publishes after the deadline even if the first folder scan never answers")
  @MainActor
  func mirrorDoesNotWaitForFolders() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = "slow-folder@example.com"
    let store = RemoteLibraryStore(accountEmail: account, directory: directory)
    let update = try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(sync: "S1", items: [.init(key: "available")]))
    try await store.apply(update, syncToken: "S1")
    try await store.markInitialSyncDone()
    let library = CloudLibrary(
      accountEmail: account, store: store, fetcher: CloudLibrarySyncTests.FakeFetcher(),
      thumbnails: NeverRequestImage(), actionClient: nil)
    let model = UnifiedLibraryModel(waitsForInitialFolders: true)
    model.setCloudLibrary(library)
    await model.start(records: [])
    let deadline = ContinuousClock.now + .seconds(3)
    while model.itemCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.launchWaitExpired)
    #expect(model.entry(at: 0) == .cloud(0))
    #expect(!model.hasMerged)
    #expect(library.localFirstThumbnails.route(for: "available") == .remote)
    await library.retire()
  }

  @Test("Signing in to the same account again attaches its new library")
  @MainActor
  func sameAccountReplacement() async throws {
    let email = "again@example.com"
    let directory = TestTemporaryDirectory.root.appending(path: "Replace-\(UUID().uuidString)")
    func library(_ name: String) -> CloudLibrary {
      CloudLibrary(
        accountEmail: email, store: RemoteLibraryStore(accountEmail: email, directory: directory.appending(path: name)),
        fetcher: CloudLibrarySyncTests.FakeFetcher(), thumbnails: NeverRequestImage(), actionClient: nil)
    }
    let old = library("old")
    let replacement = library("new")
    let model = UnifiedLibraryModel()
    model.setCloudLibrary(old)
    await old.retire()
    model.setCloudLibrary(replacement)
    #expect(model.cloud?.library === replacement)
    let grid = model.cloud
    model.setCloudLibrary(replacement)
    #expect(model.cloud === grid)
    await replacement.retire()
  }

  @Test("Changing exclusions keeps the Google row and the viewer relocates it after a folder row leaves")
  @MainActor func folderRescanKeepsGoogleRows() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    let media = directory.appending(path: "media", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = media.appending(path: "sample.jpg")
    try Data([1]).write(to: url)
    let oldDate = Date(timeIntervalSince1970: 100)
    try FileManager.default.setAttributes([.creationDate: oldDate, .modificationDate: oldDate], ofItemAtPath: url.path)
    let settledAt = ContinuousClock.now + .seconds(FolderMediaScanner.writeSettleInterval)
    let store = RemoteLibraryStore(accountEmail: email, directory: directory)
    let update = try LibraryMessages.decodeLibraryUpdate(SyncResponseBuilder.page(sync: "S1", items: [.init(key: "google")]))
    try await store.apply(update, syncToken: "S1")
    try await store.markInitialSyncDone()
    let cloud = CloudLibrary(
      accountEmail: email, store: store, fetcher: CloudLibrarySyncTests.FakeFetcher(),
      thumbnails: NeverRequestImage(), actionClient: nil)
    let model = UnifiedLibraryModel()
    model.setCloudLibrary(cloud)
    await model.start(records: [])
    try await ContinuousClock().sleep(until: settledAt)
    await model.setFolders([.init(id: "test", path: media.path, bookmarkData: nil)])
    let original = try #require(model.position(ofIndexID: "g:google"))
    #expect(original > 0)
    let selection = MediaViewer.PageSelection(index: original, source: model)
    let check = Task { @MainActor in
      while !Task.isCancelled {
        #expect(model.position(ofIndexID: "g:google") != nil)
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    await model.setFolders([.init(id: "test", path: media.path, bookmarkData: nil, exclusions: .init(["*.jpg"]))])
    let deadline = ContinuousClock.now + .seconds(2)
    while model.position(ofIndexID: "g:google") == original, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    check.cancel()
    await check.value
    let moved = try #require(model.position(ofIndexID: "g:google"))
    #expect(moved < original)
    #expect(selection.position(in: model) == moved)
    #expect(cloud.localFirstThumbnails.route(for: "google") == .remote)
    await model.setFolders([])
    await cloud.retire()
  }

  @Test("Probe plans cap total bytes, skip size disagreements and do no reads when gated")
  func probeBudget() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sizes = [LocalAssetHashes.maximumBytes, LocalAssetHashes.maximumBytes - 1, LocalAssetHashes.maximumBytes - 2]
    var files: [FolderItemInfo] = []
    var remote: [RemoteItemSummary] = []
    for (i, size) in sizes.enumerated() {
      let url = directory.appending(path: "\(i).jpg")
      try Data().write(to: url)
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: UInt64(size))
      try handle.close()
      files.append(.init(path: url.path, date: .distantPast, size: size, isVideo: false))
      var item = cloud("google\(i)", hash: hash)
      item.sizeBytes = size
      remote.append(item)
    }
    var wrongSize = cloud("wrong-size", hash: hash)
    wrongSize.fileName = "0.jpg"
    wrongSize.sizeBytes = 100
    remote.append(wrongSize)
    let store = LibraryIndexStore(directory: directory)
    let plan = await LocalAssetHashes.prepare(device: [], folder: files, cloud: remote, store: store, previous: .init(), receipts: [:])
    #expect(plan.pendingKeys == ["google0", "google1"])
    let blocked = await LocalAssetHashes.read(plan, store: store, canRead: { false })
    #expect(!blocked.complete)
    #expect(blocked.evidence.files.isEmpty)
    #expect(try await store.recentResourceHashChecks().isEmpty)
  }

  @Test("A file changed after planning is skipped at the point of reading")
  func rechecksProbeFile() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "same.jpg")
    try Data([1]).write(to: url)
    let file = FolderItemInfo(path: url.path, date: .distantPast, size: 1, isVideo: false)
    var item = cloud("google", hash: hash)
    item.sizeBytes = 1
    let store = LibraryIndexStore(directory: directory)
    let plan = await LocalAssetHashes.prepare(device: [], folder: [file], cloud: [item], store: store, previous: .init(), receipts: [:])
    #expect(plan.pendingKeys == ["google"])
    try Data([2, 3]).write(to: url)
    let result = await LocalAssetHashes.read(plan, store: store)
    #expect(result.complete)
    let evidence = result.evidence
    #expect(evidence.files.isEmpty)
    #expect(try await store.recentResourceHashChecks().isEmpty)
  }

  @Test("Empty backup filters wait for authoritative local inputs, independent of cloud matching")
  func emptyFilterReadiness() {
    for filter: LibraryFilter in [.notBackedUp, .notIncludedInBackup] {
      #expect(
        UnifiedLibraryModel.filterIsReady(
          filter, accountReady: true, hasRecords: true, foldersAreSettled: true,
          hasCloud: true, mirrorLoaded: false, initialSyncDone: false, syncFailed: false))
      #expect(
        !UnifiedLibraryModel.filterIsReady(
          filter, accountReady: true, hasRecords: true, foldersAreSettled: false,
          hasCloud: true, mirrorLoaded: true, initialSyncDone: true, syncFailed: false))
    }
    #expect(
      UnifiedLibraryModel.filterIsReady(
        .all, accountReady: true, hasRecords: true, foldersAreSettled: true,
        hasCloud: true, mirrorLoaded: true, initialSyncDone: false, syncFailed: true))
  }

  @Test("Google rows remain in backup filters when the device rendition is unconfirmed or RAW failed")
  func backupFiltersKeepUnconfirmedGoogleCopies() {
    let remote = cloud(hash: hash)
    let raw = TransferRecord(
      id: "\(email)|raw", filename: "IMG.DNG", mediaType: "Photo", status: .failed,
      assetLocalIdentifier: "device", resourceRole: .alternatePhoto)
    let primary = record("cloud")
    let backup = PhotoBackupEvidence.read([primary, raw], accountEmail: email, excludedAlbumIDs: [])
    #expect(backup.state(for: "device", version: primary.assetVersion) == .failed)
    for filter: LibraryFilter in [.backedUp, .cloudOnly, .notBackedUp, .notIncludedInBackup] {
      let result = TimelineMerge.project(
        device: [device()], cloud: [remote], uploadedMediaKeys: ["device": ["cloud"]], uploadedSHA1s: ["device": [hash]],
        folder: [], uploadedFileKeys: [:], filter: filter, hidesScreenshots: false, backup: backup)
      let expected: [UnifiedEntry]
      switch filter {
      case .backedUp, .cloudOnly: expected = [.cloud(0)]
      case .notBackedUp, .notIncludedInBackup:
        expected =
          filter.includesBackupItem(inScope: PhotoBackupScope.backsUpPhotos, backedUp: false)
          ? [.device(0, cloud: 0)] : []
      default: expected = []
      }
      #expect(result.entries == expected)
    }
    for filter: LibraryFilter in [.backedUp, .cloudOnly] {
      #expect(TimelineMerge.merge(device: [device()], cloud: [remote], uploadedMediaKeys: [:], filter: filter) == [.cloud(0)])
    }
  }

  @Test("Duplicate folder bytes give only one row the Google index ID")
  func duplicateFolderIndexIDs() {
    let files = ["/a.jpg", "/b.jpg"].map { FolderItemInfo(path: $0, date: .distantPast, size: 1, isVideo: false) }
    let remote = [cloud(hash: hash)]
    let entries = TimelineMerge.merge(
      device: [], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: [files[0].id: [hash], files[1].id: [hash]], folder: files)
    let snapshot = UnifiedLibraryModel.IndexSnapshot(entries: entries, device: [], cloud: remote, folder: files, cloudLibrary: nil)
    #expect(Set(entries.indices.compactMap { snapshot.indexID(at: $0) }) == ["g:cloud", files[1].id])
  }

  @Test("The Collections hold ends as soon as data is ready and is skipped after the first reveal")
  func collectionsRevealDelay() {
    #expect(CollectionsView.sectionRevealDelay(ready: false, hasShown: false) == .milliseconds(250))
    #expect(CollectionsView.sectionRevealDelay(ready: true, hasShown: false) == .zero)
    #expect(CollectionsView.sectionRevealDelay(ready: false, hasShown: true) == nil)
  }

  @Test("A renamed folder copy resolves by bytes and releases only its candidate key")
  func renamedFileMatching() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "renamed.jpg")
    try Data([1, 2, 3]).write(to: url)
    let digest = try GooglePhotosMobileClient.streamSHA1(fileURL: url)
    let file = FolderItemInfo(path: url.path, date: .distantPast, size: 3, isVideo: false)
    var remote = cloud("matching", hash: digest)
    remote.fileName = "original.jpg"
    remote.sizeBytes = 3
    let store = LibraryIndexStore(directory: directory)
    let plan = await LocalAssetHashes.prepare(device: [], folder: [file], cloud: [remote], store: store, previous: .init(), receipts: [:])
    #expect(plan.pendingKeys == ["matching"])
    let result = await LocalAssetHashes.read(plan, store: store)
    #expect(result.complete)
    let evidence = result.evidence
    #expect(evidence.current(device: [], folder: [file]) == [file.id: [digest]])
    let cached = await LocalAssetHashes.prepare(
      device: [], folder: [file], cloud: [remote], store: store, previous: .init(), receipts: [:])
    #expect(cached.pendingKeys.isEmpty)
    #expect(cached.known.current(device: [], folder: [file]) == [file.id: [digest]])
  }

  @Test("A Photos change retains a verified hash until the underlying rendition changes")
  func retainsHashAcrossPhotosChange() {
    let date = Date(timeIntervalSince1970: 100)
    var original = device()
    original.version = .init(.init(modifiedAt: date, hasAdjustments: false))
    var evidence = LocalAssetHashes.Evidence()
    evidence.devices[original.localIdentifier] = (original.version, hash)

    var changed = original
    changed.version = .init(.init(modifiedAt: date.addingTimeInterval(60), hasAdjustments: false))
    let device = [changed, device("new-photo")]
    let remote = [cloud(time: 700, hash: hash)]
    let hashes = evidence.current(device: device, folder: [])
    let projection = TimelineMerge.project(
      device: device, cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: hashes, folder: [], uploadedFileKeys: [:],
      filter: .all, hidesScreenshots: false)
    #expect(projection.entries.count == 2)
    #expect(projection.entries.contains(.device(0, cloud: 0)))
    #expect(projection.entries.contains(.device(1, cloud: nil)))
    #expect(projection.copies.route(for: "cloud") == .asset("device"))
    changed.version = .init(.init(modifiedAt: date.addingTimeInterval(120), hasAdjustments: true))
    #expect(evidence.current(device: [changed], folder: []).isEmpty)
  }

  @Test("Indexing collapses every file receipt key with or without a Library filter")
  func unfilteredFolderReceipts() {
    let file = FolderItemInfo(path: "/f/a.jpg", date: .distantPast, size: 1, isVideo: false)
    let remote = [cloud("first"), cloud("second")]
    let keys = [file.path: "first"]
    let extra: [String: Set<String>] = [file.path: ["first", "second"]]
    let all = TimelineMerge.project(
      device: [], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: [:], folder: [file], uploadedFileKeys: keys,
      filter: .all, hidesScreenshots: false, extraFileKeys: extra
    ).entries
    let filtered = TimelineMerge.project(
      device: [], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: [:], folder: [file], uploadedFileKeys: keys,
      filter: .videos, hidesScreenshots: false, extraFileKeys: extra
    ).entries
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: filtered, device: [], cloud: remote, folder: [file], cloudLibrary: nil,
      inputs: .init(uploadedFileKeys: keys, isFiltered: true, extraFileKeys: extra))
    #expect(filtered.isEmpty)
    #expect(all == [.folder(0, cloud: 0)])
    #expect(snapshot.unfiltered().entries == all)
  }

  @Test("Folder scan order does not change equal-date cells")
  func equalDateFolderOrder() {
    let date = Date(timeIntervalSince1970: 100)
    let files = ["b.jpg", "a.jpg"].map {
      LocalMediaFile(url: URL(fileURLWithPath: "/tmp/" + $0), size: 1, created: date, modified: date)
    }
    let names = FolderLibrary.items(from: files, pairLivePhotos: false).map(\.fileName)
    #expect(names == ["a.jpg", "b.jpg"])
    #expect(FolderLibrary.items(from: files.reversed(), pairLivePhotos: false).map(\.fileName) == names)
  }

  @Test("Hiding screenshots in Library preserves screenshots that still need backup")
  func hiddenScreenshotsInBackup() {
    var screenshot = device()
    screenshot.subtypes = PHAssetMediaSubtype.photoScreenshot.rawValue
    let items = [screenshot]
    #expect(TimelineMerge.merge(device: items, cloud: [], uploadedMediaKeys: [:], hidesScreenshots: true).isEmpty)
    #expect(
      TimelineMerge.merge(device: items, cloud: [], uploadedMediaKeys: [:], filter: .notBackedUp, hidesScreenshots: true)
        == [.device(0, cloud: nil)])
  }

  @Test("Backup filters are disjoint and an unfinished edited original takes precedence over the primary receipt")
  func backupFilterPartition() {
    for inScope in [false, true] {
      for backedUp in [false, true] {
        let filters: [LibraryFilter] = [.backedUp, .notBackedUp, .notIncludedInBackup]
        #expect(filters.filter { $0.includesBackupItem(inScope: inScope, backedUp: backedUp) }.count == 1)
      }
    }

    let primary = record("primary")
    let pending = TransferRecord(
      id: "\(email)|original", filename: "original.jpg", mediaType: "Photo", status: .pending,
      assetLocalIdentifier: "device", resourceRole: .uneditedOriginal)
    let version = primary.assetVersion
    let included = PhotoBackupEvidence.read(
      [primary, pending], accountEmail: email, excludedAlbumIDs: [], backsUpUneditedOriginals: true)
    let excluded = PhotoBackupEvidence.read(
      [primary, pending], accountEmail: email, excludedAlbumIDs: [], backsUpUneditedOriginals: false)
    #expect(included.state(for: "device", version: version) == .pending)
    #expect(excluded.state(for: "device", version: version) == .backedUp)
  }

  private final class NeverRequestImage: ThumbnailSource {
    let allowsRequests: Bool

    init(allowsRequests: Bool = false) { self.allowsRequests = allowsRequests }

    func requestImage(
      id: String, pixelSize: CGSize, quality: ImageRequestQuality,
      onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
    ) -> ImageRequestToken {
      if !allowsRequests { Issue.record("Unexpected Google thumbnail request") }
      onUnavailable()
      return .none
    }
  }

  @Test("Equal-length timelines with different item identities or dates require reindexing")
  func sameCountReplacement() {
    let original = [device("old")]
    let fields: (DeviceItemInfo) -> (String, Date) = { ($0.localIdentifier, $0.date) }
    #expect(UnifiedLibraryModel.layoutsDiffer(new: [device("new")], old: original, fields: fields))
    #expect(UnifiedLibraryModel.layoutsDiffer(new: [device("old", time: 99)], old: original, fields: fields))
    #expect(!UnifiedLibraryModel.layoutsDiffer(new: original, old: original, fields: fields))
  }

  @Test("Relevance detects an added, removed or reassigned mirror key")
  func mirrorRelevance() {
    #expect(!UnifiedLibraryModel.touchesMirror(["a": ["old"]], ["a": ["new"]], ["other"]))
    #expect(UnifiedLibraryModel.touchesMirror(["a": ["old"]], ["a": ["new"]], ["old"]))
    #expect(UnifiedLibraryModel.touchesMirror(["a": ["copy"]], ["b": ["copy"]], ["copy"]))
  }

  private let email = "me@example.com"
  private let hash = Data(repeating: 7, count: 20)

  private func device(_ id: String = "device", time: Double = 100, video: Bool = false) -> DeviceItemInfo {
    DeviceItemInfo(
      localIdentifier: id, date: Date(timeIntervalSince1970: time), width: 4032, height: 3024,
      isVideo: video, isFavorite: false)
  }

  private func cloud(
    _ id: String = "cloud", time: Double = 100, width: Int? = 4032, height: Int? = 3024,
    kind: RemoteMediaItem.Kind = .photo, hash: Data? = nil
  ) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: id, dedupKey: id, sha1: hash, kind: kind, takenAt: Date(timeIntervalSince1970: time),
      contentVersion: 0, durationMs: nil, isFavorite: false, trashedAt: nil, width: width, height: height)
  }

  private func record(_ key: String, role: AssetResourceRole = .primary) -> TransferRecord {
    TransferRecord(
      id: key, filename: "IMG_1.HEIC", mediaType: "Photo", status: .sent,
      mediaKeysByAccount: [email: key], sha1: hash.base64EncodedString(),
      assetLocalIdentifier: "device", resourceRole: role)
  }

  @Test("Subseconds crossing rounding or whole-second boundaries still pair", arguments: [100.6, 99.9])
  func fractionalCaptureTimes(time: Double) {
    #expect(
      TimelineMerge.merge(device: [device(time: time)], cloud: [cloud()], uploadedMediaKeys: [:])
        == [.device(0, cloud: 0)])
  }

  @Test("A nearby burst is ambiguous across second boundaries")
  func adjacentBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a", time: 100.1), device("b", time: 99.9)], cloud: [cloud()], uploadedMediaKeys: [:])
    #expect(entries.count == 3)
    #expect(entries.contains(.cloud(0)))
  }

  @Test("A recorded burst frame cannot make its neighbour falsely unique")
  func recordedBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud("a"), cloud("b")], uploadedMediaKeys: ["a": ["a"]])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: nil)))
    #expect(entries.contains(.cloud(1)))
  }

  @Test("Rotation, motion photos and videos use the existing normalized type and size")
  func normalizedMetadata() {
    for kind in [RemoteMediaItem.Kind.photo, .motionPhoto, .video] {
      #expect(
        TimelineMerge.merge(
          device: [device(video: kind == .video)], cloud: [cloud(width: 3024, height: 4032, kind: kind)],
          uploadedMediaKeys: [:]) == [.device(0, cloud: 0)])
    }
  }

  @Test("Missing dimensions and timezone differences need stronger evidence")
  func missingMetadata() {
    let remote = cloud(time: 100 + 8 * 3600, width: nil, height: nil, hash: hash)
    #expect(TimelineMerge.merge(device: [device()], cloud: [remote], uploadedMediaKeys: [:]).count == 2)
    let hashes = UnifiedLibraryModel.uploadEvidence([record("staleKey")], email: "").hashes
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [remote], uploadedMediaKeys: ["device": ["staleKey"]], uploadedSHA1s: hashes)
        == [.device(0, cloud: 0)])
  }

  @Test("Stored hashes resolve a same-second burst without reading resources")
  func hashesResolveBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud("a", hash: hash), cloud("b")],
      uploadedMediaKeys: [:], uploadedSHA1s: ["a": [hash]])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: nil)))
    #expect(entries.contains(.cloud(1)))
  }

  @Test("Every primary key survives, regardless of record order; RAW and original stay separate")
  func allPrimaryKeys() {
    let records = [
      record("first"), record("second"), record("raw", role: .alternatePhoto),
      record("original", role: .uneditedOriginal),
    ]
    let keys = UnifiedLibraryModel.uploadEvidence(records, email: email).keys
    #expect(keys == ["device": ["first", "second"]])
    #expect(UnifiedLibraryModel.uploadEvidence(records.reversed(), email: email).keys == keys)
    #expect(UnifiedLibraryModel.uploadEvidence(records, email: "other@example.com").keys.isEmpty)
    #expect(UnifiedLibraryModel.uploadEvidence(Array(records.suffix(2)), email: "").hashes.isEmpty)
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud("second", width: nil), cloud("first", width: nil)],
        uploadedMediaKeys: keys) == [.device(0, cloud: 0)])
  }

  @Test("An already claimed cloud copy can still badge another recorded device copy")
  func sharedCloudKey() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud()], uploadedMediaKeys: ["a": ["cloud"], "b": ["cloud"]])
    #expect(entries.count == 2)
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: 0)))
  }

  @Test("A folder claim does not prevent matching the device")
  func folderClaim() {
    let entries = TimelineMerge.merge(
      device: [device()], cloud: [cloud()], uploadedMediaKeys: [:],
      folder: [FolderItemInfo(path: "/a.heic", date: Date(timeIntervalSince1970: 100), size: 1, isVideo: false)],
      uploadedFileKeys: ["/a.heic": "cloud"])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.folder(0, cloud: 0)))
    #expect(!entries.contains(.cloud(0)))
  }

  @Test("Malformed hashes and nonprimary resources provide no matching evidence")
  func malformedHashes() {
    var invalid = record("invalid")
    invalid.sha1 = Data([1]).base64EncodedString()
    #expect(UnifiedLibraryModel.uploadEvidence([invalid], email: "").hashes.isEmpty)
  }

  @Test("Display matches cannot authorize cleanup or change the manifest")
  func displayDoesNotAuthorizeDeletion() async throws {
    let directory = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TransferManifestStore(fileURL: directory.appendingPathComponent("manifest.json"))
    var pending = record("pending")
    pending.status = .pending
    pending.sentAt = .distantPast
    pending.sentAccountEmails = []
    pending.mediaKeysByAccount = [:]
    #expect(await store.upsert(pending))
    #expect(
      TimelineMerge.merge(device: [device()], cloud: [cloud()], uploadedMediaKeys: [:])
        == [.device(0, cloud: 0)])
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud(width: nil, hash: hash)], uploadedMediaKeys: [:],
        uploadedSHA1s: UnifiedLibraryModel.uploadEvidence([pending], email: "").hashes) == [.device(0, cloud: 0)])
    #expect(await store.eligibleForDeletion(delay: .immediately, smartDelete: false, accountEmail: email).isEmpty)
    #expect(await store.record(for: pending.id) == pending)
    #expect(UnifiedLibraryModel.recordedCloudCopy(device(), cloud(), receipts: [:]) == nil)
    #expect(UnifiedLibraryModel.recordedCloudCopy(device(), cloud(), receipts: ["device": ["cloud"]])?.mediaKey == "cloud")
  }

  @Test("100,000 pairs merge with bounded metadata work")
  func largeLibrary() {
    let devices = (0..<100_000).reversed().map { device("d\($0)", time: Double($0) * 3 + 0.7) }
    let clouds = (0..<100_000).reversed().map { cloud("c\($0)", time: Double($0) * 3) }
    let clock = ContinuousClock()
    let start = clock.now
    let entries = TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:])
    print("Timeline merge: 100,000 device + 100,000 cloud items in \(start.duration(to: clock.now))")
    #expect(entries.count == 100_000)
    #expect(entries.first == .device(99_999, cloud: 99_999))
    #expect(entries.last == .device(0, cloud: 0))
  }

  @Test("Backed-up grid cells draw their cloud icon")
  @MainActor func backedUpIcon() {
    let cell = PhotoGridCellLayer()
    cell.apply(badges: PhotoGridBadges(backup: .backedUp), scale: 2)
    #expect(cell.sublayers?.contains { $0.contents != nil && !$0.isHidden } == true)
    cell.apply(badges: PhotoGridBadges(), scale: 2)
    #expect(cell.sublayers?.contains { $0.contents != nil && !$0.isHidden } == false)
  }
}
