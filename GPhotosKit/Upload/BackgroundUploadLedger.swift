import Foundation

/// The uploads the photo upload extension runs, which iOS starts on its own schedule, even
/// after the app is closed from the app switcher. Shared through the App Group by the app and
/// the extension, and changed only through `BackgroundUploadLedgerStore.update`, which holds a
/// file lock across the read and the write.
///
/// The extension never writes the transfer manifest: the app is its only writer. Finished
/// uploads wait here as `results` until the app records them.
public struct BackgroundUploadLedger: Codable, Sendable, Equatable {
  public var jobs: [BackgroundUploadJob] = []
  public var results: [BackgroundUploadResult] = []
  /// Attempts per record, counted before an item is read so one that crashes the extension
  /// is held back like one that fails.
  public var failures: [String: BackgroundUploadFailure] = [:]
  /// Pushed forward by the app while it is open or uploading. Until it passes the extension
  /// starts nothing, so the two never upload the same item.
  public var appBusyUntil: Date?
  public var appWorkEpoch: UUID?
  private var appClaims: [String: Date]?
  var preparing: [String: Preparation] = [:]
  var rateLimits: [String: RateLimit] = [:]

  struct Preparation: Codable, Sendable, Equatable {
    let jobID: String
    let expires: Date
  }

  struct RateLimit: Codable, Sendable, Equatable {
    let until: Date
    let nextDelay: TimeInterval
  }

  mutating func noteRateLimit(accountEmail: String, retryAfter: TimeInterval, at now: Date = Date()) {
    let previous = rateLimits[accountEmail]
    let delay = previous?.nextDelay ?? 60
    let until = now.addingTimeInterval(max(retryAfter, delay))
    if let previous, previous.until > now {
      rateLimits[accountEmail] = RateLimit(
        until: max(previous.until, now.addingTimeInterval(retryAfter)), nextDelay: previous.nextDelay)
    } else {
      rateLimits[accountEmail] = RateLimit(until: until, nextDelay: min(delay * 2, 600))
    }
  }

  func isRateLimited(accountEmail: String, at now: Date = Date()) -> Bool {
    rateLimits[accountEmail].map { $0.until > now } ?? false
  }

  /// Attempts after which an item waits for `failureRetryInterval` before it's tried again.
  public static let maxAttempts = 3
  public static let failureRetryInterval: TimeInterval = 6 * 60 * 60

