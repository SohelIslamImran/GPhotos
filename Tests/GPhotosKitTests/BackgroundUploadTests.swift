import Foundation
import Testing

@testable import GPhotosKit

@Suite("Uploads while the app is closed")
struct BackgroundUploadTests {
  private func temporaryDirectory() -> URL {
    let url = TestTemporaryDirectory.root.appendingPathComponent("BackgroundUploadTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func job(recordID: String = "me@example.com|asset", parts: Int = 1) -> BackgroundUploadJob {
    BackgroundUploadJob(
      recordID: recordID, accountEmail: "me@example.com", assetLocalIdentifier: "asset", role: .primary,
      kind: parts == 2 ? .livePhoto : .file, filename: "IMG_0001.HEIC", mediaType: "Photo", creationDate: nil,
      assetModifiedAt: Date(timeIntervalSince1970: 100), capturedAt: Date(timeIntervalSince1970: 50), byteCount: 10,
      sha1: Data(repeating: 1, count: 20),
      parts: (0..<parts).map { BackgroundUploadPart(stagedName: "file\($0)", size: 5, uploadID: "upload\($0)") })
  }

  private func result(
    recordID: String = "me@example.com|asset", modifiedAt: Date? = Date(timeIntervalSince1970: 100),
    uploaded: Bool = true, pairedSHA1: String? = nil
  ) -> BackgroundUploadResult {
    BackgroundUploadResult(
      recordID: recordID, accountEmail: "me@example.com",
      assetLocalIdentifier: TransferRecord.unscopedID(from: recordID), role: .primary,
      filename: "IMG_0001.HEIC", mediaType: "Photo", creationDate: nil, assetModifiedAt: modifiedAt, byteCount: 10,
      mediaKey: "key", sha1: "c2hh", pairedSHA1: pairedSHA1, uploaded: uploaded, foundInAccount: !uploaded,
      finishedAt: Date(timeIntervalSince1970: 200))
  }

  private func finalizeToken() -> Data {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 1, 2)
    writer.writeBytes(fieldNumber: 2, Data([1, 2, 3]))
    return writer.data
  }

  // MARK: - Ledger

  @Test("Fast foreground polling follows jobs, results and live preparations")
  func foregroundPollingTracksWork() {
    var ledger = BackgroundUploadLedger()
    let now = Date(timeIntervalSince1970: 10)
    ledger.appBusyUntil = now.addingTimeInterval(100)
    #expect(ledger.foregroundPollInterval(at: now) == .seconds(60))
    ledger.appBusyUntil = nil
    let claimed = ledger.claimForPreparation(recordID: "asset", jobID: "job", at: now)
    #expect(claimed)
    #expect(ledger.foregroundPollInterval(at: now) == .seconds(15))
    #expect(ledger.foregroundPollInterval(at: now.addingTimeInterval(301)) == .seconds(60))
    ledger.jobs = [job()]
    #expect(ledger.foregroundPollInterval(at: now) == .seconds(15))
    ledger.jobs = []
    ledger.results = [result()]
    #expect(ledger.foregroundPollInterval(at: now) == .seconds(15))
  }

  @Test("Bulk import persists settled receipts and leaves in-flight items for the next pass")
  func bulkImport() async throws {
    let url = temporaryDirectory().appendingPathComponent("manifest.json")
    let store = TransferManifestStore(fileURL: url)
    let first = result(recordID: "me@example.com|first")
    let second = result(recordID: "me@example.com|second")
    let inFlight = result(recordID: "me@example.com|sending")
    let pending = TransferRecord(id: inFlight.recordID, filename: "IMG.HEIC", mediaType: "Photo", status: .pending)
    #expect(await store.upsert(pending))
    #expect(await store.claimForUpload(id: pending.id))
    #expect(await store.recordBackgroundUploads([first, inFlight, second]) == [.recorded, .deferred, .recorded])
    let restored = TransferManifestStore(fileURL: url)
    #expect(await restored.record(for: first.recordID)?.status == .sent)
    #expect(await restored.record(for: second.recordID)?.status == .sent)
    #expect(await store.record(for: pending.id)?.status == .sending)
  }

