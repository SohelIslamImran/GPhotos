import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.gphotosapp.gphotos", category: "AccountMirror")

public struct SecondaryMirrorState: Sendable, Equatable {
  public var email: String
  public var isMirrorEnabled: Bool
  public var pendingCount: Int = 0
  public var copiedCount: Int = 0
  public var isRunning: Bool = false
  public var lastRunAt: Date? = nil
  public var lastError: String? = nil
  public var nextWindowDescription: String = "Idle"
  /// What copies wait for when none is running.
  public var waitingDescription = ProductCopy.idleCopiesWaiting(onlyWhileCharging: false)

  public var totalCount: Int {
    copiedCount + pendingCount
  }

  /// One line for an account row, shared by both apps.
  public var statusText: String {
    guard isMirrorEnabled else { return "Not keeping a copy" }
    if isRunning { return nextWindowDescription }
    if let lastError { return lastError }
    if pendingCount > 0 { return waitingDescription }
    return totalCount > 0 && pendingCount == 0
      ? "Copy up to date" : "Copied \(copiedCount.formatted()) of \(totalCount.formatted())"
  }

  public init(
    email: String,
    isMirrorEnabled: Bool = true,
    pendingCount: Int = 0,
    copiedCount: Int = 0,
    isRunning: Bool = false,
    lastRunAt: Date? = nil,
    lastError: String? = nil,
    nextWindowDescription: String = "Idle"
  ) {
    self.email = email
    self.isMirrorEnabled = isMirrorEnabled
    self.pendingCount = pendingCount
    self.copiedCount = copiedCount
    self.isRunning = isRunning
    self.lastRunAt = lastRunAt
    self.lastError = lastError
    self.nextWindowDescription = nextWindowDescription
  }
}

/// Orchestrates uploading a secondary copy of all primary items to secondary Google accounts during idle time.
@MainActor
@Observable
public final class AccountMirror {
  private weak var engine: SyncEngine?
  private var runners: [String: SecondaryRunner] = [:]
  public private(set) var secondaryStates: [String: SecondaryMirrorState] = [:]
  private var activeWindowTask: Task<Void, Never>?

  public init(engine: SyncEngine) {
    self.engine = engine
  }

  public var isRunning: Bool {
    secondaryStates.values.contains { $0.isRunning }
  }

  public var hasPendingWork: Bool {
    secondaryStates.values.contains { $0.isMirrorEnabled && $0.pendingCount > 0 }
  }

  public func state(for email: String) -> SecondaryMirrorState? {
    secondaryStates[email]
  }

  // MARK: - Work-List Selection (Pure Function)

  /// A secondary copy is stored under the primary record's unscoped id, so the same
  /// resource (including which of an asset's resources it is) matches exactly.
  nonisolated static func copies(in records: [TransferRecord], secondaryEmail: String) -> [String: TransferRecord] {
    records.reduce(into: [:]) { copies, record in
      guard record.isTerminalSuccess, record.sentAccountEmails.contains(secondaryEmail),
        TransferRecord.accountEmail(fromScopedID: record.id) == secondaryEmail
      else { return }
      copies[TransferRecord.unscopedID(from: record.id)] = record
    }
  }

  nonisolated static func matches(_ copy: TransferRecord?, source: TransferRecord) -> Bool {
    guard let copy else { return false }
    return copy.sha1 == source.sha1
      && copy.pairedSourceSHA1 == source.pairedSourceSHA1
      && (source.resourceRole == .uneditedOriginal
        || !TransferRecord.isAssetEdited(source.assetModifiedAt, since: copy.assetModifiedAt))
  }

  /// Primary records still waiting for a copy in `secondaryEmail`. Linear in the
  /// record count: it runs on the main actor on every records refresh.
  /// - Parameter isSourceAvailable: Whether the file or photo asset still exists.
  nonisolated public static func eligiblePrimaryRecords(
    from records: [TransferRecord],
    primaryEmail: String,
    secondaryEmail: String,
    isSourceAvailable: (TransferRecord) -> Bool = { _ in true }
  ) -> [TransferRecord] {
    let copied = copies(in: records, secondaryEmail: secondaryEmail)
    return records.filter { rec in
      rec.status == .sent
        && TransferRecord.accountEmail(fromScopedID: rec.id) == primaryEmail
        && !matches(copied[TransferRecord.unscopedID(from: rec.id)], source: rec)
        && isSourceAvailable(rec)
    }
  }

