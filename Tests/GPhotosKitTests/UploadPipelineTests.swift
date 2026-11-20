import Foundation
import Testing

@testable import GPhotosKit

@Suite("Upload pipeline")
@MainActor
struct UploadPipelineTests {
  @Test("Transport stream framing distinguishes TS/MTS video from source code")
  func mediaSignatures() throws {
    for (stride, offset) in [(188, 0), (192, 4), (204, 0)] {
      var bytes = [UInt8](repeating: 0xff, count: stride * 3)
      for packet in 0..<3 {
        bytes[packet * stride + offset] = 0x47
        bytes[packet * stride + offset + 3] = 0x10
      }
      #expect(SupportedMediaFormats.isVideoHeader(Data(bytes), extension: "ts"))
      bytes[stride + offset] = 0
      #expect(!SupportedMediaFormats.isVideoHeader(Data(bytes), extension: "ts"))
    }
    let text = Data("export const video = 'not a video';\n".utf8)
    let audio = Data([0, 0, 0, 20]) + Data("ftypM4A ".utf8) + Data(repeating: 0, count: 8)
    #expect(!SupportedMediaFormats.isVideoHeader(audio, extension: "mp4"))
    for ext in ["ts", "mts", "mod", "mp4", "mov", "avi", "webm"] {
      #expect(!SupportedMediaFormats.isVideoHeader(text, extension: ext))
    }
    let root = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for ext in ["ts", "mts", "mod", "raw", "jpg", "mp4"] {
      let url = root.appendingPathComponent("source.\(ext)")
      try text.write(to: url)
      #expect(!SupportedMediaFormats.isMediaContent(fileURL: url))
    }
  }