  @Test("Bulk import restores in-memory records if the manifest cannot be written")
  func bulkImportRollsBack() async throws {
    let root = temporaryDirectory()
    let blocked = root.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let store = TransferManifestStore(fileURL: blocked.appendingPathComponent("manifest.json"))
    let first = result(recordID: "me@example.com|first")
    let second = result(recordID: "me@example.com|second")
    #expect(await store.recordBackgroundUploads([first, second]) == [.deferred, .deferred])
    #expect(await store.record(for: first.recordID) == nil)
    #expect(await store.record(for: second.recordID) == nil)
  }

  @Test("Preparation and unimported results both hold the app off the record")
  func holdsRecordAcrossUploadHandoff() {
    var ledger = BackgroundUploadLedger()
    let job = job()
    ledger.appBusyUntil = Date().addingTimeInterval(60)
    let refusedWhileBusy = ledger.claimForPreparation(recordID: job.recordID, jobID: job.id)
    #expect(!refusedWhileBusy)
    ledger.appBusyUntil = nil
    let claimed = ledger.claimForPreparation(recordID: job.recordID, jobID: job.id)
    #expect(claimed)
    let duplicate = ledger.claimForPreparation(recordID: job.recordID, jobID: "another")
    #expect(!duplicate)
    #expect(ledger.heldRecordIDs.contains(job.recordID))
    ledger.jobs = [job]
    ledger.preparing = [:]
    #expect(ledger.heldRecordIDs.contains(job.recordID))
    let finished = result()
    ledger.finish(jobID: job.id, with: finished)
    #expect(ledger.heldRecordIDs.contains(finished.recordID))
    ledger.results.removeAll()
    #expect(ledger.heldRecordIDs.isEmpty)
  }