  public init() {}

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    jobs = try values.decode([BackgroundUploadJob].self, forKey: .jobs)
    results = try values.decode([BackgroundUploadResult].self, forKey: .results)
    failures = try values.decode([String: BackgroundUploadFailure].self, forKey: .failures)
    appBusyUntil = try values.decodeIfPresent(Date.self, forKey: .appBusyUntil)
    appWorkEpoch = try values.decodeIfPresent(UUID.self, forKey: .appWorkEpoch)
    appClaims = try values.decodeIfPresent([String: Date].self, forKey: .appClaims)
    preparing = try values.decodeIfPresent([String: Preparation].self, forKey: .preparing) ?? [:]
    rateLimits = try values.decodeIfPresent([String: RateLimit].self, forKey: .rateLimits) ?? [:]
  }

  public func appIsBusy(at now: Date = Date()) -> Bool {
    appBusyUntil.map { $0 > now } ?? false
  }

  /// Keep the app off the record from the start of export through the manifest import.
  public var heldRecordIDs: Set<String> {
    heldRecordIDs(at: Date())
  }

  private func heldRecordIDs(at now: Date) -> Set<String> {
    Set(jobs.map(\.recordID)).union(results.map(\.recordID))
      .union(preparing.filter { $0.value.expires > now }.keys)
  }

  func stagedJobIDs(at now: Date = Date()) -> Set<String> {
    Set(jobs.map(\.id)).union(preparing.values.filter { $0.expires > now }.map(\.jobID))
  }

  public mutating func resetAppClaims() {
    appClaims = nil
    appWorkEpoch = UUID()
  }

  public mutating func claimForApp(_ recordID: String, at now: Date = Date()) -> Bool {
    guard !heldRecordIDs(at: now).contains(recordID) else { return false }
    appClaims = appClaims?.filter { $0.value > now } ?? [:]
    guard appClaims?[recordID] == nil else { return false }
    appClaims?[recordID] = now.addingTimeInterval(BackgroundUploadJob.abandonAfter)
    appWorkEpoch = UUID()
    return true
  }

  public mutating func releaseAppClaim(_ recordID: String) {
    appClaims?[recordID] = nil
    // The extension must rescan after the app persists a new receipt.
    appWorkEpoch = UUID()
  }

  mutating func claimForPreparation(recordID: String, jobID: String, epoch: UUID? = nil, at now: Date = Date()) -> Bool {
    guard epoch == appWorkEpoch, !appIsBusy(at: now),
      appClaims?[recordID].map({ $0 > now }) != true, !heldRecordIDs(at: now).contains(recordID),
      !isHeldBack(recordID, at: now)
    else { return false }
    preparing = preparing.filter { $0.value.expires > now }
    preparing[recordID] = Preparation(jobID: jobID, expires: now.addingTimeInterval(BackgroundUploadJob.claimDuration))
    noteAttempt(recordID, reason: "Didn't finish preparing", at: now)
    return true
  }

  func ownsPreparation(recordID: String, jobID: String, at now: Date = Date()) -> Bool {
    guard let claim = preparing[recordID] else { return false }
    return claim.jobID == jobID && claim.expires > now
  }

  mutating func releasePreparation(_ recordID: String, jobID: String) {
    guard preparing[recordID]?.jobID == jobID else { return }
    preparing[recordID] = nil
  }

  public func job(withID id: String) -> BackgroundUploadJob? {
    jobs.first { $0.id == id }
  }

  public func isHeldBack(_ recordID: String, at now: Date = Date()) -> Bool {
    guard let failure = failures[recordID], failure.count >= Self.maxAttempts else { return false }
    return now.timeIntervalSince(failure.date) < Self.failureRetryInterval
  }

  public mutating func noteAttempt(_ recordID: String, reason: String, at now: Date = Date()) {
    var failure = failures[recordID] ?? BackgroundUploadFailure(count: 0, reason: reason, date: now)
    // A record held back long enough starts counting again.
    if failure.count >= Self.maxAttempts, now.timeIntervalSince(failure.date) >= Self.failureRetryInterval {
      failure.count = 0
    }
    failure.count += 1
    failure.reason = reason
    failure.date = now
    failures[recordID] = failure
  }

  /// Notes why the attempt counted by `noteAttempt` failed, without counting it again.
  public mutating func explainFailure(_ recordID: String, reason: String) {
    failures[recordID]?.reason = reason
  }

  public mutating func updatePart(jobID: String, index: Int, _ change: (inout BackgroundUploadPart) -> Void) {
    guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }), jobs[jobIndex].parts.indices.contains(index)
    else { return }
    change(&jobs[jobIndex].parts[index])
  }

  /// Takes a job's finished parts for committing, so the app and the extension never commit
  /// the same job twice. A claim lapses after `claimDuration` in case its holder died.
  public mutating func claimForCommit(jobID: String, at now: Date = Date()) -> BackgroundUploadJob? {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return nil }
    if let until = jobs[index].committingUntil, until > now { return nil }
    let until = now.addingTimeInterval(BackgroundUploadJob.claimDuration)
    var claim = jobs[index]
    claim.commitWasAttempted = claim.commitWasAttempted ?? false
    claim.committingUntil = until
    jobs[index].committingUntil = until
    jobs[index].commitWasAttempted = true
    return claim
  }

  public mutating func releaseCommitClaim(jobID: String) {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
    jobs[index].committingUntil = nil
  }

  /// Ends a job with the item uploaded (or found already in the account).
  public mutating func finish(jobID: String, with result: BackgroundUploadResult) {
    jobs.removeAll { $0.id == jobID }
    results.removeAll { $0.recordID == result.recordID }
    results.append(result)
    failures[result.recordID] = nil
  }

  public mutating func fail(jobID: String, reason: String) {
    guard let job = job(withID: jobID) else { return }
    jobs.removeAll { $0.id == jobID }
    explainFailure(job.recordID, reason: reason)
  }
}

public struct BackgroundUploadFailure: Codable, Sendable, Equatable {
  public var count: Int
  public var reason: String
  public var date: Date
}

