import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.gphotosapp.gphotos", category: "SyncEngine")

@MainActor
@Observable
open class SyncEngine: NSObject {
  public private(set) var accounts: [GoogleAccount] = []
  public private(set) var selectedAccount: GoogleAccount?
  public private(set) var settings: AppSettings
  public private(set) var records: [TransferRecord] = []
  public private(set) var statusMessage: String = "Ready"
  /// Mirrors `NetworkStatusMonitor.isExpensive` so views update when it changes.
  public private(set) var isOnMeteredNetwork = NetworkStatusMonitor.shared.isExpensive
  public private(set) var isOffline = !NetworkStatusMonitor.shared.isConnected

  public let authService: GoogleAuthService
  public let manifestStore: TransferManifestStore
  public let client: GooglePhotosMobileClient
  public let workerPool: UploadWorkerPool
  /// Confirms with Google Photos that uploads are still there before anything is removed.
  public let remoteCopyVerifier: RemoteCopyVerifier
  public private(set) var accountMirror: AccountMirror!
  /// The Google Photos library of the selected account, synced for browsing.
  public private(set) var cloudLibrary: CloudLibrary? {
    // Siri browses the same account, also when it runs the app without its window.
    didSet { SiriLibrary.shared.cloud = cloudLibrary }
  }
  public let shareObserver = ShareObserverHolder()
  public private(set) var accountGeneration = 0
  private var isIngestingSharedQueue = false
  private var sharedIngestionRequested = false
  private var completionRefreshTask: Task<Void, Never>?
  /// When each shared-queue item last failed in this process. Paired with the record's
  /// persisted attempt count, it keeps a failing item from being re-sent on every ingest.
  private var sharedFailureTimes: [String: Date] = [:]
  static let sharedRetryBackoff = Backoff(baseDelay: 30, maxDelay: 30 * 60, maxRetries: 5)