  // MARK: - State Management

  public func reloadAccounts(accounts: [GoogleAccount], primaryEmail: String?) {
    let secondaries = accounts.filter { $0.email != primaryEmail }
    let secondaryEmails = Set(secondaries.map(\.email))

    // Remove obsolete runners and states
    for email in Array(runners.keys) where !secondaryEmails.contains(email) {
      runners[email]?.cancel()
      runners.removeValue(forKey: email)
      secondaryStates.removeValue(forKey: email)
    }

    // Add or update runners
    for account in secondaries {
      if let existing = runners[account.email] {
        existing.updateAccount(account)
      } else if let engine {
        runners[account.email] = SecondaryRunner(account: account, engine: engine)
      }
      if secondaryStates[account.email] == nil {
        secondaryStates[account.email] = SecondaryMirrorState(
          email: account.email,
          isMirrorEnabled: account.mirrorEnabled
        )
      } else {
        secondaryStates[account.email]?.isMirrorEnabled = account.mirrorEnabled
      }
    }
    refreshStates()
  }

  public func setMirrorEnabled(email: String, enabled: Bool) {
    secondaryStates[email]?.isMirrorEnabled = enabled
    runners[email]?.setMirrorEnabled(enabled)
    if !enabled {
      runners[email]?.cancel()
    }
  }

  public func cancelMirror(for email: String) {
    runners[email]?.cancel()
    runners.removeValue(forKey: email)
    secondaryStates.removeValue(forKey: email)
  }

  public func refreshStates() {
    guard let engine else { return }
    let records = engine.records
    let primaryEmail = engine.selectedAccount?.email

    for (email, runner) in runners {
      var state = secondaryStates[email] ?? SecondaryMirrorState(email: email, isMirrorEnabled: runner.account.mirrorEnabled)
      state.isMirrorEnabled = runner.account.mirrorEnabled
      state.isRunning = runner.isRunning
      state.lastRunAt = runner.lastRunAt
      state.lastError = runner.lastError
      state.nextWindowDescription = runner.progressDescription
      state.waitingDescription = ProductCopy.idleCopiesWaiting(
        onlyWhileCharging: engine.settings.copiesOnlyWhileCharging)

      let key = CountsKey(revision: engine.recordsRevision, primaryEmail: primaryEmail)
      let counts: (copied: Int, pending: Int)
      if let cached = cachedCounts[email], cached.key == key {
        counts = cached.counts
      } else {
        var copied = 0
        var pending = 0
        if let primaryEmail {
          let copies = Self.copies(in: records, secondaryEmail: email)
          for rec in records where rec.status == .sent && TransferRecord.accountEmail(fromScopedID: rec.id) == primaryEmail {
            if Self.matches(copies[TransferRecord.unscopedID(from: rec.id)], source: rec) { copied += 1 } else { pending += 1 }
          }
        }
        counts = (copied, pending)
        cachedCounts[email] = (key, counts)
      }
      state.copiedCount = counts.copied
      state.pendingCount = counts.pending
      // Every assignment invalidates the account rows, even when nothing changed.
      if secondaryStates[email] != state { secondaryStates[email] = state }
    }
  }

  private struct CountsKey: Equatable {
    var revision: Int?
    var primaryEmail: String?
  }

  /// Per secondary account, the counts last worked out and the records they came from.
  /// Counting walks the whole manifest, and a refresh usually changes nothing.
  @ObservationIgnored private var cachedCounts: [String: (key: CountsKey, counts: (copied: Int, pending: Int))] = [:]

  // MARK: - Window Execution

  public func runIdleWindow() async {
    guard activeWindowTask == nil else { return }
    guard let engine, engine.allowsAutomaticUploads, !engine.workerPool.isRunning else { return }

    let task = Task { @MainActor in
      defer { self.activeWindowTask = nil }
      self.refreshStates()

      for (_, runner) in self.runners {
        guard !Task.isCancelled, let engine = self.engine, !engine.workerPool.isRunning else { break }
        guard runner.account.mirrorEnabled else { continue }
        await runner.runWindow()
        self.refreshStates()
      }
    }
    activeWindowTask = task
    await task.value
  }

  public func pauseAll() {
    activeWindowTask?.cancel()
    for runner in runners.values {
      runner.cancel()
    }
    refreshStates()
  }
}

