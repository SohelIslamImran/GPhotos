import Foundation
import os

public actor TransferManifestStore {
  public static let shared = TransferManifestStore()

  private var records: [String: TransferRecord] = [:] {
    didSet {
      revision &+= 1
      sortedCache = nil
    }
  }
  /// Bumped on every change, so readers can skip copying and comparing an unchanged manifest.
  private var revision = 0
  private var sortedCache: [TransferRecord]?
  private var deletionClaims = Set<String>()
  private var deletionClaimSnapshots: [String: Set<String>] = [:]
  private var invalidatedDeletionClaims = Set<String>()
  private var recordIDsBySHA1: [String: Set<String>] = [:]
  /// Asset-ID and case-folded path keys, so resource checks touch only a record's mates
  /// instead of scanning the whole manifest per record.
  private var recordIDsByResource: [String: Set<String>] = [:]
  /// Records changed since the last write. Each is appended to the journal as its
  /// current state, or as a removal once it is gone.
  private var dirtyIDs = Set<String>()
  /// A full snapshot is owed: a bulk change, a failed append or no snapshot on disk yet.
  private var needsSnapshot = false
  private var flushTask: Task<Void, Never>?
  private let fileURL: URL
  /// Changes since the snapshot, one JSON line each, after a header naming the snapshot
  /// they extend. Rewriting a large manifest for every change cost a full encode per
  /// write, so changes are appended and the snapshot is rewritten only once the journal
  /// outgrows it.
  private let journalURL: URL
  private var snapshotToken: String?
  private var snapshotSize = 0
  /// Whether the journal on disk extends the current snapshot, so appends may go to it.
  private var journalIsCurrent = false
  private var journalSize = 0
  private let lineEncoder = JSONEncoder()
  private var retentionDelay: AutoDeleteDelay
  /// Bumped whenever records are removed. A scan that reads only what changed relies on
  /// the manifest still holding every version it skipped, so a removal sends the next
  /// one back to reading everything.
  public private(set) var removalCount = 0

  /// Accounts whose records were purged. Whatever read the account before that (a scan, an
  /// import) must not write it back.
  private var removedAccounts = Set<String>()

  private var needsPersistence: Bool { needsSnapshot || !dirtyIDs.isEmpty }

  public static var defaultFileURL: URL {
    AppGroupConstants.storageDirectory().appendingPathComponent("transfer-manifest.json")
  }

  /// Only names the files: the manifest is read on the actor the first time it is used, so
  /// creating the store (during app launch, on the main thread) costs nothing.
  public init(fileURL: URL? = nil) {
    let url = fileURL ?? Self.defaultFileURL
    self.fileURL = url
    self.journalURL = url.appendingPathExtension("journal")
    self.retentionDelay = AppSettingsStore.load().autoDeleteDelay
  }

  private var isLoaded = false

  /// Reads the manifest now rather than at its first use.
  public func load() { loadIfNeeded() }

  private func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    Self.removeAbandonedSnapshots(beside: fileURL)
    let stored = Self.load(from: fileURL, journalURL: journalURL)
    var loaded = Self.deduplicate(stored.records)
    var needsNormalization = loaded.didDeduplicate
    for (id, record) in loaded.records {
      if record.status == .sending {
        var recovered = record
        recovered.status = .pending
        recovered.progress = 0
        recovered.transferredByteCount = 0
        loaded.records[id] = recovered
        needsNormalization = true
      } else if record.status == .sent {
        let deleteAfter = Self.deleteAfterDate(sentAt: record.sentAt, delay: retentionDelay)
        if deleteAfter != record.deleteAfter {
          var rescheduled = record
          rescheduled.deleteAfter = deleteAfter
          loaded.records[id] = rescheduled
          needsNormalization = true
        }
      }
    }
    self.records = loaded.records
    (self.recordIDsBySHA1, self.recordIDsByResource) = Self.makeIndexes(loaded.records)
    self.snapshotToken = stored.snapshotToken
    self.snapshotSize = stored.snapshotSize
    self.journalIsCurrent = stored.journalSize > 0
    self.journalSize = stored.journalSize
    // Without a token there is nothing to append to; a torn journal can't take appends.
    self.needsSnapshot = stored.snapshotToken == nil || stored.journalIsTorn
    if needsNormalization,
      let written = Self.writeSnapshot(Array(loaded.records.values), to: fileURL, encoder: JSONEncoder())
    {
      self.snapshotToken = written.token
      self.snapshotSize = written.size
      self.journalIsCurrent = false
      self.journalSize = 0
      try? FileManager.default.removeItem(at: journalURL)
      self.needsSnapshot = false
    } else if needsNormalization {
      self.needsSnapshot = true
    }
  }

  public func allRecords() -> [TransferRecord] {
    loadIfNeeded()
    if needsPersistence, flushTask == nil {
      flush()
    }
    return sortedCache ?? Array(records.values)
  }

  /// Newest first, for display. Internal sweeps use `allRecords()` and skip the sort.
  /// Sorted by key rather than by moving whole records, and ties broken by ID so rows
  /// keep their order between refreshes.
  public func sortedRecords() -> [TransferRecord] {
    loadIfNeeded()
    if let sortedCache { return sortedCache }
    var order: [(id: String, date: Double)] = records.map { id, record in
      (id, record.creationDate?.timeIntervalSinceReferenceDate ?? -Double.infinity)
    }
    order.sort { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    let sorted = order.compactMap { records[$0.id] }
    sortedCache = sorted
    return sorted
  }

  public func purgeSortedCache() { sortedCache = nil }

  /// `sortedRecords()` with the revision it reflects, or nil while the manifest is still
  /// at `revision`.
  public func sortedRecords(ifChangedSince revision: Int?) -> (revision: Int, records: [TransferRecord])? {
    loadIfNeeded()
    if needsPersistence, flushTask == nil {
      flush()
    }
    guard revision != self.revision else { return nil }
    return (self.revision, sortedRecords())
  }

  /// The records stored under these IDs; IDs with none are left out.
  public func records(withIDs ids: [String]) -> [String: TransferRecord] {
    loadIfNeeded()
    var found: [String: TransferRecord] = [:]
    for id in ids {
      if let record = records[id] { found[id] = record }
    }
    return found
  }

  public func record(for id: String) -> TransferRecord? {
    loadIfNeeded()
    return records[id]
  }

  func rememberPreparedAsset(id: String, asset: TransferRecord.PreparedAsset) {
    loadIfNeeded()
    guard var record = records[id], record.status == .sending, record.assetLocalIdentifier != nil,
      record.preparedAsset != asset
    else { return }
    record.preparedAsset = asset
    records[id] = record
    _ = commit([id], critical: true)
  }

  /// Finds a completed upload for a SHA-1 in a specific account and returns the
  /// media key that account received. Keys are per-account, never shared.
  public func uploadedMediaKey(
    forSHA1 sha1: String, accountEmail: String
  ) -> (mediaKey: String, pairedSourceSHA1: String?, foundInAccount: Bool)? {
    loadIfNeeded()
    guard let ids = recordIDsBySHA1[sha1] else { return nil }
    // Newest first so the answer is stable when several records share a hash.
    for id in ids.sorted(by: { (records[$0]?.sentAt ?? .distantPast) > (records[$1]?.sentAt ?? .distantPast) }) {
      guard let record = records[id],
        record.status == .sent || record.status == .deleted,
        record.sentAccountEmails.contains(accountEmail),
        let key = record.mediaKeysByAccount[accountEmail],
        !key.isEmpty
      else { continue }
      return (
        mediaKey: key, pairedSourceSHA1: record.pairedSourceSHA1,
        foundInAccount: record.foundInAccounts.contains(accountEmail)
      )
    }
    return nil
  }

  private static func deduplicate(
    _ input: [String: TransferRecord]
  ) -> (records: [String: TransferRecord], didDeduplicate: Bool) {
    enum Location: Hashable {
      case path(String)
      case asset(String, AssetResourceRole)
      case shared
    }
    enum Key: Hashable {
      case fingerprint(account: String, sha1: String, location: Location)
      case file(account: String, path: String, size: Int64, modified: Int64)
    }
    var firstIDs: [Key: String] = [:]
    var groups: [String: [String]] = [:]
    for (id, record) in input {
      let account = TransferRecord.accountEmail(fromScopedID: id) ?? record.sentAccountEmails.sorted().first ?? ""
      let key: Key
      if let fingerprint = record.sha1 ?? record.sourceSHA1 {
        // Content alone does not make two records the same file: a folder copy and a
        // share-sheet copy of identical bytes are separate files that both need a
        // record, and so are two library photos with the same bytes. Only shared queue
        // entries may merge on content.
        let location: Location =
          if let path = record.sourcePath {
            // Case-folded to match `sameResource` and the cleanup path checks, so two
            // spellings of one file still land in the same group.
            .path(standardizedPath(path).lowercased())
          } else if let asset = record.assetLocalIdentifier {
            .asset(asset, record.resourceRole)
          } else {
            .shared
          }
        key = .fingerprint(account: account, sha1: fingerprint, location: location)
      } else if let path = record.sourcePath {
        let size = record.sourceFileSize ?? record.byteCount ?? 0
        let modified = record.sourceModifiedAt.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        key = .file(account: account, path: standardizedPath(path).lowercased(), size: size, modified: modified)
      } else {
        continue
      }
      if let first = firstIDs[key] {
        groups[first, default: [first]].append(id)
      } else {
        firstIDs[key] = id
      }
    }

    guard !groups.isEmpty else { return (input, false) }
    firstIDs.removeAll()
    var result = input
    var changed = false
    for ids in groups.values where ids.count > 1 {
      let keepID = ids.sorted { lhs, rhs in
        guard let left = result[lhs], let right = result[rhs] else { return lhs < rhs }
        let leftRank = preference(left)
        let rightRank = preference(right)
        return leftRank == rightRank ? lhs < rhs : leftRank > rightRank
      }.first
      guard let keepID, var merged = result[keepID] else { continue }
      for id in ids where id != keepID {
        guard let duplicate = result[id] else { continue }
        merged = merge(merged, duplicate)
        result.removeValue(forKey: id)
        changed = true
      }
      result[keepID] = merged
    }
    return (result, changed)
  }

  /// `URL(fileURLWithPath:).standardizedFileURL.path`, without making a URL (which checks
  /// the disk for a directory) for a path that's already standard, as nearly all are:
  /// this runs for every record at launch.
  static func standardizedPath(_ path: String) -> String {
    let isStandard =
      path.hasPrefix("/") && !path.hasPrefix("/private/") && !path.contains("/.") && !path.contains("//")
      && !path.contains("\0") && (path.count == 1 || !path.hasSuffix("/"))
    return isStandard ? path : URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func preference(_ record: TransferRecord) -> Int {
    var value = 0
    if record.status == .sent { value += 8 }
    if record.status == .deleted { value += 4 }
    if record.sourcePath != nil { value += 2 }
    if TransferRecord.accountEmail(fromScopedID: record.id) != nil { value += 4 }
    if !record.mediaKeysByAccount.isEmpty { value += 1 }
    return value
  }

  private static func merge(_ base: TransferRecord, _ other: TransferRecord) -> TransferRecord {
    var result = base
    if result.filename.isEmpty { result.filename = other.filename }
    if result.mediaType.isEmpty { result.mediaType = other.mediaType }
    result.creationDate = result.creationDate ?? other.creationDate
    if !result.isTerminalSuccess && other.isTerminalSuccess { result.status = other.status }
    result.progress = max(result.progress, other.progress)
    result.byteCount = result.byteCount ?? other.byteCount
    result.transferredByteCount = max(result.transferredByteCount, other.transferredByteCount)
    result.attempts = result.isTerminalSuccess ? 0 : max(result.attempts, other.attempts)
    result.lastFailedAt = [result.lastFailedAt, other.lastFailedAt].compactMap { $0 }.max()
    result.sentAt = [result.sentAt, other.sentAt].compactMap { $0 }.max()
    result.deletedAt = [result.deletedAt, other.deletedAt].compactMap { $0 }.max()
    result.deleteAfter = [result.deleteAfter, other.deleteAfter].compactMap { $0 }.min()
    result.sentAccountEmails.formUnion(other.sentAccountEmails)
    result.mediaKeysByAccount = result.mediaKeysByAccount.merging(other.mediaKeysByAccount) { current, _ in current }
    // Either copy having found the bytes in an account is enough to hold back deletion.
    result.foundInAccounts.formUnion(other.foundInAccounts)
    result.sha1 = result.sha1 ?? other.sha1
    if !result.isTerminalSuccess || result.lastError != nil { result.lastError = result.lastError ?? other.lastError }
    result.sourcePath = result.sourcePath ?? other.sourcePath
    result.pairedSourcePath = result.pairedSourcePath ?? other.pairedSourcePath
    result.assetLocalIdentifier = result.assetLocalIdentifier ?? other.assetLocalIdentifier
    result.assetModifiedAt = result.assetModifiedAt ?? other.assetModifiedAt
    result.sharedEntryID = result.sharedEntryID ?? other.sharedEntryID
    result.sourceFileSize = result.sourceFileSize ?? other.sourceFileSize
    result.sourceModifiedAt = result.sourceModifiedAt ?? other.sourceModifiedAt
    result.sourceSHA1 = result.sourceSHA1 ?? other.sourceSHA1
    result.pairedSourceFileSize = result.pairedSourceFileSize ?? other.pairedSourceFileSize
    result.pairedSourceModifiedAt = result.pairedSourceModifiedAt ?? other.pairedSourceModifiedAt
    result.pairedSourceSHA1 = result.pairedSourceSHA1 ?? other.pairedSourceSHA1
    result.resourcesChecked = result.resourcesChecked || other.resourcesChecked
    // A record is either deleted or it is not. Folding a `.deleted` sibling into a
    // `.sent` winner used to leave `deletedAt` set, so cleanup retried a file that no
    // longer existed on every run.
    if result.status != .deleted { result.deletedAt = nil }
    return result
  }

  private static func makeIndexes(
    _ records: [String: TransferRecord]
  ) -> (sha1: [String: Set<String>], resource: [String: Set<String>]) {
    var sha1Index: [String: Set<String>] = [:]
    var resourceIndex: [String: Set<String>] = [:]
    for record in records.values {
      if let sha1 = record.sha1 { sha1Index[sha1, default: []].insert(record.id) }
      for key in resourceKeys(record) { resourceIndex[key, default: []].insert(record.id) }
    }
    return (sha1Index, resourceIndex)
  }

  private func rebuildIndexes() {
    (recordIDsBySHA1, recordIDsByResource) = Self.makeIndexes(records)
  }

  /// Every key under which `sameResource` could match this record: its asset ID and
  /// its folded source path.
  private static func resourceKeys(_ record: TransferRecord) -> [String] {
    var keys: [String] = []
    if let assetID = record.assetLocalIdentifier { keys.append("asset:\(assetID)") }
    if let path = record.sourcePath { keys.append("path:\(path.folding(options: .caseInsensitive, locale: nil))") }
    return keys
  }

  private func removeFromIndexes(_ record: TransferRecord?) {
    guard let record else { return }
    if let sha1 = record.sha1 {
      recordIDsBySHA1[sha1]?.remove(record.id)
      if recordIDsBySHA1[sha1]?.isEmpty == true {
        recordIDsBySHA1.removeValue(forKey: sha1)
      }
    }
    for key in Self.resourceKeys(record) {
      recordIDsByResource[key]?.remove(record.id)
      if recordIDsByResource[key]?.isEmpty == true {
        recordIDsByResource.removeValue(forKey: key)
      }
    }
  }

  private func addToIndexes(_ record: TransferRecord) {
    if let sha1 = record.sha1 { recordIDsBySHA1[sha1, default: []].insert(record.id) }
    for key in Self.resourceKeys(record) { recordIDsByResource[key, default: []].insert(record.id) }
  }

  /// Records `sameResource` matches with `record`, including itself when stored.
  private func resourceMates(of record: TransferRecord) -> [TransferRecord] {
    var ids = Set<String>()
    for key in Self.resourceKeys(record) {
      if let bucket = recordIDsByResource[key] { ids.formUnion(bucket) }
    }
    return ids.compactMap { records[$0] }.filter { sameResource($0, record) }
  }

  @discardableResult
  public func upsert(_ record: TransferRecord) -> Bool {
    loadIfNeeded()
    guard let record = withoutRemovedAccounts(record) else { return false }
    if hasDeletionClaim(for: record) {
      invalidateDeletionClaim(for: record)
      return false
    }
    if let existing = records[record.id],
      existing.status == .sending,
      record.status != .sending
    {
      return false
    }
    if records[record.id]?.isSkipped == true { return false }
    let previous = records[record.id]
    removeFromIndexes(previous)
    records[record.id] = record
    addToIndexes(record)
    guard commit([record.id], critical: record.isTerminalSuccess) else {
      if let previous {
        records[record.id] = previous
      } else {
        records.removeValue(forKey: record.id)
      }
      rebuildIndexes()
      return false
    }
    return true
  }

  @discardableResult
  public func upsertBatch(
    _ newRecords: [TransferRecord], ifUnchangedSince snapshot: [String: TransferRecord]? = nil
  ) -> Bool {
    loadIfNeeded()
    let newRecords = newRecords.compactMap(withoutRemovedAccounts)
    guard !newRecords.isEmpty else { return true }
    if let blocked = newRecords.first(where: { hasDeletionClaim(for: $0) }) {
      invalidateDeletionClaim(for: blocked)
      return false
    }
    let previous = records
    var critical = false
    for record in newRecords {
      if records[record.id]?.isSkipped == true { continue }
      // A scan can suspend after reading its records while an extension result is
      // imported. Its old pending state must not overwrite that completed upload.
      if let snapshot, records[record.id] != snapshot[record.id] { continue }
      if let existing = records[record.id],
        existing.status == .sending,
        record.status != .sending
      {
        continue
      }
      removeFromIndexes(records[record.id])
      records[record.id] = record
      addToIndexes(record)
      critical = critical || record.isTerminalSuccess
    }
    guard commit(newRecords.map(\.id), critical: critical) else {
      records = previous
      rebuildIndexes()
      return false
    }
    return true
  }

  @discardableResult
  public func updateStatus(
    id: String,
    status: TransferStatus,
    progress: Double? = nil,
    transferredBytes: Int64? = nil,
    mediaKey: String? = nil,
    sha1: String? = nil,
    pairedSHA1: String? = nil,
    clearsPairedSHA1: Bool = false,
    accountEmail: String? = nil,
    foundInAccount: Bool = false,
    deleteAfter: Date? = nil,
    error: String? = nil
  ) -> Bool {
    loadIfNeeded()
    guard var rec = records[id] else { return false }
    guard !hasDeletionClaim(for: rec) else { return false }
    let previous = rec
    rec.status = status
    if let progress { rec.progress = progress }
    if let transferredBytes { rec.transferredByteCount = transferredBytes }
    if let sha1 { rec.sha1 = sha1 }
    // A folder file is hashed in place, so the hash it went up under is its source hash,
    // which a later delete verifies the file against. Library exports and the app's own
    // copies record theirs elsewhere.
    if status == .sent, let sha1, rec.sourcePath != nil, rec.assetLocalIdentifier == nil, rec.sourceSHA1 == nil {
      rec.sourceSHA1 = sha1
    }
    if clearsPairedSHA1 {
      rec.pairedSourceSHA1 = nil
    } else if let pairedSHA1 {
      rec.pairedSourceSHA1 = pairedSHA1
    }
    if let deleteAfter { rec.deleteAfter = deleteAfter }
    if let error { rec.lastError = error }
    if status == .sent {
      if let prepared = rec.preparedAsset, sha1 == prepared.sha1, pairedSHA1 == prepared.motionSHA1 {
        rec.assetModifiedAt = prepared.modifiedAt
        rec.assetHadAdjustments = prepared.hasAdjustments
        rec.assetAdjustmentTimestamp = prepared.adjustmentTimestamp
      }
      rec.preparedAsset = nil
      rec.sentAt = Date()
      rec.attempts = 0
      if let error {
        rec.lastError = error
      } else {
        rec.lastError = nil
      }
      if let email = accountEmail {
        rec.sentAccountEmails.insert(email)
        if let mediaKey {
          rec.mediaKeysByAccount[email] = mediaKey
        }
        if foundInAccount {
          rec.foundInAccounts.insert(email)
        } else {
          rec.foundInAccounts.remove(email)
        }
      }
      if deleteAfter == nil {
        rec.deleteAfter = Self.deleteAfterDate(sentAt: rec.sentAt, delay: retentionDelay)
      }
    } else if status == .failed {
      rec.attempts += 1
      rec.lastFailedAt = Date()
    } else if status == .deleted {
      rec.deletedAt = Date()
    }
    removeFromIndexes(records[id])
    records[id] = rec
    addToIndexes(rec)
    // The extension reads the receipt on disk before taking over this asset.
    guard commit([id], critical: rec.isTerminalSuccess || previous.status == .deleted) else {
      records[id] = previous
      rebuildIndexes()
      return false
    }
    return true
  }

  /// Notes that each record's asset resources have been read from PhotoKit, in place,
  /// so the scan's RAW lookup for an older upload runs once.
  public func markResourcesChecked(ids: [String]) {
    loadIfNeeded()
    var changed = false
    for id in ids {
      guard var record = records[id], !record.resourcesChecked else { continue }
      record.resourcesChecked = true
      records[id] = record
      changed = true
    }
    if changed { _ = commit(ids, critical: false) }
  }

  @discardableResult
  public func markDeleted(id: String) -> Bool {
    loadIfNeeded()
    guard var rec = records[id], rec.status == .sent else { return false }
    if deletionClaims.contains(id), !deletionClaimIsValid(id: id) { return false }
    let previous = rec
    rec.status = .deleted
    rec.deletedAt = Date()
    records[id] = rec
    guard commit([id], critical: true) else {
      records[id] = previous
      return false
    }
    return true
  }

  /// Marks every claimed, still-valid record deleted in one write, so a cleanup of many
  /// library items does not rewrite the manifest once per item. Returns the IDs marked;
  /// on a failed write nothing is.
  public func markDeleted(ids: [String]) -> Set<String> {
    loadIfNeeded()
    let previous = records
    let now = Date()
    var marked = Set<String>()
    for id in ids {
      guard var rec = records[id], rec.status == .sent, deletionClaimIsValid(id: id) else { continue }
      rec.status = .deleted
      rec.deletedAt = now
      records[id] = rec
      marked.insert(id)
    }
    guard !marked.isEmpty else { return [] }
    guard commit(marked, critical: true) else {
      records = previous
      return []
    }
    return marked
  }

  /// Reverses `markDeleted(ids:)` in one write. Returns false when the write fails.
  @discardableResult
  public func restoreSent(ids: [String]) -> Bool {
    loadIfNeeded()
    let previous = records
    var changed = false
    for id in ids {
      guard var rec = records[id], rec.status == .deleted else { continue }
      rec.status = .sent
      rec.deletedAt = nil
      records[id] = rec
      changed = true
    }
    guard changed else { return true }
    guard commit(ids, critical: true) else {
      records = previous
      return false
    }
    return true
  }

  @discardableResult
  public func claimForDeletion(id: String) -> Bool {
    loadIfNeeded()
    guard let rec = records[id],
      rec.status == .sent, !rec.isSkipped,
      !deletionClaims.contains(id),
      !hasCompetingResourceRecord(rec)
    else { return false }
    deletionClaims.insert(id)
    deletionClaimSnapshots[id] = Set(resourceMates(of: rec).map(\.id))
    return true
  }

  public func deletionClaimIsValid(id: String) -> Bool {
    loadIfNeeded()
    guard deletionClaims.contains(id),
      !invalidatedDeletionClaims.contains(id),
      let rec = records[id],
      let snapshot = deletionClaimSnapshots[id]
    else { return false }
    let currentIDs = Set(resourceMates(of: rec).map(\.id))
    guard currentIDs.isSubset(of: snapshot) else { return false }
    if rec.status == .sent {
      return !hasCompetingResourceRecord(rec)
    }
    return rec.status == .deleted
  }

  @discardableResult
  public func releaseDeletionClaim(id: String) -> Bool {
    loadIfNeeded()
    deletionClaimSnapshots.removeValue(forKey: id)
    invalidatedDeletionClaims.remove(id)
    return deletionClaims.remove(id) != nil
  }

  private func invalidateDeletionClaim(for record: TransferRecord) {
    invalidatedDeletionClaims.formUnion(
      resourceMates(of: record).map(\.id).filter { deletionClaims.contains($0) })
  }

  private nonisolated static func deletionTombstoneURL(
    for url: URL,
    size: Int64?,
    modifiedAt: Date?,
    token: String
  ) -> URL {
    let sizeToken = size.map(String.init) ?? "unknown"
    let modifiedToken = modifiedAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "unknown"
    return url.deletingLastPathComponent().appendingPathComponent(
      "\(deletionTombstonePrefix)\(token)-\(sizeToken)-\(modifiedToken)-\(url.lastPathComponent)"
    )
  }

  /// `mayRemove` is asked with nothing suspended in between right before each file moves
  /// and again, on the moved files, before the record is marked deleted: a no puts
  /// everything back.
  @discardableResult
  public func deleteSourceFiles(
    id: String,
    fileURL: URL,
    pairedFileURL: URL? = nil,
    releaseClaim: Bool = true,
    mayRemove: @Sendable ([URL]) -> Bool = { _ in true }
  ) async -> Bool {
    loadIfNeeded()
    defer {
      if releaseClaim {
        releaseDeletionClaim(id: id)
      }
    }
    guard deletionClaimIsValid(id: id),
      let record = records[id],
      record.status == .sent,
      record.sourceSHA1 != nil,
      Self.isSameFile(fileURL, path: record.sourcePath)
    else { return false }

    var sides = [
      SourceSide(url: fileURL, size: record.sourceFileSize, modifiedAt: record.sourceModifiedAt, sha1: record.sourceSHA1)
    ]
    if let pairedFileURL {
      guard record.pairedSourceSHA1 != nil, Self.isSameFile(pairedFileURL, path: record.pairedSourcePath) else { return false }
      sides.append(
        SourceSide(
          url: pairedFileURL, size: record.pairedSourceFileSize, modifiedAt: record.pairedSourceModifiedAt, sha1: record.pairedSourceSHA1))
    }
    // Metadata only here; the content hash runs once the files sit in their tombstones,
    // where no writer addressing the original path can change them.
    guard sides.allSatisfy({ Self.matchesSourceContent(url: $0.url, size: $0.size, modifiedAt: $0.modifiedAt, sha1: nil) }) else {
      return false
    }

    let token = UUID().uuidString
    var moved: [(original: URL, tombstone: URL)] = []
    for side in sides {
      guard mayRemove(sides.map(\.url).filter { url in !moved.contains { $0.original == url } } + moved.map(\.tombstone)) else {
        Self.restoreTombstones(moved)
        return false
      }
      let tombstone = Self.deletionTombstoneURL(for: side.url, size: side.size, modifiedAt: side.modifiedAt, token: token)
      do {
        try FileManager.default.moveItem(at: side.url, to: tombstone)
      } catch {
        Self.restoreTombstones(moved)
        return false
      }
      moved.append((side.url, tombstone))
    }

    var verified = true
    for (side, entry) in zip(sides, moved) where verified {
      verified = await Self.verifyContent(url: entry.tombstone, size: side.size, modifiedAt: side.modifiedAt, sha1: side.sha1)
    }
    // Re-checked after the hashing suspension: the claim may have been invalidated meanwhile.
    guard verified, deletionClaimIsValid(id: id), mayRemove(moved.map(\.tombstone)), markDeleted(id: id) else {
      Self.restoreTombstones(moved)
      return false
    }
    // Writing the record takes a moment, and a change made meanwhile still puts it back.
    guard mayRemove(moved.map(\.tombstone)) else {
      // The files go back even if the record can't: they must never be left hidden.
      if !restoreSent(ids: [id]) { restoreSent(ids: [id]) }
      Self.restoreTombstones(moved)
      return false
    }
    for entry in moved {
      try? FileManager.default.removeItem(at: entry.tombstone)
    }
    return true
  }

  private struct SourceSide {
    let url: URL
    let size: Int64?
    let modifiedAt: Date?
    let sha1: String?
  }

  private nonisolated static func restoreTombstones(_ moved: [(original: URL, tombstone: URL)]) {
    for entry in moved {
      try? FileManager.default.moveItem(at: entry.tombstone, to: entry.original)
    }
  }

  /// Tombstones left behind by an interrupted delete, for one side of a record.
  /// Lives here because the store owns the naming scheme; both app targets recover
  /// through this so a format change cannot silently strand files in user folders.
  public nonisolated static func pendingTombstones(
    forRecordPath path: String,
    size: Int64?,
    modifiedAt: Date?
  ) -> [URL] {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return pendingTombstones(forRecordPath: path, size: size, modifiedAt: modifiedAt, among: names)
  }

  /// Every name in a listing of the directory that would hold a deletion tombstone.
  public static let deletionTombstonePrefix = ".gphotos-delete-"

  /// `pendingTombstones(forRecordPath:size:modifiedAt:)` against `names`, a listing of
  /// the file's directory already taken, so a directory holding many records is listed
  /// once.
  public nonisolated static func pendingTombstones(
    forRecordPath path: String,
    size: Int64?,
    modifiedAt: Date?,
    among names: [String]
  ) -> [URL] {
    let original = URL(fileURLWithPath: path)
    let sizeToken = size.map(String.init) ?? "unknown"
    let modifiedToken = modifiedAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "unknown"
    let suffix = "-\(original.lastPathComponent)"
    let stamp = "-\(sizeToken)-\(modifiedToken)-"
    let directory = original.deletingLastPathComponent()
    return names.filter {
      $0.hasPrefix(deletionTombstonePrefix) && $0.hasSuffix(suffix) && $0.contains(stamp)
    }.map { directory.appendingPathComponent($0) }
  }

  @discardableResult
  public func restoreTombstoneIfSafe(
    id: String,
    path: String,
    tombstone: URL
  ) async -> Bool {
    loadIfNeeded()
    guard let record = records[id], record.status == .sent else { return false }
    // The destination is a write target, so it must be one of this record's own
    // source paths rather than whatever the caller passed in.
    let isPaired = record.pairedSourcePath == path
    guard isPaired || record.sourcePath == path else { return false }
    let size = isPaired ? record.pairedSourceFileSize : record.sourceFileSize
    let modifiedAt = isPaired ? record.pairedSourceModifiedAt : record.sourceModifiedAt
    let sha1 = isPaired ? record.pairedSourceSHA1 : record.sourceSHA1
    guard sha1 != nil else { return false }
    let original = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: original.path),
      await Self.verifyContent(url: tombstone, size: size, modifiedAt: modifiedAt, sha1: sha1),
      let current = records[id], current.status == .sent,
      !hasCompetingResourceRecord(current),
      !FileManager.default.fileExists(atPath: original.path)
    else { return false }
    do {
      try FileManager.default.moveItem(at: tombstone, to: original)
      return true
    } catch {
      return false
    }
  }

  private nonisolated static func isSameFile(_ url: URL, path: String?) -> Bool {
    guard let path else { return false }
    return URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL
  }

  /// Hashes off the actor so verifying a large video does not stall every other caller.
  @concurrent
  private nonisolated static func verifyContent(url: URL, size: Int64?, modifiedAt: Date?, sha1: String?) async -> Bool {
    matchesSourceContent(url: url, size: size, modifiedAt: modifiedAt, sha1: sha1)
  }

  private nonisolated static func matchesSourceContent(
    url: URL,
    size: Int64?,
    modifiedAt: Date?,
    sha1: String?
  ) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { return false }
    if let size {
      guard let actual = values.fileSize, Int64(actual) == size else { return false }
    }
    if let modifiedAt {
      guard let actual = values.contentModificationDate,
        abs(actual.timeIntervalSince(modifiedAt)) < 0.01
      else { return false }
    }
    if let sha1 {
      guard let data = try? GooglePhotosMobileClient.streamSHA1(fileURL: url) else { return false }
      return data.base64EncodedString() == sha1
    }
    return true
  }

  private func hasDeletionClaim(for record: TransferRecord) -> Bool {
    guard !deletionClaims.isEmpty else { return false }
    return deletionClaims.contains(record.id)
      || resourceMates(of: record).contains { deletionClaims.contains($0.id) }
  }

  @discardableResult
  public func restoreSent(id: String) -> Bool {
    loadIfNeeded()
    guard var rec = records[id], rec.status == .deleted else { return false }
    let previous = rec
    rec.status = .sent
    rec.deletedAt = nil
    records[id] = rec
    guard commit([id], critical: true) else {
      records[id] = previous
      return false
    }
    return true
  }

  /// A new version waiting to go up (an edit) of an item this account already holds,
  /// whose photo has left the library: nothing is left to send, so it's uploaded again,
  /// with the copy the account has.
  @discardableResult
  public func settleUnsentRevision(id: String, accountEmail: String) -> Bool {
    loadIfNeeded()
    guard var rec = records[id], rec.status == .pending, rec.sentAccountEmails.contains(accountEmail),
      rec.mediaKeysByAccount[accountEmail]?.isEmpty == false, !hasDeletionClaim(for: rec)
    else { return false }
    let previous = rec
    rec.status = .sent
    rec.progress = 1
    rec.lastError = nil
    removeFromIndexes(previous)
    records[id] = rec
    addToIndexes(rec)
    guard commit([id], critical: true) else {
      records[id] = previous
      rebuildIndexes()
      return false
    }
    return true
  }

  @discardableResult
  public func claimForUpload(id: String) -> Bool {
    loadIfNeeded()
    guard var rec = records[id], rec.status == .pending || rec.status == .failed else { return false }
    guard !hasDeletionClaim(for: rec), !rec.isSkipped else { return false }
    let previous = rec
    rec.status = .sending
    rec.progress = 0
    rec.transferredByteCount = 0
    rec.lastError = nil
    records[id] = rec
    guard commit([id], critical: false) else {
      records[id] = previous
      return false
    }
    return true
  }

  public func claimForUpload(ids: [String]) -> Set<String> {
    loadIfNeeded()
    guard !ids.isEmpty else { return [] }
    let previous = records
    var claimed = Set<String>()
    for id in ids {
      guard var record = records[id], record.status == .pending || record.status == .failed else { continue }
      guard !hasDeletionClaim(for: record), !record.isSkipped else { continue }
      record.status = .sending
      record.progress = 0
      record.transferredByteCount = 0
      record.lastError = nil
      records[id] = record
      claimed.insert(id)
    }
    guard commit(claimed, critical: false) else {
      records = previous
      rebuildIndexes()
      return []
    }
    return claimed
  }

  @discardableResult
  public func releaseUploadClaim(id: String) -> Bool {
    releaseUploadClaims(ids: [id]).contains(id)
  }

  @discardableResult
  public func releaseUploadClaims(ids: [String]) -> Set<String> {
    loadIfNeeded()
    var released = Set<String>()
    for id in ids {
      guard var record = records[id], record.status == .sending else { continue }
      record.status = .pending
      record.progress = 0
      record.transferredByteCount = 0
      records[id] = record
      released.insert(id)
    }
    if !released.isEmpty { _ = commit(released, critical: false) }
    return released
  }

  @discardableResult
  public func resetForResend(id: String, accountEmail: String? = nil) -> Bool {
    loadIfNeeded()
    guard var rec = records[id] else { return false }
    guard rec.status == .failed || rec.status == .pending || rec.status == .sent else { return false }
    guard !hasDeletionClaim(for: rec) else { return false }
    let previous = rec
    rec.status = .pending
    rec.progress = 0
    rec.transferredByteCount = 0
    rec.sentAt = nil
    rec.deletedAt = nil
    rec.deleteAfter = nil
    rec.lastError = nil
    if let accountEmail {
      rec.sentAccountEmails.remove(accountEmail)
      rec.mediaKeysByAccount.removeValue(forKey: accountEmail)
      rec.foundInAccounts.remove(accountEmail)
    }
    records[id] = rec
    guard commit([id], critical: previous.isTerminalSuccess) else {
      records[id] = previous
      return false
    }
    return true
  }

  /// Keeps failed items out of future scans and upload claims without touching their files.
  @discardableResult
  public func skipFailed(ids: [String]) -> Bool {
    loadIfNeeded()
    let previous = records
    var changed: [String] = []
    for id in ids {
      guard var record = records[id], record.status == .failed, !hasDeletionClaim(for: record) else { continue }
      record.isSkipped = true
      records[id] = record
      changed.append(id)
    }
    guard commit(changed, critical: true) else {
      records = previous
      return false
    }
    return true
  }

  @discardableResult
  public func remove(id: String) -> Bool {
    loadIfNeeded()
    deletionClaims.remove(id)
    deletionClaimSnapshots.removeValue(forKey: id)
    invalidatedDeletionClaims.remove(id)
    removeFromIndexes(records[id])
    if records.removeValue(forKey: id) != nil { removalCount += 1 }
    return commit([id], critical: true)
  }

  /// Removes a record that never finished, deciding on its state now rather than a copy read
  /// earlier: a record that has since started uploading, or that proves a copy, stays.
  @discardableResult
  public func removeIfUnfinished(id: String) -> Bool {
    loadIfNeeded()
    guard let record = records[id], record.status == .pending || record.status == .failed,
      record.sentAccountEmails.isEmpty, record.mediaKeysByAccount.isEmpty, !hasDeletionClaim(for: record)
    else { return false }
    return remove(id: id)
  }

  /// Nil for a removed account's own record; another's loses what it read of that account.
  private func withoutRemovedAccounts(_ record: TransferRecord) -> TransferRecord? {
    guard !removedAccounts.isEmpty else { return record }
    if let email = TransferRecord.accountEmail(fromScopedID: record.id), removedAccounts.contains(email) { return nil }
    var record = record
    record.sentAccountEmails.subtract(removedAccounts)
    record.foundInAccounts.subtract(removedAccounts)
    for email in removedAccounts { record.mediaKeysByAccount[email] = nil }
    return record
  }

  /// These accounts are configured, so one removed earlier and added again has records again.
  func acceptRecords(forAccountEmails emails: [String]) {
    removedAccounts.subtract(emails)
  }

  /// Removes the records scoped to the given account, so it no longer blocks deletion.
  /// With `keepingSent`, its finished copies stay (copying was only switched off), and
  /// only the unfinished ones, which would hold cleanup back forever, are dropped. Without
  /// it the account is gone: no writer adds records for it until it's configured again.
  @discardableResult
  public func removeRecords(forAccountEmail email: String, keepingSent: Bool = false) -> Bool {
    loadIfNeeded()
    if !keepingSent { removedAccounts.insert(email) }
    let idsToRemove = records.values.compactMap { rec -> String? in
      guard TransferRecord.accountEmail(fromScopedID: rec.id) == email else { return nil }
      if keepingSent, rec.status == .sent || rec.status == .deleted || rec.status == .sending { return nil }
      return rec.id
    }
    for id in idsToRemove {
      deletionClaims.remove(id)
      deletionClaimSnapshots.removeValue(forKey: id)
      invalidatedDeletionClaims.remove(id)
      removeFromIndexes(records[id])
      records.removeValue(forKey: id)
    }
    if !idsToRemove.isEmpty { removalCount += 1 }
    for (id, var rec) in records {
      // A finished copy that's kept keeps what proves it is in that account.
      if keepingSent, TransferRecord.accountEmail(fromScopedID: id) == email { continue }
      var changed = false
      if rec.sentAccountEmails.contains(email) {
        rec.sentAccountEmails.remove(email)
        changed = true
      }
      if rec.mediaKeysByAccount.removeValue(forKey: email) != nil {
        changed = true
      }
      if rec.foundInAccounts.remove(email) != nil {
        changed = true
      }
      if changed {
        records[id] = rec
      }
    }
    return commitAll()
  }

  @discardableResult
  public func clearAll() -> Bool {
    loadIfNeeded()
    deletionClaims.removeAll()
    deletionClaimSnapshots.removeAll()
    invalidatedDeletionClaims.removeAll()
    if !records.isEmpty { removalCount += 1 }
    records.removeAll()
    recordIDsBySHA1.removeAll()
    recordIDsByResource.removeAll()
    return commitAll()
  }

  /// Recomputes `deleteAfter` for records already uploaded. The delay is measured from each record's `sentAt`.
  @discardableResult
  public func setRetention(_ delay: AutoDeleteDelay) -> Bool {
    loadIfNeeded()
    retentionDelay = delay
    var changed: [String] = []
    for id in records.keys {
      guard var record = records[id], record.status == .sent else { continue }
      let deleteAfter = Self.deleteAfterDate(sentAt: record.sentAt, delay: delay)
      guard deleteAfter != record.deleteAfter else { continue }
      record.deleteAfter = deleteAfter
      records[id] = record
      changed.append(id)
    }
    return changed.isEmpty ? true : commit(changed, critical: true)
  }

  private static func deleteAfterDate(sentAt: Date?, delay: AutoDeleteDelay) -> Date? {
    guard let sentAt, let interval = delay.interval else { return nil }
    return sentAt.addingTimeInterval(interval)
  }

  public func eligibleForDeletion(
    delay: AutoDeleteDelay,
    smartDelete: Bool,
    accountEmail: String,
    accountEmails: Set<String> = [],
    excludingAccounts: Set<String> = [],
    includesFoundItems: Bool = false
  ) -> [TransferRecord] {
    loadIfNeeded()
    guard delay != .never else { return [] }
    // "Only When Low on Space" holds everything back until the device is short of room;
    // the delay still applies once it is.
    if smartDelete, bytesNeededToRecover() == 0 { return [] }
    let now = Date()
    let knownAccounts = cleanupAccounts(accountEmails, excluding: excludingAccounts, accountEmail: accountEmail)
    return records.values.filter {
      isEligible(
        $0, delay: delay, now: now, accountEmail: accountEmail, knownAccounts: knownAccounts, includesFoundItems: includesFoundItems)
    }
    .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
  }

  /// An account that no longer receives copies is not waited for.
  private func cleanupAccounts(_ accounts: Set<String>, excluding: Set<String>, accountEmail: String) -> Set<String> {
    let persisted = Set(records.values.compactMap { TransferRecord.accountEmail(fromScopedID: $0.id) })
    return accounts.union(persisted).subtracting(excluding).union([accountEmail])
  }

  private func isEligible(
    _ rec: TransferRecord, delay: AutoDeleteDelay, now: Date, accountEmail: String, knownAccounts: Set<String>,
    includesFoundItems: Bool
  ) -> Bool {
    guard rec.status == .sent, !rec.isSkipped, rec.sentAccountEmails.contains(accountEmail) else { return false }
    guard let mediaKey = rec.mediaKeysByAccount[accountEmail], !mediaKey.isEmpty else { return false }
    // A copy this app did not upload may be Storage saver, so it does not stand in for
    // the original unless the user says their account holds originals.
    guard includesFoundItems || !rec.foundInAccounts.contains(accountEmail) else { return false }
    guard !hasCompetingResourceRecord(rec) else { return false }
    let otherAccounts = knownAccounts.filter { $0 != accountEmail }
    if !otherAccounts.isEmpty {
      let mates = resourceMates(of: rec)
      let hasUnuploadedAccount = otherAccounts.contains { email in
        let matching = mates.filter {
          TransferRecord.accountEmail(fromScopedID: $0.id) == email && $0.sentAccountEmails.contains(email)
        }
        if matching.isEmpty { return true }
        if matching.contains(where: { $0.status == .pending || $0.status == .sending || $0.status == .failed }) {
          return true
        }
        return !matching.contains {
          ($0.mediaKeysByAccount[email]?.isEmpty == false) && sameResourceVersion($0, rec)
            && ($0.status == .sent || $0.status == .deleted)
            && (includesFoundItems || !$0.foundInAccounts.contains(email))
        }
      }
      guard !hasUnuploadedAccount else { return false }
    }
    guard let deleteAfter = Self.deleteAfterDate(sentAt: rec.sentAt, delay: delay) else { return false }
    return deleteAfter <= now
  }

  /// Whether a claimed record is still due under the settings as they are now: checked
  /// last, since confirming and thumbnail work can outlast a change to them.
  public func isStillDue(id: String, settings: AppSettings, accountEmail: String, accounts: [GoogleAccount]) -> Bool {
    loadIfNeeded()
    guard settings.autoDeleteDelay != .never, let record = records[id] else { return false }
    let known = cleanupAccounts(
      Set(accounts.map(\.email)), excluding: Set(accounts.filter { !$0.mirrorEnabled && $0.email != accountEmail }.map(\.email)),
      accountEmail: accountEmail)
    return isEligible(
      record, delay: settings.autoDeleteDelay, now: Date(), accountEmail: accountEmail, knownAccounts: known,
      includesFoundItems: settings.removesItemsAlreadyInGooglePhotos)
  }

  /// The app's own staged copies that may go now. They're copies of files the user keeps, so
  /// Delete After Backup doesn't hold them back; everything else that holds back a removal
  /// does, and `ids` limits it to the copies asked about.
  public func eligibleStagedCopies(
    among ids: Set<String>, accountEmail: String, accounts: [GoogleAccount], includesFoundItems: Bool
  ) -> Set<String> {
    let eligible = eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: accountEmail,
      accountEmails: Set(accounts.map(\.email)).union([accountEmail]),
      excludingAccounts: Set(accounts.filter { !$0.mirrorEnabled && $0.email != accountEmail }.map(\.email)),
      includesFoundItems: includesFoundItems)
    return ids.intersection(eligible.map(\.id))
  }

  /// An asset's RAW and its primary share the asset as a resource, so they compete with
  /// each other while either is in flight, but neither stands in for the other's upload.
  private func sameResourceVersion(_ lhs: TransferRecord, _ rhs: TransferRecord) -> Bool {
    guard sameResource(lhs, rhs), lhs.resourceRole == rhs.resourceRole else { return false }
    switch (lhs.pairedSourcePath, rhs.pairedSourcePath) {
    case (nil, nil):
      break
    case (let left?, let right?):
      guard URL(fileURLWithPath: left).standardizedFileURL == URL(fileURLWithPath: right).standardizedFileURL else { return false }
    default:
      return false
    }
    if let currentSize = rhs.sourceFileSize {
      guard lhs.sourceFileSize == currentSize else { return false }
    }
    if let currentPairedSize = rhs.pairedSourceFileSize {
      guard lhs.pairedSourceFileSize == currentPairedSize else { return false }
    }
    if let currentSHA1 = rhs.sourceSHA1 {
      guard lhs.sourceSHA1 == currentSHA1 else { return false }
    }
    if let currentPairedSHA1 = rhs.pairedSourceSHA1 {
      guard lhs.pairedSourceSHA1 == currentPairedSHA1 else { return false }
    }
    guard let currentDate = rhs.sourceModifiedAt else { return true }
    guard let candidateDate = lhs.sourceModifiedAt,
      abs(candidateDate.timeIntervalSince(currentDate)) < 0.01
    else { return false }
    guard let currentPairedDate = rhs.pairedSourceModifiedAt else { return true }
    guard let candidatePairedDate = lhs.pairedSourceModifiedAt else { return false }
    return abs(candidatePairedDate.timeIntervalSince(currentPairedDate)) < 0.01
  }

  private func hasCompetingResourceRecord(_ record: TransferRecord) -> Bool {
    for candidate in resourceMates(of: record) {
      guard candidate.id != record.id else { continue }
      if candidate.status == .pending || candidate.status == .sending || candidate.status == .failed {
        return true
      }
      guard candidate.status == .sent || candidate.status == .deleted else { continue }
      let isSameAsset = record.assetLocalIdentifier != nil && candidate.assetLocalIdentifier == record.assetLocalIdentifier
      guard let currentDate = record.sourceModifiedAt else {
        if isSameAsset { continue }
        return true
      }
      guard let candidateDate = candidate.sourceModifiedAt else {
        if isSameAsset { continue }
        return true
      }
      if candidateDate > currentDate { return true }
      if candidateDate == currentDate {
        if !sameResourceVersion(candidate, record) { return true }
        continue
      }
      if let currentPairedDate = record.pairedSourceModifiedAt,
        let candidatePairedDate = candidate.pairedSourceModifiedAt,
        candidatePairedDate > currentPairedDate
      {
        return true
      }
    }
    return false
  }

  private func sameResource(_ lhs: TransferRecord, _ rhs: TransferRecord) -> Bool {
    if let assetID = lhs.assetLocalIdentifier, let rhsAssetID = rhs.assetLocalIdentifier {
      return assetID == rhsAssetID
    }
    if let sourcePath = lhs.sourcePath, let rhsSourcePath = rhs.sourcePath {
      return sourcePath == rhsSourcePath || sourcePath.caseInsensitiveCompare(rhsSourcePath) == .orderedSame
    }
    return false
  }

  /// Free space below which "Only When Low on Space" starts removing local copies.
  public static let lowSpaceThreshold: Int64 = 5_000_000_000

  /// How far free space on the home volume is below `lowSpaceThreshold`, or 0 when it
  /// is not (or cannot be read), so a cleanup can stop once it has freed enough.
  public func bytesNeededToRecover() -> Int64 {
    Self.bytesNeededToRecover(onVolumeOf: URL(fileURLWithPath: NSHomeDirectory()))
  }

  /// The same measure for the volume holding `url`. External volumes may not report the
  /// important-usage figure, so plain available capacity stands in for it.
  public nonisolated static func bytesNeededToRecover(onVolumeOf url: URL) -> Int64 {
    guard
      let values = try? url.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
      ])
    else { return 0 }
    let available: Int64
    if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
      available = important
    } else if let plain = values.volumeAvailableCapacity {
      available = Int64(plain)
    } else {
      return 0
    }
    return max(0, lowSpaceThreshold - available)
  }

  // MARK: - Background Uploads

  /// The records on disk, read without taking the manifest over: for the photo upload
  /// extension, which never writes it. An unreadable file is left where it is.
  public nonisolated static func storedRecords(fileURL: URL = defaultFileURL) -> [String: TransferRecord] {
    load(from: fileURL, journalURL: fileURL.appendingPathExtension("journal"), quarantinesUnreadable: false).records
  }

  public enum BackgroundUploadImport: Sendable, Equatable {
    case recorded
    /// The record already holds this version, or a later one, as uploaded.
    case superseded
    /// The app is sending or removing the record right now; offer the result again later.
    case deferred
  }

  /// Records an upload the photo upload extension finished, as the upload pool records its
  /// own: the media key the account received and the hashes cleanup verifies against.
  public func recordBackgroundUpload(_ result: BackgroundUploadResult) -> BackgroundUploadImport {
    recordBackgroundUploads([result])[0]
  }

  public func recordBackgroundUploads(_ results: [BackgroundUploadResult]) -> [BackgroundUploadImport] {
    loadIfNeeded()
    var previous: [String: TransferRecord?] = [:]
    var outcomes = results.map { result in
      let original = records[result.recordID]
      let outcome = applyBackgroundUpload(result, previous: original)
      if outcome == .recorded, previous[result.recordID] == nil {
        previous.updateValue(original, forKey: result.recordID)
      }
      return outcome
    }
    guard !previous.isEmpty else { return outcomes }
    guard commit(previous.keys, critical: true) else {
      for (id, record) in previous { records[id] = record }
      rebuildIndexes()
      for index in results.indices where previous[results[index].recordID] != nil {
        outcomes[index] = .deferred
      }
      return outcomes
    }
    return outcomes
  }

  private func applyBackgroundUpload(
    _ result: BackgroundUploadResult, previous: TransferRecord?
  ) -> BackgroundUploadImport {
    // Left for the app, which drops an absent account's receipts itself.
    if removedAccounts.contains(result.accountEmail) { return .deferred }
    if let email = TransferRecord.accountEmail(fromScopedID: result.recordID), removedAccounts.contains(email) {
      return .deferred
    }
    var record =
      previous
      ?? TransferRecord(
        id: result.recordID,
        filename: result.filename,
        mediaType: result.mediaType,
        creationDate: result.creationDate,
        status: .pending,
        assetLocalIdentifier: result.assetLocalIdentifier,
        resourceRole: result.role
      )
    if record.status == .sending || hasDeletionClaim(for: record) { return .deferred }
    if record.status == .deleted { return .superseded }
    if record.status == .sent, record.sentAccountEmails.contains(result.accountEmail) {
      let incoming = TransferRecord.AssetVersion(
        modifiedAt: result.assetModifiedAt, hasAdjustments: result.assetHadAdjustments,
        adjustmentTimestamp: result.assetAdjustmentTimestamp)
      let isNewVersion =
        incoming.hasAdjustments == nil && incoming.adjustmentTimestamp == nil
        ? TransferRecord.isAssetEdited(incoming.modifiedAt, since: record.assetModifiedAt)
        : incoming.contentChanged(since: record.assetVersion)
      if record.resourceRole == .uneditedOriginal
        || TransferRecord.isAssetEdited(record.assetModifiedAt, since: result.assetModifiedAt)
        || !isNewVersion
      {
        return .superseded
      }
    }
    record.filename = result.filename
    record.mediaType = result.mediaType
    record.status = .sent
    record.progress = 1
    record.byteCount = result.byteCount
    record.transferredByteCount = result.uploaded ? result.byteCount : 0
    record.attempts = 0
    record.sentAt = result.finishedAt
    record.deleteAfter = Self.deleteAfterDate(sentAt: result.finishedAt, delay: retentionDelay)
    record.sha1 = result.sha1
    record.pairedSourceSHA1 = result.pairedSHA1
    record.assetModifiedAt = result.assetModifiedAt
    record.assetHadAdjustments = result.assetHadAdjustments
    record.assetAdjustmentTimestamp = result.assetAdjustmentTimestamp
    record.preparedAsset = nil
    if let checked = result.resourcesChecked { record.resourcesChecked = checked }
    record.lastError = result.note ?? (result.uploaded ? nil : "Deduplicated (Already in Google Photos)")
    record.sentAccountEmails.insert(result.accountEmail)
    record.mediaKeysByAccount[result.accountEmail] = result.mediaKey
    if result.foundInAccount {
      record.foundInAccounts.insert(result.accountEmail)
    } else {
      record.foundInAccounts.remove(result.accountEmail)
    }
    removeFromIndexes(previous)
    records[record.id] = record
    addToIndexes(record)
    return .recorded
  }

  /// Writes pending changes now. Call before the app suspends or terminates; routine
  /// changes are otherwise coalesced and written shortly after they happen.
  @discardableResult
  public func flush() -> Bool {
    loadIfNeeded()
    flushTask?.cancel()
    flushTask = nil
    guard needsPersistence else { return true }
    // A snapshot costs a full encode, so it waits until appending would cost more: most
    // of the manifest changed, or the journal has outgrown the snapshot it extends.
    if needsSnapshot || dirtyIDs.count * 2 > records.count
      || journalSize > max(snapshotSize, Self.minimumCompactionSize)
    {
      return writeSnapshot()
    }
    return appendJournal()
  }

  /// Marks `ids` dirty and persists them. Critical transitions (a deletion, a record
  /// stored as already uploaded) are written immediately so their success is only
  /// reported once on disk; the rest are coalesced behind a short debounce.
  private func commit(_ ids: some Sequence<String>, critical: Bool) -> Bool {
    dirtyIDs.formUnion(ids)
    if critical { return flush() }
    scheduleFlush()
    return true
  }

  /// For changes touching much of the manifest, which a snapshot records more cheaply.
  private func commitAll() -> Bool {
    needsSnapshot = true
    return flush()
  }

  private func scheduleFlush() {
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: Self.flushDelay)
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  private static let flushDelay = Duration.milliseconds(500)
  private static let minimumCompactionSize = 1 << 20
  private static let snapshotTokenAttribute = "org.gphotosapp.gphotos.manifest-snapshot"

  private func writeSnapshot() -> Bool {
    guard let written = Self.writeSnapshot(sortedCache ?? Array(records.values), to: fileURL, encoder: lineEncoder) else {
      needsSnapshot = true
      return false
    }
    snapshotToken = written.token
    snapshotSize = written.size
    // The old journal names the old snapshot, so it is ignored even if this removal fails,
    // and the next append replaces it.
    journalIsCurrent = false
    journalSize = 0
    try? FileManager.default.removeItem(at: journalURL)
    needsSnapshot = false
    dirtyIDs.removeAll()
    return true
  }

  /// Appends the current state of every dirty record. The first append after a snapshot
  /// starts a new journal naming it; a failed append is cut back off and leaves a
  /// snapshot owed, so a torn line can never sit in front of later entries.
  private func appendJournal() -> Bool {
    guard let token = snapshotToken else { return writeSnapshot() }
    var data = Data()
    do {
      if !journalIsCurrent {
        data.append(try lineEncoder.encode(JournalHeader(snapshot: token)))
        data.append(0x0A)
      }
      for id in dirtyIDs {
        let entry = records[id].map { JournalEntry(record: $0) } ?? JournalEntry(removedID: id)
        data.append(try lineEncoder.encode(entry))
        data.append(0x0A)
      }
    } catch {
      return writeSnapshot()
    }
    if journalIsCurrent {
      guard let handle = try? FileHandle(forWritingTo: journalURL) else { return writeSnapshot() }
      defer { try? handle.close() }
      do {
        try handle.seek(toOffset: UInt64(journalSize))
        try handle.write(contentsOf: data)
      } catch {
        try? handle.truncate(atOffset: UInt64(journalSize))
        needsSnapshot = true
        return false
      }
      journalSize += data.count
    } else {
      guard (try? data.write(to: journalURL, options: .atomic)) != nil else {
        needsSnapshot = true
        return false
      }
      journalIsCurrent = true
      journalSize = data.count
    }
    dirtyIDs.removeAll()
    return true
  }

  /// Writes the snapshot under a fresh token, stored on the file itself so it is replaced
  /// in the same rename: a journal written for an earlier snapshot can then never be
  /// replayed over this one. Where the token can't be stored the snapshot is still
  /// written, without one, and every later write is a snapshot again.
  private static func writeSnapshot(
    _ records: [TransferRecord], to url: URL, encoder: JSONEncoder
  ) -> (token: String?, size: Int)? {
    let token = UUID().uuidString
    guard let data = try? encoder.encode(records) else { return nil }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      "\(temporaryPrefix(for: url))\(token)\(temporarySuffix)")
    guard (try? data.write(to: temporary)) != nil else { return nil }
    let tagged = token.withCString { setxattr(temporary.path, snapshotTokenAttribute, $0, strlen($0), 0, 0) } == 0
    guard rename(temporary.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      return nil
    }
    return (tagged ? token : nil, data.count)
  }

  private static func temporaryPrefix(for url: URL) -> String { ".\(url.lastPathComponent)." }
  private static let temporarySuffix = ".tmp"

  /// Snapshot writes cut short by the process ending, each as large as the manifest.
  private static func removeAbandonedSnapshots(beside url: URL) {
    let directory = url.deletingLastPathComponent()
    let prefix = temporaryPrefix(for: url)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(temporarySuffix) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private static func snapshotToken(of url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: 64)
    let length = getxattr(url.path, snapshotTokenAttribute, &buffer, buffer.count - 1, 0, 0)
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private struct JournalHeader: Codable {
    var snapshot: String
  }

  /// One change: a record's state after it, or the ID of a record removed.
  private struct JournalEntry: Codable {
    var record: TransferRecord?
    var removedID: String?

    init(record: TransferRecord) { self.record = record }
    init(removedID: String) { self.removedID = removedID }
  }

  private struct StoredManifest {
    var records: [String: TransferRecord] = [:]
    var snapshotToken: String?
    var snapshotSize = 0
    /// Size of a journal replayed onto the snapshot, or 0 when there was none to replay.
    var journalSize = 0
    /// A journal ending mid-line (an interrupted append) can't be appended to.
    var journalIsTorn = false
  }

  /// Reads the snapshot record by record, so one undecodable entry costs only itself, then
  /// replays the journal written for it. A snapshot that is not a JSON array at all is
  /// preserved rather than overwritten.
  private static func load(from url: URL, journalURL: URL, quarantinesUnreadable: Bool = true) -> StoredManifest {
    var stored = StoredManifest()
    guard FileManager.default.fileExists(atPath: url.path) else { return stored }
    guard let data = try? Data(contentsOf: url), let chunks = decodeSnapshotChunks(data) else {
      if quarantinesUnreadable { quarantine(url) }
      return stored
    }
    stored.records.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
    for item in chunks.joined() { stored.records[item.id] = item }
    stored.snapshotSize = data.count
    stored.snapshotToken = snapshotToken(of: url)
    guard let token = stored.snapshotToken, let journal = try? Data(contentsOf: journalURL) else { return stored }
    let decoder = JSONDecoder()
    let lines = journal.split(separator: 0x0A)
    guard let header = lines.first, (try? decoder.decode(JournalHeader.self, from: header))?.snapshot == token
    else { return stored }
    for line in lines.dropFirst() {
      guard let entry = try? decoder.decode(JournalEntry.self, from: line) else { continue }
      if let record = entry.record {
        stored.records[record.id] = record
      } else if let id = entry.removedID {
        stored.records.removeValue(forKey: id)
      }
    }
    stored.journalSize = journal.count
    stored.journalIsTorn = journal.last != 0x0A
    return stored
  }

  /// The snapshot's records in file order, skipping any that don't decode; nil when it
  /// isn't a JSON array.
  static func decodeSnapshot(_ data: Data) -> [TransferRecord]? {
    decodeSnapshotChunks(data)?.flatMap { $0 }
  }

  private static func decodeSnapshotChunks(_ data: Data) -> [[TransferRecord]]? {
    if data.count >= 1_000_000, let ranges = snapshotRanges(data, into: 8), ranges.count > 1 {
      let workers = min(ProcessInfo.processInfo.activeProcessorCount, ranges.count, 4)
      let decoded = OSAllocatedUnfairLock(initialState: [Int: [TransferRecord]]())
      DispatchQueue.concurrentPerform(iterations: workers) { worker in
        for index in stride(from: worker, to: ranges.count, by: workers) {
          let piece = snapshotPiece(data, range: ranges[index])
          guard let list = try? JSONDecoder().decode([Failable<TransferRecord>].self, from: piece) else { return }
          let records = list.compactMap(\.value)
          decoded.withLock { $0[index] = records }
        }
      }
      let results = decoded.withLock { $0 }
      if results.count == ranges.count { return ranges.indices.map { results[$0] ?? [] } }
    }
    guard let list = try? JSONDecoder().decode([Failable<TransferRecord>].self, from: data) else { return nil }
    return [list.compactMap(\.value)]
  }

  /// A top-level JSON array cut into about `count` smaller arrays at the commas between
  /// its elements, so each can be decoded alone. Nil when it isn't one array.
  static func splitArray(_ data: Data, into count: Int) -> [Data]? {
    snapshotRanges(data, into: count)?.map { snapshotPiece(data, range: $0) }
  }

  private static func snapshotPiece(_ data: Data, range: Range<Int>) -> Data {
    data.withUnsafeBytes { bytes in
      var piece = Data()
      piece.reserveCapacity(range.count + 2)
      piece.append(UInt8(ascii: "["))
      piece.append(UnsafeBufferPointer(rebasing: bytes.bindMemory(to: UInt8.self)[range]))
      piece.append(UInt8(ascii: "]"))
      return piece
    }
  }

  private static func snapshotRanges(_ data: Data, into count: Int) -> [Range<Int>]? {
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Range<Int>]? in
      let bytes = bytes.bindMemory(to: UInt8.self)
      var start = 0
      while start < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[start]) { start += 1 }
      var end = bytes.count - 1
      while end > start, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[end]) { end -= 1 }
      guard start < end, bytes[start] == UInt8(ascii: "["), bytes[end] == UInt8(ascii: "]") else { return nil }
      // The commas between top-level elements: outside strings, at depth 1.
      let target = max(1, (end - start) / count)
      var cuts: [Int] = []
      var depth = 0
      var inString = false
      var escaped = false
      var nextCut = start + target
      for index in start...end {
        let byte = bytes[index]
        if inString {
          if escaped {
            escaped = false
          } else if byte == UInt8(ascii: "\\") {
            escaped = true
          } else if byte == UInt8(ascii: "\"") {
            inString = false
          }
          continue
        }
        switch byte {
        case UInt8(ascii: "\""): inString = true
        case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
        case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
        case UInt8(ascii: ","):
          if depth == 1, index >= nextCut {
            cuts.append(index)
            nextCut = index + target
          }
        default: break
        }
      }
      guard depth == 0, !inString else { return nil }
      return zip([start] + cuts, cuts + [end]).map { ($0 + 1)..<$1 }
    }
  }

  private struct Failable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
      value = try? Value(from: decoder)
    }
  }

  private static func quarantine(_ url: URL) {
    let backup = url.appendingPathExtension("unreadable")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
  }
}

