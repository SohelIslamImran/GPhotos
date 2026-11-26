import AppIntents
import AppKit
import Darwin
import Foundation
import GPhotosKit
import Observation
import ServiceManagement

/// What a manual Clean Up would remove, worked out first so the confirmation can name
/// the count. Each file is checked again when the cleanup runs.
public struct MacCleanupPlan: Sendable, Equatable {
  public var records: [TransferRecord] = []

  public var count: Int { records.count }
  public var isEmpty: Bool { records.isEmpty }
}

public struct AccountRecordCounts: Equatable, Sendable {
  public var uploading = 0
  public var queued = 0
  public var sent = 0
  public var failed = 0
  public var completedBytes: Int64 = 0
}

@MainActor
@Observable
public final class MacSyncStore: SyncEngine {
  @ObservationIgnored private var retriesFailedItemsNow = false
  public private(set) var folders: [MacWatchedFolder] = [] {
    didSet {
      if folders.map(\.id) != oldValue.map(\.id) || folders.map(\.isEnabled) != oldValue.map(\.isEnabled) {
        cleanupPolicy.invalidate()
      }
    }
  }
  public private(set) var launchAtLoginEnabled = false
  public private(set) var isScanning = false
  /// Sidebar section the menu bar or a menu command asked the window to show.
  /// Set when imported files are waiting for an account; the window presents sign-in.
  public var presentSignIn = false
  public private(set) var importError: String?
  /// What the last cleanup removed. Set only when files were actually removed, since it
  /// drives the "Cleaned Up" status.
  public private(set) var cleanupMessage: String?
  /// A cleanup outcome that removed nothing, shown beside Clean Up for a few seconds.
  public private(set) var cleanupNotice: (text: String, isWarning: Bool)?
  public private(set) var isPreparingCleanup = false
  public private(set) var isCleaningUp = false
  /// Protected folders that can be found neither through their bookmark nor at their
  /// path. While any is missing, cleanup removes nothing. Read from SwiftUI `body`, so
  /// it is worked out off the main actor and cached.
  public private(set) var missingProtectedFolderIDs: Set<String> = []
  /// Recomputed in `refreshRecords` so body evaluations never re-filter the record list.
  public private(set) var accountRecordCounts = AccountRecordCounts()
  public private(set) var failedRecordCount = 0
  public private(set) var hasFailedRecords = false

  private var watchers: [String: MacFolderWatcher] = [:]
  private var needsRescan = false
  /// Where the watchers saw changes since the last pass began, which is all the next
  /// pass reads, besides directories with unfinished files. Everything is read when the
  /// watchers may have missed something (launch, restarted streams, wake, a mount), when
  /// a pass did not finish, and on Sync Now.
  @ObservationIgnored private var pendingChanges = FolderChanges.full
  /// Directories holding files a pass left for later (still being written, or iCloud
  /// placeholders), read again by every pass until they settle.
  @ObservationIgnored private var unsettledDirectories: Set<String> = []
  /// The account and manifest removal count the last full pass ran against. Reading
  /// only what changed relies on the manifest holding every file it skips, which a
  /// different account or removed records would break.
  @ObservationIgnored private var fullScanBasis: ScanBasis?
  /// Sync Now asked for while a scan or upload was under way; honoured when that pass
  /// ends even with Auto-Sync off.
  private var manualRescanRequested = false
  private var pendingDropURLs: [URL] = []
  private var pendingDropURLsByAccount: [String: [URL]] = [:]
  private var activeStagingOperations = 0
  private var lastStagingHadFailure = false
  private var stagingError: String?
  private var dropGeneration = 0
  private var scanGeneration = 0
  private var activeScanTask: Task<Void, Never>?
  private let foldersKey = "macWatchedFolders"
  private var didStart = false
  /// True until the first launch pass finishes, so the status doesn't flash interim states.
  public private(set) var isStarting = true
  private var pendingImportURLs: [URL] = []
  private var stopRequested = false
  private var deferredRescanTask: Task<Void, Never>?
  private var usabilityTask: Task<Void, Never>?
  private var usabilityGeneration = 0
  private var watcherGeneration = 0
  @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var isRunningCleanupMaintenance = false
  /// The due set the automatic cleanup last looked at, and when.
  @ObservationIgnored private var lastCleanupMaintenance: (key: Int, date: Date)?
  @ObservationIgnored private var cleanupNoticeTask: Task<Void, Never>?
  @ObservationIgnored private var protectedFolderCheckGeneration = 0
  /// Set at launch and when a removal fails, so the next batch looks for a file left in
  /// its tombstone.
  @ObservationIgnored private var needsTombstoneRecovery = true

  /// A file that never settles (a recording in progress) would otherwise re-enumerate
  /// every folder each `FolderMediaScanner.writeSettleInterval`, so consecutive deferrals
  /// back off to this.
  private nonisolated static let maxDeferredRescanDelay: TimeInterval = 5 * 60
  private var deferredRescanDelay = FolderMediaScanner.writeSettleInterval

  public init() {
    super.init()
    self.refreshLaunchAtLoginStatus()
    self.loadFolders()
    self.refreshFolderUsability()
    self.refreshProtectedFolderStatus()
    MediaThumbnailLoader.shared.fileAccess = { [weak self] in self?.thumbnailAccess(for: $0) }
    workerPool.onBatchCompleted = { [weak self] in
      await self?.handleBatchCompleted()
      await self?.primaryBatchDidComplete()
    }
    observeWorkspace()

    Task { await self.start() }
  }

  public override var allowsAutomaticUploads: Bool { !stopRequested }