// MARK: - Secondary Runner

@MainActor
final class SecondaryRunner {
  var account: GoogleAccount
  private weak var engine: SyncEngine?
  private let authService: GoogleAuthService
  private let mobileClient: GooglePhotosMobileClient
  private let workerPool: UploadWorkerPool

  private(set) var isRunning: Bool = false
  private(set) var lastRunAt: Date?
  private(set) var lastError: String?
  private var currentBackoffDelay: TimeInterval = 0
  private var isCancelled: Bool = false
  var progressDescription: String {
    if workerPool.isRateLimited { return "Waiting on Google Photos" }
    if let engine, engine.isOffline { return "Waiting for a connection" }
    if workerPool.isRunning {
      return workerPool.workers.first { !$0.itemID.isEmpty }?.message ?? "Preparing a copy…"
    }
    return isRunning
      ? "Waiting for the next copy"
      : ProductCopy.idleCopiesWaiting(onlyWhileCharging: engine?.settings.copiesOnlyWhileCharging ?? false)
  }

  init(account: GoogleAccount, engine: SyncEngine) {
    self.account = account
    self.engine = engine
    let auth = GoogleAuthService()
    self.authService = auth
    self.mobileClient = GooglePhotosMobileClient(authService: auth, isolatedSession: true)
    let pool = UploadWorkerPool(client: mobileClient, manifestStore: engine.manifestStore)
    pool.setConcurrency(1)
    pool.pairLivePhotos = engine.settings.pairLivePhotos
    pool.useFilenameDate = engine.settings.setDateFromFilename
    pool.claimPhotoUpload = engine.workerPool.claimPhotoUpload
    pool.releasePhotoUpload = engine.workerPool.releasePhotoUpload
    self.workerPool = pool
    pool.onProgressUpdated = { [weak engine] in engine?.accountMirror.refreshStates() }
  }

  func updateAccount(_ account: GoogleAccount) {
    self.account = account
    workerPool.pairLivePhotos = engine?.settings.pairLivePhotos ?? true
    workerPool.useFilenameDate = engine?.settings.setDateFromFilename ?? false
  }

  func setMirrorEnabled(_ enabled: Bool) {
    account.mirrorEnabled = enabled
  }

  func cancel() {
    isCancelled = true
    workerPool.cancel()
    workerPool.abortAlbumUpdates()
  }