/// Records whose source files could not be removed. Cleanup leaves each alone for a day
/// rather than failing, and reporting, the same file on every pass. Kept in the app's
/// own defaults, since a background launch starts a fresh process.
public enum DeletionFailureBackoff {
  public static let interval: TimeInterval = 24 * 60 * 60
  private static let defaultsKey = "deletionFailureTimes"

  /// Records that failed within the last `interval`, read once per cleanup pass.
  public static func idsBackingOff(now: Date = Date(), defaults: UserDefaults = .standard) -> Set<String> {
    Set(failures(in: defaults).filter { now.timeIntervalSince($0.value) < interval && $0.value <= now }.keys)
  }

  public static func recordFailure(_ id: String, now: Date = Date(), defaults: UserDefaults = .standard) {
    var current = failures(in: defaults).filter { now.timeIntervalSince($0.value) < interval }
    current[id] = now
    defaults.set(current, forKey: defaultsKey)
  }

  public static func clear(_ id: String, defaults: UserDefaults = .standard) {
    var current = failures(in: defaults)
    guard current.removeValue(forKey: id) != nil else { return }
    defaults.set(current, forKey: defaultsKey)
  }

  private static func failures(in defaults: UserDefaults) -> [String: Date] {
    defaults.dictionary(forKey: defaultsKey) as? [String: Date] ?? [:]
  }
}