  /// A mounted volume can bring a watched folder back, an unmounted one takes it away,
  /// and FSEvents streams can miss changes across sleep.
  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    let names = [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification,
    ]
    workspaceObservers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          self?.refreshFolderUsability()
          self?.refreshProtectedFolderStatus()
          self?.rebuildWatchers()
          self?.handleFolderChange()
        }
      }
    }
  }

  private func handleBatchCompleted() async {
    // The hook fires from inside the batch's own task while `isBatchFinalizing` is
    // still true, so `waitForCurrentBatch()` must be reached through a new
    // unstructured Task. Awaiting it directly here would await the task we are
    // already running on and hang the main actor.
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.workerPool.waitForCurrentBatch()
      await self.backUpDuringStagedCleanup {
        await self.ingestSharedQueueItems()
        await self.resumeRequestedScan()
      }
      // One cleanup after the other: neither may take the other's tombstone for an
      // interrupted deletion's.
      await self.waitForStagedCleanup()
      await self.runCleanupMaintenance()
    }
  }

  override public func primaryBatchDidComplete() async {
    await super.primaryBatchDidComplete()
    // Cut short by the network, the batch isn't finished: its items go up when it's back.
    if !workerPool.isBatchCancelled, !workerPool.lastBatchLostNetwork {
      await BackupNotifier.shared.notifyBatchCompletion(
        uploadedCount: workerPool.lastBatchCompletedCount,
        failedCount: workerPool.lastBatchFailedCount,
        authErrorEmail: workerPool.lastBatchAuthErrorEmail,
        storageFullEmail: workerPool.lastBatchStorageFullEmail
      )
    }
  }

  /// Writes any batched manifest changes before the app quits.
  public func prepareForTermination() async {
    _ = await manifestStore.flush()
  }

  public func start() async {
    guard !didStart else { return }
    didStart = true
    defer {
      // A cancelled pass is retried, and until then the account isn't known yet.
      if Task.isCancelled { didStart = false } else { isStarting = false }
    }
    await loadAccounts()
    await refreshRecords()
    await ingestSharedQueueItems()
    await withAccountWork { await self.recoverTombstonesIfNeeded() }
    await backUpDuringStagedCleanup {
      rebuildWatchers()
      await awaitFolderUsability()
      // With Auto-Sync off, anything left pending (stopped, say) waits for the user to ask.
      if settings.autoSyncEnabled, selectedAccount != nil { await resumePendingWork() }
    }
  }

  /// A watched folder's scan re-queues its own files with the folder's scope held and
  /// Live Photos paired; the shared-queue ingest must not send them as singles. Folders
  /// are matched where they were added and where they last resolved, with no bookmark
  /// resolved here.
  public override func ingestSkipPredicate() -> (TransferRecord) -> Bool {
    var roots = watchedRootPaths
    for folder in folders {
      let path = WatchedFolderPaths.privatePrefixed(folder.url.standardizedFileURL.path)
      if !roots.contains(path) { roots.append(path) }
    }
    guard !roots.isEmpty else { return { _ in false } }
    return { record in
      guard let sourcePath = record.sourcePath else { return false }
      let path = WatchedFolderPaths.privatePrefixed(URL(fileURLWithPath: sourcePath).standardizedFileURL.path)
      return roots.contains { WatchedFolderPaths.isPath(path, inside: $0) }
    }
  }

  /// Only folders that are enabled and actually readable, because this list bounds
  /// what cleanup is permitted to delete. A disabled or sandbox-blocked folder must
  /// not appear here.
  public override func allowedSourceRoots() -> [URL] {
    let resolved = Self.sourceRoots(base: super.allowedSourceRoots(), folders: folders)
    storeRefreshedBookmarks(resolved.refreshedBookmarks)
    return resolved.roots
  }

  /// `allowedSourceRoots()` with the bookmark resolution and `opendir` probes run off
  /// the main actor. Call once per operation and pass the roots to each record check.
  private func allowedSourceRootsAsync() async -> [URL] {
    let base = super.allowedSourceRoots()
    let snapshot = folders
    let resolved = await Task.detached(priority: .utility) {
      Self.sourceRoots(base: base, folders: snapshot)
    }.value
    storeRefreshedBookmarks(resolved.refreshedBookmarks)
    return resolved.roots
  }

  private nonisolated static func sourceRoots(
    base: [URL],
    folders: [MacWatchedFolder]
  ) -> (roots: [URL], refreshedBookmarks: [BookmarkRefresh]) {
    var roots = base
    roots.append(dropRoot)
    var refreshed: [BookmarkRefresh] = []
    for folder in folders where folder.isEnabled {
      let access = folder.beginAccess()
      defer {
        if access.started { folder.endAccess(access.url) }
      }
      if let data = access.refreshedBookmark {
        refreshed.append(BookmarkRefresh(folderID: folder.id, previous: folder.bookmarkData, refreshed: data))
      }
      guard isReadableDirectory(access.url) else { continue }
      let standardized = access.url.standardizedFileURL
      guard !roots.contains(where: { $0.standardizedFileURL == standardized }) else { continue }
      roots.append(standardized)
    }
    return (roots, refreshed)
  }

  public override func accountsDidChange() async {
    stopRequested = false
    importError = nil
    let staged = stagedDropURLs()
    guard let account = selectedAccount else {
      if staged.contains(where: { $0.accountEmail == nil }) {
        presentSignIn = true
      }
      return
    }
    for staged in staged {
      if let originAccount = staged.accountEmail {
        guard originAccount == account.email else { continue }
        enqueuePendingDropURLs([staged.url], accountEmail: originAccount)
        continue
      }
      if activeStagingOperations > 0 { continue }
      if let promoted = Self.promoteStagedDropURL(staged.url, to: account.email, root: Self.dropRoot) {
        enqueuePendingDropURLs([promoted], accountEmail: account.email)
        pendingImportURLs.removeAll { $0 == staged.url }
      }
    }
    let pendingImports = pendingImportURLs
    pendingImportURLs.removeAll()
    let urls = takePendingDropURLs(for: account.email)
    let allURLs = urls + pendingImports
    guard !allURLs.isEmpty else { return }
    await uploadDroppedFiles(urls: allURLs)
  }

  // Cleanup sweeps the whole manifest and re-hashes staged files, so it runs once
  // per batch from `handleBatchCompleted()` rather than after every item.
  public override func transferItemDidComplete() async {}

  /// Matches one side of `record` against tombstone names already listed from
  /// `directory`. The name pattern must stay in step with
  /// `TransferManifestStore.deletionTombstoneURL`. Hash verification reads whole files,
  /// so it runs off the main actor.
  private nonisolated static func deletionTombstones(
    for record: TransferRecord,
    path: String,
    names: [String],
    in directory: URL
  ) -> [URL] {
    let isPaired = record.pairedSourcePath == path
    let size = isPaired ? record.pairedSourceFileSize : record.sourceFileSize
    let modified = isPaired ? record.pairedSourceModifiedAt : record.sourceModifiedAt
    let sha1 = isPaired ? record.pairedSourceSHA1 : record.sourceSHA1
    guard let size, let modified else { return [] }
    let suffix = "-\(URL(fileURLWithPath: path).lastPathComponent)"
    let stamp = "-\(size)-\(Int64(modified.timeIntervalSince1970 * 1000))-"
    return
      names
      .filter { $0.hasSuffix(suffix) && $0.contains(stamp) }
      .map { directory.appendingPathComponent($0) }
      .filter { tombstone in
        guard let sha1 else { return true }
        guard let data = try? GooglePhotosMobileClient.streamSHA1(fileURL: tombstone) else { return false }
        return data.base64EncodedString() == sha1
      }
  }

  private func recoverDeletionTombstones() async {
    let records = await manifestStore.allRecords()
    // Tombstones live beside the original file, so the security scope of the folder
    // that actually contains the file has to be held while looking for them. Without
    // it the sandbox denies the directory listing and an interrupted delete strands
    // the user's photo as an invisible dotfile with no record update.
    let pending: [(TransferRecord, String)] = records.flatMap { record in
      [record.sourcePath, record.pairedSourcePath].compactMap { path in
        path.map { (record, $0) }
      }
    }
    // Grouped so the whole lookup-and-restore for a folder runs under one scope. Each
    // bookmark is resolved once here rather than once per record.
    let snapshot = folders
    let rootPaths = await Task.detached(priority: .utility) {
      snapshot.map { ($0.resolvedURL ?? $0.url).standardizedFileURL.path }
    }.value
    var byFolder: [Int: [String: [(TransferRecord, String)]]] = [:]
    for (record, path) in pending {
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
      guard let index = rootPaths.firstIndex(where: { WatchedFolderPaths.isPath(directory, inside: $0) }) else { continue }
      byFolder[index, default: [:]][directory, default: []].append((record, path))
    }

    for (index, byDirectory) in byFolder {
      let folder = snapshot[index]
      await withFolderAccess(folder) {
        // Directory listings and content hashes run off the main actor. Each directory
        // is listed once, however many records live in it, and most hold no tombstone.
        let found = await Task.detached(priority: .utility) { () -> [(TransferRecord, String, [URL])] in
          var matches: [(TransferRecord, String, [URL])] = []
          for (directory, entries) in byDirectory {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
              .filter { $0.hasPrefix(TransferManifestStore.deletionTombstonePrefix) }
            guard !names.isEmpty else { continue }
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            for (record, path) in entries {
              let tombstones = Self.deletionTombstones(for: record, path: path, names: names, in: directoryURL)
              if !tombstones.isEmpty { matches.append((record, path, tombstones)) }
            }
          }
          return matches
        }.value

        for (record, path, tombstones) in found {
          let originalExists = FileManager.default.fileExists(atPath: path)
          for tombstone in tombstones {
            if record.status == .deleted || originalExists {
              try? FileManager.default.removeItem(at: tombstone)
            } else {
              _ = await manifestStore.restoreTombstoneIfSafe(
                id: record.id,
                path: path,
                tombstone: tombstone
              )
            }
          }
        }
      }
    }
  }

  /// Watched-folder tombstones only come from a cleanup pass, which recovers them itself
  /// first, so every record's directory is listed only at launch or after a failed removal.
  /// One a cleanup is just checking isn't left behind.
  private func recoverTombstonesIfNeeded() async {
    guard needsTombstoneRecovery, !isRunningCleanupMaintenance, !isCleaningUp else { return }
    needsTombstoneRecovery = false
    await recoverDeletionTombstones()
  }

  override public func removeCompletedStagedCopies() async {
    await recoverTombstonesIfNeeded()
    guard !Task.isCancelled, allowsAccountWork, let accountEmail = selectedAccount?.email,
      activeStagingOperations == 0
    else { return }
    let root = Self.dropRoot
    let rootPath = root.standardizedFileURL.path
    let terminalStatuses: [TransferStatus] = [.sent, .deleted]
    let records = await manifestStore.allRecords()

    func sameVersion(_ candidate: TransferRecord, _ record: TransferRecord) -> Bool {
      guard let sourcePath = candidate.sourcePath,
        let recordPath = record.sourcePath,
        sourcePath == recordPath || sourcePath.caseInsensitiveCompare(recordPath) == .orderedSame
      else { return false }
      switch (candidate.pairedSourcePath, record.pairedSourcePath) {
      case (nil, nil):
        break
      case (let left?, let right?):
        guard URL(fileURLWithPath: left).standardizedFileURL == URL(fileURLWithPath: right).standardizedFileURL else { return false }
      default:
        return false
      }
      if let sourceSize = record.sourceFileSize, candidate.sourceFileSize != sourceSize { return false }
      if let pairedSize = record.pairedSourceFileSize, candidate.pairedSourceFileSize != pairedSize { return false }
      if let sourceSHA1 = record.sourceSHA1, candidate.sourceSHA1 != sourceSHA1 { return false }
      if let pairedSHA1 = record.pairedSourceSHA1, candidate.pairedSourceSHA1 != pairedSHA1 { return false }
      guard let modifiedAt = record.sourceModifiedAt else { return true }
      guard let candidateModifiedAt = candidate.sourceModifiedAt else { return false }
      guard abs(candidateModifiedAt.timeIntervalSince(modifiedAt)) < 0.01 else { return false }
      guard let pairedModifiedAt = record.pairedSourceModifiedAt else { return true }
      guard let candidatePairedModifiedAt = candidate.pairedSourceModifiedAt else { return false }
      return abs(candidatePairedModifiedAt.timeIntervalSince(pairedModifiedAt)) < 0.01
    }

    // Resolved once: each call re-resolves every folder's security-scoped bookmark.
    let roots = await allowedSourceRootsAsync()

    func canCleanup(_ record: TransferRecord, in snapshot: [TransferRecord]) -> Bool {
      guard terminalStatuses.contains(record.status),
        let sourcePath = record.sourcePath,
        URL(fileURLWithPath: sourcePath).standardizedFileURL.path.hasPrefix(rootPath + "/"),
        Self.validatedSourceFileURL(atPath: sourcePath, roots: roots) != nil
      else { return false }
      let matching = snapshot.filter {
        guard let path = $0.sourcePath else { return false }
        return path == sourcePath || path.caseInsensitiveCompare(sourcePath) == .orderedSame
      }
      guard matching.allSatisfy({ terminalStatuses.contains($0.status) }) else { return false }
      // Every staged drop belongs to one account (DroppedUploads/<hex(account)>/…).
      guard
        let owner = Self.stagingAccountEmail(for: URL(fileURLWithPath: sourcePath), root: root)
          ?? TransferRecord.accountEmail(fromScopedID: record.id)
      else { return false }
      return snapshot.contains {
        TransferRecord.accountEmail(fromScopedID: $0.id) == owner && terminalStatuses.contains($0.status)
          && $0.mediaKeysByAccount[owner].map { !$0.isEmpty } == true && sameVersion($0, record)
      }
    }

    // Standardizing a path cannot move it under the drop root unless it already names
    // the drop root's folder, so this string test spares every other record the URL work.
    let dropFolderComponent = "/\(root.lastPathComponent)/"
    let staged = records.filter {
      terminalStatuses.contains($0.status) && $0.sourcePath?.contains(dropFolderComponent) == true
        && TransferRecord.accountEmail(fromScopedID: $0.id) == accountEmail && canCleanup($0, in: records)
    }
    guard !Task.isCancelled, allowsAccountWork else { return }
    func eligibleIDs(_ ids: Set<String>) async -> Set<String> {
      await manifestStore.eligibleStagedCopies(
        among: ids, accountEmail: accountEmail, accounts: accounts,
        includesFoundItems: settings.removesItemsAlreadyInGooglePhotos)
    }
    let eligible = await eligibleIDs(Set(staged.map(\.id)))
    guard !Task.isCancelled, allowsAccountWork else { return }
    let confirmed = await remoteCopyVerifier.confirmed(staged.filter { eligible.contains($0.id) }, accountEmail: accountEmail)
    var deletedRecords: [TransferRecord] = []
    for record in confirmed {
      // Drops can be staged while Google Photos is asked; they're looked at on a later pass.
      guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail, activeStagingOperations == 0
      else { break }
      guard let sourcePath = record.sourcePath,
        let fileURL = Self.validatedSourceFileURL(atPath: sourcePath, roots: roots),
        await manifestStore.claimForDeletion(id: record.id)
      else { continue }
      let latest = await manifestStore.allRecords()
      guard canCleanup(record, in: latest),
        await eligibleIDs([record.id]).contains(record.id),
        await manifestStore.deletionClaimIsValid(id: record.id)
      else {
        await manifestStore.releaseDeletionClaim(id: record.id)
        continue
      }
      let pairedFileURL: URL?
      if record.mediaType == "Live Photo" {
        guard let resolvedPairedFileURL = await existingPairedFileURLAsync(for: record, roots: roots) else {
          await manifestStore.releaseDeletionClaim(id: record.id)
          continue
        }
        pairedFileURL = resolvedPairedFileURL
      } else {
        pairedFileURL = nil
      }
      await KeptThumbnails.keep(record, fileURL: fileURL)
      guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else {
        await manifestStore.releaseDeletionClaim(id: record.id)
        break
      }
      if await manifestStore.deleteSourceFiles(
        id: record.id,
        fileURL: fileURL,
        pairedFileURL: pairedFileURL
      ) {
        deletedRecords.append(record)
      }
    }
    scheduleCleanupRekey(deletedRecords, accountEmail: accountEmail)
  }

  public func discardPendingDropURLs() {
    dropGeneration &+= 1
    for url in pendingDropURLs {
      try? FileManager.default.removeItem(at: url)
    }
    for urls in pendingDropURLsByAccount.values {
      for url in urls {
        try? FileManager.default.removeItem(at: url)
      }
    }
    let root = Self.dropRoot
    let rootPath = root.standardizedFileURL.path + "/"
    for url in pendingImportURLs
    where url.standardizedFileURL.path.hasPrefix(rootPath) && Self.stagingAccountEmail(for: url, root: root) == nil {
      try? FileManager.default.removeItem(at: url)
    }
    pendingDropURLs.removeAll()
    pendingDropURLsByAccount.removeAll()
    pendingImportURLs.removeAll()
  }

  private func enqueuePendingDropURLs(_ urls: [URL], accountEmail: String?) {
    guard !urls.isEmpty else { return }
    if let accountEmail {
      var existing = pendingDropURLsByAccount[accountEmail, default: []]
      for url in urls where !existing.contains(url) {
        existing.append(url)
      }
      pendingDropURLsByAccount[accountEmail] = existing
    } else {
      for url in urls where !pendingDropURLs.contains(url) {
        pendingDropURLs.append(url)
      }
    }
  }

  private func takePendingDropURLs(for accountEmail: String) -> [URL] {
    var urls = pendingDropURLs
    pendingDropURLs.removeAll()
    let targeted = pendingDropURLsByAccount.removeValue(forKey: accountEmail) ?? []
    for url in targeted where !urls.contains(url) {
      urls.append(url)
    }
    return urls
  }

  private func removeStalePartialCopies() {
    guard activeStagingOperations == 0 else { return }
    let root = Self.dropRoot
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return }
    let cutoff = Date().addingTimeInterval(-300)
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "partial" {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, modified < cutoff {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private func stagedDropURLs() -> [StagedDrop] {
    removeStalePartialCopies()
    let root = Self.dropRoot
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }
    var urls: [StagedDrop] = []
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      let isRegular = values?.isRegularFile == true && values?.isSymbolicLink != true
      if isRegular, SupportedMediaFormats.isSupported(fileURL: url) {
        urls.append(StagedDrop(url: url, accountEmail: Self.stagingAccountEmail(for: url, root: root)))
      }
    }
    return urls
  }

  /// The selected account's records, rebuilt in `refreshRecords`, which also runs on
  /// every account change, so reads from `body` never re-filter the manifest.
  public private(set) var accountRecords: [TransferRecord] = []

  public var accountUploadingCount: Int { accountRecordCounts.uploading }

  public var accountQueuedCount: Int { accountRecordCounts.queued }

  public var accountCompletedByteCount: Int64 { accountRecordCounts.completedBytes }

  public private(set) var accountActivityRevision = 0

  private struct AccountRecordSource: Equatable {
    let revision: Int?
    let email: String?
  }

  private struct AccountRecordSnapshot: Sendable {
    var records: [TransferRecord] = []
    var indexByID: [String: Int] = [:]
    var sendingByFilename: [String: Int] = [:]
    var counts = AccountRecordCounts()

    nonisolated init(records: [TransferRecord], email: String?) {
      guard let email else { return }
      let prefix = "\(email)|"
      for record in records where record.id.hasPrefix(prefix) && !record.isSkipped {
        let index = self.records.count
        self.records.append(record)
        indexByID[record.id] = index
        switch record.status {
        case .sending:
          counts.uploading += 1
          if sendingByFilename[record.filename] == nil { sendingByFilename[record.filename] = index }
        case .pending:
          counts.queued += 1
        case .sent, .deleted:
          counts.sent += 1
          counts.completedBytes += record.byteCount ?? 0
        case .failed:
          counts.failed += 1
        }
      }
    }
  }

  @ObservationIgnored private var accountRecordsSource: AccountRecordSource?
  @ObservationIgnored private var accountProjectionSource: AccountRecordSource?
  @ObservationIgnored private var accountProjectionTask: Task<AccountRecordSnapshot?, Never>?
  private var accountIndexByID: [String: Int] = [:]
  private var sendingByFilename: [String: Int] = [:]

  private var currentAccountRecordSource: AccountRecordSource {
    AccountRecordSource(revision: recordsRevision, email: selectedAccount?.email)
  }

  public override func refreshRecords() async {
    await super.refreshRecords()
    let source = currentAccountRecordSource
    if source == accountRecordsSource { return }
    if source != accountProjectionSource {
      accountProjectionTask?.cancel()
      accountProjectionSource = source
      let records = self.records
      let previous = accountRecords
      accountProjectionTask = Task.detached(priority: .utility) {
        guard !Task.isCancelled else { return nil }
        let snapshot = AccountRecordSnapshot(records: records, email: source.email)
        return snapshot.records == previous ? nil : snapshot
      }
    }
    guard let task = accountProjectionTask else { return }
    let snapshot = await task.value
    guard source == currentAccountRecordSource, task == accountProjectionTask, source != accountRecordsSource else {
      return
    }
    accountProjectionSource = nil
    accountProjectionTask = nil
    accountRecordsSource = source
    guard let snapshot else { return }
    accountIndexByID = snapshot.indexByID
    sendingByFilename = snapshot.sendingByFilename
    accountRecords = snapshot.records
    accountActivityRevision &+= 1
    if snapshot.counts != accountRecordCounts { accountRecordCounts = snapshot.counts }
    if snapshot.counts.failed != failedRecordCount { failedRecordCount = snapshot.counts.failed }
    let hasFailed = snapshot.counts.failed > 0
    if hasFailed != hasFailedRecords { hasFailedRecords = hasFailed }
  }

  func activityRecords(for email: String?) -> [TransferRecord] {
    accountRecordsSource?.email == email ? accountRecords : []
  }

  func uploadingRecord(for worker: WorkerState) -> TransferRecord? {
    guard !worker.itemID.isEmpty else { return nil }
    let exact = accountIndexByID[worker.itemID].map { accountRecords[$0] }
    if exact?.status == .sending { return exact }
    return sendingByFilename[worker.filename].map { accountRecords[$0] } ?? exact
  }

  /// Resolving a security-scoped bookmark is an XPC round trip and probing readability
  /// lists the directory, so both answers are cached and only recomputed when the
  /// folder list, a volume or a watched folder's location changes — these are read
  /// from SwiftUI `body`.
  public private(set) var launchAtLoginError: String?
  /// Registered, but macOS is waiting for the user to allow it in Login Items.
  public private(set) var launchAtLoginRequiresApproval = false
  public private(set) var hasUsableEnabledFolder = false
  public private(set) var enabledFoldersNeedingAccess = 0
  /// Folders macOS will let us read but not watch, so auto-sync never fires for them.
  public private(set) var unwatchableFolders: Set<String> = []
  private var folderReadability: [String: Bool] = [:]
  /// Where the enabled folders last resolved, as given and with symbolic links resolved,
  /// so per-record path checks resolve no bookmark.
  @ObservationIgnored private var watchedRootPaths: [String] = []

  /// Runs `body` while holding `folder`'s security scope, so sandboxed directory
  /// listings and reads actually succeed. The scope is released per call, not at the
  /// end of the enclosing function.
  private func withFolderAccess<T>(
    _ folder: MacWatchedFolder,
    _ body: () async -> T
  ) async -> T {
    let access = beginAccess(folder)
    defer {
      if access.started { folder.endAccess(access.url) }
    }
    return await body()
  }

  /// The one path that resolves a folder's bookmark for access from the store. A stale
  /// bookmark is replaced while access is held, so it keeps resolving after the folder
  /// is moved or renamed; it could not be recreated once access had lapsed.
  private func beginAccess(_ folder: MacWatchedFolder) -> (url: URL, started: Bool, isResolved: Bool) {
    let access = folder.beginAccess()
    if let refreshed = access.refreshedBookmark {
      storeRefreshedBookmarks([
        BookmarkRefresh(folderID: folder.id, previous: folder.bookmarkData, refreshed: refreshed)
      ])
    }
    return (access.url, access.started, access.isResolved)
  }

  /// Refreshes resolved off the main actor are applied only while the folder still has
  /// the bookmark they were made from, so a re-grant made meanwhile is not overwritten.
  private func storeRefreshedBookmarks(_ refreshes: [BookmarkRefresh]) {
    var changed = false
    for refresh in refreshes where refresh.refreshed != refresh.previous {
      guard let index = folders.firstIndex(where: { $0.id == refresh.folderID }),
        folders[index].bookmarkData == refresh.previous
      else { continue }
      folders[index].bookmarkData = refresh.refreshed
      changed = true
    }
    if changed { persistFolders() }
  }

  private let thumbnailFolders = ThumbnailFolderScopes()

  private func thumbnailAccess(for fileURL: URL) -> MediaThumbnailLoader.FileAccessOpener? {
    let folders = self.folders
    guard !folders.isEmpty else { return nil }
    let scopes = thumbnailFolders
    let generation = usabilityGeneration
    return {
      guard let url = await scopes.root(for: fileURL, folders: folders, generation: generation),
        !Task.isCancelled, url.startAccessingSecurityScopedResource()
      else { return nil }
      return { url.stopAccessingSecurityScopedResource() }
    }
  }

  /// Bookmark resolution and the `opendir` probes run off the main actor; the newest
  /// request's answers are applied when they arrive. `awaitFolderUsability()` waits
  /// for them.
  private func refreshFolderUsability() {
    usabilityGeneration &+= 1
    let generation = usabilityGeneration
    let snapshot = folders.filter(\.isEnabled)
    usabilityTask?.cancel()
    usabilityTask = Task { @MainActor [weak self] in
      let work = Task.detached(priority: .userInitiated) { Self.probeUsability(of: snapshot) }
      let usability = await withTaskCancellationHandler {
        await work.value
      } onCancel: {
        work.cancel()
      }
      guard !Task.isCancelled, let self, generation == self.usabilityGeneration else { return }
      self.storeRefreshedBookmarks(usability.refreshedBookmarks)
      self.folderReadability = usability.readability
      self.watchedRootPaths = usability.rootPaths
      self.hasUsableEnabledFolder = usability.readability.values.contains(true)
      self.enabledFoldersNeedingAccess = usability.needingAccess
      self.usabilityTask = nil
    }
  }

  /// Only the newest refresh clears `usabilityTask`, so this returns once the latest
  /// answers are applied.
  private func awaitFolderUsability() async {
    while let task = usabilityTask {
      await task.value
    }
  }

  private nonisolated static func probeUsability(of folders: [MacWatchedFolder]) -> FolderUsability {
    var usability = FolderUsability()
    for folder in folders {
      guard !Task.isCancelled else { break }
      let access = folder.beginAccess()
      defer {
        if access.started { folder.endAccess(access.url) }
      }
      if let refreshed = access.refreshedBookmark {
        usability.refreshedBookmarks.append(
          BookmarkRefresh(folderID: folder.id, previous: folder.bookmarkData, refreshed: refreshed))
      }
      let readable = isReadableDirectory(access.url)
      usability.readability[folder.id] = readable
      if access.isResolved {
        for path in [access.url.standardizedFileURL.path, access.url.resolvingSymlinksInPath().path].map(
          WatchedFolderPaths.privatePrefixed)
        where !usability.rootPaths.contains(path) {
          usability.rootPaths.append(path)
        }
      }
      if access.isResolved && !readable { usability.needingAccess += 1 }
    }
    return usability
  }

  /// The real usability gate still waits for the background probe.
  public func isFolderReadable(_ folder: MacWatchedFolder) -> Bool {
    folderReadability[folder.id] ?? true
  }

  /// A sandboxed process can stat a folder it was never granted and still be unable to
  /// read it, so existence alone would report a folder as usable while every scan
  /// silently returned nothing. `opendir` answers the same question without paying for
  /// a full directory listing.
  private nonisolated static func isReadableDirectory(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    guard let handle = opendir(path) else { return false }
    closedir(handle)
    return true
  }

  public var canSync: Bool {
    selectedAccount != nil && !isRunning && !isScanning && hasUsableEnabledFolder
  }

  public override func stopTransfer() {
    stopRequested = true
    scanGeneration += 1
    activeScanTask?.cancel()
    activeScanTask = nil
    deferredRescanTask?.cancel()
    deferredRescanTask = nil
    needsRescan = false
    manualRescanRequested = false
    super.stopTransfer()
  }

  public var isStoppedForThisSession: Bool { stopRequested }

  public func requestSyncNow(donate: Bool = true) {
    if donate {
      Task { _ = try? await IntentDonationManager.shared.donate(intent: MacBackUpNowIntent()) }
    }
    stopRequested = false
    cleanupMessage = nil
    manualRescanRequested = true
    Task { await syncNow() }
  }

  /// Whether a pass that just ended should start another: one was asked for while it ran,
  /// by a folder change under Auto-Sync or by Sync Now.
  private var shouldRescanAfterPass: Bool {
    needsRescan && (settings.autoSyncEnabled || manualRescanRequested) && selectedAccount != nil
  }

  public override func toggleAutoSync() {
    super.toggleAutoSync()
    if settings.autoSyncEnabled {
      stopRequested = false
    }
    if settings.autoSyncEnabled && selectedAccount != nil {
      Task { await syncNow() }
    }
  }

  // MARK: - Folders & Watchers

  private func loadFolders() {
    if let data = UserDefaults.standard.data(forKey: foldersKey),
      let list = try? JSONDecoder().decode([MacWatchedFolder].self, from: data)
    {
      self.folders = list
    } else {
      // Default: ~/Pictures
      let picturesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
      self.folders = [MacWatchedFolder(url: picturesURL, title: "Pictures", isEnabled: false)]
      persistFolders()
    }
  }

  private func saveFolders() {
    persistFolders()
    refreshFolderUsability()
  }

  private func persistFolders() {
    if let data = try? JSONEncoder().encode(folders) {
      UserDefaults.standard.set(data, forKey: foldersKey)
    }
  }

  public func addFolder(url: URL) {
    let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    let item = MacWatchedFolder(url: url, bookmarkData: bookmark)
    if let index = folders.firstIndex(where: { $0.id == item.id }) {
      if let bookmark {
        folders[index].bookmarkData = bookmark
        saveFolders()
        rebuildWatchers()
      }
      return
    }
    scanGeneration += 1
    folders.append(item)
    saveFolders()
    rebuildWatchers()
    if settings.autoSyncEnabled {
      if isRunning || isScanning {
        needsRescan = true
      } else {
        Task { await syncNow() }
      }
    }
  }

  public func removeFolder(id: String) {
    scanGeneration += 1
    folders.removeAll { $0.id == id }
    saveFolders()
    rebuildWatchers()
  }

  public func setFolderEnabled(id: String, isEnabled: Bool) {
    if let index = folders.firstIndex(where: { $0.id == id }) {
      scanGeneration += 1
      folders[index].isEnabled = isEnabled
      saveFolders()
      rebuildWatchers()
      if isEnabled && settings.autoSyncEnabled {
        if isRunning || isScanning {
          needsRescan = true
        } else {
          Task { await syncNow() }
        }
      }
    }
  }

  public func openFolderInFinder(url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Bookmark resolution and stream setup run off the main actor. Only the newest
  /// rebuild installs its watchers; an overtaken one stops what it started.
  private func rebuildWatchers() {
    // Changes made while the streams restart are never reported.
    pendingChanges.markFull()
    watcherGeneration &+= 1
    let generation = watcherGeneration
    for watcher in watchers.values { watcher.stop() }
    watchers.removeAll()
    let snapshot = folders.filter(\.isEnabled)
    let onChange: @Sendable (FolderChanges) -> Void = { [weak self] changes in
      Task { @MainActor in
        self?.handleFolderChange(changes)
      }
    }
    // A moved or renamed folder resolves to its new location through the bookmark.
    let onRootChanged: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in
        self?.refreshFolderUsability()
        self?.rebuildWatchers()
      }
    }

    Task { @MainActor [weak self] in
      let started = await Task.detached(priority: .utility) {
        Self.startWatchers(for: snapshot, onChange: onChange, onRootChanged: onRootChanged)
      }.value
      guard let self, generation == self.watcherGeneration else {
        for entry in started { entry.watcher?.stop() }
        return
      }
      self.storeRefreshedBookmarks(started.compactMap(\.refreshedBookmark))
      var unwatchable: Set<String> = []
      for entry in started {
        guard let watcher = entry.watcher else {
          if entry.failedToStart { unwatchable.insert(entry.folderID) }
          continue
        }
        // Stop any watcher already registered for this path: the FSEventStream context
        // retains the watcher, so replacing the entry would leak its stream, queue and
        // security scope for the life of the process.
        self.watchers[entry.key]?.stop()
        self.watchers[entry.key] = watcher
      }
      self.unwatchableFolders = unwatchable
      // A pass that ran while the streams were starting may have read a folder before
      // its stream saw anything.
      self.pendingChanges.markFull()
    }
  }

  private nonisolated static func startWatchers(
    for folders: [MacWatchedFolder],
    onChange: @escaping @Sendable (FolderChanges) -> Void,
    onRootChanged: @escaping @Sendable () -> Void
  ) -> [WatcherStart] {
    folders.compactMap { folder -> WatcherStart? in
      // The watcher takes its own reference on the scope, so this one only covers setup.
      let access = folder.beginAccess()
      defer {
        if access.started { folder.endAccess(access.url) }
      }
      guard access.isResolved else { return nil }
      let watcher = MacFolderWatcher(
        folderURL: access.url,
        isSecurityScoped: access.started,
        onRootChanged: onRootChanged,
        onChange: onChange
      )
      watcher.start()
      return WatcherStart(
        folderID: folder.id,
        key: access.url.standardizedFileURL.path,
        watcher: watcher.isActive ? watcher : nil,
        failedToStart: watcher.failedToStart,
        refreshedBookmark: access.refreshedBookmark.map {
          BookmarkRefresh(folderID: folder.id, previous: folder.bookmarkData, refreshed: $0)
        }
      )
    }
  }

  override public func updateSettings(_ newSettings: AppSettings) {
    let exclusionsChanged = settings.backupExclusions != newSettings.backupExclusions
    super.updateSettings(newSettings)
    if exclusionsChanged { handleFolderChange(.full) }
  }

  private func handleFolderChange(_ changes: FolderChanges = .full) {
    pendingChanges.formUnion(changes)
    guard !stopRequested, settings.autoSyncEnabled else { return }
    if isRunning || isScanning {
      needsRescan = true
      return
    }
    Task { await self.scanChanges() }
  }

  // MARK: - Sync & Upload

  private func resumeRequestedScan() async {
    guard !stopRequested, needsRescan, selectedAccount != nil, !isRunning, !isScanning else { return }
    await scanChanges()
  }

  /// Reads every enabled folder.
  public func syncNow() async {
    pendingChanges.markFull()
    await scanChanges()
  }

  /// Reads what changed since the last pass, or everything when that isn't known.
  private func scanChanges() async {
    // A folder just added, enabled or remounted is only usable once its probe lands.
    await awaitFolderUsability()
    guard !replaysAfterAccountChange(("folderScan", { [weak self] in await self?.scanChanges() })) else { return }
    guard canUseSelectedAccount, !stopRequested, let account = selectedAccount else { return }
    guard !isRunning, !isScanning else {
      needsRescan = true
      return
    }
    // This pass answers any Sync Now asked for so far.
    let retriesFailedNow = manualRescanRequested
    manualRescanRequested = false
    guard hasUsableEnabledFolder else { return }
    cleanupMessage = nil
    isScanning = true
    needsRescan = false
    let generation = scanGeneration
    let accountGeneration = self.accountGeneration
    let changes = pendingChanges
    pendingChanges = FolderChanges()
    defer {
      isScanning = false
      if shouldRescanAfterPass {
        needsRescan = false
        Task { await scanChanges() }
      }
      if !stopRequested, let account = selectedAccount {
        let urls = takePendingDropURLs(for: account.email)
        if !urls.isEmpty {
          Task { await uploadDroppedFiles(urls: urls) }
        }
      }
      // A scan that queued nothing ends no batch, so the batch hook won't run cleanup.
      Task { await runCleanupMaintenance() }
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let finished = await self.scanAllFolders(
        changes, accountEmail: account.email, generation: generation, accountGeneration: accountGeneration,
        retriesFailedNow: retriesFailedNow)
      // A pass cut short may have read only part of what changed.
      if !finished { self.pendingChanges.markFull() }
    }
    activeScanTask = task
    await task.value
    activeScanTask = nil
  }

  public func uploadDroppedFiles(urls: [URL]) async {
    guard !urls.isEmpty else { return }
    stopRequested = false
    importError = nil
    guard let originAccountEmail = selectedAccount?.email else {
      let operationGeneration = dropGeneration
      let stagedFiles = await stageDroppedFiles(urls, accountEmail: nil)
      if stagedFiles.isEmpty {
        importError = stagingError ?? "No supported photos or videos were found."
        return
      }
      if lastStagingHadFailure {
        importError = stagingError ?? "Some selected items could not be imported."
      }
      let pendingURLs = stagedFiles.map(\.url)
      guard !Task.isCancelled, dropGeneration == operationGeneration else {
        for url in stagedFiles.map(\.url) {
          try? FileManager.default.removeItem(at: url)
        }
        return
      }
      for url in pendingURLs where !pendingImportURLs.contains(url) {
        pendingImportURLs.append(url)
      }
      presentSignIn = true
      return
    }
    let originAccountGeneration = accountGeneration
    let operationGeneration = dropGeneration
    let stagedFiles = await stageDroppedFiles(urls, accountEmail: originAccountEmail)
    guard !stagedFiles.isEmpty else {
      importError = stagingError ?? "No supported photos or videos were found."
      return
    }
    if lastStagingHadFailure {
      importError = stagingError ?? "Some selected items could not be imported."
    }
    let stagedURLs = stagedFiles.map(\.url)

    guard !Task.isCancelled, dropGeneration == operationGeneration else {
      for url in stagedURLs {
        try? FileManager.default.removeItem(at: url)
      }
      return
    }

    guard let account = selectedAccount,
      account.email == originAccountEmail,
      accountGeneration == originAccountGeneration
    else {
      enqueuePendingDropURLs(stagedURLs, accountEmail: originAccountEmail)
      return
    }

    guard !isScanning else {
      enqueuePendingDropURLs(stagedURLs, accountEmail: originAccountEmail)
      return
    }

    isScanning = true
    defer {
      isScanning = false
      if shouldRescanAfterPass {
        needsRescan = false
        Task { await scanChanges() }
      }
      if !stopRequested, let account = selectedAccount {
        let pending = takePendingDropURLs(for: account.email)
        if !pending.isEmpty {
          Task { await uploadDroppedFiles(urls: pending) }
        }
      }
    }
    await queue(stagedFiles, accountEmail: account.email, accountGeneration: originAccountGeneration, scanGeneration: nil)
    isScanning = false
    await workerPool.waitForCurrentBatch()
  }

  public func resumePendingImports() async {
    guard selectedAccount != nil, !pendingImportURLs.isEmpty else { return }
    let urls = pendingImportURLs
    pendingImportURLs.removeAll()
    await uploadDroppedFiles(urls: urls)
  }

  private func stageDroppedFiles(_ urls: [URL], accountEmail: String?) async -> [LocalMediaFile] {
    lastStagingHadFailure = false
    stagingError = nil
    activeStagingOperations += 1
    defer { activeStagingOperations -= 1 }
    // Security scope is per process, so holding it here covers the detached copy.
    let accesses = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
    defer {
      for (url, started) in accesses where started {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let root = Self.dropRoot
    // Copying whole photos and videos must not block the main actor.
    let result = await Task.detached(priority: .utility) {
      Self.copyIntoStaging(urls, root: root, accountEmail: accountEmail)
    }.value
    stagingError = result.error
    lastStagingHadFailure = result.hadFailure
    return result.files
  }

  private nonisolated static func copyIntoStaging(
    _ urls: [URL],
    root: URL,
    accountEmail: String?
  ) -> (files: [LocalMediaFile], hadFailure: Bool, error: String?) {
    guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
      return ([], true, "The selected items could not be imported.")
    }
    let stagingPrefix = root.standardizedFileURL.path + "/"
    var staged: [LocalMediaFile] = []
    var hadFailure = false
    var stagingError: String?
    let accountDirectory = root.appendingPathComponent(stagingAccountToken(accountEmail), isDirectory: true)
    // Loose files dropped together share one directory, so a still and its motion file
    // dropped side by side can still pair. Each dropped folder keeps its own.
    var looseBatch: URL?
    for input in urls {
      let files = expand(input, skipsUnsettledFiles: false).files
      guard !files.isEmpty else { continue }
      let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      let batch: URL
      if !isFolder, let looseBatch {
        batch = looseBatch
      } else {
        batch = accountDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)) != nil else { continue }
        if !isFolder { looseBatch = batch }
      }
      for file in files {
        if file.url.standardizedFileURL.path.hasPrefix(stagingPrefix) {
          let existingAccount = stagingAccountEmail(for: file.url, root: root)
          if existingAccount == nil, let accountEmail,
            let promotedURL = promoteStagedDropURL(file.url, to: accountEmail, root: root)
          {
            staged.append(
              LocalMediaFile(
                url: promotedURL,
                size: file.size,
                created: file.created,
                modified: file.modified
              ))
          } else {
            staged.append(file)
          }
          continue
        }
        let destination = uniqueStagingURL(in: batch, for: file.url)
        let temporary = destination.appendingPathExtension("partial")
        do {
          try UploadWorkerPool.requireFreeSpace(for: file.size, at: batch)
          try FileManager.default.copyItem(at: file.url, to: temporary)
          try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: temporary.path)
          try FileManager.default.moveItem(at: temporary, to: destination)
          staged.append(
            LocalMediaFile(
              url: destination,
              size: file.size,
              created: file.created,
              modified: file.modified
            ))
        } catch {
          hadFailure = true
          stagingError = error.localizedDescription
          try? FileManager.default.removeItem(at: temporary)
          try? FileManager.default.removeItem(at: destination)
        }
      }
    }
    return (staged, hadFailure, stagingError)
  }

  private nonisolated static var dropRoot: URL {
    AppGroupConstants.storageDirectory().appendingPathComponent("DroppedUploads", isDirectory: true)
  }

  private nonisolated static func promoteStagedDropURL(_ url: URL, to accountEmail: String, root: URL) -> URL? {
    guard stagingAccountEmail(for: url, root: root) == nil else { return url }
    let accountDirectory = root.appendingPathComponent(stagingAccountToken(accountEmail), isDirectory: true)
    let destinationBatch = accountDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = destinationBatch.appendingPathComponent(url.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: destinationBatch, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: url, to: destination)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: destinationBatch)
      return nil
    }
  }

  private nonisolated static func stagingAccountToken(_ accountEmail: String?) -> String {
    guard let accountEmail, !accountEmail.isEmpty else { return "_unassigned" }
    return accountEmail.utf8.map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func stagingAccountEmail(for url: URL, root: URL) -> String? {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    let relative = String(path.dropFirst(rootPath.count + 1))
    guard let token = relative.split(separator: "/").first else { return nil }
    if token == "_unassigned" { return nil }
    let characters = Array(token)
    guard characters.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    for index in stride(from: 0, to: characters.count, by: 2) {
      guard let first = UInt8(String(characters[index]), radix: 16),
        let second = UInt8(String(characters[index + 1]), radix: 16)
      else { return nil }
      bytes.append(first << 4 | second)
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  private nonisolated static func uniqueStagingURL(in directory: URL, for source: URL) -> URL {
    let original = directory.appendingPathComponent(source.lastPathComponent)
    guard FileManager.default.fileExists(atPath: original.path) else { return original }
    let suffix = UUID().uuidString
    let extensionName = source.pathExtension
    let stem = source.deletingPathExtension().lastPathComponent
    let filename = extensionName.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(extensionName)"
    return directory.appendingPathComponent(filename)
  }

  /// Returns false when the pass stopped before recording what it found.
  private func scanAllFolders(
    _ requested: FolderChanges, accountEmail: String, generation: Int, accountGeneration: Int, retriesFailedNow: Bool
  ) async -> Bool {
    let enabled = folders.filter(\.isEnabled)
    let exclusions = settings.folderExclusions
    let basis = ScanBasis(
      accountEmail: accountEmail, removalCount: await manifestStore.removalCount, pairLivePhotos: settings.pairLivePhotos,
      exclusions: exclusions)
    let changes = await scanScope(requested, basis: basis, accountEmail: accountEmail)
    let watchedPaths = Set(watchers.filter { $0.value.isActive }.keys)
    var accesses: [(MacWatchedFolder, URL)] = []
    defer {
      for (folder, url) in accesses {
        folder.endAccess(url)
      }
    }
    var allFiles: [LocalMediaFile] = []
    var deferredRecentWrites = false
    var unsettled = Set<String>()
    for folder in enabled {
      guard !stopRequested, generation == scanGeneration, accountGeneration == self.accountGeneration else {
        if !stopRequested { needsRescan = true }
        return false
      }
      // Access is taken inside the task so the bookmark resolves off the main actor,
      // and is released by the `defer` above once the upload batch has finished.
      let scanTask = Task.detached(priority: .utility) { () -> FolderScan in
        let access = folder.beginAccess()
        // Only a live stream on a local volume reports every change; a network share
        // misses what other machines write.
        let isWatched =
          watchedPaths.contains(access.url.standardizedFileURL.path)
          && (try? access.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
        return FolderScan(
          url: access.url,
          started: access.started,
          isResolved: access.isResolved,
          refreshedBookmark: access.refreshedBookmark.map {
            BookmarkRefresh(folderID: folder.id, previous: folder.bookmarkData, refreshed: $0)
          },
          media: access.isResolved
            ? Self.expand(access.url, changes: isWatched ? changes : .full, exclusions: exclusions) : MediaScan()
        )
      }
      let scan = await withTaskCancellationHandler {
        await scanTask.value
      } onCancel: {
        scanTask.cancel()
      }
      if scan.started {
        accesses.append((folder, scan.url))
      }
      if let refresh = scan.refreshedBookmark {
        storeRefreshedBookmarks([refresh])
      }
      guard !stopRequested, !Task.isCancelled,
        generation == scanGeneration,
        accountGeneration == self.accountGeneration
      else {
        if !stopRequested { needsRescan = true }
        return false
      }
      if scan.isResolved {
        await removeUnfinishedRecordsWithoutSource(
          accountEmail: accountEmail, folderRoot: scan.url, scannedFiles: scan.media.files)
        await removeUnfinishedRecordsExcluded(accountEmail: accountEmail, folderRoot: scan.url, exclusions: exclusions)
      }
      allFiles.append(contentsOf: scan.media.files)
      deferredRecentWrites = deferredRecentWrites || scan.media.deferredRecentWrites
      unsettled.formUnion(scan.media.unsettledDirectories)
    }
    if deferredRecentWrites {
      scheduleDeferredRescan()
    } else {
      deferredRescanDelay = FolderMediaScanner.writeSettleInterval
    }
    guard
      await queue(
        allFiles, accountEmail: accountEmail, accountGeneration: accountGeneration, scanGeneration: generation,
        retriesFailedNow: retriesFailedNow)
    else { return false }
    // Every directory left unsettled before was part of this pass, so what it found
    // replaces them.
    unsettledDirectories = unsettled
    if changes.isFull { fullScanBasis = basis }
    isScanning = false
    await workerPool.waitForCurrentBatch()
    return true
  }

  /// What a pass must read to find everything a full one would queue: the changed
  /// directories, those still holding unfinished files, and those of files waiting to
  /// go up or retried after a failure, which a full pass queues every time.
  private func scanScope(_ requested: FolderChanges, basis: ScanBasis, accountEmail: String) async -> FolderChanges {
    var changes = requested
    if fullScanBasis != basis { changes.markFull() }
    guard !changes.isFull else { return changes }
    for directory in unsettledDirectories { changes.insertDirectory(directory) }
    let dropRoot = Self.dropRoot.standardizedFileURL.path
    for record in await manifestStore.allRecords()
    where record.status == .pending || record.status == .failed {
      guard TransferRecord.accountEmail(fromScopedID: record.id) == accountEmail else { continue }
      for path in [record.sourcePath, record.pairedSourcePath].compactMap(\.self)
      where !WatchedFolderPaths.isPath(path, inside: dropRoot) {
        changes.insertDirectory((path as NSString).deletingLastPathComponent)
      }
    }
    return changes
  }

  /// Returns false when the files were not recorded, so a pass must read them again.
  @discardableResult
  private func queue(
    _ files: [LocalMediaFile],
    accountEmail: String,
    accountGeneration: Int,
    scanGeneration: Int?,
    retriesFailedNow: Bool = false
  ) async -> Bool {
    guard !stopRequested, !Task.isCancelled,
      self.accountGeneration == accountGeneration,
      selectedAccount?.email == accountEmail,
      scanGeneration == nil || scanGeneration == self.scanGeneration
    else {
      if selectedAccount != nil { needsRescan = true }
      return false
    }
    let currentRecords = await manifestStore.allRecords()
    guard !stopRequested, !Task.isCancelled,
      self.accountGeneration == accountGeneration,
      selectedAccount?.email == accountEmail
    else { return false }
    // Matching a whole library against the manifest and pairing Live Photos (which
    // stats every candidate) must not block the main actor.
    let pairLivePhotos = settings.pairLivePhotos
    // Drops (no scan generation) are staged under random directory names, which must
    // never become album names.
    let createAlbumsFromFolders = settings.createAlbumsFromFolders && scanGeneration != nil
    let plan = await Task.detached(priority: .utility) {
      FolderMediaScanner.planQueue(
        files: files,
        records: currentRecords,
        accountEmail: accountEmail,
        pairLivePhotos: pairLivePhotos,
        createAlbumsFromFolders: createAlbumsFromFolders,
        retriesFailedNow: retriesFailedNow
      )
    }.value
    let queueItems = plan.items
    let newRecords = plan.newRecords

    guard !stopRequested, !Task.isCancelled,
      self.accountGeneration == accountGeneration,
      selectedAccount?.email == accountEmail,
      scanGeneration == nil || scanGeneration == self.scanGeneration
    else {
      if selectedAccount != nil { needsRescan = true }
      return false
    }
    guard await manifestStore.upsertBatch(newRecords) else {
      importError = "The import could not be saved. Please try again."
      return false
    }
    // From here every file has a record; one left unclaimed stays pending, and the
    // next pass reads its directory again.

    let claimedIDs = await manifestStore.claimForUpload(ids: queueItems.map(\.id))
    let claimedItems = queueItems.filter { claimedIDs.contains($0.id) }
    await refreshRecords()
    guard !stopRequested, !Task.isCancelled,
      self.accountGeneration == accountGeneration,
      selectedAccount?.email == accountEmail,
      scanGeneration == nil || scanGeneration == self.scanGeneration,
      !claimedItems.isEmpty
    else {
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
      return true
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !stopRequested, !Task.isCancelled,
      self.accountGeneration == accountGeneration,
      selectedAccount?.email == accountEmail,
      scanGeneration == nil || scanGeneration == self.scanGeneration
    else {
      if selectedAccount != nil { needsRescan = true }
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
      return true
    }
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: accountEmail) == .rejected {
      if scanGeneration != nil {
        _ = replaysAfterAccountChange(("folderScan", { [weak self] in await self?.scanChanges() }))
      } else {
        let dropRoot = Self.dropRoot.standardizedFileURL.path
        _ = replaysAfterAccountChange(
          (
            "drops",
            { [weak self] in
              await self?.requeuePendingRecords(named: "drops") { record in
                record.sourcePath.map { WatchedFolderPaths.isPath($0, inside: dropRoot) } ?? false
              }
            }
          ))
      }
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
    }
    return true
  }

  /// Files still being written are skipped by a scan; this picks them up once they
  /// have settled. A newer deferral replaces the pending one, and each consecutive one
  /// waits twice as long.
  private func scheduleDeferredRescan() {
    deferredRescanTask?.cancel()
    let delay = deferredRescanDelay
    deferredRescanDelay = min(delay * 2, Self.maxDeferredRescanDelay)
    deferredRescanTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.deferredRescanTask = nil
      await self.scanChanges()
    }
  }

  /// Each directory's pairs, so a pass over many Live Photos lists it once.
  private final class LivePhotoPairCache {
    var pairsByDirectory: [String: [LivePhotoExport]] = [:]
  }

  private func livePhotoPairs(in directory: URL, cache: LivePhotoPairCache) async -> [LivePhotoExport] {
    if let cached = cache.pairsByDirectory[directory.path] { return cached }
    let read: @Sendable () -> [LivePhotoExport] = {
      let candidates =
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      return LivePhotoManager.findLivePhotoPairs(in: candidates).pairs
    }
    let enclosingFolder = folders.first { folder in
      FolderMediaScanner.isInsideProtectedFolder(directory, ignored: (folder.resolvedURL ?? folder.url).path)
    }
    let pairs: [LivePhotoExport]
    if let enclosingFolder {
      pairs = await withFolderAccess(enclosingFolder) { await Task.detached(priority: .utility, operation: read).value }
    } else {
      pairs = await Task.detached(priority: .utility, operation: read).value
    }
    cache.pairsByDirectory[directory.path] = pairs
    return pairs
  }

  private func makeRetryItem(
    for record: TransferRecord, roots: [URL], pairCache: LivePhotoPairCache = LivePhotoPairCache()
  ) async -> UploadQueueItem? {
    guard let url = await existingFileURLAsync(for: record, roots: roots) else { return nil }
    if record.mediaType == "Live Photo" {
      guard await existingPairedFileURLAsync(for: record, roots: roots) != nil else { return nil }
      let pairs = await livePhotoPairs(in: url.deletingLastPathComponent(), cache: pairCache)
      guard
        let pair = pairs.first(where: {
          $0.photoURL.standardizedFileURL.path == url.standardizedFileURL.path
            && (record.pairedSourcePath == nil || $0.videoURL.path == record.pairedSourcePath)
        })
      else {
        return nil
      }
      return UploadQueueItem(
        id: record.id,
        fileURL: pair.photoURL,
        filename: pair.photoFilename,
        livePhotoExport: pair,
        creationDate: pair.creationDate,
        albumNames: albumNames(for: pair.photoURL),
        precomputedSHA1: record.sourceSHA1,
        precomputedSourceModifiedAt: record.sourceModifiedAt,
        pairLivePhotos: settings.pairLivePhotos,
        removeSourceOnSuccess: false
      )
    }
    return UploadQueueItem(
      id: record.id,
      fileURL: url,
      filename: record.filename,
      fileSize: record.byteCount ?? 0,
      creationDate: record.creationDate,
      albumNames: albumNames(for: url),
      precomputedSHA1: record.sourceSHA1,
      precomputedSourceModifiedAt: record.sourceModifiedAt,
      pairLivePhotos: settings.pairLivePhotos,
      removeSourceOnSuccess: false
    )
  }

  override public func idleMirrorConditionsHold() -> Bool {
    MacMirrorScheduler.powerAndNetworkAllowMirror(requiresPower: settings.copiesOnlyWhileCharging)
  }

  override public func mirrorItem(for record: TransferRecord) async -> UploadQueueItem? {
    let roots = await allowedSourceRootsAsync()
    return await makeRetryItem(for: record, roots: roots)
  }

  /// A scan holds its folder's scope; manual retries take their own below.
  private func removeUnfinishedRecordsWithoutSource(
    accountEmail: String, records requested: [TransferRecord]? = nil,
    folderRoot: URL? = nil, scannedFiles: [LocalMediaFile] = []
  ) async {
    let snapshot: [TransferRecord]
    if let requested { snapshot = requested } else { snapshot = await manifestStore.allRecords() }
    let candidates = snapshot.filter {
      ($0.status == .pending || $0.status == .failed) && $0.id.hasPrefix("\(accountEmail)|")
    }
    guard !candidates.isEmpty else { return }
    let folders = folders
    let missing = await Task.detached(priority: .utility) {
      let entries = Dictionary(
        SharedQueueBridge.loadEntries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let scanned = Set(scannedFiles.map { $0.url.standardizedFileURL.path })
      return candidates.filter { record in
        guard let path = record.sourcePath else { return false }
        let url = URL(fileURLWithPath: path)
        if let id = record.sharedEntryID, let entry = entries[id],
          SharedQueueBridge.fileURL(for: entry) != nil
        {
          return false
        }
        if let folderRoot {
          guard !scanned.contains(url.standardizedFileURL.path) else { return false }
          return FolderMediaScanner.fileIsConfirmedMissing(url, in: folderRoot, includesCloudPlaceholder: true)
        }
        if let folder = folders.first(where: { $0.contains(url) }) {
          let access = folder.beginAccess()
          defer { if access.started { folder.endAccess(access.url) } }
          guard access.isResolved else { return false }
          return FolderMediaScanner.fileIsConfirmedMissing(url, in: access.url)
        }
        return FolderMediaScanner.fileIsConfirmedMissing(url, in: url.deletingLastPathComponent())
      }
    }.value
    var entriesToRemove = Set<UUID>()
    for record in missing {
      guard await manifestStore.removeIfUnfinished(id: record.id) else { continue }
      if let id = record.sharedEntryID { entriesToRemove.insert(id) }
    }
    if !entriesToRemove.isEmpty { try? SharedQueueBridge.removeEntries(ids: entriesToRemove) }
    if !missing.isEmpty { await refreshRecords() }
  }

  /// Items queued from a folder or file the rules now leave out never go up: their
  /// unfinished records are dropped (nothing was sent, so nothing is lost).
  private func removeUnfinishedRecordsExcluded(
    accountEmail: String, folderRoot: URL, exclusions: FolderExclusions
  ) async {
    guard !exclusions.isEmpty else { return }
    let excluded = await manifestStore.allRecords().filter { record in
      guard record.status == .pending || record.status == .failed, record.id.hasPrefix("\(accountEmail)|"),
        record.sharedEntryID == nil, let path = record.sourcePath
      else { return false }
      let url = URL(fileURLWithPath: path)
      return WatchedFolderPaths.isPath(path, inside: folderRoot.standardizedFileURL.path)
        && exclusions.excludes(url, below: folderRoot)
    }
    var removed = false
    for record in excluded where await manifestStore.removeIfUnfinished(id: record.id) { removed = true }
    if removed { await refreshRecords() }
  }

  override public func retryFailedForUser() async {
    stopRequested = false
    if let account = selectedAccount {
      await removeUnfinishedRecordsWithoutSource(accountEmail: account.email, records: failedRecords)
    }
    retriesFailedItemsNow = true
    await super.retryFailedForUser()
  }

  override public func queueItems(forPending records: [TransferRecord]) async -> [UploadQueueItem] {
    if let account = selectedAccount {
      await removeUnfinishedRecordsWithoutSource(accountEmail: account.email, records: records)
    }
    let roots = await allowedSourceRootsAsync()
    let pairCache = LivePhotoPairCache()
    var items: [UploadQueueItem] = []
    for record in records {
      if let item = await makeRetryItem(for: record, roots: roots, pairCache: pairCache) { items.append(item) }
    }
    return items
  }

  override public func resumePendingWork() async {
    guard !stopRequested else { return }
    await ingestSharedQueueItems()
    if settings.autoSyncEnabled { await syncNow() }
    await requeuePendingRecords { $0.sharedEntryID == nil }
  }

  override public func retryFailed() async {
    guard canUseSelectedAccount, !stopRequested, !isRunning, let account = selectedAccount else { return }
    let retriesNow = retriesFailedItemsNow
    retriesFailedItemsNow = false
    let generation = accountGeneration
    let accountPrefix = "\(account.email)|"
    let roots = await allowedSourceRootsAsync()
    let pairCache = LivePhotoPairCache()
    var candidates: [UploadQueueItem] = []
    for record in failedRecords
    where record.id.hasPrefix(accountPrefix) && (retriesNow || record.isDueForAutomaticRetry()) {
      if let item = await makeRetryItem(for: record, roots: roots, pairCache: pairCache) {
        candidates.append(item)
      }
    }

    var claimedItems: [UploadQueueItem] = []
    for item in candidates {
      guard await manifestStore.resetForResend(id: item.id, accountEmail: account.email),
        await manifestStore.claimForUpload(id: item.id)
      else { continue }
      claimedItems.append(item)
    }
    await refreshRecords()
    guard !stopRequested, !claimedItems.isEmpty, accountGeneration == generation, selectedAccount?.email == account.email else {
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
      return
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !stopRequested, accountGeneration == generation, selectedAccount?.email == account.email else {
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
      return
    }
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: account.email) == .rejected {
      for item in claimedItems { await manifestStore.releaseUploadClaim(id: item.id) }
    }
  }

  public override func requeueRecord(_ record: TransferRecord) async {
    guard canUseSelectedAccount, let account = selectedAccount else { return }
    stopRequested = false
    let generation = accountGeneration
    guard record.id.hasPrefix("\(account.email)|") else { return }
    await removeUnfinishedRecordsWithoutSource(accountEmail: account.email, records: [record])
    let roots = await allowedSourceRootsAsync()
    guard let item = await makeRetryItem(for: record, roots: roots) else { return }
    guard await manifestStore.resetForResend(id: record.id, accountEmail: account.email),
      await manifestStore.claimForUpload(id: record.id)
    else { return }
    await refreshRecords()
    workerPool.setConcurrency(settings.uploadThreads)
    guard !stopRequested, accountGeneration == generation, selectedAccount?.email == account.email else {
      await manifestStore.releaseUploadClaim(id: record.id)
      return
    }
    if workerPool.start(items: [item], quality: 3, accountEmail: account.email) == .rejected {
      await manifestStore.releaseUploadClaim(id: record.id)
      await manifestStore.updateStatus(id: record.id, status: .failed, error: "Unable to start upload")
    }
  }

  /// macOS derives at most one album, from the file's own folder. iOS mirrors a photo
  /// library instead and can attach a photo to several albums at once.
  private func albumNames(for fileURL: URL) -> [String] {
    // A staged drop lives in a randomly named directory, not a folder the user named.
    guard !WatchedFolderPaths.isPath(fileURL.standardizedFileURL.path, inside: Self.dropRoot.standardizedFileURL.path)
    else { return [] }
    return FolderMediaScanner.albumNames(for: fileURL, createAlbumsFromFolders: settings.createAlbumsFromFolders)
  }

  // MARK: - Settings & Launch at Login

  public func setLaunchAtLogin(_ enabled: Bool) {
    launchAtLoginError = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLaunchAtLoginStatus()
    } catch {
      refreshLaunchAtLoginStatus()
      // Reported next to the toggle, not through `importError`, which is the first
      // branch of the backup status card and would hijack it.
      if !launchAtLoginRequiresApproval {
        launchAtLoginError = error.localizedDescription
      }
    }
  }

  /// Re-reads the login item status, which the user can change in System Settings
  /// while the app is running. Call when the app becomes active.
  public func refreshLaunchAtLoginStatus() {
    let status = SMAppService.mainApp.status
    launchAtLoginEnabled = status == .enabled
    launchAtLoginRequiresApproval = status == .requiresApproval
    if launchAtLoginRequiresApproval {
      launchAtLoginError = Self.launchAtLoginApprovalMessage
    } else if launchAtLoginError == Self.launchAtLoginApprovalMessage {
      launchAtLoginError = nil
    }
  }

  public func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private static let launchAtLoginApprovalMessage =
    "Allow \(ProductCopy.name) in System Settings › General › Login Items to finish turning this on."

  public func addIgnoredFolder(url: URL) {
    var copy = settings
    let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    let loc = IgnoredFolderLocation(url: url, bookmarkData: bookmark)
    if let index = copy.ignoredFolders.firstIndex(where: { $0.path == loc.path }) {
      if let bookmark { copy.ignoredFolders[index].bookmarkData = bookmark }
      updateSettings(copy)
    } else {
      copy.ignoredFolders.append(loc)
      updateSettings(copy)
    }
    refreshProtectedFolderStatus()
  }

  public func removeIgnoredFolder(id: String) {
    var copy = settings
    copy.ignoredFolders.removeAll(where: { $0.id == id })
    updateSettings(copy)
    refreshProtectedFolderStatus()
  }

  /// Bookmark resolution is an XPC round trip, so it runs off the main actor; only the
  /// newest check's answer is applied.
  public func refreshProtectedFolderStatus() {
    protectedFolderCheckGeneration &+= 1
    let generation = protectedFolderCheckGeneration
    let protected = settings.ignoredFolders
    Task { @MainActor [weak self] in
      let missing = await Task.detached(priority: .utility) {
        Set(protected.filter { !$0.canBeFound }.map(\.id))
      }.value
      guard let self, generation == self.protectedFolderCheckGeneration else { return }
      if missing != self.missingProtectedFolderIDs { self.missingProtectedFolderIDs = missing }
    }
  }

  // MARK: - Cleanup

  /// Whether a manual Clean Up can start now.
  public var canCleanUp: Bool {
    canUseSelectedAccount && settings.autoDeleteDelay != .never && !isRunning && !isCleaningUp && !isPreparingCleanup
  }

  /// Lists what Clean Up would remove, through every check the removal itself makes.
  /// Nil while a cleanup is already being prepared or run. An empty plan has already
  /// said why in `cleanupNotice`.
  public func prepareCleanup() async -> MacCleanupPlan? {
    await withAccountWork { await self.planCleanup() } ?? nil
  }

  private func planCleanup() async -> MacCleanupPlan? {
    guard !Task.isCancelled, !isPreparingCleanup, !isCleaningUp else { return nil }
    isPreparingCleanup = true
    defer { isPreparingCleanup = false }
    cleanupMessage = nil
    clearCleanupNotice()
    await recoverDeletionTombstones()
    guard settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email else { return nil }
    let eligible = await eligibleCleanupRecords(accountEmail: accountEmail)
    let pass = await cleanupPass(.plan, eligible: eligible, accountEmail: accountEmail)
    let plan = MacCleanupPlan(records: pass.planned)
    if plan.isEmpty { reportNothingRemoved(pass) }
    return plan
  }

  /// Removes what `plan` lists that is still due now. The plan may be minutes old, so
  /// every file goes through the full check, claim and verification again.
  public func performCleanup(plan: MacCleanupPlan) async {
    await withAccountWork { await self.applyCleanup(plan: plan) }
  }

  private func applyCleanup(plan: MacCleanupPlan) async {
    guard !Task.isCancelled, !isCleaningUp, !isPreparingCleanup, !plan.isEmpty else { return }
    isCleaningUp = true
    defer { isCleaningUp = false }
    cleanupMessage = nil
    clearCleanupNotice()
    await recoverDeletionTombstones()
    guard settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email else { return }
    let eligible = await eligibleCleanupRecords(accountEmail: accountEmail)
    let pass = await cleanupPass(.remove(limitedTo: Set(plan.records.map(\.id))), eligible: eligible, accountEmail: accountEmail)
    await refreshRecords()
    if pass.removed > 0 {
      cleanupMessage =
        pass.failed > 0
        ? ProductCopy.inflected(
          "Removed ^[\(pass.removed) file](inflect: true) from this Mac; ^[\(pass.failed) file](inflect: true) couldn’t be removed.")
        : ProductCopy.inflected("Removed ^[\(pass.removed) file](inflect: true) from this Mac. They stay in Google Photos.")
    } else {
      reportNothingRemoved(pass)
    }
    scheduleCleanupRekey(pass.deletedRecords, accountEmail: accountEmail)
  }

  /// After a batch or a watched-folder scan, Delete After Backup removes what is due
  /// without asking, through the same pass as Clean Up. That pass re-reads and hashes
  /// files, so an unchanged due set is looked at again at most hourly.
  public func runCleanupMaintenance() async {
    await withAccountWork(wake: ("cleanup", { [weak self] in await self?.runCleanupMaintenance() })) {
      await self.applyCleanupMaintenance()
    }
  }

  private func applyCleanupMaintenance() async {
    guard !isRunningCleanupMaintenance, !isCleaningUp, !isPreparingCleanup, !isRunning, !isScanning,
      !Task.isCancelled, settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email
    else { return }
    isRunningCleanupMaintenance = true
    defer { isRunningCleanupMaintenance = false }

    let eligible = await eligibleCleanupRecords(accountEmail: accountEmail)
    guard !eligible.isEmpty else { return }
    var hasher = Hasher()
    hasher.combine(eligible.map(\.id).sorted())
    hasher.combine(settings.ignoredFolders)
    hasher.combine(settings.smartDeleteEnabled)
    let key = hasher.finalize()
    if let last = lastCleanupMaintenance, last.key == key,
      Date().timeIntervalSince(last.date) < Self.cleanupMaintenanceInterval
    {
      return
    }
    lastCleanupMaintenance = (key, Date())

    await recoverDeletionTombstones()
    guard !isRunning, !isScanning, !isCleaningUp, !Task.isCancelled, settings.autoDeleteDelay != .never,
      selectedAccount?.email == accountEmail
    else { return }
    let pass = await cleanupPass(.remove(limitedTo: nil), eligible: eligible, accountEmail: accountEmail)
    if pass.removed > 0 || pass.failed > 0 { await refreshRecords() }
    scheduleCleanupRekey(pass.deletedRecords, accountEmail: accountEmail)
  }

  private func scheduleCleanupRekey(_ records: [TransferRecord], accountEmail: String) {
    guard !records.isEmpty, canUseSelectedAccount,
      let cloudLibrary, cloudLibrary.accountEmail == accountEmail
    else { return }
    LibraryIndexer.scheduleRekeyDeleted(records, cloud: cloudLibrary)
  }

  private static let cleanupMaintenanceInterval: TimeInterval = 60 * 60

  private func eligibleCleanupRecords(accountEmail: String) async -> [TransferRecord] {
    guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else { return [] }
    await manifestStore.setRetention(settings.autoDeleteDelay)
    // Free space is judged per volume in the pass, not on the home volume the store measures.
    let candidates = await manifestStore.eligibleForDeletion(
      delay: settings.autoDeleteDelay,
      smartDelete: false,
      accountEmail: accountEmail,
      accountEmails: Set(accounts.map(\.email)).union([accountEmail]),
      excludingAccounts: Set(accounts.filter { !$0.mirrorEnabled && $0.email != accountEmail }.map(\.email)),
      includesFoundItems: settings.removesItemsAlreadyInGooglePhotos
    )
    guard !Task.isCancelled, allowsAccountWork else { return [] }
    return await remoteCopyVerifier.confirmed(candidates, accountEmail: accountEmail)
  }

  private enum CleanupMode {
    /// Runs every check and lists what would go, removing nothing.
    case plan
    /// Removes what passes every check, only among `limitedTo` when given.
    case remove(limitedTo: Set<String>?)
  }

  private struct CleanupPass {
    var protectedFolderMissing = false
    var planned: [TransferRecord] = []
    var deletedRecords: [TransferRecord] = []
    var removed: Int { deletedRecords.count }
    var failed = 0
    var checkedSpace = false
    var anyVolumeLow = false
  }

  /// The one path every removal from this Mac takes — Clean Up's plan, its run, and the
  /// automatic pass — so none of them can check less. A record goes only when it is
  /// eligible in the manifest, inside an allowed root, outside every protected folder,
  /// not a shared iCloud item, has its Live Photo motion, and (with Only When Low on
  /// Space) sits on a volume that is still short; then it is claimed, re-checked and
  /// deleted through the manifest's verified tombstone path.
  private func cleanupPass(_ mode: CleanupMode, eligible: [TransferRecord], accountEmail: String) async -> CleanupPass {
    var pass = CleanupPass()
    let smartDelete = settings.smartDeleteEnabled
    let ignored = settings.ignoredFolders
    let watchedIDs = folders.map(\.id)
    let watchedEnabled = folders.map(\.isEnabled)
    // A protected folder that can be found neither through its bookmark nor at its path
    // could hold any of these files, so nothing goes until it can be.
    let protectedPaths = await Task.detached(priority: .utility) { IgnoredFolderLocation.protectedPaths(ignored) }.value
    guard let protectedPaths else {
      pass.protectedFolderMissing = true
      return pass
    }
    // A file that could not be removed is left alone for a while, not retried and
    // reported again on every pass.
    let backingOff = DeletionFailureBackoff.idsBackingOff()
    // Bytes still to free per volume, measured once; `eligible` is oldest upload first.
    var bytesNeededByVolume: [URL: Int64] = [:]
    var volumeByRoot: [String: URL] = [:]
    // Resolved once: each call re-resolves every folder's security-scoped bookmark.
    let roots = await allowedSourceRootsAsync()
    let folderRoots = folders.compactMap { folder in folder.resolvedURL.map { (folder, $0.path) } }
    for rec in eligible where !backingOff.contains(rec.id) {
      guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else { break }
      if case .remove(let ids?) = mode, !ids.contains(rec.id) { continue }
      guard rec.sharedEntryID == nil,
        let sourcePath = rec.sourcePath,
        let fileURL = Self.validatedSourceFileURL(atPath: sourcePath, roots: roots)
      else { continue }
      if IgnoredFolderLocation.isProtected(fileURL, protectedPaths: protectedPaths) {
        continue
      }
      let folder = folderRoots.first { FolderMediaScanner.isInsideProtectedFolder(fileURL, ignored: $0.1) }?.0
      let access = folder.map { beginAccess($0) }
      defer {
        if let folder, let access, access.started {
          folder.endAccess(access.url)
        }
      }
      // Removing a shared iCloud item's local copy removes it for everyone. Read under
      // the folder's scope, since an unreadable item counts as shared.
      if FolderMediaScanner.isSharedCloudItem(fileURL) { continue }
      var volume: URL?
      if smartDelete {
        let root = folder?.resolvedURL ?? fileURL.deletingLastPathComponent()
        let resolved =
          volumeByRoot[root.path]
          ?? (try? root.resourceValues(forKeys: [.volumeURLKey]))?.volume
          ?? root
        volumeByRoot[root.path] = resolved
        if bytesNeededByVolume[resolved] == nil {
          let needed = TransferManifestStore.bytesNeededToRecover(onVolumeOf: root)
          bytesNeededByVolume[resolved] = needed
          pass.checkedSpace = true
          pass.anyVolumeLow = pass.anyVolumeLow || needed > 0
        }
        guard (bytesNeededByVolume[resolved] ?? 0) > 0 else { continue }
        volume = resolved
      }
      let pairedVideoURL: URL?
      if rec.mediaType == "Live Photo" {
        pairedVideoURL = await existingPairedFileURLAsync(for: rec, roots: roots)
      } else {
        pairedVideoURL = nil
      }
      let pairedFileAvailable = rec.mediaType != "Live Photo" || pairedVideoURL != nil
      if rec.mediaType == "Live Photo" && pairedVideoURL == nil { continue }
      if let pairedVideoURL,
        IgnoredFolderLocation.isProtected(pairedVideoURL, protectedPaths: protectedPaths)
          || FolderMediaScanner.isSharedCloudItem(pairedVideoURL)
      {
        continue
      }
      switch mode {
      case .plan:
        pass.planned.append(rec)
      case .remove:
        guard !Task.isCancelled, allowsAccountWork else { break }
        guard await manifestStore.claimForDeletion(id: rec.id) else { continue }
        guard await manifestStore.deletionClaimIsValid(id: rec.id),
          settings.ignoredFolders == ignored,
          Self.validatedSourceFileURL(atPath: sourcePath, roots: roots) != nil,
          pairedFileAvailable
        else {
          await manifestStore.releaseDeletionClaim(id: rec.id)
          continue
        }
        await KeptThumbnails.keep(rec, fileURL: fileURL)
        let current = settings
        guard
          await manifestStore.isStillDue(id: rec.id, settings: current, accountEmail: accountEmail, accounts: accounts)
        else {
          await manifestStore.releaseDeletionClaim(id: rec.id)
          continue
        }
        // Nothing suspends from here to the store's own checks: a folder may have been
        // protected or removed, or cleanup turned down, while the thumbnail was saved.
        guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail, settings == current,
          settings.ignoredFolders == ignored, settings.smartDeleteEnabled == smartDelete,
          folders.map(\.id) == watchedIDs, folders.map(\.isEnabled) == watchedEnabled,
          Self.validatedSourceFileURL(atPath: sourcePath, roots: roots) != nil,
          !FolderMediaScanner.isSharedCloudItem(fileURL),
          pairedVideoURL.map({ !FolderMediaScanner.isSharedCloudItem($0) }) ?? true
        else {
          await manifestStore.releaseDeletionClaim(id: rec.id)
          continue
        }
        let policy = cleanupPolicy.current
        guard
          await manifestStore.deleteSourceFiles(
            id: rec.id,
            fileURL: fileURL,
            pairedFileURL: pairedVideoURL,
            mayRemove: cleanupPolicy.check(root: folder?.resolvedURL)
          )
        else {
          // Called off by a change made meanwhile, it isn't a failure.
          guard cleanupPolicy.current == policy else { continue }
          pass.failed += 1
          DeletionFailureBackoff.recordFailure(rec.id)
          needsTombstoneRecovery = true
          continue
        }
        DeletionFailureBackoff.clear(rec.id)
        pass.deletedRecords.append(rec)
      }
      if let volume {
        var freed = rec.sourceFileSize ?? rec.byteCount ?? 0
        if pairedVideoURL != nil { freed += rec.pairedSourceFileSize ?? 0 }
        bytesNeededByVolume[volume, default: 0] -= max(0, freed)
      }
    }
    return pass
  }

  /// Says why a cleanup removed nothing, beside the Clean Up button.
  private func reportNothingRemoved(_ pass: CleanupPass) {
    if pass.protectedFolderMissing {
      showCleanupNotice(
        String(
          localized:
            "A protected folder can’t be found, so nothing was removed. Reconnect it or remove it from Protected Folders."),
        isWarning: true)
    } else if pass.failed > 0 {
      showCleanupNotice(
        ProductCopy.inflected("^[\(pass.failed) file](inflect: true) couldn’t be removed. Clean Up will try again later."),
        isWarning: true)
    } else if settings.smartDeleteEnabled && pass.checkedSpace && !pass.anyVolumeLow {
      showCleanupNotice(String(localized: "Not low on space — nothing to remove."), isWarning: false)
    } else {
      showCleanupNotice(String(localized: "Nothing to clean up right now."), isWarning: false)
    }
  }

  private func showCleanupNotice(_ text: String, isWarning: Bool) {
    cleanupNotice = (text, isWarning)
    cleanupNoticeTask?.cancel()
    cleanupNoticeTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      self?.cleanupNotice = nil
    }
  }

  private func clearCleanupNotice() {
    cleanupNoticeTask?.cancel()
    cleanupNoticeTask = nil
    cleanupNotice = nil
  }

  /// `skipsUnsettledFiles` is for watched-folder scans, which come back for skipped
  /// files. A drop is imported once, so it takes everything it was given.
  private nonisolated static func expand(
    _ url: URL, skipsUnsettledFiles: Bool = true, changes: FolderChanges = .full, exclusions: FolderExclusions = .none
  ) -> MediaScan {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return MediaScan() }
    if isDir.boolValue {
      return FolderMediaScanner.collectMedia(
        in: url, changes: changes, skipsUnsettledFiles: skipsUnsettledFiles, excluding: exclusions)
    }
    guard SupportedMediaFormats.isSupported(fileURL: url) else { return MediaScan() }
    return MediaScan(files: [FolderMediaScanner.metadata(for: url)])
  }
}