  func runWindow() async {
    guard !isRunning, account.mirrorEnabled else { return }
    guard let engine, !engine.workerPool.isRunning, engine.idleMirrorConditionsHold() else { return }

    isCancelled = false
    isRunning = true
    lastRunAt = Date()
    defer {
      isRunning = false
      engine.accountMirror.refreshStates()
    }
    engine.accountMirror.refreshStates()

    do {
      try await authService.setCredential(account.credentialString)
    } catch {
      logger.error("Failed to set credential for mirror account \(self.account.email): \(error.localizedDescription)")
      lastError = "Sign in again"
      await BackupNotifier.shared.notifyAccountNeedsSignIn(email: self.account.email)
      return
    }

    let windowStart = Date()
    var itemsProcessed = 0
    let maxItems = 500
    let maxDuration: TimeInterval = 2 * 60 * 60  // 2 hours

    logger.info("Starting mirror idle window for \(self.account.email)")

    guard let primaryEmail = engine.selectedAccount?.email else { return }
    // One snapshot per window. Each item is tried at most once per window, so a source
    // that cannot be rebuilt or keeps failing never spins the loop.
    let work = AccountMirror.eligiblePrimaryRecords(
      from: engine.records,
      primaryEmail: primaryEmail,
      secondaryEmail: account.email
    )
    guard !work.isEmpty else { return }
    var hasSource = false
    var hadAuthError = false
    let manifest = engine.manifestStore

    for primaryRecord in work {
      guard !isCancelled, !Task.isCancelled else { break }
      guard let currentEngine = self.engine, !currentEngine.workerPool.isRunning,
        currentEngine.selectedAccount?.email == primaryEmail
      else {
        logger.info("Pausing mirror window: primary upload pool became active")
        break
      }
      guard currentEngine.idleMirrorConditionsHold() else {
        logger.info("Pausing mirror window: idle conditions no longer hold")
        break
      }
      if itemsProcessed >= maxItems {
        logger.info("Reached mirror window cap of 500 items for \(self.account.email)")
        break
      }
      if Date().timeIntervalSince(windowStart) >= maxDuration {
        logger.info("Reached mirror window 2 hour limit for \(self.account.email)")
        break
      }

      let rawID = TransferRecord.unscopedID(from: primaryRecord.id)
      let secondaryID = TransferRecord.accountScopedID(rawID, accountEmail: account.email)
      let previous = await manifest.record(for: secondaryID)
      if let previous {
        guard previous.status != .sending, previous.isDueForAutomaticRetry(),
          !AccountMirror.matches(previous.isTerminalSuccess ? previous : nil, source: primaryRecord)
        else { continue }
      }
      guard let queueItem = await currentEngine.mirrorItem(for: primaryRecord) else { continue }
      hasSource = true
      guard !isCancelled, !Task.isCancelled, !currentEngine.isRunning else { break }
      let mirrorItem = queueItem.withID(secondaryID, mirrorSource: primaryRecord)

      guard await prepareRecord(id: secondaryID, from: primaryRecord, previous: previous, manifest: manifest),
        await manifest.claimForUpload(id: secondaryID)
      else { continue }

      let outcome = workerPool.start(items: [mirrorItem], quality: 3, accountEmail: account.email)
      guard outcome == .started else {
        await manifest.releaseUploadClaim(id: secondaryID)
        break
      }

      await workerPool.waitForCurrentBatch()
      await currentEngine.refreshRecords()
      guard !isCancelled, !Task.isCancelled else { break }

      let record = await manifest.record(for: secondaryID)
      if record?.status == .sent {
        itemsProcessed += 1
        currentBackoffDelay = 0
        lastError = nil
        BackupNotifier.shared.clearSignInNotice(for: account.email)
        // A phone backing up does not fire uploads back to back.
        try? await Task.sleep(for: .seconds(Double.random(in: 3.0...8.0)))
      } else {
        let errorMsg = record?.lastError ?? "Transfer failed"
        lastError = errorMsg
        if workerPool.lastItemRanOutOfSpace { break }

        if isAuthError(errorMsg) {
          logger.error("Stopping mirror window for \(self.account.email): auth error")
          lastError = "Sign in again"
          hadAuthError = true
          await BackupNotifier.shared.notifyAccountNeedsSignIn(email: self.account.email)
          break
        }

        if isRateOrServerError(errorMsg) {
          currentBackoffDelay = min(900, currentBackoffDelay == 0 ? 30 : currentBackoffDelay * 2)
          logger.warning("Mirror rate limit/server error: backing off for \(self.currentBackoffDelay)s")
          try? await Task.sleep(for: .seconds(currentBackoffDelay))
        } else {
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }

    if !hasSource, lastError == nil, !Task.isCancelled {
      lastError = "Waiting for originals to become available"
    }
    await BackupNotifier.shared.notifySecondaryCopyCompletion(
      copiedCount: itemsProcessed,
      secondaryEmail: account.email,
      hasAuthError: hadAuthError
    )
  }

  /// The secondary copy gets its own record, scoped to the secondary account, so the
  /// manifest tracks it like any upload. It starts from the primary record's source
  /// fields with every upload and deletion field cleared.
  private func prepareRecord(
    id: String, from primary: TransferRecord, previous: TransferRecord?, manifest: TransferManifestStore
  ) async -> Bool {
    var record = TransferRecord(copying: primary, id: id)
    record.status = .pending
    record.progress = 0
    record.transferredByteCount = 0
    record.attempts = previous?.attempts ?? 0
    record.lastFailedAt = previous?.lastFailedAt
    record.preparedAsset = previous?.preparedAsset
    record.sentAt = nil
    record.deletedAt = nil
    record.deleteAfter = nil
    record.sentAccountEmails = []
    record.mediaKeysByAccount = [:]
    record.foundInAccounts = []
    record.lastError = nil
    record.sharedEntryID = nil
    return await manifest.upsertBatch([record], ifUnchangedSince: previous.map { [id: $0] } ?? [:])
  }

  private func isAuthError(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("401") || lower.contains("403") || lower.contains("unauthorized")
      || lower.contains("invalid credentials") || lower.contains("sign in again")
  }

  private func isRateOrServerError(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("429") || lower.contains("500") || lower.contains("502")
      || lower.contains("503") || lower.contains("504") || lower.contains("quota")
      || lower.contains("too many requests")
  }
}