  @Test("Skipped failures survive reload, disappear from Activity, and cannot be claimed or overwritten")
  func skippedFailuresPersist() async throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("journal"))
    }
    let store = TransferManifestStore(fileURL: url)
    let record = TransferRecord(id: "a|file", filename: "index.ts", mediaType: "Video", status: .failed)
    #expect(await store.upsert(record))
    #expect(await store.skipFailed(ids: [record.id]))
    let restored = TransferManifestStore(fileURL: url)
    let skipped = try #require(await restored.record(for: record.id))
    #expect(skipped.isSkipped)
    #expect(!skipped.isDueForAutomaticRetry())
    #expect(ActivityFilter.failed.apply(to: [skipped], query: "").isEmpty)
    #expect(ActivityFilter.all.apply(to: [skipped], query: "").isEmpty)
    #expect(!(await restored.claimForUpload(id: record.id)))
    #expect(await restored.claimForUpload(ids: [record.id]).isEmpty)
    #expect(!(await restored.upsert(record)))
    #expect(await restored.upsertBatch([record]))
    #expect(await restored.record(for: record.id)?.isSkipped == true)
  }

  private func makePool() -> UploadWorkerPool {
    let url = TestTemporaryDirectory.root
      .appendingPathComponent("UploadPipelineTests-manifest-\(UUID().uuidString).json")
    return UploadWorkerPool(
      client: GooglePhotosMobileClient(authService: GoogleAuthService()),
      manifestStore: TransferManifestStore(fileURL: url))
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1000 where !condition() {
      await Task.yield()
    }
  }

  @Test("A cancelled SHA-1 waiter leaves the other waiters parked and wakes promptly")
  func cancelledSHA1WaiterOnlyRemovesItself() async {
    let pool = makePool()
    let sha1 = "hash"
    #expect(await pool.acquireSHA1(sha1))

    let cancelled = Task { await pool.acquireSHA1(sha1) }
    let survivor = Task { await pool.acquireSHA1(sha1) }
    await waitUntil { pool.sha1Waiters[sha1]?.count == 2 }
    #expect(pool.sha1Waiters[sha1]?.count == 2)

    cancelled.cancel()
    #expect(await cancelled.value == false)
    #expect(pool.sha1Waiters[sha1]?.count == 1)

    pool.releaseSHA1(sha1)
    #expect(await survivor.value)
    pool.releaseSHA1(sha1)
    #expect(pool.sha1Waiters[sha1] == nil)
  }

  @Test("A paused queue supports bounded and cancelled waits, then releases its claims and progress")
  func pausedBatchCanBeCancelled() async {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("journal"))
    }
    let store = TransferManifestStore(fileURL: url)
    let pool = UploadWorkerPool(client: GooglePhotosMobileClient(authService: GoogleAuthService()), manifestStore: store)
    let item = UploadQueueItem(id: "waiting", fileURL: url, fileSize: 500)
    await store.upsert(TransferRecord(id: item.id, filename: "photo.jpg", mediaType: "Photo", status: .pending))
    #expect(await store.claimForUpload(id: item.id))
    #expect(pool.start(items: [item]) == .started)
    pool.pause()
    await pool.waitForCurrentBatch(timeout: .milliseconds(20))
    #expect(pool.isPaused)
    let waiter = Task { await pool.waitForCurrentBatch() }
    await Task.yield()
    waiter.cancel()
    await waiter.value
    #expect(pool.isPaused)
    pool.cancel()
    await pool.waitForCurrentBatch(timeout: .seconds(5))
    #expect(!pool.isRunning)
    #expect(!pool.hasItem(id: item.id))
    #expect(pool.currentTotalBytes == 0)
    #expect(await store.record(for: item.id)?.status == .pending)
  }

  @Test("A pause during the last item does not park the finished batch")
  func pauseDuringFinalItemDrains() async {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("journal"))
    }
    let manifest = TransferManifestStore(fileURL: url)
    let client = GooglePhotosMobileClient(authService: GoogleAuthService())
    let pool = UploadWorkerPool(client: client, manifestStore: manifest)
    let started = OneShotSignal()
    let finish = OneShotSignal()
    pool.onItemCompleted = {
      started.resume()
      await finish.wait()
    }
    let item = UploadQueueItem(id: "photo", fileURL: url.appendingPathExtension("jpg"), fileSize: 1)
    await manifest.upsert(TransferRecord(id: item.id, filename: item.filename, mediaType: "Photo", status: .pending))
    #expect(await manifest.claimForUpload(id: item.id))
    #expect(pool.start(items: [item]) == .started)
    await started.wait()
    pool.pause()
    finish.resume()
    await pool.waitForCurrentBatch(timeout: .seconds(5))
    #expect(!pool.isRunning)
    #expect(!pool.isPaused)
    #expect(await manifest.record(for: item.id)?.status == .failed)
    pool.cancel()
  }

  @Test("Waiting on an idle pool returns immediately")
  func idleWaitReturns() async {
    let pool = makePool()
    await pool.waitForCurrentBatch(timeout: .seconds(1))
    await pool.waitForCurrentBatch()
    #expect(!pool.isRunning)
  }

  @Test("Progress from a slot's previous item is dropped")
  func staleProgressIsIgnored() {
    let pool = makePool()
    pool.applyProgress(workerID: 0, itemID: "gone", phase: .uploading) { $0.bytesUploaded = 99 }
    #expect(pool.workers[0].bytesUploaded == 0)
    #expect(pool.workers[0].status == "idle")
  }

  @Test("A cached file hash is reused only for the same path and modification date")
  func cachedHashChecksVersion() throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let modifiedAt = try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let hash = Data(repeating: 1, count: 20)
    let item = UploadQueueItem(
      fileURL: url, precomputedSHA1: hash.base64EncodedString(), precomputedSourceModifiedAt: modifiedAt)
    #expect(item.cachedSHA1(for: url) == hash)
    #expect(item.cachedSHA1(for: url.appendingPathExtension("other")) == nil)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt.addingTimeInterval(10)], ofItemAtPath: url.path)
    #expect(item.cachedSHA1(for: URL(fileURLWithPath: url.path)) == nil)
  }

  @Test("Backoff jitter never exceeds the cap and gates retries by attempt and time")
  func backoff() {
    let backoff = Backoff(baseDelay: 10, maxDelay: 60, maxRetries: 3)
    for attempt in 0..<20 {
      #expect(backoff.delay(forAttempt: attempt) <= 60)
    }
    let now = Date()
    #expect(backoff.isReady(attempts: 0, lastAttempt: nil, now: now))
    #expect(backoff.isReady(attempts: 1, lastAttempt: nil, now: now))
    #expect(!backoff.isReady(attempts: 1, lastAttempt: now.addingTimeInterval(-5), now: now))
    #expect(backoff.isReady(attempts: 1, lastAttempt: now.addingTimeInterval(-10), now: now))
    #expect(!backoff.isReady(attempts: 2, lastAttempt: now.addingTimeInterval(-15), now: now))
    #expect(!backoff.isReady(attempts: 3, lastAttempt: nil, now: now))
  }

  @Test("Album keys are scoped per account, cached, and can be forgotten")
  func albumKeysAreAccountScoped() throws {
    let url = TestTemporaryDirectory.root
      .appendingPathComponent("UploadPipelineTests-albums-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = AlbumKeyStore(fileURL: url)
    store.remember(key: "a-family", forAlbumNamed: "Family", accountEmail: "a@example.com")
    store.remember(key: "a-other", forAlbumNamed: "Family", accountEmail: "a@example.com")
    #expect(store.key(forAlbumNamed: "Family", accountEmail: "a@example.com") == "a-family")
    #expect(store.key(forAlbumNamed: "Family", accountEmail: "b@example.com") == nil)

    let reloaded = AlbumKeyStore(fileURL: url)
    #expect(reloaded.key(forAlbumNamed: "Family", accountEmail: "a@example.com") == "a-family")

    reloaded.forget(albumNamed: "Family", accountEmail: "a@example.com")
    #expect(reloaded.key(forAlbumNamed: "Family", accountEmail: "a@example.com") == nil)
    reloaded.remember(key: "a-new", forAlbumNamed: "Family", accountEmail: "a@example.com")
    #expect(AlbumKeyStore(fileURL: url).key(forAlbumNamed: "Family", accountEmail: "a@example.com") == "a-new")
  }

  @Test("An item that keeps failing is retried less and less often")
  func spacesOutFailedRetries() {
    let now = Date()
    var record = TransferRecord(
      id: "a", filename: "a.mov", mediaType: "Video", creationDate: nil, status: .failed, lastError: "No space")
    record.attempts = 1
    record.lastFailedAt = now
    #expect(!record.isDueForAutomaticRetry(at: now))
    #expect(record.isDueForAutomaticRetry(at: now.addingTimeInterval(5 * 60)))
    record.attempts = 2
    #expect(!record.isDueForAutomaticRetry(at: now.addingTimeInterval(9 * 60)))
    #expect(record.isDueForAutomaticRetry(at: now.addingTimeInterval(10 * 60)))
    record.attempts = 72
    #expect(!record.isDueForAutomaticRetry(at: now.addingTimeInterval(23 * 60 * 60)))
    #expect(record.isDueForAutomaticRetry(at: now.addingTimeInterval(24 * 60 * 60)))
    record.status = .pending
    #expect(record.isDueForAutomaticRetry(at: now))
  }

  @Test("A file recorded under /private is recognized by a folder scan, and left alone once sent")
  func folderScanMatchesPrivatePaths() {
    let modified = Date(timeIntervalSince1970: 1_000_000)
    let path = "/private/var/mobile/Downloads/a.mp4"
    var record = TransferRecord(
      id: "me@example.com|\(path)|5", filename: "a.mp4", mediaType: "Video", creationDate: modified, status: .sent,
      byteCount: 5, sourcePath: path, sourceFileSize: 5, sourceModifiedAt: modified)
    record.sentAccountEmails = ["me@example.com"]
    let file = LocalMediaFile(url: URL(fileURLWithPath: path), size: 5, created: modified, modified: modified)
    let plan = FolderMediaScanner.planQueue(
      files: [file], records: [record], accountEmail: "me@example.com", pairLivePhotos: false,
      createAlbumsFromFolders: false)
    #expect(plan.items.isEmpty)
    #expect(plan.newRecords.isEmpty)
  }

  @Test("Two library photos with the same bytes keep their own records across a reload")
  func identicalAssetsStaySeparate() async throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    for asset in ["A", "B"] {
      var record = TransferRecord(
        id: "me@example.com|\(asset)", filename: "same.jpg", mediaType: "Photo", creationDate: nil, status: .sent,
        assetLocalIdentifier: asset)
      record.sha1 = "c2FtZS1ieXRlcw=="
      #expect(await store.upsert(record))
    }
    #expect(await store.flush())
    let ids = Set(await TransferManifestStore(fileURL: url).allRecords().map(\.id))
    #expect(ids == ["me@example.com|A", "me@example.com|B"])
  }

  @Test("Only a record that never finished can be removed as unfinished")
  func removesOnlyUnfinishedRecords() async {
    let url = TestTemporaryDirectory.root.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    func record(_ id: String, _ status: TransferStatus) -> TransferRecord {
      TransferRecord(id: "me@example.com|\(id)", filename: "\(id).jpg", mediaType: "Photo", creationDate: nil, status: status)
    }
    #expect(await store.upsert(record("waiting", .pending)))
    #expect(await store.upsert(record("sending", .sending)))
    #expect(await store.upsert(record("sent", .sent)))
    #expect(await store.removeIfUnfinished(id: "me@example.com|waiting"))
    #expect(!(await store.removeIfUnfinished(id: "me@example.com|sending")))
    #expect(!(await store.removeIfUnfinished(id: "me@example.com|sent")))
    #expect(await store.allRecords().count == 2)
  }

  @Test("An edit waiting to go up goes back to uploaded only when this account has the item")
  func settlesUnsentRevisionOnlyForUploadedItems() async {
    let url = TestTemporaryDirectory.root.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    func record(_ id: String, sentTo email: String?) -> TransferRecord {
      var record = TransferRecord(
        id: "me@example.com|\(id)", filename: "\(id).jpg", mediaType: "Photo", creationDate: nil, status: .pending)
      if let email {
        record.sentAccountEmails = [email]
        record.mediaKeysByAccount = [email: "KEY-\(id)"]
      }
      return record
    }
    #expect(await store.upsert(record("edited", sentTo: "me@example.com")))
    #expect(await store.upsert(record("elsewhere", sentTo: "other@example.com")))
    #expect(await store.upsert(record("new", sentTo: nil)))
    #expect(await store.settleUnsentRevision(id: "me@example.com|edited", accountEmail: "me@example.com"))
    #expect(!(await store.settleUnsentRevision(id: "me@example.com|elsewhere", accountEmail: "me@example.com")))
    #expect(!(await store.settleUnsentRevision(id: "me@example.com|new", accountEmail: "me@example.com")))
    let statuses = Dictionary(uniqueKeysWithValues: await store.allRecords().map { ($0.id, $0.status) })
    #expect(statuses["me@example.com|edited"] == .sent)
    #expect(statuses["me@example.com|elsewhere"] == .pending)
    #expect(statuses["me@example.com|new"] == .pending)
  }

  @Test("A folder file that keeps failing waits its turn, unless the user retries")
  func folderScanHonorsRetryDelay() {
    let modified = Date(timeIntervalSince1970: 1_000_000)
    let path = "/Volumes/Backup/a.mp4"
    var record = TransferRecord(
      id: "me@example.com|\(path)|5", filename: "a.mp4", mediaType: "Video", creationDate: modified, status: .failed,
      byteCount: 5, sourcePath: path, sourceFileSize: 5, sourceModifiedAt: modified)
    record.attempts = 9
    record.lastFailedAt = Date()
    let file = LocalMediaFile(url: URL(fileURLWithPath: path), size: 5, created: modified, modified: modified)
    func plan(_ retries: Bool) -> FolderMediaScanner.QueuePlan {
      FolderMediaScanner.planQueue(
        files: [file], records: [record], accountEmail: "me@example.com", pairLivePhotos: false,
        createAlbumsFromFolders: false, retriesFailedNow: retries)
    }
    #expect(plan(false).items.isEmpty)
    #expect(plan(true).items.count == 1)
  }

  @Test("Unreadable files aren't mistaken for a lost network")
  func fileErrorsAreNotNetworkErrors() {
    #expect(GPhotosError.from(urlError: URLError(.notConnectedToInternet)) == .networkUnavailable)
    #expect(GPhotosError.from(urlError: URLError(.fileDoesNotExist)) != .networkUnavailable)
  }

  @Test("Claiming pending items leaves one that has since been sent as it is")
  func claimLeavesSentRecords() async {
    let url = TestTemporaryDirectory.root.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    var sent = TransferRecord(
      id: "me@example.com|sent", filename: "a.jpg", mediaType: "Photo", creationDate: nil, status: .sent)
    sent.sentAccountEmails = ["me@example.com"]
    #expect(await store.upsert(sent))
    #expect(
      await store.upsert(
        TransferRecord(id: "me@example.com|waiting", filename: "b.jpg", mediaType: "Photo", creationDate: nil, status: .pending)))
    let claimed = await store.claimForUpload(ids: ["me@example.com|sent", "me@example.com|waiting"])
    #expect(claimed == ["me@example.com|waiting"])
    #expect(await store.record(for: "me@example.com|sent")?.sentAccountEmails == ["me@example.com"])
    #expect(await store.record(for: "me@example.com|sent")?.status == .sent)
  }
  @Test("Missing source cleanup requires a readable parent and preserves existing files")
  func confirmsMissingSourceConservatively() throws {
    let root = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("a.jpg")
    #expect(FolderMediaScanner.fileIsConfirmedMissing(file, in: root))
    try Data([1]).write(to: file)
    #expect(!FolderMediaScanner.fileIsConfirmedMissing(file, in: root))
    #expect(!FolderMediaScanner.fileIsConfirmedMissing(file, in: root, includesCloudPlaceholder: true))
    let unreachable = root.appendingPathComponent("unmounted")
    #expect(!FolderMediaScanner.fileIsConfirmedMissing(unreachable.appendingPathComponent("a.jpg"), in: unreachable))
    #expect(!FolderMediaScanner.fileIsConfirmedMissing(unreachable.appendingPathComponent("a.jpg"), in: root))
    #expect(!FolderMediaScanner.fileIsConfirmedMissing(file, in: unreachable))
  }

  @Test("Staging rejects a copy that exceeds the volume's free space")
  func refusesOversizedCopy() throws {
    let directory = TestTemporaryDirectory.root
    let available = try #require(
      directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage)
    #expect(throws: GPhotosError.notEnoughSpace(needed: available + 200_000_000)) {
      try UploadWorkerPool.requireFreeSpace(for: available, at: directory)
    }
    #expect(throws: GPhotosError.notEnoughSpace(needed: available + 200_000_001)) {
      try UploadWorkerPool.requireFreeSpace(for: 1, reserving: available, at: directory)
    }
    #expect(throws: GPhotosError.notEnoughSpace(needed: Int64.max)) {
      try UploadWorkerPool.requireFreeSpace(for: Int64.max, reserving: 1, at: directory)
    }
  }

}