/// What a full pass's view of the folders depends on besides the files themselves:
/// pairing decides which records a file matches.
private struct ScanBasis: Equatable {
  var accountEmail: String
  var removalCount: Int
  var pairLivePhotos: Bool
  /// New rules leave out files the last full pass read, or bring back ones it skipped.
  var exclusions: FolderExclusions
}

private struct StagedDrop {
  let url: URL
  let accountEmail: String?
}

private struct FolderScan: Sendable {
  var url: URL
  var started: Bool
  var isResolved: Bool
  var refreshedBookmark: BookmarkRefresh?
  var media: MediaScan
}

/// A stale bookmark recreated away from the main actor, applied only if the folder
/// still holds `previous`.
private struct BookmarkRefresh: Sendable {
  var folderID: String
  var previous: Data?
  var refreshed: Data
}

/// Cache the resolved URLs, leaving each thumbnail job responsible for its own scope.
private actor ThumbnailFolderScopes {
  private struct Entry {
    let bookmark: Data
    let url: URL?
    let path: String?
  }

  private var generation = 0
  private var entries: [String: Entry] = [:]

  func root(for fileURL: URL, folders: [MacWatchedFolder], generation: Int) -> URL? {
    guard !Task.isCancelled, generation >= self.generation else { return nil }
    if generation != self.generation {
      self.generation = generation
      entries.removeAll()
    }
    let path = WatchedFolderPaths.privatePrefixed(fileURL.standardizedFileURL.path)
    for folder in folders {
      guard !Task.isCancelled else { return nil }
      guard let bookmark = folder.bookmarkData else { continue }
      let entry: Entry
      if let cached = entries[folder.id], cached.bookmark == bookmark {
        entry = cached
      } else {
        let url = folder.resolveBookmark()?.url
        let root = url.map { WatchedFolderPaths.privatePrefixed($0.standardizedFileURL.path) }
        entry = Entry(bookmark: bookmark, url: url, path: root)
        entries[folder.id] = entry
      }
      if let root = entry.path, WatchedFolderPaths.isPath(path, inside: root) { return entry.url }
    }
    return nil
  }
}

private struct FolderUsability: Sendable {
  var readability: [String: Bool] = [:]
  var rootPaths: [String] = []
  var needingAccess = 0
  var refreshedBookmarks: [BookmarkRefresh] = []
}

private struct WatcherStart: Sendable {
  var folderID: String
  var key: String
  var watcher: MacFolderWatcher?
  var failedToStart: Bool
  var refreshedBookmark: BookmarkRefresh?
}