/// One item the extension is uploading: a file, a Live Photo's still and motion, or only the
/// motion of a Live Photo whose still is already in the account.
public struct BackgroundUploadJob: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case file
    case livePhoto
    case livePhotoMotion
  }

  public static let claimDuration: TimeInterval = 5 * 60
  public static let abandonAfter: TimeInterval = 24 * 60 * 60

  public let id: String
  public let recordID: String
  public let accountEmail: String
  public let assetLocalIdentifier: String
  public let role: AssetResourceRole
  public let kind: Kind
  /// The name the item is committed under: the still's for a Live Photo.
  public let filename: String
  public let videoFilename: String?
  public let mediaType: String
  public let creationDate: Date?
  /// The asset version uploaded, so the app can tell a later edit apart.
  public let assetModifiedAt: Date?
  public let assetHadAdjustments: Bool?
  public let assetAdjustmentTimestamp: Date?
  public let resourcesChecked: Bool?
  /// The capture date the item is committed under.
  public let capturedAt: Date
  public let byteCount: Int64
  public let sha1: Data
  public let videoSHA1: Data?
  /// Shown in Activity, as for an upload the app made: "Uploaded without motion".
  public let note: String?
  public let startedAt: Date
  public var parts: [BackgroundUploadPart]
  public var committingUntil: Date?
  var commitWasAttempted: Bool?

  public init(
    id: String = UUID().uuidString,
    recordID: String,
    accountEmail: String,
    assetLocalIdentifier: String,
    role: AssetResourceRole,
    kind: Kind,
    filename: String,
    videoFilename: String? = nil,
    mediaType: String,
    creationDate: Date?,
    assetModifiedAt: Date?,
    assetHadAdjustments: Bool? = nil,
    assetAdjustmentTimestamp: Date? = nil,
    resourcesChecked: Bool? = nil,
    capturedAt: Date,
    byteCount: Int64,
    sha1: Data,
    videoSHA1: Data? = nil,
    note: String? = nil,
    startedAt: Date = Date(),
    parts: [BackgroundUploadPart]
  ) {
    self.id = id
    self.recordID = recordID
    self.accountEmail = accountEmail
    self.assetLocalIdentifier = assetLocalIdentifier
    self.role = role
    self.kind = kind
    self.filename = filename
    self.videoFilename = videoFilename
    self.mediaType = mediaType
    self.creationDate = creationDate
    self.assetModifiedAt = assetModifiedAt
    self.assetHadAdjustments = assetHadAdjustments
    self.assetAdjustmentTimestamp = assetAdjustmentTimestamp
    self.resourcesChecked = resourcesChecked
    self.capturedAt = capturedAt
    self.byteCount = byteCount
    self.sha1 = sha1
    self.videoSHA1 = videoSHA1
    self.note = note
    self.startedAt = startedAt
    self.parts = parts
  }

  public var isSettled: Bool {
    parts.allSatisfy { $0.state != .sending }
  }

  func canCommit(at now: Date) -> Bool {
    committingUntil.map { $0 <= now } ?? true
  }

  func hasExpired(at now: Date) -> Bool {
    now.timeIntervalSince(startedAt) >= Self.abandonAfter && canCommit(at: now)
  }
}

/// One file of a job, sent by iOS in a single request from a copy in the App Group.
public struct BackgroundUploadPart: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable {
    case sending
    case sent
    case failed
  }

  /// The copy's name in the job's staging directory.
  public let stagedName: String
  public let size: Int64
  public let uploadID: String
  public var state: State = .sending
  /// Scotty's finalize token: the body of the response that completed the upload.
  public var finalizeToken: Data?
  public var error: String?
  /// When Google was last asked how much of the file it holds.
  public var checkedAt: Date?

  public init(stagedName: String, size: Int64, uploadID: String) {
    self.stagedName = stagedName
    self.size = size
    self.uploadID = uploadID
  }
}

/// An item the extension backed up, for the app to record in the manifest.
public struct BackgroundUploadResult: Codable, Sendable, Equatable {
  public let recordID: String
  public let accountEmail: String
  public let assetLocalIdentifier: String
  public let role: AssetResourceRole
  public let filename: String
  public let mediaType: String
  public let creationDate: Date?
  public let assetModifiedAt: Date?
  public let assetHadAdjustments: Bool?
  public let assetAdjustmentTimestamp: Date?
  public let resourcesChecked: Bool?
  public let byteCount: Int64
  public let mediaKey: String
  public let sha1: String
  /// The motion's hash, set only once a Live Photo's video is attached to its still.
  public let pairedSHA1: String?
  /// False when the account already held the item.
  public let uploaded: Bool
  /// The account held the item's bytes (or a Live Photo's still) before this upload, so its
  /// quality is unknown: it may be a Storage saver copy.
  public let foundInAccount: Bool
  public let note: String?
  public let finishedAt: Date