  @Test("Retry-After supports both seconds and HTTP dates")
  func transferRetryAfter() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(BackgroundUploadTransfers.Delegate.retryDelay("90", now: now) == 90)
    #expect(BackgroundUploadTransfers.Delegate.retryDelay("Thu, 01 Jan 1970 00:01:30 GMT", now: now) == 90)
    #expect(BackgroundUploadTransfers.Delegate.retryDelay("-5", now: now) == 0)
  }

  @Test("Concurrent 429s share a cooldown and a later 429 backs off further")
  func transferRateLimit() {
    var ledger = BackgroundUploadLedger()
    let now = Date()
    ledger.noteRateLimit(accountEmail: "a", retryAfter: 90, at: now)
    ledger.noteRateLimit(accountEmail: "a", retryAfter: 0, at: now.addingTimeInterval(1))
    #expect(ledger.isRateLimited(accountEmail: "a", at: now.addingTimeInterval(89)))
    #expect(!ledger.isRateLimited(accountEmail: "b", at: now))
    let next = now.addingTimeInterval(90)
    #expect(!ledger.isRateLimited(accountEmail: "a", at: next))
    ledger.noteRateLimit(accountEmail: "a", retryAfter: 0, at: next)
    #expect(ledger.isRateLimited(accountEmail: "a", at: next.addingTimeInterval(119)))
    #expect(!ledger.isRateLimited(accountEmail: "a", at: next.addingTimeInterval(120)))
  }

  @Test("Changes from separate stores of the same directory all land")
  func ledgerChangesAreSerialized() async {
    let directory = temporaryDirectory()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          BackgroundUploadLedgerStore(directory: directory).update { ledger in
            ledger.noteAttempt("record\(index)", reason: "test")
          }
        }
      }
    }
    #expect(BackgroundUploadLedgerStore(directory: directory).read().failures.count == 40)
  }

  @Test("An unreadable ledger starts over")
  func unreadableLedgerStartsOver() throws {
    let store = BackgroundUploadLedgerStore(directory: temporaryDirectory())
    try Data("not json".utf8).write(to: store.fileURL)
    #expect(store.read() == BackgroundUploadLedger())
    store.update { $0.appBusyUntil = Date(timeIntervalSince1970: 10) }
    #expect(store.read().appBusyUntil == Date(timeIntervalSince1970: 10))
  }

  @Test("The app counts as busy only until its mark lapses")
  func appBusyLapses() {
    var ledger = BackgroundUploadLedger()
    let now = Date()
    #expect(!ledger.appIsBusy(at: now))
    ledger.appBusyUntil = now.addingTimeInterval(60)
    #expect(ledger.appIsBusy(at: now))
    #expect(!ledger.appIsBusy(at: now.addingTimeInterval(61)))
  }

  @Test("Preparation, transfer, and a finished result hold an asset through extension handoff")
  func extensionOwnership() {
    var ledger = BackgroundUploadLedger()
    let now = Date()
    let job = job()
    let id = job.recordID
    let prepared = ledger.claimForPreparation(recordID: id, jobID: job.id, epoch: nil, at: now)
    #expect(prepared)
    let appWhilePreparing = ledger.claimForApp(id, at: now)
    #expect(!appWhilePreparing)
    let duplicate = ledger.claimForPreparation(recordID: id, jobID: "duplicate", epoch: nil, at: now)
    #expect(!duplicate)
    #expect(ledger.stagedJobIDs(at: now).contains(job.id))
    ledger.jobs.append(job)
    ledger.releasePreparation(id, jobID: job.id)
    let appWhileSending = ledger.claimForApp(id, at: now)
    #expect(!appWhileSending)
    ledger.finish(jobID: job.id, with: result())
    let appBeforeImport = ledger.claimForApp(id, at: now)
    #expect(!appBeforeImport)
    ledger.results = []
    let appAfterImport = ledger.claimForApp(id, at: now)
    #expect(appAfterImport)
  }

  @Test("A stale extension snapshot can't claim an asset after the app released it")
  func appOwnershipInvalidatesSnapshot() {
    var ledger = BackgroundUploadLedger()
    let now = Date()
    let generation = ledger.appWorkEpoch
    let appClaim = ledger.claimForApp("a", at: now)
    #expect(appClaim)
    let extensionWhileAppOwns = ledger.claimForPreparation(recordID: "a", jobID: "attempt", epoch: ledger.appWorkEpoch, at: now)
    #expect(!extensionWhileAppOwns)
    ledger.releaseAppClaim("a")
    let extensionWithStaleSnapshot = ledger.claimForPreparation(recordID: "a", jobID: "stale", epoch: generation, at: now)
    #expect(!extensionWithStaleSnapshot)
    let extensionAfterApp = ledger.claimForPreparation(recordID: "a", jobID: "fresh", epoch: ledger.appWorkEpoch, at: now)
    #expect(extensionAfterApp)
    let later = now.addingTimeInterval(11 * 60)
    #expect(!ledger.ownsPreparation(recordID: "a", jobID: "fresh", at: later))
    let appAfterExpiry = ledger.claimForApp("a", at: later)
    #expect(appAfterExpiry)
  }

  @Test("An expired job can be recovered once its commit lease ends")
  func expiredJobCanBeRecovered() {
    var job = job()
    let expiry = job.startedAt.addingTimeInterval(BackgroundUploadJob.abandonAfter)
    #expect(!job.hasExpired(at: expiry.addingTimeInterval(-1)))
    job.committingUntil = expiry.addingTimeInterval(1)
    #expect(!job.hasExpired(at: expiry))
    #expect(job.hasExpired(at: expiry.addingTimeInterval(1)))
  }

  @Test("An item that keeps failing is held back for a while, then tried again")
  func failuresHoldBack() {
    var ledger = BackgroundUploadLedger()
    let start = Date()
    for _ in 0..<BackgroundUploadLedger.maxAttempts - 1 {
      ledger.noteAttempt("a", reason: "x", at: start)
    }
    #expect(!ledger.isHeldBack("a", at: start))
    ledger.noteAttempt("a", reason: "x", at: start)
    #expect(ledger.isHeldBack("a", at: start.addingTimeInterval(60)))
    let later = start.addingTimeInterval(BackgroundUploadLedger.failureRetryInterval + 1)
    #expect(!ledger.isHeldBack("a", at: later))
    ledger.noteAttempt("a", reason: "x", at: later)
    #expect(ledger.failures["a"]?.count == 1)
  }

  @Test("Finishing a job leaves its result, replaces an older one and clears its failures")
  func finishingRecordsResult() {
    var ledger = BackgroundUploadLedger()
    let job = job()
    ledger.jobs = [job]
    ledger.results = [result(modifiedAt: Date(timeIntervalSince1970: 1))]
    ledger.noteAttempt(job.recordID, reason: "preparing")
    ledger.finish(jobID: job.id, with: result())
    #expect(ledger.jobs.isEmpty)
    #expect(ledger.results == [result()])
    #expect(ledger.failures[job.recordID] == nil)
    #expect(ledger.heldRecordIDs == [job.recordID])
  }

  @Test("A failed job keeps its attempt and says why")
  func failingExplains() {
    var ledger = BackgroundUploadLedger()
    let job = job()
    ledger.noteAttempt(job.recordID, reason: "preparing")
    ledger.jobs = [job]
    ledger.fail(jobID: job.id, reason: "HTTP 500")
    #expect(ledger.jobs.isEmpty)
    #expect(ledger.failures[job.recordID]?.count == 1)
    #expect(ledger.failures[job.recordID]?.reason == "HTTP 500")
  }

  @Test("Only one process commits a job until its claim lapses")
  func commitClaims() {
    var ledger = BackgroundUploadLedger()
    let job = job()
    ledger.jobs = [job]
    let now = Date()
    let firstClaim = ledger.claimForCommit(jobID: job.id, at: now)
    #expect(firstClaim?.commitWasAttempted == false)
    #expect(ledger.claimForCommit(jobID: job.id, at: now.addingTimeInterval(1)) == nil)
    let recoveredClaim = ledger.claimForCommit(jobID: job.id, at: now.addingTimeInterval(BackgroundUploadJob.claimDuration + 1))
    #expect(recoveredClaim?.commitWasAttempted == true)
    ledger.releaseCommitClaim(jobID: job.id)
    #expect(ledger.claimForCommit(jobID: job.id, at: now) != nil)
  }

  @Test("A job is settled once every part has an outcome")
  func settledParts() {
    var ledger = BackgroundUploadLedger()
    let job = job(parts: 2)
    ledger.jobs = [job]
    #expect(!ledger.jobs[0].isSettled)
    ledger.updatePart(jobID: job.id, index: 0) { $0.state = .sent }
    #expect(!ledger.jobs[0].isSettled)
    ledger.updatePart(jobID: job.id, index: 1) { $0.state = .failed }
    #expect(ledger.jobs[0].isSettled)
    // Out of range or unknown parts change nothing.
    ledger.updatePart(jobID: job.id, index: 2) { $0.state = .sending }
    ledger.updatePart(jobID: "other", index: 0) { $0.state = .sending }
    #expect(ledger.jobs[0].isSettled)
  }

  @Test("Staged copies no job refers to are removed")
  func abandonedStagingIsRemoved() throws {
    let store = BackgroundUploadLedgerStore(directory: temporaryDirectory())
    let kept = job()
    store.update { $0.jobs = [kept] }
    for id in [kept.id, "gone"] {
      try FileManager.default.createDirectory(at: store.stagingDirectory(forJob: id), withIntermediateDirectories: true)
    }
    store.removeAbandonedStaging()
    #expect(FileManager.default.fileExists(atPath: store.stagingDirectory(forJob: kept.id).path))
    #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory(forJob: "gone").path))
  }

  // MARK: - Transfers

  @Test("Task descriptions name a job's part")
  func taskDescriptions() {
    let description = BackgroundUploadTransfers.taskDescription(jobID: "job/with/slash", part: 1)
    let parsed = BackgroundUploadTransfers.part(fromTaskDescription: description)
    #expect(parsed?.jobID == "job/with/slash")
    #expect(parsed?.part == 1)
    #expect(BackgroundUploadTransfers.part(fromTaskDescription: "nothing") == nil)
    #expect(BackgroundUploadTransfers.part(fromTaskDescription: nil) == nil)
  }

  @Test("Only a 2xx with a finalize token completes a part")
  func transferOutcomes() {
    let token = finalizeToken()
    let delegate = BackgroundUploadTransfers.Delegate.self
    #expect(delegate.outcome(status: 200, body: token, error: nil).token == token)
    #expect(delegate.outcome(status: 200, body: Data("x".utf8), error: nil).error == "Unreadable upload response")
    #expect(delegate.outcome(status: 401, body: token, error: nil).error == "HTTP 401")
    let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    #expect(delegate.outcome(status: 0, body: Data(), error: timeout).token == nil)
  }

  // MARK: - Manifest

  @Test("An upload the extension made is recorded like one the app made")
  func importRecordsUpload() async throws {
    let directory = temporaryDirectory()
    let store = TransferManifestStore(fileURL: directory.appendingPathComponent("manifest.json"))
    let live = result(pairedSHA1: "dmlk")
    #expect(await store.recordBackgroundUpload(live) == .recorded)
    let record = try #require(await store.record(for: live.recordID))
    #expect(record.status == .sent)
    #expect(record.mediaKeysByAccount["me@example.com"] == "key")
    #expect(record.sentAccountEmails == ["me@example.com"])
    #expect(record.sha1 == "c2hh")
    #expect(record.pairedSourceSHA1 == "dmlk")
    #expect(record.assetModifiedAt == live.assetModifiedAt)
    #expect(record.assetLocalIdentifier == "asset")
    #expect(record.sentAt == live.finishedAt)
    #expect(record.foundInAccounts.isEmpty)
    // Recorded again: nothing to do.
    #expect(await store.recordBackgroundUpload(live) == .superseded)
    // Read from disk as the extension reads it.
    let stored = TransferManifestStore.storedRecords(fileURL: directory.appendingPathComponent("manifest.json"))
    #expect(stored[live.recordID]?.status == .sent)
  }

  @Test("An edit uploaded later replaces the earlier version, an older one doesn't")
  func importHonoursVersions() async throws {
    let store = TransferManifestStore(fileURL: temporaryDirectory().appendingPathComponent("manifest.json"))
    #expect(await store.recordBackgroundUpload(result(modifiedAt: Date(timeIntervalSince1970: 100))) == .recorded)
    #expect(await store.recordBackgroundUpload(result(modifiedAt: Date(timeIntervalSince1970: 50))) == .superseded)
    #expect(await store.recordBackgroundUpload(result(modifiedAt: Date(timeIntervalSince1970: 300))) == .recorded)
    let record = try #require(await store.record(for: result().recordID))
    #expect(record.assetModifiedAt == Date(timeIntervalSince1970: 300))
  }

  @Test("A completed upload persists immediately and a prepared hash survives an interrupted upload")
  func uploadRecovery() async throws {
    let url = temporaryDirectory().appendingPathComponent("manifest.json")
    let store = TransferManifestStore(fileURL: url)
    let email = "me@example.com"
    let item = result()
    await store.upsert(
      TransferRecord(
        id: item.recordID, filename: item.filename, mediaType: "Photo", status: .pending,
        assetLocalIdentifier: item.assetLocalIdentifier))
    #expect(await store.claimForUpload(id: item.recordID))
    let prepared = TransferRecord.PreparedAsset(
      modifiedAt: item.assetModifiedAt, hasAdjustments: true, adjustmentTimestamp: item.assetModifiedAt,
      sha1: item.sha1, motionSHA1: nil)
    await store.rememberPreparedAsset(id: item.recordID, asset: prepared)
    let recovered = TransferManifestStore(fileURL: url)
    let record = try #require(await recovered.record(for: item.recordID))
    #expect(record.status == .pending)
    #expect(record.preparedAsset == prepared)
    #expect(record.sentAccountEmails.isEmpty)
    #expect(await recovered.claimForUpload(id: item.recordID))
    #expect(
      await recovered.updateStatus(
        id: item.recordID, status: .sent, mediaKey: item.mediaKey, sha1: item.sha1,
        accountEmail: email, foundInAccount: true))
    let saved = try #require(TransferManifestStore.storedRecords(fileURL: url)[item.recordID])
    #expect(saved.preparedAsset == nil)
    #expect(saved.foundInAccounts == [email])
    #expect(saved.assetHadAdjustments == true)
    #expect(saved.assetAdjustmentTimestamp == item.assetModifiedAt)
    #expect(saved.hasBackedUpAsset(to: email, version: prepared.version))
    #expect(!saved.hasBackedUpAsset(to: "other@example.com", version: prepared.version))
    let editedAt = item.assetModifiedAt?.addingTimeInterval(1)
    let edited = TransferRecord.AssetVersion(modifiedAt: editedAt, hasAdjustments: true, adjustmentTimestamp: editedAt)
    #expect(!saved.hasBackedUpAsset(to: email, version: edited))
  }

  @Test("Only new adjustments, including reverts, invalidate a backed-up rendition")
  func assetContentVersions() {
    let upload = Date(timeIntervalSince1970: 100)
    let change = upload.addingTimeInterval(60)
    let firstEdit = upload.addingTimeInterval(-10)
    let original = TransferRecord.AssetVersion(modifiedAt: upload, hasAdjustments: false)
    let edited = TransferRecord.AssetVersion(modifiedAt: upload, hasAdjustments: true, adjustmentTimestamp: firstEdit)
    let receiptWithoutAdjustments = TransferRecord.AssetVersion(modifiedAt: upload)
    let metadataOnly = TransferRecord.AssetVersion(modifiedAt: change, hasAdjustments: false)
    let editedMetadataOnly = TransferRecord.AssetVersion(
      modifiedAt: change, hasAdjustments: true, adjustmentTimestamp: firstEdit)
    let newEdit = TransferRecord.AssetVersion(modifiedAt: change, hasAdjustments: true, adjustmentTimestamp: change)
    let revert = TransferRecord.AssetVersion(modifiedAt: change, hasAdjustments: false, adjustmentTimestamp: change)

    #expect(!metadataOnly.contentChanged(since: original))
    #expect(!metadataOnly.contentChanged(since: receiptWithoutAdjustments))
    #expect(!editedMetadataOnly.contentChanged(since: edited))
    #expect(!editedMetadataOnly.contentChanged(since: receiptWithoutAdjustments))
    #expect(newEdit.contentChanged(since: original))
    #expect(newEdit.contentChanged(since: edited))
    #expect(revert.contentChanged(since: edited))
    #expect(revert.contentChanged(since: receiptWithoutAdjustments))
    #expect(!revert.contentChanged(since: original))
    #expect(TransferRecord.AssetVersion(modifiedAt: change, hasAdjustments: true).contentChanged(since: edited))
  }

  @Test("The unedited original keeps its own receipt across edits and reverts")
  func originalBackupIsIndependent() {
    let account = "me@example.com"
    let upload = Date(timeIntervalSince1970: 100)
    let later = upload.addingTimeInterval(60)
    let record = TransferRecord(
      id: "\(account)|asset#original", filename: "original.heic", mediaType: "Photo", status: .sent,
      sentAccountEmails: [account], assetModifiedAt: upload, assetHadAdjustments: true, assetAdjustmentTimestamp: upload,
      resourceRole: .uneditedOriginal)
    let changed = TransferRecord.AssetVersion(modifiedAt: later, hasAdjustments: false, adjustmentTimestamp: later)
    #expect(record.hasBackedUpAsset(to: account, version: changed))
    #expect(!record.hasBackedUpAsset(to: "other@example.com", version: changed))
  }

  @Test("A result for a record the app is sending waits")
  func importDefersWhileSending() async throws {
    let store = TransferManifestStore(fileURL: temporaryDirectory().appendingPathComponent("manifest.json"))
    let id = result().recordID
    await store.upsert(TransferRecord(id: id, filename: "IMG_0001.HEIC", mediaType: "Photo", status: .pending))
    #expect(await store.claimForUpload(id: id))
    #expect(await store.recordBackgroundUpload(result()) == .deferred)
    #expect(await store.releaseUploadClaim(id: id))
    #expect(await store.recordBackgroundUpload(result(uploaded: false)) == .recorded)
    let record = try #require(await store.record(for: id))
    #expect(record.lastError == "Deduplicated (Already in Google Photos)")
    #expect(record.pairedSourceSHA1 == nil)
  }

  @Test("An item the account already held isn't removed unless found items may be")
  func importedFoundItemsAreKept() async throws {
    let store = TransferManifestStore(fileURL: temporaryDirectory().appendingPathComponent("manifest.json"))
    #expect(await store.recordBackgroundUpload(result(uploaded: false)) == .recorded)
    #expect(await store.record(for: result().recordID)?.foundInAccounts == ["me@example.com"])
    #expect(
      await store.eligibleForDeletion(delay: .immediately, smartDelete: false, accountEmail: "me@example.com").isEmpty)
    #expect(
      await store.eligibleForDeletion(
        delay: .immediately, smartDelete: false, accountEmail: "me@example.com", includesFoundItems: true
      ).count == 1)
  }

  @Test("A record removed from the library isn't brought back")
  func importLeavesDeletedRecords() async throws {
    let store = TransferManifestStore(fileURL: temporaryDirectory().appendingPathComponent("manifest.json"))
    #expect(await store.recordBackgroundUpload(result()) == .recorded)
    #expect(await store.markDeleted(id: result().recordID))
    #expect(await store.recordBackgroundUpload(result(modifiedAt: Date(timeIntervalSince1970: 900))) == .superseded)
    #expect(await store.record(for: result().recordID)?.status == .deleted)
  }

  @Test("Reading the manifest from another process leaves an unreadable file in place")
  func storedRecordsLeavesUnreadableFile() throws {
    let url = temporaryDirectory().appendingPathComponent("manifest.json")
    try Data("{".utf8).write(to: url)
    #expect(TransferManifestStore.storedRecords(fileURL: url).isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }
}