  public override init() {
    let auth = GoogleAuthService()
    let manifest = TransferManifestStore.shared
    let settings = AppSettingsStore.load()
    self.settings = settings
    self.authService = auth
    self.manifestStore = manifest
    let mobileClient = GooglePhotosMobileClient(
      authService: auth, allowsExpensiveNetworkAccess: settings.uploadsOnMeteredNetworks)
    self.client = mobileClient
    self.remoteCopyVerifier = RemoteCopyVerifier(client: mobileClient)
    let pool = UploadWorkerPool(client: mobileClient, manifestStore: manifest)
    self.workerPool = pool

    super.init()
    // Off the main thread, so launch doesn't wait for it; ready by the first records read.
    Task.detached(priority: .userInitiated) { await manifest.load() }
    let mirror = AccountMirror(engine: self)
    self.accountMirror = mirror
    pool.useFilenameDate = settings.setDateFromFilename
    pool.pairLivePhotos = settings.pairLivePhotos
    pool.onBatchStarted = { [weak self] in
      self?.accountMirror?.pauseAll()
      self?.primaryBatchDidStart()
    }

    pool.onItemCompleted = { [weak self] in
      await self?.scheduleCompletionRefresh()
    }

    pool.onItemFinished = { [weak self] itemID, status in
      Task { @MainActor in
        if status == .failed { self?.sharedFailureTimes[itemID] = Date() }
        await self?.handleSharedItemFinished(itemID: itemID, status: status)
      }
    }

    reconnectObserver = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didReconnect, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.retryAfterReconnect() }
    }
    meteredObserver = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didChangeExpensive, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshMeteredNetwork() }
    }
    connectivityObserver = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didChangeConnectivity, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshMeteredNetwork() }
    }
    // The monitor's first path can arrive before the observer above was added.
    Task { @MainActor [weak self] in self?.refreshMeteredNetwork() }

    self.shareObserver.token = SharedQueueBridge.observeItemsAdded { [weak self] in
      Task { @MainActor in
        await self?.ingestSharedQueueItems()
      }
    }
  }

  public var isRunning: Bool {
    workerPool.isRunning
  }

  @ObservationIgnored private var reconnectObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var lastReconnectRetry: Date?
  @ObservationIgnored private var needsResumeAfterLostNetwork = false
  @ObservationIgnored private var lostNetworkRetryDelay: TimeInterval = 60
  private static let longestLostNetworkRetryDelay: TimeInterval = 10 * 60
  @ObservationIgnored private var lostNetworkRetryTask: Task<Void, Never>?
  @ObservationIgnored private var meteredObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var connectivityObserver: (any NSObjectProtocol)?

  /// Uploads are held by the client until an unmetered network is available.
  public var isWaitingForUnmeteredNetwork: Bool {
    isOnMeteredNetwork && !settings.uploadsOnMeteredNetworks
  }

  /// Called when `isWaitingForUnmeteredNetwork` changes. Overridden by each app.
  open func waitingForNetworkDidChange() {}

  private func refreshMeteredNetwork() {
    let wasWaiting = isWaitingForUnmeteredNetwork
    let wasOffline = isOffline
    isOnMeteredNetwork = NetworkStatusMonitor.shared.isExpensive
    isOffline = !NetworkStatusMonitor.shared.isConnected
    if isWaitingForUnmeteredNetwork != wasWaiting || isOffline != wasOffline { waitingForNetworkDidChange() }
  }

  /// Retries failed items in the background. Overridden by each app.
  open func retryFailed() async {}

  /// The user asked for the failed items again, which ends any skip after a crash. Automatic
  /// retries leave those in place, so an item that ends the process can't do so repeatedly.
  open func retryFailedForUser() async {
    for record in failedRecords { PreparationGuard.shared.forgive(record.id) }
    await retryFailed()
  }

  /// Uploads that failed while offline go again once the network is back. Throttled,
  /// because a flapping connection must not resend the same failures over and over.
  private func retryAfterReconnect() async {
    guard allowsAutomaticUploads, !isRunning, needsResumeAfterLostNetwork || !failedRecords.isEmpty else { return }
    // The throttle is for failures; a batch waiting on this reconnect has nothing else coming.
    if !needsResumeAfterLostNetwork, let lastReconnectRetry, Date().timeIntervalSince(lastReconnectRetry) < 5 * 60 {
      return
    }
    lastReconnectRetry = Date()
    if needsResumeAfterLostNetwork {
      needsResumeAfterLostNetwork = false
      await resumePendingWork()
    }
    await retryFailed()
  }

  public var isPaused: Bool {
    workerPool.isPaused
  }

  public var failedRecords: [TransferRecord] {
    records.filter { $0.status == .failed }
  }

  /// Backed-up items whose bytes were already in the selected account, which cleanup
  /// keeps unless `removesItemsAlreadyInGooglePhotos` is on.
  public var foundInAccountCount: Int {
    guard let email = selectedAccount?.email else { return 0 }
    return records.reduce(0) { $0 + ($1.status == .sent && $1.foundInAccounts.contains(email) ? 1 : 0) }
  }

  public func activeWorker(for itemIdOrPath: String, filename: String? = nil) -> WorkerState? {
    let isActive: (WorkerState) -> Bool = {
      $0.status == "uploading" || $0.status == "hashing" || $0.status == "checking" || $0.status == "finalizing"
    }
    if let worker = workerPool.workers.first(where: { $0.itemID == itemIdOrPath && isActive($0) }) {
      return worker
    }
    let fallbackName = URL(fileURLWithPath: itemIdOrPath).lastPathComponent
    let matches = workerPool.workers.filter { isActive($0) && $0.filename == (filename ?? fallbackName) }
    return matches.count == 1 ? matches[0] : nil
  }

  /// Accounts and their upload records have been read once, so the Library can draw the
  /// whole merged timeline in one go instead of adding Google Photos to it afterwards.
  public private(set) var hasLoadedAccounts = false

  private typealias StoredAccounts = (accounts: [GoogleAccount], selected: GoogleAccount?)
  @ObservationIgnored private var accountsPrefetch: Task<Result<StoredAccounts, any Error>, Never>?
  @ObservationIgnored private var accountsPrefetchedAt = ContinuousClock.now

  /// Starts reading the stored accounts and the upload manifest at once (call while the
  /// app is still launching), so the first `loadAccounts()` finds them read.
  public func prefetchAccounts() {
    guard accountsPrefetch == nil, !hasLoadedAccounts else { return }
    let authService = authService
    // The manifest is read on its first use too; that read joins the keychain's.
    let manifestStore = manifestStore
    Task.detached(priority: .userInitiated) { await manifestStore.load() }
    accountsPrefetchedAt = .now
    accountsPrefetch = Task.detached(priority: .userInitiated) {
      do { return .success(try await authService.accountsAndSelection()) } catch { return .failure(error) }
    }
  }

  public func loadAccounts() async {
    accountGeneration += 1
    cancelLostNetworkRetry()
    // A keychain read that fails is not the same as being signed out. Reporting both
    // as "no accounts" makes an entitlement or locked-keychain problem look like a
    // request to sign in again, which then fails for the same reason.
    var credentialFailure: String?
    // Only the first load can use the read started at launch, and only soon after it:
    // later ones (a sign-in, an account switch) read again.
    let prefetched = ContinuousClock.now - accountsPrefetchedAt < .seconds(10) ? accountsPrefetch : nil
    accountsPrefetch = nil
    do {
      let stored: StoredAccounts
      if let prefetched {
        stored = try await prefetched.value.get()
      } else {
        stored = try await authService.accountsAndSelection()
      }
      self.accounts = stored.accounts
      self.selectedAccount = stored.selected
    } catch {
      self.accounts = []
      self.selectedAccount = nil
      credentialFailure = error.localizedDescription
    }
    updateCloudLibrary()
    // Siri forgets an account signed out or switched from; a keychain that can't be read
    // says nothing about which account is browsed.
    if credentialFailure == nil {
      let email = selectedAccount?.email
      Task { await SiriLibrary.shared.spotlight.browsedAccountChanged(to: email) }
    }
    if let sel = selectedAccount {
      do {
        try await authService.setCredential(sel.credentialString)
        statusMessage = "Active account: \(sel.email)"
      } catch {
        // A credential that cannot be written is unusable, so it must not be reported
        // as a healthy active account.
        credentialFailure = credentialFailure ?? error.localizedDescription
        statusMessage = "Credentials could not be saved."
      }
    } else {
      statusMessage = "No accounts configured."
    }
    credentialError = credentialFailure
    AccountPhotoStore.shared.update(for: accounts)
    // The account-scoped caches are derived from `selectedAccount`, so they must be
    // rebuilt here or a sign-out / account switch keeps showing the previous
    // account's records.
    await refreshRecords()
    hasLoadedAccounts = true
    await accountsDidChange()
    accountMirror?.reloadAccounts(accounts: accounts, primaryEmail: selectedAccount?.email)
  }

  /// Set when stored credentials could not be read, so the UI can distinguish a
  /// keychain failure from a signed-out state.
  public private(set) var credentialError: String?

  open func accountsDidChange() async {}

  /// Item transitions arrive in bursts (several workers, start and finish), and each
  /// refresh copies the whole manifest, so they are coalesced into one pass.
  private func scheduleCompletionRefresh() {
    guard completionRefreshTask == nil else { return }
    completionRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self else { return }
      self.completionRefreshTask = nil
      await self.refreshRecords()
      await self.removeCompletedSharedEntries()
      await self.transferItemDidComplete()
    }
  }

  open func transferItemDidComplete() async {}

  /// Called after a primary batch starts and secondary copies were paused. Subclasses
  /// override this rather than replacing `onBatchStarted`, which this class owns.
  open func primaryBatchDidStart() {}

  /// Subclasses call this from their batch-completion handler (they own `onBatchCompleted`).
  open func primaryBatchDidComplete() async {
    // The Library shows the new uploads from Google Photos soon, not at the next delta.
    if workerPool.lastBatchCompletedCount > 0 { cloudLibrary?.refreshAfterUpload() }
    scheduleRetryAfterLostNetwork()
  }

  /// Stop, sign-out and account changes end any resume still waiting to run.
  public func cancelLostNetworkRetry() {
    lostNetworkRetryTask?.cancel()
    lostNetworkRetryTask = nil
    lostNetworkRetryDelay = 60
    needsResumeAfterLostNetwork = false
  }

  /// Queues whatever is still waiting to go up. Overridden by each app.
  open func resumePendingWork() async {}

  /// A connection that looks up but carries nothing (a VPN reconnecting, say) never reports
  /// coming back, so a batch cut short by the network also tries again by itself.
  private func scheduleRetryAfterLostNetwork() {
    if workerPool.isBatchCancelled {
      cancelLostNetworkRetry()
    } else if workerPool.lastBatchLostNetwork {
      needsResumeAfterLostNetwork = true
      let delay = lostNetworkRetryDelay
      lostNetworkRetryDelay = min(delay * 2, Self.longestLostNetworkRetryDelay)
      armLostNetworkRetry(after: delay)
    } else if needsResumeAfterLostNetwork {
      // This batch was fine, but one before it was cut short and is still owed its resume.
      armLostNetworkRetry(after: 1)
    } else {
      lostNetworkRetryDelay = 60
    }
  }

  private func armLostNetworkRetry(after delay: TimeInterval) {
    let generation = accountGeneration
    lostNetworkRetryTask?.cancel()
    lostNetworkRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, self.accountGeneration == generation, self.allowsAutomaticUploads,
        self.needsResumeAfterLostNetwork
      else { return }
      // A batch still finishing refuses new work, and offline there's nothing to resume yet.
      guard !self.workerPool.isBatchFinalizing, NetworkStatusMonitor.shared.isConnected else {
        self.armLostNetworkRetry(after: min(delay * 2, Self.longestLostNetworkRetryDelay))
        return
      }
      // A running batch comes back here when it completes, with the flag still set.
      guard !self.isRunning else { return }
      self.needsResumeAfterLostNetwork = false
      await self.resumePendingWork()
    }
  }

  /// The manifest revision `records` reflects. A refresh while it is unchanged copies,
  /// sorts and compares nothing.
  @ObservationIgnored public private(set) var recordsRevision: Int?

  open func refreshRecords() async {
    if let latest = await manifestStore.sortedRecords(ifChangedSince: recordsRevision) {
      recordsRevision = latest.revision
      records = latest.records
    }
    accountMirror?.refreshStates()
  }

  /// Gates every automatic start (shared-queue ingest, settings changes, batch
  /// completion). Subclasses return false while the user has stopped transfers.
  open var allowsAutomaticUploads: Bool { true }

  open func updateSettings(_ newSettings: AppSettings) {
    let wasWaiting = isWaitingForUnmeteredNetwork
    let copyRuleChanged = settings.copiesOnlyWhileCharging != newSettings.copiesOnlyWhileCharging
    self.settings = newSettings
    if isWaitingForUnmeteredNetwork != wasWaiting { waitingForNetworkDidChange() }
    if copyRuleChanged { accountMirror.refreshStates() }
    do {
      try AppSettingsStore.save(newSettings)
    } catch {
      logger.error("Saving settings failed: \(error.localizedDescription, privacy: .public)")
      statusMessage = "Settings could not be saved: \(error.localizedDescription)"
    }
    workerPool.setConcurrency(newSettings.uploadThreads)
    workerPool.useFilenameDate = newSettings.setDateFromFilename
    workerPool.pairLivePhotos = newSettings.pairLivePhotos
    let delay = newSettings.autoDeleteDelay
    let allowsMetered = newSettings.uploadsOnMeteredNetworks
    Task {
      await client.setAllowsExpensiveNetworkAccess(allowsMetered)
      await manifestStore.setRetention(delay)
      await self.ingestSharedQueueItems()
    }
  }

  /// Leaves a folder or file name ("CapCut", "*.tmp") or a folder path out of every
  /// backed-up folder.
  public func addBackupExclusion(_ rule: String) {
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rule.isEmpty, !FolderExclusions([rule]).isEmpty,
      !settings.backupExclusions.contains(where: { $0.caseInsensitiveCompare(rule) == .orderedSame })
    else { return }
    var copy = settings
    copy.backupExclusions.append(rule)
    updateSettings(copy)
  }

  public func removeBackupExclusion(_ rule: String) {
    var copy = settings
    copy.backupExclusions.removeAll { $0 == rule }
    updateSettings(copy)
  }

  open func toggleAutoSync() {
    var copy = settings
    copy.autoSyncEnabled.toggle()
    updateSettings(copy)
  }

  /// One cloud library per browsed account; a new account gets its own.
  private func updateCloudLibrary() {
    #if DEBUG
      if UserDefaults.standard.string(forKey: "UIScreen")?.hasPrefix("cloud") == true {
        if cloudLibrary == nil {
          let screen = UserDefaults.standard.string(forKey: "UIScreen") ?? ""
          let large = screen == "cloudLarge" || screen.hasSuffix("Stress")
          cloudLibrary = .preview(itemCount: large ? 100_000 : 600)
        }
        return
      }
    #endif
    guard cloudLibrary?.accountEmail != selectedAccount?.email else { return }
    cloudLibrary?.cancelSync()
    cloudLibrary = selectedAccount.map { CloudLibrary(accountEmail: $0.email, client: client) }
  }

  public func signOut() async {
    accountGeneration += 1
    cancelLostNetworkRetry()
    await cloudLibrary?.removeLocalData()
    workerPool.cancel()
    workerPool.abortAlbumUpdates()
    await workerPool.waitForCurrentBatch()
    accountMirror?.pauseAll()
    do {
      try await authService.signOut()
    } catch {
      statusMessage = "Sign-out could not remove all stored credentials."
    }
    await loadAccounts()
  }

  public func setPrimary(email: String) async {
    guard selectedAccount?.email != email else { return }
    accountGeneration += 1
    cancelLostNetworkRetry()
    workerPool.cancel()
    workerPool.abortAlbumUpdates()
    await workerPool.waitForCurrentBatch()
    accountMirror?.pauseAll()
    do {
      try KeychainStore.setPrimary(email: email)
    } catch {
      statusMessage = "Could not update primary account: \(error.localizedDescription)"
    }
    await loadAccounts()
  }

  public func removeAccount(email: String) async {
    let wasPrimary = (selectedAccount?.email == email)
    if wasPrimary {
      accountGeneration += 1
      cancelLostNetworkRetry()
      workerPool.cancel()
      workerPool.abortAlbumUpdates()
      await workerPool.waitForCurrentBatch()
    }
    accountMirror?.cancelMirror(for: email)
    do {
      try KeychainStore.removeAccount(email: email)
    } catch {
      statusMessage = "Could not remove account: \(error.localizedDescription)"
    }
    await manifestStore.removeRecords(forAccountEmail: email)
    AlbumKeyStore.shared.forgetAll(forAccountEmail: email)
    if cloudLibrary?.accountEmail == email {
      await cloudLibrary?.removeLocalData()
    } else {
      await CloudLibrary.removeLocalData(forAccountEmail: email)
    }
    await loadAccounts()
  }

  public func setMirrorEnabled(email: String, enabled: Bool) async {
    do {
      try KeychainStore.setMirrorEnabled(email: email, enabled: enabled)
      accounts = (try? await authService.accounts()) ?? []
      accountMirror?.setMirrorEnabled(email: email, enabled: enabled)
      if !enabled {
        await manifestStore.removeRecords(forAccountEmail: email, keepingSent: true)
        await refreshRecords()
      }
    } catch {
      statusMessage = "Could not update mirror setting: \(error.localizedDescription)"
    }
  }

  open func mirrorItem(for record: TransferRecord) async -> UploadQueueItem? {
    nil
  }

  /// Whether the idle conditions a copy window started under (power, network) still
  /// hold. Checked before each copy, so with Copy Only While Charging on, a window started
  /// while charging does not carry on for hours on battery.
  open func idleMirrorConditionsHold() -> Bool {
    true
  }

  public func addAccountFromOAuthToken(_ token: String) async throws {
    let hadPrimary = (selectedAccount != nil)
    if !hadPrimary {
      accountGeneration += 1
      cancelLostNetworkRetry()
      if isRunning {
        workerPool.cancel()
        workerPool.abortAlbumUpdates()
        await workerPool.waitForCurrentBatch()
      }
    }
    let account = try await authService.addAccountFromOAuthToken(token)
    await loadAccounts()
    if !hadPrimary {
      await ingestSharedQueueItems()
    }
    statusMessage = "Added \(account.email)"
  }

  public func addAccountFromRawCredential(_ raw: String) async throws {
    let hadPrimary = (selectedAccount != nil)
    if !hadPrimary {
      accountGeneration += 1
      cancelLostNetworkRetry()
      if isRunning {
        workerPool.cancel()
        workerPool.abortAlbumUpdates()
        await workerPool.waitForCurrentBatch()
      }
    }
    let account = try await authService.addAccountWithRawCredential(raw)
    await loadAccounts()
    if !hadPrimary {
      await ingestSharedQueueItems()
    }
    statusMessage = "Added \(account.email)"
  }

  public func ingestSharedQueueItems() async {
    guard !isIngestingSharedQueue else {
      sharedIngestionRequested = true
      return
    }
    isIngestingSharedQueue = true
    defer {
      isIngestingSharedQueue = false
      if sharedIngestionRequested {
        sharedIngestionRequested = false
        Task { @MainActor [weak self] in
          await self?.ingestSharedQueueItems()
        }
      }
    }

    guard let accountEmail = selectedAccount?.email else { return }
    await removeCompletedSharedEntries()
    guard !Task.isCancelled else { return }
    let generation = accountGeneration
    let entries = await Self.loadSharedEntries()
    guard !Task.isCancelled else { return }
    let current = await manifestStore.allRecords()
    let protectedPaths = Set(current.compactMap { $0.sourcePath })
    Task.detached(priority: .utility) {
      SharedQueueBridge.removeOrphanedIncomingFiles(protectedPaths: protectedPaths)
    }
    guard !Task.isCancelled else { return }
    var known: [String: TransferRecord] = [:]
    known.reserveCapacity(current.count)
    var activeSharedEntryIDs = Set<UUID>()
    for record in current {
      known[record.id] = record
      if let entryID = record.sharedEntryID,
        record.status == .pending || record.status == .sending || record.status == .failed
      {
        activeSharedEntryIDs.insert(entryID)
      }
    }

    let canUpload = allowsAutomaticUploads && (settings.autoStartQueue || settings.autoSyncEnabled)
    var candidateItems: [UploadQueueItem] = []
    var newRecords: [TransferRecord] = []
    var queuedIDs = Set<String>()
    var removableEntryIDs = Set<UUID>()

    for entry in entries {
      // `pending-uploads.json` is written by another App Group process, so its hash is
      // a claim. Trust it only while the staged file still matches the recorded size.
      let entrySHA1 = Data(base64Encoded: entry.sha1Base64).flatMap { $0.count == 20 ? entry.sha1Base64 : nil }

      let id = TransferRecord.accountScopedID(entry.id.uuidString, accountEmail: accountEmail)
      if let existing = known[id] {
        if existing.status == .sending {
          continue
        }
        if existing.status == .failed,
          !Self.sharedRetryBackoff.isReady(attempts: existing.attempts, lastAttempt: sharedFailureTimes[id])
        {
          continue
        }
        if existing.status == .sent || existing.status == .deleted {
          if (existing.sentAccountEmails.isEmpty || isHandled(existing, accountEmail: accountEmail))
            && !activeSharedEntryIDs.contains(entry.id)
          {
            removableEntryIDs.insert(entry.id)
          }
          continue
        }
      }

      guard let fileURL = SharedQueueBridge.fileURL(for: entry) else {
        if var existing = known[id], existing.status == .pending || existing.status == .failed {
          existing.status = .failed
          existing.progress = 0
          existing.transferredByteCount = 0
          existing.lastError = "Source file is no longer available"
          existing.sharedEntryID = entry.id
          known[id] = existing
          newRecords.append(existing)
        } else if known[id] == nil {
          let record = TransferRecord(
            id: id,
            filename: entry.fileName,
            mediaType: SupportedMediaFormats.isVideo(filename: entry.fileName) ? "Video" : "Photo",
            creationDate: entry.addedAt,
            status: .failed,
            byteCount: entry.bytesTotal,
            lastError: "Source file is no longer available",
            sharedEntryID: entry.id
          )
          known[id] = record
          newRecords.append(record)
        }
        continue
      }

      if workerPool.hasItem(id: id) || queuedIDs.contains(id) {
        continue
      }

      let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
      let trustedSHA1: String? = {
        guard let entrySHA1, let fileSize else { return nil }
        return fileSize == entry.bytesTotal ? entrySHA1 : nil
      }()
      var precomputedSHA1 = trustedSHA1

      if known[id] == nil {
        let record = TransferRecord(
          id: id,
          filename: entry.fileName,
          mediaType: SupportedMediaFormats.isVideo(filename: entry.fileName) ? "Video" : "Photo",
          creationDate: entry.addedAt,
          status: .pending,
          byteCount: entry.bytesTotal,
          sourcePath: fileURL.path,
          sharedEntryID: entry.id,
          sourceSHA1: trustedSHA1,
        )
        known[id] = record
        newRecords.append(record)
      } else if var existing = known[id], existing.status == .pending || existing.status == .failed {
        if existing.sourcePath != fileURL.path || existing.sharedEntryID != entry.id
          || (trustedSHA1 != nil && existing.sourceSHA1 != trustedSHA1)
        {
          existing.sourcePath = fileURL.path
          if let trustedSHA1 { existing.sourceSHA1 = trustedSHA1 }
          existing.sharedEntryID = entry.id
          known[id] = existing
          newRecords.append(existing)
        }
        if precomputedSHA1 == nil, let fileSize, fileSize == existing.byteCount {
          precomputedSHA1 = existing.sourceSHA1 ?? existing.sha1
        }
      }

      guard canUpload else { continue }
      queuedIDs.insert(id)
      candidateItems.append(
        UploadQueueItem(
          id: id,
          fileURL: fileURL,
          filename: entry.fileName,
          fileSize: entry.bytesTotal,
          creationDate: entry.addedAt,
          precomputedSHA1: precomputedSHA1,
          removeSourceOnSuccess: false
        ))
    }

    let accountPrefix = "\(accountEmail)|"
    if canUpload {
      let roots = allowedSourceRoots()
      let skips = ingestSkipPredicate()
      for record in current
      where record.id.hasPrefix(accountPrefix)
        && record.status == .pending
        && record.sourcePath != nil
        && !queuedIDs.contains(record.id)
        && !workerPool.hasItem(id: record.id)
        && !skips(record)
      {
        guard let fileURL = await existingFileURLAsync(for: record, roots: roots) else { continue }
        queuedIDs.insert(record.id)
        candidateItems.append(
          UploadQueueItem(
            id: record.id,
            fileURL: fileURL,
            filename: record.filename,
            fileSize: record.byteCount ?? 0,
            creationDate: record.creationDate,
            precomputedSHA1: record.sourceSHA1,
            precomputedSourceModifiedAt: record.sourceModifiedAt,
            removeSourceOnSuccess: isAppOwnedCopy(fileURL)
          ))
      }
    }

    guard !Task.isCancelled else { return }
    guard await manifestStore.upsertBatch(newRecords) else { return }
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == accountEmail
    else { return }
    if !removableEntryIDs.isEmpty, await manifestStore.flush() {
      do {
        try SharedQueueBridge.removeEntries(ids: removableEntryIDs)
      } catch {
        logger.error("Removing finished shared entries failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    await refreshRecords()

    guard canUpload, !candidateItems.isEmpty else { return }
    let claimedIDs = await manifestStore.claimForUpload(ids: candidateItems.map(\.id))
    let claimedItems = candidateItems.filter { claimedIDs.contains($0.id) }
    await refreshRecords()

    guard !Task.isCancelled,
      !claimedItems.isEmpty,
      accountGeneration == generation,
      selectedAccount?.email == accountEmail,
      allowsAutomaticUploads,
      settings.autoStartQueue || settings.autoSyncEnabled
    else {
      for item in claimedItems {
        await manifestStore.releaseUploadClaim(id: item.id)
      }
      return
    }

    workerPool.setConcurrency(settings.uploadThreads)
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == accountEmail
    else {
      for item in claimedItems {
        await manifestStore.releaseUploadClaim(id: item.id)
      }
      return
    }
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: accountEmail) == .rejected {
      for item in claimedItems {
        await manifestStore.releaseUploadClaim(id: item.id)
      }
    }
  }

  /// The queue read takes a file lock the share extension may be holding.
  @concurrent
  private nonisolated static func loadSharedEntries() async -> [SharedUploadEntry] {
    SharedQueueBridge.loadEntries()
  }

  private func removeCompletedSharedEntries() async {
    let entries = await Self.loadSharedEntries()
    guard !entries.isEmpty else { return }
    let records = await manifestStore.allRecords()
    var recordsByEntryID: [UUID: [TransferRecord]] = [:]
    for record in records {
      guard let entryID = record.sharedEntryID else { continue }
      recordsByEntryID[entryID, default: []].append(record)
    }
    var removable = Set<UUID>()
    for entry in entries {
      guard let matching = recordsByEntryID[entry.id],
        matching.allSatisfy({ $0.status == .sent || $0.status == .deleted })
      else { continue }
      removable.insert(entry.id)
    }
    guard !removable.isEmpty else { return }
    // `.sent` is written in batches. Once the entry and its file are gone, a record
    // that a crash reverted to pending could never be uploaded or cleared.
    guard await manifestStore.flush() else { return }
    do {
      try SharedQueueBridge.removeEntries(ids: removable)
    } catch {
      logger.error("Removing completed shared entries failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    for entry in entries where removable.contains(entry.id) {
      guard let url = SharedQueueBridge.fileURL(for: entry) else { continue }
      let stillReferenced = records.contains {
        $0.sharedEntryID != entry.id && $0.sourcePath == url.path && $0.status != .deleted
      }
      if !stillReferenced {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  /// Pending records the shared-queue ingest must leave alone because another scan owns
  /// them: a folder's scan re-queues its own files with the folder's scope held and
  /// Live Photos paired, which a re-queue from here would do neither of. Called once
  /// per ingest; the predicate runs for every pending record, so it must not touch the
  /// file system.
  open func ingestSkipPredicate() -> (TransferRecord) -> Bool {
    { _ in false }
  }

  open func allowedSourceRoots() -> [URL] {
    [AppGroupConstants.storageDirectory().appendingPathComponent(AppGroupConstants.incomingFolderName, isDirectory: true)]
  }

  private func isHandled(_ record: TransferRecord, accountEmail: String) -> Bool {
    (record.status == .sent || record.status == .deleted)
      && record.sentAccountEmails.contains(accountEmail)
  }

  private func handleSharedItemFinished(itemID: String, status: TransferStatus) async {
    guard status == .sent else { return }
    let record = await manifestStore.record(for: itemID)
    let sharedID: UUID?
    if let record {
      guard record.status == .sent else { return }
      sharedID = record.sharedEntryID
    } else {
      let parts = itemID.split(separator: "|", maxSplits: 1)
      guard parts.count == 2 else { return }
      sharedID = UUID(uuidString: String(parts[1]))
    }
    guard let sharedID else { return }
    let entries = await Self.loadSharedEntries().filter { $0.id == sharedID }
    guard !entries.isEmpty else { return }
    guard await manifestStore.flush() else { return }
    do {
      try SharedQueueBridge.removeEntries(ids: Set(entries.map(\.id)))
    } catch {
      logger.error("Removing a sent shared entry failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    for entry in entries {
      if let url = SharedQueueBridge.fileURL(for: entry) {
        let records = await manifestStore.allRecords()
        let isReferenced = records.contains {
          $0.id != itemID && $0.sourcePath == url.path
        }
        if !isReferenced {
          try? FileManager.default.removeItem(at: url)
        }
      }
    }
    await refreshRecords()
  }

  public nonisolated static func validatedExistingFileURL(for record: TransferRecord, roots: [URL]) -> URL? {
    guard let path = record.sourcePath,
      let url = Self.validatedSourceFileURL(atPath: path, roots: roots),
      Self.matchesSourceMetadata(
        url: url,
        size: record.sourceFileSize,
        modifiedAt: record.sourceModifiedAt,
        sha1: record.sourceSHA1
      )
    else { return nil }
    return url
  }

  public func existingFileURLAsync(for record: TransferRecord) async -> URL? {
    await existingFileURLAsync(for: record, roots: allowedSourceRoots())
  }

  /// For loops: `allowedSourceRoots()` may resolve security-scoped bookmarks, so it is
  /// computed once per operation rather than once per record.
  public func existingFileURLAsync(for record: TransferRecord, roots: [URL]) async -> URL? {
    await Task.detached(priority: .utility) {
      Self.validatedExistingFileURL(for: record, roots: roots)
    }.value
  }

  public nonisolated static func validatedExistingPairedFileURL(for record: TransferRecord, roots: [URL]) -> URL? {
    guard let path = record.pairedSourcePath,
      let url = Self.validatedSourceFileURL(atPath: path, roots: roots),
      Self.matchesSourceMetadata(
        url: url,
        size: record.pairedSourceFileSize,
        modifiedAt: record.pairedSourceModifiedAt,
        sha1: record.pairedSourceSHA1
      )
    else { return nil }
    return url
  }

  public func existingPairedFileURLAsync(for record: TransferRecord) async -> URL? {
    await existingPairedFileURLAsync(for: record, roots: allowedSourceRoots())
  }

  public func existingPairedFileURLAsync(for record: TransferRecord, roots: [URL]) async -> URL? {
    await Task.detached(priority: .utility) {
      Self.validatedExistingPairedFileURL(for: record, roots: roots)
    }.value
  }

  private nonisolated static func matchesSourceMetadata(
    url: URL,
    size: Int64?,
    modifiedAt: Date?,
    sha1: String?
  ) -> Bool {
    guard size != nil || modifiedAt != nil || sha1 != nil else { return true }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    if let expected = size {
      guard let actual = values?.fileSize else { return false }
      guard Int64(actual) == expected else { return false }
    }
    if let expected = modifiedAt {
      guard let actual = values?.contentModificationDate else { return false }
      guard abs(actual.timeIntervalSince(expected)) < 0.01 else { return false }
    }
    if let expected = sha1 {
      guard let data = try? GooglePhotosMobileClient.streamSHA1(fileURL: url) else { return false }
      guard data.base64EncodedString() == expected else { return false }
    }
    return true
  }

  public nonisolated static func validatedSourceFileURL(atPath path: String, roots: [URL]) -> URL? {
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }

    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    for root in roots {
      let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
      let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
      guard resolvedCandidate.path.lowercased().hasPrefix(prefix.lowercased()) else { continue }
      return candidate
    }
    return nil
  }

  public func pauseTransfer() {
    workerPool.pause()
  }

  public func resumeTransfer() {
    workerPool.resume()
  }

  public func skipFailedRecords(_ ids: [String]) async {
    _ = await manifestStore.skipFailed(ids: ids)
    await refreshRecords()
  }

  open func stopTransfer() {
    cancelLostNetworkRetry()
    workerPool.cancel()
  }

  /// The user asked for this item again, which ends any skip after a crash.
  public func resendRecord(_ record: TransferRecord) async {
    PreparationGuard.shared.forgive(record.id)
    await requeueRecord(record)
  }

  /// Items a batch cut short left pending, which no scan queues (files picked for upload, say,
  /// or anything while Auto-Sync is off), as one claim and one batch. A claim only takes an item
  /// still unfinished, so one that went up in the meantime is left as it is.
  public func requeuePendingRecords(where shouldRequeue: (TransferRecord) -> Bool) async {
    guard let account = selectedAccount, allowsAutomaticUploads else { return }
    let generation = accountGeneration
    let prefix = "\(account.email)|"
    let pending = await manifestStore.allRecords().filter {
      $0.status == .pending && $0.id.hasPrefix(prefix) && shouldRequeue($0)
    }
    guard !pending.isEmpty else { return }
    let items = await queueItems(forPending: pending)
    guard accountGeneration == generation, allowsAutomaticUploads else { return }
    // One the running batch still holds (waiting on its iCloud download, say) goes up with
    // the next pass: claimed now, the batch would skip it as already tracked and strand it.
    let free = items.filter { !workerPool.hasItem(id: $0.id) }
    let claimedIDs = await manifestStore.claimForUpload(ids: free.map(\.id))
    let claimed = free.filter { claimedIDs.contains($0.id) }
    await refreshRecords()
    guard !claimed.isEmpty else { return }
    workerPool.setConcurrency(settings.uploadThreads)
    guard accountGeneration == generation, allowsAutomaticUploads,
      workerPool.start(items: claimed, quality: 3, accountEmail: account.email) != .rejected
    else {
      for item in claimed { await manifestStore.releaseUploadClaim(id: item.id) }
      await refreshRecords()
      return
    }
  }

  /// Whether this is the app's own copy of a picked file, removed once it's up. Overridden by
  /// the app that keeps such copies.
  open func isAppOwnedCopy(_ url: URL) -> Bool { false }

  /// What to upload for records left pending; one that can't be rebuilt stays as it is.
  open func queueItems(forPending records: [TransferRecord]) async -> [UploadQueueItem] { [] }

  open func requeueRecord(_ record: TransferRecord) async {
    guard let account = selectedAccount,
      record.id.hasPrefix("\(account.email)|"),
      let url = await existingFileURLAsync(for: record)
    else { return }
    let generation = accountGeneration
    let item = UploadQueueItem(
      id: record.id,
      fileURL: url,
      filename: record.filename,
      fileSize: record.byteCount ?? 0,
      creationDate: record.creationDate,
      precomputedSHA1: record.sourceSHA1,
      precomputedSourceModifiedAt: record.sourceModifiedAt,
      removeSourceOnSuccess: false
    )
    guard await manifestStore.resetForResend(id: record.id, accountEmail: account.email),
      await manifestStore.claimForUpload(id: record.id)
    else { return }
    await refreshRecords()
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaim(id: record.id)
      return
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaim(id: record.id)
      return
    }
    if workerPool.start(items: [item], quality: 3, accountEmail: account.email) == .rejected {
      await manifestStore.releaseUploadClaim(id: record.id)
      await manifestStore.updateStatus(id: record.id, status: .failed, accountEmail: account.email, error: "Unable to start upload")
    }
  }
}

public final class ShareObserverHolder: @unchecked Sendable {
  public var token: UnsafeMutableRawPointer? {
    didSet {
      if let oldValue, oldValue != token {
        SharedQueueBridge.removeObserver(oldValue)
      }
    }
  }

  public init(token: UnsafeMutableRawPointer? = nil) {
    self.token = token
  }

  deinit {
    if let token {
      SharedQueueBridge.removeObserver(token)
    }
  }
}