  public init(
    recordID: String,
    accountEmail: String,
    assetLocalIdentifier: String,
    role: AssetResourceRole,
    filename: String,
    mediaType: String,
    creationDate: Date?,
    assetModifiedAt: Date?,
    assetHadAdjustments: Bool? = nil,
    assetAdjustmentTimestamp: Date? = nil,
    resourcesChecked: Bool? = nil,
    byteCount: Int64,
    mediaKey: String,
    sha1: String,
    pairedSHA1: String?,
    uploaded: Bool,
    foundInAccount: Bool,
    note: String? = nil,
    finishedAt: Date = Date()
  ) {
    self.recordID = recordID
    self.accountEmail = accountEmail
    self.assetLocalIdentifier = assetLocalIdentifier
    self.role = role
    self.filename = filename
    self.mediaType = mediaType
    self.creationDate = creationDate
    self.assetModifiedAt = assetModifiedAt
    self.assetHadAdjustments = assetHadAdjustments
    self.assetAdjustmentTimestamp = assetAdjustmentTimestamp
    self.resourcesChecked = resourcesChecked
    self.byteCount = byteCount
    self.mediaKey = mediaKey
    self.sha1 = sha1
    self.pairedSHA1 = pairedSHA1
    self.uploaded = uploaded
    self.foundInAccount = foundInAccount
    self.note = note
    self.finishedAt = finishedAt
  }
}

/// The ledger on disk, in the App Group. Each change runs under an exclusive `flock`, which
/// orders it against every other change in this process and in the other one.
public struct BackgroundUploadLedgerStore: Sendable {
  public static let shared = BackgroundUploadLedgerStore(directory: AppGroupConstants.storageDirectory())

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  var fileURL: URL { directory.appendingPathComponent("background-uploads.json") }
  private var lockURL: URL { directory.appendingPathComponent("background-uploads.lock") }

  /// Copies of the files being sent, one directory per job. iOS reads them after the
  /// extension is gone, so they live in the App Group rather than a temporary directory.
  public var stagingDirectory: URL { directory.appendingPathComponent("BackgroundUploads", isDirectory: true) }

  public func stagingDirectory(forJob id: String) -> URL {
    stagingDirectory.appendingPathComponent(id, isDirectory: true)
  }

  public func read() -> BackgroundUploadLedger {
    withLock { load() } ?? BackgroundUploadLedger()
  }

  @discardableResult
  public func update<T>(_ change: (inout BackgroundUploadLedger) throws -> T) rethrows -> T {
    if let value = try withLock({
      var ledger = load()
      let original = ledger
      let value = try change(&ledger)
      if ledger != original { _ = save(ledger) }
      return value
    }) {
      return value
    }
    var unavailable = BackgroundUploadLedger()
    return try change(&unavailable)
  }

  /// A claim must reach disk before another process can rely on it.
  public func persist(_ change: (inout BackgroundUploadLedger) -> Bool) -> Bool {
    withLock {
      var ledger = load()
      return change(&ledger) && save(ledger)
    } ?? false
  }

  /// Removes staged copies no job or preparation refers to.
  public func removeAbandonedStaging() {
    let names = (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
    guard let held = withLock({ load().stagedJobIDs() }) else { return }
    for url in names where !held.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// A ledger that no longer decodes starts over: its items are found again by the next scan,
  /// and Google's duplicate check stops a second upload of anything already sent.
  private func load() -> BackgroundUploadLedger {
    guard let data = try? Data(contentsOf: fileURL) else { return BackgroundUploadLedger() }
    return (try? JSONDecoder().decode(BackgroundUploadLedger.self, from: data)) ?? BackgroundUploadLedger()
  }

  private func save(_ ledger: BackgroundUploadLedger) -> Bool {
    do {
      try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
      return true
    } catch {
      BackgroundUploadLog.write("ledger: could not save: \(error.localizedDescription)")
      return false
    }
  }

  /// The lock is held only for a read and a write, never across a suspension point: iOS ends
  /// a suspended process that holds a lock on a file in a shared container.
  private func withLock<T>(_ body: () throws -> T) rethrows -> T? {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { return nil }
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
