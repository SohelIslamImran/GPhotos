import AppIntents
import CryptoKit
import Foundation
import GPhotosKit
import Observation
import Photos
import SwiftUI
import UIKit
import UserNotifications
import os

private let libraryScanLogger = Logger(subsystem: "org.gphotosapp.gphotos", category: "LibraryScan")

/// What a cleanup would remove: photo-library assets (one system prompt), the app's own
/// staged copies of manual uploads and files in backed-up folders (no prompt).
public struct CleanupPlan: Sendable, Equatable {
  public var libraryRecords: [TransferRecord] = []
  public var stagedRecords: [TransferRecord] = []
  public var folderRecords: [TransferRecord] = []
  public var totalBytes: Int64 = 0

  /// A RAW+JPEG asset has two records but is one item to remove.
  public var itemCount: Int { libraryAssetCount + stagedRecords.count + folderRecords.count }
  public var libraryAssetCount: Int { Set(libraryRecords.compactMap(\.assetLocalIdentifier)).count }
  public var isEmpty: Bool { itemCount == 0 }
}

/// A user-created photo-library album, as offered for protection from cleanup.
public struct AlbumSummary: Identifiable, Sendable, Hashable {
  public let id: String
  public let title: String
  public let count: Int
}

/// The library-wide fetch result that change notifications are diffed against. PhotoKit
/// calls the observer on its own serial queue; the lock only covers the hand-off from
/// the task that starts observation.
private final class LibraryChangeTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var assets: PHFetchResult<PHAsset>?

  func start() {
    let assets = PHAsset.fetchAssets(with: AssetExportService.allFramesFetchOptions())
    lock.withLock { self.assets = assets }
  }

  /// Advances the tracked fetch result and reports the assets `change` added or edited,
  /// or nil when it holds nothing to upload: removals and iCloud metadata churn.
  func advance(past change: PHChange) -> LibraryChange? {
    lock.withLock {
      guard let current = self.assets else { return .everything }
      guard let details = change.changeDetails(for: current) else { return nil }
      self.assets = details.fetchResultAfterChanges
      guard details.hasIncrementalChanges else { return .everything }
      let ids = Set((details.insertedObjects + details.changedObjects).map(\.localIdentifier))
      return ids.isEmpty ? nil : .assets(ids)
    }
  }
}

private enum LibraryChange {
  case assets(Set<String>)
  /// PhotoKit could not say what changed.
  case everything
}

/// The account and manifest removal count a whole-library pass ran against. Reading only
/// the assets that changed relies on the manifest holding every asset it skips, which a
/// different account or removed records would break.
private struct LibraryScanBasis: Equatable {
  var accountEmail: String
  var removalCount: Int
}

@Observable
@MainActor
public final class AppModel: SyncEngine, PHPhotoLibraryChangeObserver {
  public private(set) var photoLibraryStatus: PHAuthorizationStatus = .notDetermined
  public var manualUploadNeedsSignIn = false
  public var pendingActivityFilter: ActivityFilter?
  public var pendingAccountSheet = false
  public private(set) var cleanupMessage: String?
  /// Set by a tapped cleanup notification or due items found in the foreground; the UI
  /// clears it when it starts the cleanup flow.
  public var pendingCleanupPrompt = false
  public private(set) var isCleaningUp = false
  private var isRunningCleanupMaintenance = false
  public private(set) var isScanning = false
  private var didStart = false
  /// True until the first launch pass finishes, so the status doesn't flash interim states.
  public private(set) var isStarting = true
  private var rescanRequested = false
  /// Assets the change feed reported since the last library pass began, which is all the
  /// next pass reads besides unfinished and newly unprotected ones. The whole library is
  /// read at launch, on Sync Now, in background passes, and whenever this isn't enough.
  @ObservationIgnored private var changedAssetIDs: Set<String> = []
  @ObservationIgnored private var needsFullLibraryScan = true
  /// The user asked for failed items again, so the next scan doesn't space them out.
  @ObservationIgnored private var retriesFailedItemsNow = false
  @ObservationIgnored private var retriesFolderFailuresNow = false
  @ObservationIgnored private var libraryScanBasis: LibraryScanBasis?
  /// Assets in protected albums at the last pass; one that leaves them must be read again.
  private var excludedAssetIDs: Set<String>?
  private var stopRequested = false
  private var libraryChangeTask: Task<Void, Never>?
  private var pendingManualUploads: [URL] = []
  private var isResumingManualUploads = false
  private nonisolated let libraryChanges = LibraryChangeTracker()
  private var isObservingLibrary = false

  /// Folders from the Files app backed up alongside the library.
  public private(set) var backedUpFolders: [BackedUpFolder] = FolderBackup.load()
  /// Backed-up folders whose bookmark no longer resolves or whose contents can't be read.
  public private(set) var foldersNeedingAccess: Set<String> = []
  public private(set) var isScanningFolders = false
  private var folderRescanRequested = false
  /// Bumped when a folder is removed, turned off or replaced, so a scan already under
  /// way can't queue its files.
  private var folderGeneration = 0 {
    didSet { cleanupPolicy.invalidate() }
  }
  /// Where each folder's bookmark last resolved to a readable directory.
  @ObservationIgnored private var resolvedFolderRoots: [String: URL] = [:]
  /// Every path the backed-up folders may be known by, for checks that run per record on
  /// the main actor. Replaced in plain string form whenever the folders or where they
  /// resolve change, then with symbolic links resolved once that is worked out off the
  /// main actor.
  @ObservationIgnored private var folderRootPaths = FolderRootPaths()
  @ObservationIgnored private var folderRootPathsGeneration = 0
  /// Folder scopes held for the running upload batch, which reads the files in place.
  /// Released once the pool is idle again.
  @ObservationIgnored private var folderUploadAccesses: [FolderAccess] = []
  @ObservationIgnored private var deferredFolderRescanTask: Task<Void, Never>?
  /// Keeps a primary batch uploading after the app leaves the foreground.
  @ObservationIgnored let continuedUpload = ContinuedUploadSession()
  /// The photo upload extension, which backs up the library after the app is closed.
  @ObservationIgnored let backgroundUploads = BackgroundUploads()
  @ObservationIgnored private var backgroundUploadPoll: Task<Void, Never>?
  @ObservationIgnored private var backgroundUploadPollSleep: Task<Void, Never>?
  @ObservationIgnored private var backgroundUploadWakeRequested = false
  @ObservationIgnored private let backgroundUploadObserver = ShareObserverHolder()
  @ObservationIgnored private var isImportingBackgroundUploads = false
  @ObservationIgnored private var isReconcilingBackgroundUploads = false
  private(set) var backgroundUploadWaitIDs = Set<String>()
  var isStoppedForSession: Bool { stopRequested }
  @ObservationIgnored private var isSceneActive = false
  /// Albums for items the extension uploaded, added once no batch is running.
  @ObservationIgnored private var pendingAlbumKeys: [String: [String: [String]]] = [:]
  /// Whether the running continued task holds the batch through background expiration.
  @ObservationIgnored private var continuedUploadHoldsBatch = false
  @ObservationIgnored private var deferredFolderRescanDelay = FolderMediaScanner.writeSettleInterval
  /// A file that never settles (a recording in progress) would otherwise re-enumerate
  /// every folder each `writeSettleInterval`, so consecutive deferrals back off to this.
  private static let maxDeferredFolderRescanDelay: TimeInterval = 5 * 60

  public init() {
    super.init()
    refreshFolderRootPaths()
    MediaThumbnailLoader.shared.fileAccess = { [weak self] url in
      guard let self,
        let folder = self.backedUpFolders.first(where: { folder in
          self.resolvedFolderRoots[folder.id].map { FolderBackup.isPath(url.path, inside: $0) } ?? false
        })
      else { return nil }
      return {
        let access = FolderBackup.beginAccess(folder)
        guard access.started else { return nil }
        return { FolderBackup.endAccess([access]) }
      }
    }
    self.photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    backgroundUploads.resetAppClaims()
    workerPool.claimPhotoUpload = BackgroundUploads.claimForApp
    workerPool.releasePhotoUpload = BackgroundUploads.releaseAppClaim
    workerPool.onBatchCompleted = { [weak self] in
      await self?.handleBatchCompleted()
      await self?.primaryBatchDidComplete()
    }
    continuedUpload.onStarted = { [weak self] in
      guard let self, !self.continuedUploadHoldsBatch else { return }
      self.continuedUploadHoldsBatch = true
      self.workerPool.holdThroughBackgroundExpiration()
    }
    continuedUpload.onExpired = { [weak self] in
      guard let self else { return }
      self.releaseContinuedUploadHold()
      self.workerPool.cancel()
    }
    workerPool.onProgressUpdated = { [weak self] in
      guard let self else { return }
      if self.continuedUpload.isActive {
        self.continuedUpload.update(
          fraction: self.workerPool.currentProgress,
          totalItems: self.workerPool.lastBatchTotalCount,
          subtitle: self.continuedUploadSubtitle)
      }
      #if os(iOS) && canImport(ActivityKit)
        guard LiveActivityController.shared.isActive else { return }
        LiveActivityController.shared.update(self.backupActivityState)
      #endif
    }
    workerPool.onBatchCancelled = { [weak self] in
      guard let self else { return }
      self.endContinuedUpload(success: false)
      #if os(iOS) && canImport(ActivityKit)
        LiveActivityController.shared.update(self.backupActivityState)
        LiveActivityController.shared.end(
          completed: self.workerPool.lastBatchCompletedCount, total: self.workerPool.lastBatchTotalCount, stopped: true)
      #endif
    }
  }

  deinit {
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }

  public override func allowedSourceRoots() -> [URL] {
    stagedSourceRoots() + enabledFolderRoots()
  }

  /// A backed-up folder's own scan re-queues its files, holding the folder's scope and
  /// keeping Live Photos paired; the shared-queue ingest must not send them as singles.
  public override func ingestSkipPredicate() -> (TransferRecord) -> Bool {
    let roots = folderRootPaths.all
    guard !roots.isEmpty else { return { _ in false } }
    return { record in record.sourcePath.map { FolderBackup.isPath($0, insideAny: roots) } ?? false }
  }

  /// Where the app's own copies live: shared items and manual uploads.
  private func stagedSourceRoots() -> [URL] {
    super.allowedSourceRoots() + [Self.manualUploadsDirectory]
  }

  /// Stop must stick until the user syncs again.
  public override var allowsAutomaticUploads: Bool { !stopRequested }

  public var isAuthorized: Bool {
    photoLibraryStatus == .authorized || photoLibraryStatus == .limited
  }

  @ObservationIgnored private var bucketSnapshot = AccountTransferBuckets()
  public var accountBuckets: AccountTransferBuckets {
    _ = accountBucketsRevision
    return bucketSnapshot.accountEmail == selectedAccount?.email ? bucketSnapshot : AccountTransferBuckets()
  }
  private(set) var accountBucketsRevision = 0

  public var accountPendingRecords: [TransferRecord] { accountBuckets.queued }
  public var accountUploadingCount: Int { accountBuckets.uploadingCount }
  public var accountQueuedCount: Int { accountBuckets.queued.count }
  public var accountCompletedByteCount: Int64 { accountBuckets.completedBytes }
  public var accountFailedCount: Int { accountBuckets.failedCount }
  public var accountTransferredCount: Int { accountBuckets.sentCount }

  @ObservationIgnored private var bucketsSource: (revision: Int?, email: String?)?

  public override func refreshRecords() async {
    await super.refreshRecords()
    let source = (revision: recordsRevision, email: selectedAccount?.email)
    if let bucketsSource, bucketsSource == source { return }
    let records = records
    let previous = bucketSnapshot
    let (buckets, changed) = await Task.detached(priority: .utility) {
      let buckets = AccountTransferBuckets(records: records, accountEmail: source.email)
      return (buckets, !buckets.hasSameRecords(as: previous))
    }.value
    guard source == (recordsRevision, selectedAccount?.email), bucketsSource.map({ $0 != source }) ?? true else { return }
    bucketsSource = source
    bucketSnapshot = buckets
    if changed { accountBucketsRevision &+= 1 }
  }

  /// Whether Sync Now can ever do anything. A tap while busy queues one more pass instead
  /// of being refused, so the button never flickers to its disabled look.
  public var canRequestSync: Bool {
    (isAuthorized || hasEnabledFolders) && selectedAccount != nil
  }

  // MARK: - Lifecycle

  private func handleBatchCompleted() async {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.workerPool.waitForCurrentBatch()
      self.releaseFolderUploadAccessIfIdle()
      await self.importBackgroundUploads()
      await self.addPendingAlbums()
      await self.ingestSharedQueueItems()
      await self.resumeRequestedScan()
      await self.resumeRequestedFolderScan()
      await self.runCleanupMaintenance()
    }
  }

  public override func accountsDidChange() async {
    stopRequested = false
    refreshBackgroundUploads()
    // Scopes held for the previous account's batch, which an account change stops.
    releaseFolderUploadAccessIfIdle()
    if !pendingAlbumKeys.isEmpty { Task { [weak self] in await self?.addPendingAlbums() } }
    await resumePendingManualUploads()
  }

  public func onAppear() async {
    await start()
  }

  public func start() async {
    guard !didStart, !Task.isCancelled else { return }
    didStart = true
    defer {
      // A cancelled pass is retried, and until then the account isn't known yet.
      if Task.isCancelled {
        didStart = false
      } else {
        isStarting = false
        if isSceneActive { checkAndRunForegroundMirror() }
      }
    }
    startObservingLibraryIfAuthorized()
    await loadAccounts()
    await Self.purgeAbandonedPicks()
    await recoverPendingManualUploads()
    guard !Task.isCancelled else { return }
    await refreshRecords()
    await recoverDeletionTombstones()
    await reconcileDeletedLibraryRecords()
    await importBackgroundUploads()
    guard !Task.isCancelled else { return }
    await ingestSharedQueueItems()
    await resumePendingManualUploads()
    guard !Task.isCancelled else { return }
    if settings.autoSyncEnabled && selectedAccount != nil {
      // On screen, the Library's first grid comes first: the scan reads the same photo
      // library. In the background nothing is drawn, so it starts at once.
      if UIApplication.shared.applicationState == .active { try? await Task.sleep(for: .seconds(1.5)) }
      await syncLibraryAutomatically()
      await syncFoldersAutomatically()
    } else {
      await refreshFolderStatus()
    }
    #if DEBUG
      await logUnfinishedRecords()
    #endif
  }

  #if DEBUG
    /// What the unfinished records of the browsed account are, for diagnosing items that
    /// wait without moving.
    private func logUnfinishedRecords() async {
      guard let email = selectedAccount?.email else { return }
      let unfinished = await manifestStore.allRecords().filter {
        $0.id.hasPrefix("\(email)|") && ($0.status == .pending || $0.status == .sending || $0.status == .failed)
      }
      let assetIDs = unfinished.compactMap(\.assetLocalIdentifier)
      let present = await Task.detached { Self.fetchableAssetIdentifiers(assetIDs) }.value
      var counts: [String: Int] = [:]
      var samples: [String: String] = [:]
      for record in unfinished {
        let kind: String
        if let asset = record.assetLocalIdentifier {
          kind =
            "asset-\(present.contains(asset) ? "present" : "missing")-\(record.resourceRole)-sent=\(record.sentAccountEmails.count)-keys=\(record.mediaKeysByAccount.count)-found=\(record.foundInAccounts.count)-id=\(asset.split(separator: "/").dropFirst().joined(separator: "/"))"
        } else if let path = record.sourcePath {
          let root = resolvedFolderRoots.values.first { path.hasPrefix($0.path) }
          kind = "folder-\(root == nil ? "noReadableRoot" : (FileManager.default.fileExists(atPath: path) ? "exists" : "gone"))"
        } else if record.sharedEntryID != nil {
          kind = "shared"
        } else {
          kind = "other"
        }
        let key = "\(record.status)/\(kind)/skipped=\(record.isSkipped)/attempts=\(record.attempts)"
        counts[key, default: 0] += 1
        if samples[key] == nil {
          samples[key] = "\(record.filename) err=\(record.lastError ?? "-") path=\(record.sourcePath ?? "-")"
        }
      }
      libraryScanLogger.notice(
        "Unfinished: \(unfinished.count, privacy: .public) folders=\(self.backedUpFolders.count, privacy: .public) readableRoots=\(self.resolvedFolderRoots.count, privacy: .public) needingAccess=\(self.foldersNeedingAccess.count, privacy: .public)"
      )
      for (key, count) in counts.sorted(by: { $0.value > $1.value }) {
        libraryScanLogger.notice(
          "Unfinished \(count, privacy: .public) \(key, privacy: .public) e.g. \(samples[key] ?? "", privacy: .public)")
      }
    }
  #endif

  /// Writes any batched manifest changes before the process can be suspended.
  @discardableResult
  public func prepareForBackground() async -> Bool {
    await manifestStore.flush()
  }

  /// One background-task pass on the app-wide model: launch work the first time,
  /// otherwise just pick up shared items and scan the library and backed-up folders.
  public func runBackgroundPass() async {
    guard didStart else {
      await start()
      return
    }
    guard !isStarting, !Task.isCancelled else { return }
    await reconcileBackgroundUploads(timeout: .seconds(8))
    await ingestSharedQueueItems()
    await resumePendingManualUploads()
    if settings.autoSyncEnabled && selectedAccount != nil {
      await syncLibraryAutomatically()
      await syncFoldersAutomatically()
    }
  }

  /// Whether a processing task would have anything to do: a scan under way or requested,
  /// uploads queued or in flight, or staged picks to resume.
  var hasKnownBackgroundWork: Bool {
    selectedAccount != nil
      && (isStarting || isScanning || rescanRequested || isRunning || isScanningFolders || folderRescanRequested
        || !pendingManualUploads.isEmpty || !accountBuckets.queued.isEmpty || accountUploadingCount > 0)
  }

  public func hasPendingBackgroundWork() async -> Bool {
    if hasKnownBackgroundWork { return true }
    guard selectedAccount != nil || !hasLoadedAccounts else { return false }
    let background = await BackgroundUploads.readLedger()
    guard !Task.isCancelled else { return false }
    if hasKnownBackgroundWork { return true }
    if !hasLoadedAccounts { return !background.jobs.isEmpty || !background.results.isEmpty }
    return background.jobs.contains { acceptsBackgroundReceipt(accountEmail: $0.accountEmail) }
      || background.results.contains { acceptsBackgroundReceipt(accountEmail: $0.accountEmail) }
  }

  /// Library changes, background tasks and foreground activation; a tapped Sync Now calls
  /// `syncLibrary()` directly and clears a previous Stop.
  private func syncLibraryAutomatically() async {
    guard !stopRequested else { return }
    await scanLibrary()
  }

  // MARK: - Photo Library Observer

  /// Register first so a change during the initial fetch can request a full scan.
  private func startObservingLibraryIfAuthorized() {
    refreshBackgroundUploads()
    guard isAuthorized, !isObservingLibrary else { return }
    isObservingLibrary = true
    PHPhotoLibrary.shared().register(self)
    let tracker = libraryChanges
    Task.detached(priority: .utility) { tracker.start() }
  }

  public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    guard let change = libraryChanges.advance(past: changeInstance) else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      switch change {
      case .assets(let ids): changedAssetIDs.formUnion(ids)
      case .everything: needsFullLibraryScan = true
      }
      libraryChangeTask?.cancel()
      libraryChangeTask = Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if self.settings.autoSyncEnabled && !self.stopRequested {
          await self.scanLibrary()
        }
      }
    }
  }

  public override func stopTransfer() {
    stopRequested = true
    rescanRequested = false
    folderRescanRequested = false
    deferredFolderRescanTask?.cancel()
    deferredFolderRescanTask = nil
    super.stopTransfer()
    accountMirror.pauseAll()
    releaseFolderUploadAccessIfIdle()
  }

  public override func toggleAutoSync() {
    super.toggleAutoSync()
    if settings.autoSyncEnabled {
      stopRequested = false
    }
    if settings.autoSyncEnabled && selectedAccount != nil {
      Task {
        await syncLibrary()
        await syncFolders()
      }
    }
  }

  // MARK: - Photos Permission

  public func requestPhotoAccess() async {
    photoLibraryStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    if isAuthorized {
      startObservingLibraryIfAuthorized()
      if settings.autoSyncEnabled {
        await syncLibrary()
      }
    }
  }

  /// Called on every foreground activation. Library edits are covered by the change
  /// observer, so a full rescan only runs when access changed, work was left queued
  /// (for example by a background task that ran out of time). Folders have no change
  /// feed on iOS, so they are rescanned every time.
  public func refreshPhotoLibraryStatus(using foregroundRead: FolderMediaScanner.ForegroundRead? = nil) async {
    let previous = photoLibraryStatus
    photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    startObservingLibraryIfAuthorized()
    if photoLibraryStatus != previous {
      needsFullLibraryScan = true
      if isScanning { rescanRequested = true }
    }
    guard didStart, !isStarting else {
      return
    }
    await importBackgroundUploads()
    if isAuthorized, settings.autoSyncEnabled, !isRunning,
      needsFullLibraryScan || !changedAssetIDs.isEmpty || photoLibraryStatus != previous || !accountBuckets.queued.isEmpty
    {
      if photoLibraryStatus != previous { needsFullLibraryScan = true }
      if !stopRequested { await scanLibrary() }
    }
    await syncFoldersAutomatically(using: foregroundRead)
  }

  public func openPhotoSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  // MARK: - Sync & Upload

  public func startTransfer() async {
    stopRequested = false
    guard canRequestSync else { return }
    Task { _ = try? await IntentDonationManager.shared.donate(intent: BackUpPhotosIntent()) }
    await syncLibrary()
    await syncFolders()
  }

  /// Plain values read from PhotoKit. Gathering these off the main actor keeps the
  /// per-resource `photosd` IPC round trips out of the UI.
  private struct LibraryAsset: Sendable {
    let localIdentifier: String
    let filename: String
    let byteCount: Int64
    let creationDate: Date?
    let version: TransferRecord.AssetVersion
    let isVideo: Bool
    let isLivePhoto: Bool
    /// The RAW of a RAW+JPEG pair, which goes up as its own record.
    let alternatePhoto: LibraryResource?
    /// An edited asset's unedited original, which goes up as its own record.
    let uneditedOriginal: LibraryResource?

    /// One upload per resource the asset carries, under the account's record IDs.
    func entries(accountEmail: String) -> [LibraryEntry] {
      let primaryID = TransferRecord.accountScopedID(localIdentifier, accountEmail: accountEmail)
      var entries = [LibraryEntry(id: primaryID, filename: filename, byteCount: byteCount, role: .primary)]
      if let alternatePhoto {
        entries.append(
          LibraryEntry(
            id: TransferRecord.alternatePhotoID(forPrimaryID: primaryID),
            filename: alternatePhoto.filename,
            byteCount: alternatePhoto.byteCount,
            role: .alternatePhoto
          ))
      }
      if let uneditedOriginal {
        entries.append(
          LibraryEntry(
            id: TransferRecord.uneditedOriginalID(forPrimaryID: primaryID),
            filename: uneditedOriginal.filename,
            byteCount: uneditedOriginal.byteCount,
            role: .uneditedOriginal
          ))
      }
      return entries
    }
  }

  private struct LibraryResource: Sendable {
    let filename: String
    let byteCount: Int64
  }

  private struct LibraryEntry {
    let id: String
    let filename: String
    let byteCount: Int64
    let role: AssetResourceRole
  }

  /// What the manifest recorded for an asset already backed up to the account.
  private struct SentAsset: Sendable {
    let filename: String
    let byteCount: Int64
    let version: TransferRecord.AssetVersion
    /// Whether the primary's record was made from the asset's PhotoKit resources.
    let resourcesChecked: Bool
    /// The asset's RAW record, in any state. A RAW is recorded whenever its primary is
    /// made from the asset's resources, so a checked primary without one had no RAW.
    var alternatePhoto: LibraryResource?
    /// The asset's unedited original record, in any state.
    var uneditedOriginal: LibraryResource?
  }

  /// The scan's view of the library, plus the sent assets whose resources it read to
  /// look for a RAW recorded before RAW support.
  private struct LibraryDescription: Sendable {
    var assets: [LibraryAsset] = []
    var checkedAssetIDs: [String] = []
    var excludedAssetIDs: Set<String> = []
  }

  /// Past this many changed assets, reading the whole library costs about the same.
  private static let maxChangedAssets = 1000

  /// Describes the whole library, or with `only` just those assets plus any that left
  /// the protected albums since `previouslyExcluded` was taken.
  private nonisolated static func describeLibrary(
    pairLivePhotos: Bool,
    backsUpUneditedOriginals: Bool,
    sentAssets: [String: SentAsset],
    excludedAlbumIDs: Set<String> = [],
    only: Set<String>? = nil,
    previouslyExcluded: Set<String> = []
  ) -> LibraryDescription {
    var excludedAssetIDs = Set<String>()
    if !excludedAlbumIDs.isEmpty {
      let collections = PHAssetCollection.fetchAssetCollections(
        withLocalIdentifiers: Array(excludedAlbumIDs),
        options: nil
      )
      collections.enumerateObjects { collection, _, _ in
        // Same options as the scan below, so burst frames in the album are skipped too.
        let memberAssets = PHAsset.fetchAssets(in: collection, options: AssetExportService.allFramesFetchOptions())
        memberAssets.enumerateObjects { asset, _, _ in
          excludedAssetIDs.insert(asset.localIdentifier)
        }
      }
    }
    // Every burst frame is its own asset to back up, not just the representative.
    let options = AssetExportService.allFramesFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    options.predicate = NSPredicate(
      format: "mediaType == %d || mediaType == %d",
      PHAssetMediaType.image.rawValue,
      PHAssetMediaType.video.rawValue
    )
    let assets: PHFetchResult<PHAsset>
    if let only {
      let identifiers = only.union(previouslyExcluded.subtracting(excludedAssetIDs))
      guard !identifiers.isEmpty else { return LibraryDescription(excludedAssetIDs: excludedAssetIDs) }
      // The same options, so the subset is exactly what the whole-library fetch would
      // return for these assets.
      assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: options)
    } else {
      assets = PHAsset.fetchAssets(with: options)
    }
    var descriptors: [LibraryAsset] = []
    descriptors.reserveCapacity(assets.count)
    var checkedAssetIDs: [String] = []
    for index in 0..<assets.count {
      if Task.isCancelled { break }
      let asset = assets.object(at: index)
      // The whole-library fetch leaves hidden assets out; a fetch by identifier is not
      // documented to.
      if only != nil, asset.isHidden { continue }
      let version = AssetExportService.version(of: asset)
      let isVideo = asset.mediaType == .video
      let isLivePhoto = pairLivePhotos && LivePhotoManager.isLivePhoto(asset)
      if !excludedAssetIDs.isEmpty, excludedAssetIDs.contains(asset.localIdentifier) {
        if let sent = sentAssets[asset.localIdentifier] {
          descriptors.append(
            LibraryAsset(
              localIdentifier: asset.localIdentifier,
              filename: sent.filename,
              byteCount: sent.byteCount,
              creationDate: asset.creationDate,
              version: sent.version,
              isVideo: isVideo,
              isLivePhoto: isLivePhoto,
              alternatePhoto: sent.alternatePhoto,
              uneditedOriginal: sent.uneditedOriginal
            )
          )
        }
        continue
      }
      // A sent, unedited asset is skipped by the scan, so it is described from its
      // record rather than paying the per-resource round trip. One uploaded before RAW
      // support pays it once, to find a RAW that never went up; a video has none.
      if let sent = sentAssets[asset.localIdentifier],
        !version.contentChanged(since: sent.version)
      {
        var alternatePhoto = sent.alternatePhoto
        if !sent.resourcesChecked, alternatePhoto == nil {
          if !isVideo, let raw = AssetExportService.alternatePhotoResource(in: PHAssetResource.assetResources(for: asset)) {
            alternatePhoto = Self.libraryResource(raw)
          }
          checkedAssetIDs.append(asset.localIdentifier)
        }
        // An asset edited before its upload, or uploaded before originals went up, reads
        // its resources once: after this scan the original has a record.
        var uneditedOriginal = sent.uneditedOriginal
        if backsUpUneditedOriginals, uneditedOriginal == nil, asset.hasAdjustments {
          uneditedOriginal = Self.uneditedOriginal(
            of: asset, in: PHAssetResource.assetResources(for: asset), isLivePhoto: isLivePhoto)
        }
        descriptors.append(
          LibraryAsset(
            localIdentifier: asset.localIdentifier,
            filename: sent.filename,
            byteCount: sent.byteCount,
            creationDate: asset.creationDate,
            version: version,
            isVideo: isVideo,
            isLivePhoto: isLivePhoto,
            alternatePhoto: alternatePhoto,
            uneditedOriginal: uneditedOriginal
          )
        )
        continue
      }
      let resources = PHAssetResource.assetResources(for: asset)
      let raw = AssetExportService.alternatePhotoResource(in: resources)
      let primaryResources = resources.filter { $0.type != .alternatePhoto }
      var uploadResources = AssetExportService.primaryResource(for: asset, in: primaryResources).map { [$0] } ?? []
      if isLivePhoto,
        let motion = AssetExportService.firstResource(
          in: resources, type: \.type, preferring: AssetExportService.pairedVideoResourceTypes(edited: asset.hasAdjustments))
      {
        uploadResources.append(motion)
      }
      let byteCount = Self.reportedByteCount(of: uploadResources)
      descriptors.append(
        LibraryAsset(
          localIdentifier: asset.localIdentifier,
          filename: AssetExportService.primaryUploadFilename(for: asset, in: primaryResources)
            ?? primaryResources.first?.filenameOrEmpty
            ?? "\(UUID().uuidString).\(isVideo ? "mov" : "jpg")",
          byteCount: byteCount > 0 ? byteCount : 3_000_000,
          creationDate: asset.creationDate,
          version: version,
          isVideo: isVideo,
          isLivePhoto: isLivePhoto,
          alternatePhoto: raw.map(Self.libraryResource),
          uneditedOriginal: backsUpUneditedOriginals && asset.hasAdjustments
            ? Self.uneditedOriginal(of: asset, in: resources, isLivePhoto: isLivePhoto) : nil
        )
      )
    }
    return LibraryDescription(assets: descriptors, checkedAssetIDs: checkedAssetIDs, excludedAssetIDs: excludedAssetIDs)
  }

  /// The name a resource is committed under: the camera's name for the primary, even when
  /// its rendered edit goes up, and the resource's own name for a RAW or an original.
  private nonisolated static func uploadFilename(
    for asset: PHAsset, role: AssetResourceRole, resources: [PHAssetResource]
  ) -> String? {
    switch role {
    case .primary: AssetExportService.primaryUploadFilename(for: asset, in: resources)
    case .alternatePhoto, .uneditedOriginal: resources.first?.filenameOrEmpty
    }
  }

  /// The resources a record uploads, with the original's still first.
  private nonisolated static func resources(
    for role: AssetResourceRole, of asset: PHAsset, in allResources: [PHAssetResource]
  ) -> [PHAssetResource] {
    switch role {
    case .primary:
      return allResources.filter { $0.type != .alternatePhoto }
    case .alternatePhoto:
      return AssetExportService.alternatePhotoResource(in: allResources).map { [$0] } ?? []
    case .uneditedOriginal:
      guard let original = AssetExportService.uneditedOriginalResource(mediaType: asset.mediaType, in: allResources)
      else { return [] }
      let motion = LivePhotoManager.isLivePhoto(asset) ? allResources.filter { $0.type == .pairedVideo } : []
      return [original] + motion
    }
  }

  /// An edited asset's original as the scan records it: the camera's file, with the
  /// original motion counted in for a Live Photo.
  private nonisolated static func uneditedOriginal(
    of asset: PHAsset, in resources: [PHAssetResource], isLivePhoto: Bool
  ) -> LibraryResource? {
    guard let original = AssetExportService.uneditedOriginalResource(mediaType: asset.mediaType, in: resources)
    else { return nil }
    let parts = [original] + (isLivePhoto ? resources.filter { $0.type == .pairedVideo } : [])
    let byteCount = reportedByteCount(of: parts)
    return LibraryResource(
      filename: original.filenameOrEmpty.isEmpty
        ? "\(UUID().uuidString).\(asset.mediaType == .video ? "mov" : "jpg")" : original.filenameOrEmpty,
      byteCount: byteCount > 0 ? byteCount : 3_000_000
    )
  }

  private nonisolated static func libraryResource(_ raw: PHAssetResource) -> LibraryResource {
    let byteCount = reportedByteCount(of: [raw])
    return LibraryResource(
      filename: raw.filenameOrEmpty.isEmpty ? "\(UUID().uuidString).dng" : raw.filenameOrEmpty,
      byteCount: byteCount > 0 ? byteCount : 25_000_000
    )
  }

  /// The scan's re-upload rule: only a modification date later than the one recorded at
  /// upload counts as an edit.
  private nonisolated static func reportedByteCount(of resources: [PHAssetResource]) -> Int64 {
    return resources.reduce(Int64(0)) { total, resource in
      total + Int64(max(0, resource.dataSize ?? 0))
    }
  }

  private func resumeRequestedScan() async {
    guard !stopRequested,
      !Task.isCancelled,
      rescanRequested,
      isAuthorized,
      selectedAccount != nil,
      !isRunning,
      !isScanning
    else { return }
    await scanLibrary()
  }

  /// Reads the whole library.
  public func syncLibrary() async {
    needsFullLibraryScan = true
    await scanLibrary()
  }

  @concurrent
  private nonisolated static func describeLibrary(
    records currentRecords: [TransferRecord], account: GoogleAccount, settings: AppSettings,
    scope initialScope: Set<String>?, previouslyExcluded: Set<String>
  ) async -> (description: LibraryDescription, scope: Set<String>?, failed: [TransferRecord], savedCount: Int) {
    var scope = initialScope
    let accountPrefix = "\(account.email)|"
    if scope != nil {
      // A whole-library pass queues every unfinished asset each time.
      for record in currentRecords
      where record.status == .pending || record.status == .failed {
        guard record.id.hasPrefix(accountPrefix), let assetID = record.assetLocalIdentifier else { continue }
        scope?.insert(assetID)
      }
    }
    var sentAssets: [String: SentAsset] = [:]
    var alternatePhotos: [String: LibraryResource] = [:]
    var uneditedOriginals: [String: LibraryResource] = [:]
    for record in currentRecords where record.id.hasPrefix(accountPrefix) {
      guard let assetID = record.assetLocalIdentifier else { continue }
      // A partial pass describes only its scope and the assets that left protected albums.
      if let scope, !scope.contains(assetID), !previouslyExcluded.contains(assetID) { continue }
      let resource = LibraryResource(
        filename: record.filename,
        byteCount: record.byteCount.flatMap { $0 > 0 ? $0 : nil } ?? 3_000_000
      )
      switch record.resourceRole {
      case .primary:
        guard record.isTerminalSuccess, record.sentAccountEmails.contains(account.email) else { continue }
        sentAssets[assetID] = SentAsset(
          filename: resource.filename,
          byteCount: resource.byteCount,
          version: record.assetVersion,
          resourcesChecked: record.resourcesChecked
        )
      case .alternatePhoto:
        alternatePhotos[assetID] = resource
      case .uneditedOriginal:
        uneditedOriginals[assetID] = resource
      }
    }
    for (assetID, resource) in alternatePhotos {
      sentAssets[assetID]?.alternatePhoto = resource
    }
    for (assetID, resource) in uneditedOriginals {
      sentAssets[assetID]?.uneditedOriginal = resource
    }
    let description = describeLibrary(
      pairLivePhotos: settings.pairLivePhotos,
      backsUpUneditedOriginals: settings.backsUpUneditedOriginals,
      sentAssets: sentAssets,
      excludedAlbumIDs: settings.excludedAlbumIDs,
      only: scope,
      previouslyExcluded: previouslyExcluded
    )
    let failed = scope == nil ? currentRecords.filter { $0.id.hasPrefix(accountPrefix) && $0.status == .failed } : []
    return (description, scope, failed, sentAssets.count)
  }

  private struct LibraryQueuePlan: Sendable {
    var records: [TransferRecord]
    var previous: [String: TransferRecord]
    var items: [UploadQueueItem]
    var described: Set<String>
  }

  @concurrent
  private nonisolated static func planLibraryQueue(
    description: LibraryDescription, account: GoogleAccount, manifest: TransferManifestStore,
    retriesFailedNow: Bool, pairLivePhotos: Bool, mirrorPhotoAlbums: Bool, isFullScan: Bool
  ) async -> LibraryQueuePlan? {
    let descriptors = description.assets
    var queueItems: [UploadQueueItem] = []
    var newRecords: [TransferRecord] = []
    let known = await manifest.records(
      withIDs: descriptors.flatMap { $0.entries(accountEmail: account.email).map(\.id) })
    guard !Task.isCancelled else { return nil }

    /// True when this resource of an asset still needs to go through the upload queue.
    ///
    /// Shared with the gate below so the mapping is never built for a scan that turns
    /// out to queue nothing.
    func needsUpload(_ entry: LibraryEntry, of descriptor: LibraryAsset) -> Bool {
      guard !description.excludedAssetIDs.contains(descriptor.localIdentifier) else { return false }
      guard let existing = known[entry.id] else { return true }
      if existing.status == .sending { return false }
      if !retriesFailedNow, !existing.isDueForAutomaticRetry() { return false }
      return !existing.hasBackedUpAsset(to: account.email, version: descriptor.version)
    }

    // Walking album membership costs one PhotoKit query per collection and materialises
    // every member, so it runs off the main actor, only when mirroring is on, and only
    // when the scan will actually queue something — otherwise a settled library pays
    // the full cost on every change notification for nothing.

    let albumMapping =
      mirrorPhotoAlbums
        && descriptors.contains { descriptor in
          descriptor.entries(accountEmail: account.email).contains { needsUpload($0, of: descriptor) }
        } ? PhotoAlbumMirror.buildMapping() : nil

    for descriptor in descriptors {
      guard !Task.isCancelled else { return nil }
      let assetID = descriptor.localIdentifier
      // The RAW of a RAW+JPEG pair follows the same rules as its primary: queued when
      // new, unfinished or edited since its upload. An original does not change with a
      // new edit, so once it is up it stays up.
      for entry in descriptor.entries(accountEmail: account.email) {
        let id = entry.id
        let isPrimary = entry.role == .primary
        let isLiveUpload = descriptor.isLivePhoto && entry.role != .alternatePhoto
        guard needsUpload(entry, of: descriptor) else { continue }
        if let existing = known[id] {
          if existing.isTerminalSuccess {
            var updated = existing
            updated.status = .pending
            updated.progress = 0
            updated.transferredByteCount = 0
            updated.lastError = nil
            // The new version may go up without motion; until it is paired again the old
            // video hash must not vouch for it.
            updated.pairedSourceSHA1 = nil
            // An edited asset is described from its resources, RAW included.
            if isPrimary { updated.resourcesChecked = true }
            newRecords.append(updated)
          }
        }

        let originalFilename = entry.filename
        let estimatedSize = entry.byteCount

        if known[id] == nil {
          newRecords.append(
            TransferRecord(
              id: id,
              filename: originalFilename,
              mediaType: isLiveUpload ? "Live Photo" : (descriptor.isVideo ? "Video" : "Photo"),
              creationDate: descriptor.creationDate,
              status: .pending,
              byteCount: estimatedSize,
              assetLocalIdentifier: assetID,
              assetModifiedAt: descriptor.version.modifiedAt,
              resourceRole: entry.role,
              resourcesChecked: isPrimary
            ))
        }

        let placeholderURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("GPhotosPlaceholders", isDirectory: true)
          .appendingPathComponent(originalFilename)
        queueItems.append(
          UploadQueueItem(
            id: id,
            fileURL: placeholderURL,
            filename: originalFilename,
            fileSize: estimatedSize,
            creationDate: descriptor.creationDate,
            assetLocalIdentifier: assetID,
            resourceRole: entry.role,
            isTemporaryFile: true,
            // The RAW and the original stay out of mirrored albums, which would otherwise
            // show those photos twice.
            albumNames: isPrimary ? albumMapping?.albumNames(forAssetIdentifier: assetID) ?? [] : [],
            pairLivePhotos: entry.role != .alternatePhoto && pairLivePhotos
          ))
      }
    }

    var previous: [String: TransferRecord] = [:]
    for record in newRecords { previous[record.id] = known[record.id] }
    return LibraryQueuePlan(
      records: newRecords, previous: previous, items: queueItems,
      described: isFullScan ? Set(descriptors.map(\.localIdentifier)) : []
    )
  }

  /// Reads the assets that changed since the last pass, or the whole library when that
  /// isn't known.
  private func scanLibrary() async {
    guard !replaysAfterAccountChange(("libraryScan", { [weak self] in await self?.scanLibrary() })) else { return }
    guard canUseSelectedAccount, !stopRequested, !Task.isCancelled, isAuthorized, let account = selectedAccount else { return }
    guard !isRunning, !workerPool.isBatchFinalizing, !isScanning else {
      rescanRequested = true
      return
    }
    isScanning = true
    rescanRequested = false
    defer {
      isScanning = false
      // A library change that arrived during the pass sets this; honour it once the
      // pass ends rather than dropping it.
      if rescanRequested, !isRunning, !stopRequested {
        rescanRequested = false
        Task { @MainActor [weak self] in
          await self?.scanLibrary()
        }
      }
    }
    let generation = accountGeneration
    let basis = LibraryScanBasis(accountEmail: account.email, removalCount: await manifestStore.removalCount)
    var scope: Set<String>? =
      needsFullLibraryScan || libraryScanBasis != basis || excludedAssetIDs == nil
        || changedAssetIDs.count > Self.maxChangedAssets
      ? nil : changedAssetIDs
    needsFullLibraryScan = false
    changedAssetIDs = []
    var finished = false
    let retriesFailedNow = retriesFailedItemsNow
    retriesFailedItemsNow = false
    // A pass cut short (often by the next change notification) may have read only part
    // of its scope, so the scope is owed to the next one.
    defer {
      if !finished {
        if retriesFailedNow { retriesFailedItemsNow = true }
        if let scope { changedAssetIDs.formUnion(scope) } else { needsFullLibraryScan = true }
      }
    }
    let settings = settings
    let currentRecords = await manifestStore.allRecords()
    let snapshot = await Self.describeLibrary(
      records: currentRecords, account: account, settings: settings,
      scope: scope, previouslyExcluded: excludedAssetIDs ?? []
    )
    scope = snapshot.scope
    guard !Task.isCancelled, accountGeneration == generation, selectedAccount?.email == account.email else { return }
    let description = snapshot.description
    guard
      let plan = await Self.planLibraryQueue(
        description: description, account: account, manifest: manifestStore,
        retriesFailedNow: retriesFailedNow, pairLivePhotos: settings.pairLivePhotos,
        mirrorPhotoAlbums: settings.mirrorPhotoAlbums, isFullScan: scope == nil
      )
    else { return }
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else { return }
    guard await manifestStore.upsertBatch(plan.records, ifUnchangedSince: plan.previous) else { return }
    // Only once any RAW it found is recorded, or that RAW would never be looked for again.
    if !description.checkedAssetIDs.isEmpty {
      await manifestStore.markResourcesChecked(
        ids: description.checkedAssetIDs.map { TransferRecord.accountScopedID($0, accountEmail: account.email) })
    }
    // Every asset that needs to go up now has a record; one left unclaimed stays pending
    // and is read again by the next pass.
    finished = true
    excludedAssetIDs = description.excludedAssetIDs
    if scope == nil {
      libraryScanBasis = basis
      await removeFailedRecordsWithoutSource(snapshot.failed, accountEmail: account.email, includingFiles: false)
      await removeUnfinishedRecordsOutsideLibrary(described: plan.described, accountEmail: account.email)
    }
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else { return }

    // An item the photo upload extension is sending is left to it; its result is imported.
    let heldByExtension = await BackgroundUploads.readLedger().heldRecordIDs
    backgroundUploadWaitIDs = heldByExtension
    let queueItems = plan.items
    let eligibleIDs = await Task.detached(priority: .utility) {
      queueItems.compactMap { heldByExtension.contains($0.id) ? nil : $0.id }
    }.value
    let claimedIDs = await manifestStore.claimForUpload(ids: eligibleIDs)
    let claimedItems = await Task.detached(priority: .utility) {
      queueItems.filter { claimedIDs.contains($0.id) }
    }.value
    libraryScanLogger.notice(
      "Scan complete: full=\(scope == nil), assets=\(description.assets.count), saved=\(snapshot.savedCount), queued=\(queueItems.count), claimed=\(claimedItems.count)"
    )
    await refreshRecords()
    guard !stopRequested,
      !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email,
      !claimedItems.isEmpty
    else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      await refreshRecords()
      return
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      await refreshRecords()
      return
    }
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: account.email) == .rejected {
      if workerPool.isBatchFinalizing || isChangingAccount, !stopRequested, accountGeneration == generation {
        rescanRequested = true
      }
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      await refreshRecords()
    }
  }

  private static var manualUploadsDirectory: URL {
    let baseDirectory =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      baseDirectory
      .appendingPathComponent("GPhotosSync", isDirectory: true)
      .appendingPathComponent("ManualUploads", isDirectory: true)
  }

  private static var pendingManualUploadsDirectory: URL {
    manualUploadsDirectory.appendingPathComponent("Pending", isDirectory: true)
  }

  private nonisolated static var temporaryPicksDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("GPhotosPicked", isDirectory: true)
  }

  /// Picker copies live in tmp until the confirm sheet uploads or stages them. A sheet
  /// dismissed without either leaves one behind, so whatever survives a launch is
  /// abandoned.
  private nonisolated static func purgeAbandonedPicks() async {
    await Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: Self.temporaryPicksDirectory)
    }.value
  }

  private func recoverPendingManualUploads() async {
    let root = Self.pendingManualUploadsDirectory
    let recovered = await Task.detached(priority: .utility) {
      Self.stagedManualUploads(in: root)
    }.value
    for url in recovered where !pendingManualUploads.contains(url) {
      pendingManualUploads.append(url)
    }
    manualUploadNeedsSignIn = selectedAccount == nil && !pendingManualUploads.isEmpty
  }

  /// Staged uploads left from an earlier launch, pruning the empty per-pick directories.
  private nonisolated static func stagedManualUploads(in root: URL) -> [URL] {
    if let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      for directory in directories where (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
        try? FileManager.default.removeItem(at: directory)
      }
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator {
      guard SupportedMediaFormats.isSupported(fileURL: url),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
      else { continue }
      urls.append(url)
    }
    return urls
  }

  /// A temporary pick is moved, since nothing else reads it; anything else, or a pick
  /// whose move fails, is copied. Returns whether the source was moved.
  @discardableResult
  private nonisolated static func place(_ source: URL, at destination: URL, moving: Bool) throws -> Bool {
    if moving, (try? FileManager.default.moveItem(at: source, to: destination)) != nil { return true }
    try FileManager.default.copyItem(at: source, to: destination)
    return false
  }

  /// Drops the store's copy of a manual upload. A pick that was moved in goes back, so
  /// the sheet can still retry it.
  private nonisolated static func discardStoredUpload(_ storedURL: URL, restoringTo pick: URL?) {
    if let pick, (try? FileManager.default.moveItem(at: storedURL, to: pick)) != nil { return }
    try? FileManager.default.removeItem(at: storedURL)
  }

  private func stageManualUpload(_ url: URL, movingPick: Bool) async throws -> URL {
    let pendingDirectory = Self.pendingManualUploadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stagedURL = pendingDirectory.appendingPathComponent(url.lastPathComponent)
    try await Task.detached(priority: .utility) {
      do {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try Self.place(url, at: stagedURL, moving: movingPick)
      } catch {
        try? FileManager.default.removeItem(at: pendingDirectory)
        throw error
      }
    }.value
    return stagedURL
  }

  private static func isStagedManualUpload(_ url: URL) -> Bool {
    url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
      == pendingManualUploadsDirectory.standardizedFileURL.path
  }

  public func uploadSingleFile(url: URL) async throws -> String? {
    guard !isChangingAccount else { return nil }
    let filename = url.lastPathComponent
    guard SupportedMediaFormats.isSupported(filename: filename) else {
      throw GPhotosError.fileReadFailed("Unsupported media type")
    }
    let temporaryPickDirectory = url.deletingLastPathComponent()
    let isTemporaryPick =
      temporaryPickDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
      == Self.temporaryPicksDirectory.resolvingSymlinksInPath().path
    // The pick is only released once it has been handed off (queued or staged), so a
    // failed or refused attempt can be retried from the same sheet.
    var pickConsumed = false
    defer {
      if pickConsumed && isTemporaryPick {
        try? FileManager.default.removeItem(at: temporaryPickDirectory)
      }
    }
    // Files-app picks are security-scoped; staging and uploading both read the original.
    let started = url.startAccessingSecurityScopedResource()
    defer {
      if started { url.stopAccessingSecurityScopedResource() }
    }
    guard let account = selectedAccount else {
      let stagedURL = try await stageManualUpload(url, movingPick: isTemporaryPick)
      pickConsumed = true
      pendingManualUploads.removeAll { $0 == url }
      pendingManualUploads.append(stagedURL)
      manualUploadNeedsSignIn = true
      return nil
    }
    let generation = accountGeneration
    guard !Task.isCancelled else { return nil }

    let id = TransferRecord.accountScopedID(UUID().uuidString, accountEmail: account.email)
    let fileExtension = url.pathExtension
    let uploadDirectory = Self.manualUploadsDirectory
    let storedURL = uploadDirectory.appendingPathComponent(id + (fileExtension.isEmpty ? ".dat" : ".\(fileExtension)"))
    // Hashing is a whole-file read, as is copying anything that isn't a temporary pick.
    let staged: (size: Int64, creation: Date, modified: Date, sha1: String, movedPick: Bool) = try await Task.detached(
      priority: .utility
    ) {
      var movedPick = false
      do {
        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        movedPick = try Self.place(url, at: storedURL, moving: isTemporaryPick)
        let attributes = try FileManager.default.attributesOfItem(atPath: storedURL.path)
        let creation = (attributes[.creationDate] as? Date) ?? Date()
        return (
          size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
          creation: creation,
          modified: (attributes[.modificationDate] as? Date) ?? creation,
          sha1: try GooglePhotosMobileClient.streamSHA1(fileURL: storedURL).base64EncodedString(),
          movedPick: movedPick
        )
      } catch {
        Self.discardStoredUpload(storedURL, restoringTo: movedPick ? url : nil)
        throw error
      }
    }.value
    let restorablePick = staged.movedPick ? url : nil
    let size = staged.size
    let creation = staged.creation
    let modified = staged.modified
    let sourceSHA1 = staged.sha1
    let rec = TransferRecord(
      id: id,
      filename: filename,
      mediaType: SupportedMediaFormats.isVideo(filename: filename) ? "Video" : "Photo",
      creationDate: creation,
      status: .pending,
      byteCount: size,
      sourcePath: storedURL.path,
      sourceFileSize: size,
      sourceModifiedAt: modified,
      sourceSHA1: sourceSHA1
    )
    guard await manifestStore.upsert(rec) else {
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      return nil
    }
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      await manifestStore.remove(id: id)
      return nil
    }
    guard await manifestStore.claimForUpload(id: id) else {
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      await manifestStore.remove(id: id)
      return nil
    }
    await refreshRecords()

    guard !Task.isCancelled else {
      await manifestStore.releaseUploadClaim(id: id)
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      await manifestStore.remove(id: id)
      return nil
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaim(id: id)
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      await manifestStore.remove(id: id)
      return nil
    }
    let accepted = workerPool.start(
      items: [
        UploadQueueItem(
          id: id,
          fileURL: storedURL,
          filename: filename,
          fileSize: size,
          creationDate: creation,
          precomputedSHA1: sourceSHA1,
          precomputedSourceModifiedAt: modified,
          removeSourceOnSuccess: true
        )
      ], quality: 3, accountEmail: account.email)
    if accepted == .rejected {
      // The pool refused the batch, so nothing owns `storedURL` any more. Leaving the
      // copy and the record behind leaked a full-size duplicate on every retry. The
      // original pick is kept, so the user can try again.
      await manifestStore.releaseUploadClaim(id: id)
      await manifestStore.remove(id: id)
      Self.discardStoredUpload(storedURL, restoringTo: restorablePick)
      throw GPhotosError.fileReadFailed("The upload could not start right now. Please try again in a moment.")
    }
    pickConsumed = true
    return id
  }

  public func resumePendingManualUploads() async {
    guard !replaysAfterAccountChange(("manualUploads", { [weak self] in await self?.resumePendingManualUploads() }))
    else { return }
    guard canUseSelectedAccount, !isResumingManualUploads, !pendingManualUploads.isEmpty else { return }
    isResumingManualUploads = true
    defer {
      isResumingManualUploads = false
      manualUploadNeedsSignIn = selectedAccount == nil && !pendingManualUploads.isEmpty
    }
    for url in pendingManualUploads {
      guard !Task.isCancelled, selectedAccount != nil else { break }
      guard (try? await uploadSingleFile(url: url)) != nil else {
        _ = replaysAfterAccountChange(("manualUploads", { [weak self] in await self?.resumePendingManualUploads() }))
        break
      }
      pendingManualUploads.removeAll { $0 == url }
      let directory = url.deletingLastPathComponent()
      try? FileManager.default.removeItem(at: Self.isStagedManualUpload(url) ? directory : url)
    }
  }

  /// Album membership for the retry paths, which do not go through the scan that normally
  /// attaches it. Built once per operation, off the main actor, and only while mirroring.
  private func mirroredAlbumMapping() async -> PhotoAlbumMirror.Mapping? {
    guard settings.mirrorPhotoAlbums else { return nil }
    return await Task.detached(priority: .utility) { PhotoAlbumMirror.buildMapping() }.value
  }

  override public func retryFailedForUser() async {
    guard canUseSelectedAccount else { return }
    let ledger = await BackgroundUploads.readLedger()
    let retryExtensionItems =
      selectedAccount.map { account in
        let prefix = TransferRecord.accountScopedID("", accountEmail: account.email)
        return ledger.failures.keys.contains { $0.hasPrefix(prefix) }
      } ?? false
    if let account = selectedAccount {
      await removeFailedRecordsWithoutSource(failedRecords, accountEmail: account.email, includingFiles: true)
    }
    retriesFailedItemsNow = true
    retriesFolderFailuresNow = true
    await super.retryFailedForUser()
    if retryExtensionItems {
      stopRequested = false
      await syncLibrary()
    }
  }

  override public func retryFailed() async {
    guard canUseSelectedAccount else { return }
    await backgroundUploads.forgetFailures()
    let failed = failedRecords
    guard canUseSelectedAccount, !Task.isCancelled, !failed.isEmpty, !isRunning, let account = selectedAccount else { return }
    let generation = accountGeneration
    let accountPrefix = "\(account.email)|"
    let roots = allowedSourceRoots()
    let needsAlbums = failed.contains { $0.id.hasPrefix(accountPrefix) && $0.assetLocalIdentifier != nil }
    let albumMapping = needsAlbums ? await mirroredAlbumMapping() : nil
    let folderRoots = folderRootPaths.all
    var retriesFolderFiles = false
    var sourceItems: [UploadQueueItem] = []

    let retriesNow = retriesFailedItemsNow
    for record in failed where record.id.hasPrefix(accountPrefix) && (retriesNow || record.isDueForAutomaticRetry()) {
      // A folder's own scan re-queues its failed files, holding the folder's scope and
      // keeping Live Photos paired, which a direct retry can do neither of.
      if let path = record.sourcePath, FolderBackup.isPath(path, insideAny: folderRoots) {
        retriesFolderFiles = true
        continue
      }
      guard let url = await existingFileURLAsync(for: record, roots: roots) else { continue }
      sourceItems.append(
        UploadQueueItem(
          id: record.id,
          fileURL: url,
          filename: record.filename,
          fileSize: record.byteCount ?? 0,
          creationDate: record.creationDate,
          albumNames: record.assetLocalIdentifier.flatMap { albumMapping?.albumNames(forAssetIdentifier: $0) } ?? [],
          precomputedSHA1: record.sourceSHA1,
          precomputedSourceModifiedAt: record.sourceModifiedAt,
          removeSourceOnSuccess: isAppOwnedCopy(url)
        ))
    }

    var claimedItems: [UploadQueueItem] = []
    for item in sourceItems {
      guard await manifestStore.resetForResend(id: item.id, accountEmail: account.email),
        await manifestStore.claimForUpload(id: item.id)
      else { continue }
      claimedItems.append(item)
    }

    await refreshRecords()
    await syncLibrary()
    if retriesFolderFiles { await syncFolders() }
    guard !Task.isCancelled,
      !claimedItems.isEmpty,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      return
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard !Task.isCancelled,
      accountGeneration == generation,
      selectedAccount?.email == account.email
    else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      return
    }
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: account.email) == .rejected {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
    }
  }

  public override func requeueRecord(_ record: TransferRecord) async {
    guard canUseSelectedAccount, let account = selectedAccount else { return }
    let generation = accountGeneration
    guard !Task.isCancelled, record.id.hasPrefix("\(account.email)|") else { return }
    await backgroundUploads.forgetFailure(of: record.id)
    if record.status == .failed,
      await removeFailedRecordsWithoutSource([record], accountEmail: account.email, includingFiles: true)
    {
      return
    }

    if let path = record.sourcePath, FolderBackup.isPath(path, insideAny: folderRootPaths.all) {
      // Re-queued by the folder's scan, as in `retryFailed()`.
      retriesFolderFailuresNow = true
      await syncFolders()
      return
    }

    if let url = await existingFileURLAsync(for: record) {
      var albumNames: [String] = []
      if let assetID = record.assetLocalIdentifier {
        albumNames = await mirroredAlbumMapping()?.albumNames(forAssetIdentifier: assetID) ?? []
      }
      let item = UploadQueueItem(
        id: record.id,
        fileURL: url,
        filename: record.filename,
        fileSize: record.byteCount ?? 0,
        creationDate: record.creationDate,
        albumNames: albumNames,
        precomputedSHA1: record.sourceSHA1,
        precomputedSourceModifiedAt: record.sourceModifiedAt,
        removeSourceOnSuccess: false
      )
      guard await manifestStore.resetForResend(id: record.id, accountEmail: account.email),
        await manifestStore.claimForUpload(id: record.id)
      else { return }
      await refreshRecords()
      guard !Task.isCancelled else {
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
        await refreshRecords()
      }
      return
    }

    let assetID = record.assetLocalIdentifier
    guard !Task.isCancelled else { return }
    guard let assetID else {
      await manifestStore.updateStatus(id: record.id, status: .failed, error: "The original file is no longer available")
      return
    }
    guard
      let asset = PHAsset.fetchAssets(
        withLocalIdentifiers: [assetID], options: AssetExportService.allFramesFetchOptions()
      ).firstObject
    else {
      await manifestStore.updateStatus(id: record.id, status: .failed, error: "Photos access is required to retry this item")
      return
    }
    let allResources = PHAssetResource.assetResources(for: asset)
    let role = record.resourceRole
    let resources = Self.resources(for: role, of: asset, in: allResources)
    guard !resources.isEmpty else {
      await manifestStore.updateStatus(id: record.id, status: .failed, error: "The original file is no longer available")
      return
    }
    let originalFilename = Self.uploadFilename(for: asset, role: role, resources: resources) ?? record.filename
    var estimatedSize = record.byteCount ?? 0
    if estimatedSize <= 0 {
      estimatedSize = Self.reportedByteCount(of: resources)
    }
    if estimatedSize <= 0 { estimatedSize = 3_000_000 }
    let placeholderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GPhotosPlaceholders", isDirectory: true)
      .appendingPathComponent(originalFilename)
    let item = UploadQueueItem(
      id: record.id,
      fileURL: placeholderURL,
      filename: originalFilename,
      fileSize: estimatedSize,
      creationDate: asset.creationDate,
      assetLocalIdentifier: assetID,
      resourceRole: role,
      isTemporaryFile: true,
      pairLivePhotos: role != .alternatePhoto && settings.pairLivePhotos
    )
    guard await manifestStore.resetForResend(id: record.id, accountEmail: account.email),
      await manifestStore.claimForUpload(id: record.id)
    else { return }
    await refreshRecords()
    guard !Task.isCancelled else {
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
      await refreshRecords()
    }
  }

  /// A failed item whose photo or file is gone can never upload or be retried, so its record
  /// is dropped. Needs full library access: otherwise a missing photo may only be out of reach.
  /// Folder files stay with their folder's scan, and a file only counts as gone when the user
  /// retries it, since its volume may just be unavailable. True if anything was removed.
  @discardableResult
  private func removeFailedRecordsWithoutSource(
    _ records: [TransferRecord], accountEmail: String, includingFiles: Bool
  ) async -> Bool {
    let folderRoots = folderRootPaths.all
    let candidates = records.filter { record in
      guard record.status == .failed, record.id.hasPrefix("\(accountEmail)|") else { return false }
      if let path = record.sourcePath, FolderBackup.isPath(path, insideAny: folderRoots) { return false }
      return record.assetLocalIdentifier != nil ? photoLibraryStatus == .authorized : includingFiles
    }
    guard !candidates.isEmpty else { return false }
    let assetIDs = candidates.compactMap(\.assetLocalIdentifier)
    let present = await Task.detached(priority: .utility) { Self.existingAssetIDs(assetIDs) }.value
    var removedAny = false
    var sharedEntries = Set<UUID>()
    let gone = candidates.filter { record in record.assetLocalIdentifier.map { !present.contains($0) } ?? true }
    let missing = await Task.detached(priority: .utility) {
      let entries =
        gone.contains { $0.sharedEntryID != nil }
        ? Dictionary(
          SharedQueueBridge.loadEntries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
      return gone.filter { Self.fileIsConfirmedMissing($0, sharedEntries: entries) }
    }.value
    for record in missing {
      guard await manifestStore.removeIfUnfinished(id: record.id) else { continue }
      removedAny = true
      if let entry = record.sharedEntryID { sharedEntries.insert(entry) }
    }
    // Its queue entry would otherwise bring the record back.
    if !sharedEntries.isEmpty { try? SharedQueueBridge.removeEntries(ids: sharedEntries) }
    if removedAny { await refreshRecords() }
    return removedAny
  }

  /// A pending record of a photo the whole-library scan no longer lists (deleted, hidden,
  /// or in a Don't Back Up album) is never queued again and would show as waiting forever.
  /// One never uploaded is dropped (if the photo comes back, the scan makes a new record);
  /// an edit waiting to replace a copy the account has goes back to uploaded.
  private func removeUnfinishedRecordsOutsideLibrary(described: Set<String>, accountEmail: String) async {
    // Limited access lists only the chosen photos, and an empty pass may be a library
    // that isn't readable yet: neither says a photo is gone.
    guard photoLibraryStatus == .authorized, !described.isEmpty else { return }
    let prefix = "\(accountEmail)|"
    let records = await manifestStore.allRecords()
    let stale = await Task.detached(priority: .utility) {
      records.filter { record in
        guard record.status == .pending, record.id.hasPrefix(prefix), record.sourcePath == nil,
          record.sharedEntryID == nil, let asset = record.assetLocalIdentifier
        else { return false }
        return !described.contains(asset)
      }
    }.value
    guard !stale.isEmpty else { return }
    var settled = 0
    for record in stale {
      if record.sentAccountEmails.contains(accountEmail) {
        if await manifestStore.settleUnsentRevision(id: record.id, accountEmail: accountEmail) { settled += 1 }
      } else if await manifestStore.removeIfUnfinished(id: record.id) {
        settled += 1
      }
    }
    libraryScanLogger.notice("Settled \(settled, privacy: .public) waiting records of photos no longer in the library")
    if settled > 0 { await refreshRecords() }
  }

  /// Only a file whose folder can be seen and that isn't in it. A file that changed, or whose
  /// folder is out of reach (no access, a volume not mounted), still has a source.
  private nonisolated static func fileIsConfirmedMissing(
    _ record: TransferRecord, sharedEntries: [UUID: SharedUploadEntry]
  ) -> Bool {
    let manager = FileManager.default
    if let entryID = record.sharedEntryID, let entry = sharedEntries[entryID],
      SharedQueueBridge.fileURL(for: entry) != nil
    {
      return false
    }
    guard let path = record.sourcePath else { return true }
    if manager.fileExists(atPath: path) { return false }
    return manager.fileExists(atPath: (path as NSString).deletingLastPathComponent)
  }

  private nonisolated static func existingAssetIDs(_ ids: [String]) -> Set<String> {
    guard !ids.isEmpty else { return [] }
    let options = AssetExportService.allFramesFetchOptions()
    options.includeHiddenAssets = true
    var found = Set<String>()
    PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options).enumerateObjects { asset, _, _ in
      found.insert(asset.localIdentifier)
    }
    return found
  }

  override public func mirrorItem(for record: TransferRecord) async -> UploadQueueItem? {
    if let url = await existingFileURLAsync(for: record) {
      var albumNames: [String] = []
      if let assetID = record.assetLocalIdentifier {
        albumNames = await mirroredAlbumMapping()?.albumNames(forAssetIdentifier: assetID) ?? []
      }
      return UploadQueueItem(
        id: record.id,
        fileURL: url,
        filename: record.filename,
        fileSize: record.byteCount ?? 0,
        creationDate: record.creationDate,
        albumNames: albumNames,
        precomputedSHA1: record.sourceSHA1,
        precomputedSourceModifiedAt: record.sourceModifiedAt,
        removeSourceOnSuccess: false
      )
    }

    guard let assetID = record.assetLocalIdentifier else { return nil }
    guard
      let asset = PHAsset.fetchAssets(
        withLocalIdentifiers: [assetID],
        options: AssetExportService.allFramesFetchOptions()
      ).firstObject
    else { return nil }

    let allResources = PHAssetResource.assetResources(for: asset)
    let role = record.resourceRole
    let resources = Self.resources(for: role, of: asset, in: allResources)
    guard !resources.isEmpty else { return nil }

    let originalFilename = Self.uploadFilename(for: asset, role: role, resources: resources) ?? record.filename
    var estimatedSize = record.byteCount ?? 0
    if estimatedSize <= 0 {
      estimatedSize = Self.reportedByteCount(of: resources)
    }
    if estimatedSize <= 0 { estimatedSize = 3_000_000 }
    let placeholderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GPhotosPlaceholders", isDirectory: true)
      .appendingPathComponent(originalFilename)
    let albumNames = await mirroredAlbumMapping()?.albumNames(forAssetIdentifier: assetID) ?? []

    return UploadQueueItem(
      id: record.id,
      fileURL: placeholderURL,
      filename: originalFilename,
      fileSize: estimatedSize,
      creationDate: asset.creationDate,
      assetLocalIdentifier: assetID,
      resourceRole: role,
      isTemporaryFile: true,
      albumNames: role == .primary ? albumNames : [],
      pairLivePhotos: role != .alternatePhoto && settings.pairLivePhotos,
      removeSourceOnSuccess: false
    )
  }

  override public func primaryBatchDidStart() {
    updateAppBusy()
    beginContinuedUpload()
    startLiveActivity()
  }

  func startLiveActivity() {
    #if os(iOS) && canImport(ActivityKit)
      guard UIApplication.shared.applicationState == .active else { return }
      LiveActivityController.shared.start(backupActivityState)
    #endif
  }

  #if os(iOS) && canImport(ActivityKit)
    private var backupActivityState: BackupActivityAttributes.ContentState {
      let phase: BackupActivityAttributes.ContentState.Phase
      if workerPool.isPaused {
        phase = .paused
      } else if isOffline {
        phase = .offline
      } else if isWaitingForUnmeteredNetwork {
        phase = .waitingForNetwork
      } else if workerPool.isRateLimited {
        phase = .waitingForGoogle
      } else if workerPool.isBatchFinalizing {
        phase = .finishing
      } else {
        phase = .uploading
      }
      return .init(
        phase: phase,
        completedCount: workerPool.lastBatchCompletedCount, totalCount: workerPool.lastBatchTotalCount,
        bytesSent: workerPool.currentTransferredBytes, bytesTotal: workerPool.currentTotalBytes,
        etaText: phase == .uploading ? workerPool.overallFormattedETA : "",
        currentFilename: workerPool.workers.first { TransferState(workerStatus: $0.status) == .uploading }?.filename)
    }
  #endif

  override public func resumePendingWork() async {
    guard !stopRequested else { return }
    await ingestSharedQueueItems()
    let folderRoots = folderRootPaths.all
    if settings.autoSyncEnabled {
      // The scans queue what's unfinished; a partial library pass covers its pending items.
      await scanLibrary()
      await syncFolders()
    } else if accountPendingRecords.contains(where: {
      $0.sourcePath.map { FolderBackup.isPath($0, insideAny: folderRoots) } == true
    }) {
      await syncFolders(resumingOnly: true)
    }
    await requeuePendingRecords { record in
      guard record.sharedEntryID == nil else { return false }
      return record.sourcePath.map { !FolderBackup.isPath($0, insideAny: folderRoots) } ?? true
    }
  }

  /// A picked file's copy sits directly in Manual Uploads, and goes once it's up, as on its
  /// first try. Nothing outside that folder is ever the app's to remove.
  override public func isAppOwnedCopy(_ url: URL) -> Bool {
    Self.isInManualUploads(url, directory: Self.manualUploadsDirectory.standardizedFileURL.path)
  }

  private nonisolated static func isInManualUploads(_ url: URL, directory: String) -> Bool {
    url.deletingLastPathComponent().standardizedFileURL.path == directory
  }

  /// Off the main actor: an interrupted first backup can leave tens of thousands pending.
  override public func queueItems(forPending records: [TransferRecord]) async -> [UploadQueueItem] {
    let roots = allowedSourceRoots()
    let manualDirectory = Self.manualUploadsDirectory.standardizedFileURL.path
    let (items, assetRecords) = await Task.detached(priority: .utility) {
      var items: [UploadQueueItem] = []
      var assetRecords: [TransferRecord] = []
      for record in records {
        if let url = Self.validatedExistingFileURL(for: record, roots: roots) {
          items.append(
            UploadQueueItem(
              id: record.id, fileURL: url, filename: record.filename, fileSize: record.byteCount ?? 0,
              creationDate: record.creationDate, precomputedSHA1: record.sourceSHA1,
              precomputedSourceModifiedAt: record.sourceModifiedAt,
              removeSourceOnSuccess: Self.isInManualUploads(url, directory: manualDirectory)))
        } else if record.assetLocalIdentifier != nil {
          assetRecords.append(record)
        }
      }
      return (items, assetRecords)
    }.value
    guard !assetRecords.isEmpty else { return items }
    let mapping = await mirroredAlbumMapping()
    let pairLivePhotos = settings.pairLivePhotos
    let assetItems = await Task.detached(priority: .utility) {
      Self.assetQueueItems(for: assetRecords, albumMapping: mapping, pairLivePhotos: pairLivePhotos)
    }.value
    return items + assetItems
  }

  private nonisolated static func assetQueueItems(
    for records: [TransferRecord], albumMapping: PhotoAlbumMirror.Mapping?, pairLivePhotos: Bool
  ) -> [UploadQueueItem] {
    var assets: [String: PHAsset] = [:]
    PHAsset.fetchAssets(
      withLocalIdentifiers: records.compactMap(\.assetLocalIdentifier), options: AssetExportService.allFramesFetchOptions()
    ).enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
    let placeholders = FileManager.default.temporaryDirectory.appendingPathComponent("GPhotosPlaceholders", isDirectory: true)
    return records.compactMap { record in
      guard let assetID = record.assetLocalIdentifier, let asset = assets[assetID] else { return nil }
      let role = record.resourceRole
      let resources = Self.resources(for: role, of: asset, in: PHAssetResource.assetResources(for: asset))
      guard !resources.isEmpty else { return nil }
      let filename = Self.uploadFilename(for: asset, role: role, resources: resources) ?? record.filename
      let size = record.byteCount.flatMap { $0 > 0 ? $0 : nil } ?? Self.reportedByteCount(of: resources)
      return UploadQueueItem(
        id: record.id, fileURL: placeholders.appendingPathComponent(filename), filename: filename,
        fileSize: size > 0 ? size : 3_000_000, creationDate: asset.creationDate, assetLocalIdentifier: assetID,
        resourceRole: role, isTemporaryFile: true,
        // As the scan does: the RAW and the original stay out of mirrored albums.
        albumNames: role == .primary ? albumMapping?.albumNames(forAssetIdentifier: assetID) ?? [] : [],
        pairLivePhotos: role != .alternatePhoto && pairLivePhotos)
    }
  }

  override public func primaryBatchDidComplete() async {
    await super.primaryBatchDidComplete()
    updateAppBusy()
    // Signed in before notifications were ever asked for: the moment a backup has just run
    // in front of the user is when a summary of the ones that run while closed makes sense.
    if workerPool.lastBatchCompletedCount > 0 { Task { await BackupNotifier.shared.requestAuthorization() } }
    let stopped = workerPool.isBatchCancelled || workerPool.lastBatchLostNetwork
    endContinuedUpload(success: !stopped && workerPool.lastBatchCompletedCount == workerPool.lastBatchTotalCount)
    #if os(iOS) && canImport(ActivityKit)
      LiveActivityController.shared.update(backupActivityState)
      LiveActivityController.shared.end(
        completed: workerPool.lastBatchCompletedCount, total: workerPool.lastBatchTotalCount, stopped: stopped)
    #endif
    // Cut short by the network, the batch isn't finished: its items go up when it's back.
    if !workerPool.isBatchCancelled, !workerPool.lastBatchLostNetwork {
      await BackupNotifier.shared.notifyBatchCompletion(
        uploadedCount: workerPool.lastBatchCompletedCount,
        failedCount: workerPool.lastBatchFailedCount,
        authErrorEmail: workerPool.lastBatchAuthErrorEmail,
        storageFullEmail: workerPool.lastBatchStorageFullEmail
      )
    }
    checkAndRunForegroundMirror()
  }

  // MARK: - Uploads While Closed

  /// The extension runs while auto-sync is on for a signed-in account with full library access.
  private func refreshBackgroundUploads() {
    // Accounts load a moment after launch. Until then "no account" means nothing, and turning
    // the extension off would undo what a launch in the background is there to keep going.
    guard hasLoadedAccounts, selectedAccount != nil || credentialError == nil else { return }
    backgroundUploads.setEnabled(
      photoLibraryStatus == .authorized && selectedAccount != nil && settings.autoSyncEnabled)
  }

  public func sceneDidBecomeActive() {
    isSceneActive = true
    workerPool.iCloudDownloadLimit = nil
    updateAppBusy()
    if isRunning { startLiveActivity() }
    guard backgroundUploadPoll == nil else { return }
    backgroundUploadObserver.token = BackgroundUploadLedgerStore.observeWork { [weak self] in
      Task { @MainActor in
        guard let self, self.isSceneActive else { return }
        self.backgroundUploadWakeRequested = true
        self.backgroundUploadPollSleep?.cancel()
      }
    }
    backgroundUploadPoll = Task { [weak self] in
      while !Task.isCancelled, let self {
        self.backgroundUploadWakeRequested = false
        let ledger = await BackgroundUploads.readLedger()
        let interval: Duration
        if ledger.hasWork() || !self.backgroundUploadWaitIDs.isEmpty {
          await self.reconcileBackgroundUploads(timeout: .seconds(30), ledger: ledger)
          interval = await BackgroundUploads.readLedger().foregroundPollInterval()
        } else {
          interval = ledger.foregroundPollInterval()
        }
        guard !Task.isCancelled else { return }
        if self.backgroundUploadWakeRequested { continue }
        let sleep = Task { do { try await Task.sleep(for: interval) } catch {} }
        self.backgroundUploadPollSleep = sleep
        await sleep.value
      }
    }
  }

  /// A batch still running keeps uploading here for as long as iOS allows.
  public func sceneDidEnterBackground() {
    isSceneActive = false
    backgroundUploadObserver.token = nil
    backgroundUploadPoll?.cancel()
    backgroundUploadPoll = nil
    backgroundUploadPollSleep?.cancel()
    backgroundUploadPollSleep = nil
    updateAppBusy()
  }

  private func updateAppBusy() {
    backgroundUploads.setAppBusy(isSceneActive || isRunning)
  }

  func reconcileBackgroundTransfers() async {
    if !hasLoadedAccounts, !didStart { await loadAccounts() }
    await reconcileBackgroundUploads(timeout: .seconds(8))
    await BackgroundTaskRegistrar.scheduleProcessing(for: self)
  }

  private func reconcileBackgroundUploads(timeout: Duration, ledger snapshot: BackgroundUploadLedger? = nil) async {
    guard hasLoadedAccounts, !isReconcilingBackgroundUploads, !Task.isCancelled else { return }
    isReconcilingBackgroundUploads = true
    defer { isReconcilingBackgroundUploads = false }
    var previouslyHeld = backgroundUploadWaitIDs
    let ledger: BackgroundUploadLedger
    if let snapshot { ledger = snapshot } else { ledger = await BackgroundUploads.readLedger() }
    await importBackgroundUploads(ledger)
    previouslyHeld.formUnion(backgroundUploadWaitIDs)
    if !ledger.jobs.isEmpty {
      await backgroundUploads.finishJobs(timeout: timeout)
      await importBackgroundUploads()
    }
    guard !isStarting, isSceneActive, settings.autoSyncEnabled, !Task.isCancelled else { return }
    if accountPendingRecords.contains(where: {
      previouslyHeld.contains($0.id) && !backgroundUploadWaitIDs.contains($0.id)
    }) {
      await syncLibraryAutomatically()
    }
  }

  private func importBackgroundUploads(_ snapshot: BackgroundUploadLedger? = nil) async {
    guard hasLoadedAccounts, !isImportingBackgroundUploads else { return }
    isImportingBackgroundUploads = true
    defer { isImportingBackgroundUploads = false }
    await withAccountWork(wake: ("receipts", { [weak self] in await self?.importBackgroundUploads() })) {
      await self.recordBackgroundReceipts(snapshot)
    }
  }

  private func recordBackgroundReceipts(_ snapshot: BackgroundUploadLedger?) async {
    let ledger: BackgroundUploadLedger
    if let snapshot { ledger = snapshot } else { ledger = await BackgroundUploads.readLedger() }
    backgroundUploadWaitIDs = ledger.heldRecordIDs
    guard !ledger.results.isEmpty else { return }
    let primaryEmail = selectedAccount?.email
    let mapping =
      ledger.results.contains { $0.accountEmail == primaryEmail && $0.role == .primary } ? await mirroredAlbumMapping() : nil
    guard !Task.isCancelled else { return }
    let valid = ledger.results.filter { acceptsBackgroundReceipt(accountEmail: $0.accountEmail) }
    let outcomes = await manifestStore.recordBackgroundUploads(valid)
    var settled: [BackgroundUploadResult] = []
    var keysByAlbum: [String: [String]] = [:]
    for (result, outcome) in zip(valid, outcomes) {
      guard outcome != .deferred, acceptsBackgroundReceipt(accountEmail: result.accountEmail) else { continue }
      settled.append(result)
      guard outcome == .recorded, result.accountEmail == primaryEmail, result.role == .primary, let mapping else { continue }
      for album in mapping.albumNames(forAssetIdentifier: result.assetLocalIdentifier)
      where !(keysByAlbum[album]?.contains(result.mediaKey) ?? false) {
        keysByAlbum[album, default: []].append(result.mediaKey)
      }
    }
    // A settled receipt is durably recorded. Separately discard orphaned receipts for
    // accounts that are already gone. The removal gate stays closed until their records are gone.
    let configuredEmails = Set(accounts.map(\.email))
    let discarded = ledger.results.filter { !configuredEmails.contains($0.accountEmail) }
    let imported = Dictionary(
      (settled + discarded).map { ($0.recordID, $0) },
      uniquingKeysWith: { _, last in last })
    guard !imported.isEmpty else { return }
    backgroundUploadWaitIDs = await BackgroundUploads.withLedger {
      let store = BackgroundUploadLedgerStore.shared
      var held = Set<String>()
      let saved = store.persist(notifiesAboutWork: false) { ledger in
        ledger.results.removeAll { imported[$0.recordID] == $0 }
        ledger.appWorkEpoch = UUID()
        held = ledger.heldRecordIDs
        return true
      }
      return saved ? held : store.read().heldRecordIDs
    }
    BackgroundUploadLog.write("app: recorded \(settled.count) uploads made while closed")
    if let primaryEmail, !keysByAlbum.isEmpty {
      addPendingAlbumKeys(keysByAlbum, accountEmail: primaryEmail)
    }
    await refreshRecords()
    if !pendingAlbumKeys.isEmpty, !isOffline, !isWaitingForUnmeteredNetwork {
      Task { [weak self] in await self?.addPendingAlbums() }
    }
  }

  func waitingReason(for record: TransferRecord) -> String? {
    guard record.status == .pending || record.status == .sending else { return nil }
    if stopRequested { return String(localized: "Backup stopped") }
    if workerPool.isPaused
      && !workerPool.workers.contains(where: {
        $0.itemID == record.id && TransferState(workerStatus: $0.status) == .uploading
      })
    {
      return String(localized: "Backup paused")
    }
    if isOffline { return BackupStatus.offline.title }
    if isWaitingForUnmeteredNetwork { return BackupStatus.waitingForNetwork.title }
    if workerPool.isRateLimited { return BackupStatus.rateLimited.title }
    if backgroundUploadWaitIDs.contains(record.id) { return BackupStatus.waitingForBackgroundBackup.title }
    if let assetID = record.assetLocalIdentifier {
      if excludedAssetIDs?.contains(assetID) == true { return String(localized: "Excluded from backup") }
      if !isAuthorized { return String(localized: "Photos access needed") }
      if record.resourceRole == .uneditedOriginal && !settings.backsUpUneditedOriginals {
        return String(localized: "Backup of unedited originals is off")
      }
    }
    if let path = record.sourcePath,
      let folder = backedUpFolders.first(where: {
        resolvedFolderRoots[$0.id].map { FolderBackup.isPath(path, inside: $0) } ?? false
      })
    {
      if foldersNeedingAccess.contains(folder.id) { return String(localized: "Folder access needed") }
      if !folder.isEnabled { return String(localized: "Folder backup paused") }
    }
    if !settings.autoSyncEnabled && record.status == .pending { return BackupStatus.autoSyncOff.title }
    return nil
  }

  /// Not while a batch runs: its own album step could create the same album.
  private func addPendingAlbums() async {
    await withAccountWork(isPrimaryOnly: true, wake: ("albums", { [weak self] in await self?.addPendingAlbums() })) {
      await self.applyPendingAlbums()
    }
  }

  private func addPendingAlbumKeys(_ keysByAlbum: [String: [String]], accountEmail: String) {
    guard !keysByAlbum.isEmpty else { return }
    pendingAlbumKeys[accountEmail, default: [:]].merge(keysByAlbum) { old, new in old + new.filter { !old.contains($0) } }
  }

  private func applyPendingAlbums() async {
    guard !Task.isCancelled, !isRunning, let email = selectedAccount?.email,
      let pending = pendingAlbumKeys.removeValue(forKey: email)
    else { return }
    let failed = await workerPool.addToAlbums(pending, accountEmail: email)
    if Task.isCancelled {
      // Cut off by an account change: the albums not finished wait for this account's next pass.
      addPendingAlbumKeys(pending.filter { failed.contains($0.key) }, accountEmail: email)
      return
    }
    if !failed.isEmpty {
      BackgroundUploadLog.write("app: couldn't add to \(failed.joined(separator: ", "))")
    }
  }

  // MARK: - Continued Upload

  private var continuedUploadSubtitle: String {
    let speed = workerPool.overallSpeedBytesPerSec
    let remaining = max(0, workerPool.currentTotalBytes - workerPool.currentTransferredBytes)
    return ContinuedUploadProgress.subtitle(
      completed: workerPool.lastBatchCompletedCount,
      total: workerPool.lastBatchTotalCount,
      secondsLeft: speed > 1024 ? Double(remaining) / speed : nil,
      isPaused: workerPool.isPaused,
      isOffline: isOffline,
      isWaitingForNetwork: isWaitingForUnmeteredNetwork,
      isRateLimited: workerPool.isRateLimited)
  }

  /// Asks iOS to keep the batch running after the app leaves the foreground. iOS accepts
  /// this only while the app is open.
  private func beginContinuedUpload() {
    guard UIApplication.shared.applicationState == .active else { return }
    continuedUpload.start(totalItems: workerPool.lastBatchTotalCount, subtitle: continuedUploadSubtitle)
  }

  private func endContinuedUpload(success: Bool) {
    guard continuedUpload.isActive else { return }
    continuedUpload.finish(success: success)
    releaseContinuedUploadHold()
  }

  private func releaseContinuedUploadHold() {
    guard continuedUploadHoldsBatch else { return }
    continuedUploadHoldsBatch = false
    workerPool.releaseBackgroundExpirationHold()
  }

  public func checkAndRunForegroundMirror() {
    guard !isStarting, accountMirror.hasPendingWork, !accountMirror.isRunning, !workerPool.isRunning, !stopRequested,
      idleMirrorConditionsHold()
    else { return }

    Task { [weak self] in
      await self?.accountMirror.runIdleWindow()
    }
  }

  public override func resumeCopies() {
    if isSceneActive { checkAndRunForegroundMirror() }
  }

  public override func idleMirrorConditionsHold() -> Bool {
    guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
      !NetworkStatusMonitor.shared.isExpensive,
      !NetworkStatusMonitor.shared.isConstrained
    else { return false }
    guard settings.copiesOnlyWhileCharging else { return true }
    // Left on, battery monitoring keeps the system reporting every battery change.
    UIDevice.current.isBatteryMonitoringEnabled = true
    defer { UIDevice.current.isBatteryMonitoringEnabled = false }
    let batteryState = UIDevice.current.batteryState
    return batteryState == .charging || batteryState == .full
  }

  // MARK: - Settings & Deletion

  public override func waitingForNetworkDidChange() {
    workerPool.onProgressUpdated?()
    accountMirror.refreshStates()
  }

  public override func updateSettings(_ newSettings: AppSettings) {
    if newSettings.autoSyncEnabled {
      stopRequested = false
    }
    let enablesCleanup = settings.autoDeleteDelay == .never && newSettings.autoDeleteDelay != .never
    // Edits made earlier are only found by reading the whole library.
    if newSettings.backsUpUneditedOriginals && !settings.backsUpUneditedOriginals {
      needsFullLibraryScan = true
    }
    let copiesAnyTime = settings.copiesOnlyWhileCharging && !newSettings.copiesOnlyWhileCharging
    let exclusionsChanged = settings.backupExclusions != newSettings.backupExclusions
    super.updateSettings(newSettings)
    refreshBackgroundUploads()
    if copiesAnyTime, isSceneActive { checkAndRunForegroundMirror() }
    if exclusionsChanged { Task { await syncFolders() } }
    if enablesCleanup {
      // Due library items are announced with a notification, so ask when the user opts in.
      Task { await BackupNotifier.shared.requestAuthorization() }
    }
  }

  /// Restores originals left aside by a deletion that was interrupted mid-way, and
  /// finishes deletions that were recorded but not completed.
  private func recoverDeletionTombstones() async {
    // Only an uploaded file is ever set aside: a crash leaves its record `.sent` (the
    // file goes back) or `.deleted` (the tombstone goes).
    let sides = await manifestStore.allRecords().flatMap { record -> [TombstoneSide] in
      guard record.status == .sent || record.status == .deleted else { return [] }
      var sides: [TombstoneSide] = []
      if let path = record.sourcePath {
        sides.append(
          TombstoneSide(recordID: record.id, path: path, size: record.sourceFileSize, modifiedAt: record.sourceModifiedAt))
      }
      if let path = record.pairedSourcePath {
        sides.append(
          TombstoneSide(
            recordID: record.id, path: path, size: record.pairedSourceFileSize, modifiedAt: record.pairedSourceModifiedAt))
      }
      return sides
    }
    guard !sides.isEmpty else { return }
    let folders = backedUpFolders
    let store = manifestStore
    let accesses = await Task.detached(priority: .utility) { () -> [FolderAccess] in
      // Tombstones sit beside the original, so listing a backed-up folder's directory
      // needs that folder's scope. Without it an interrupted delete would strand the
      // file as an invisible dotfile.
      let accesses = FolderBackup.beginAccess(folders)
      // Each directory is listed once, however many records live in it.
      let sidesByDirectory = Dictionary(grouping: sides) { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
      for (directory, directorySides) in sidesByDirectory {
        if Task.isCancelled { break }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
          .filter { $0.hasPrefix(TransferManifestStore.deletionTombstonePrefix) }
        guard !names.isEmpty else { continue }
        for side in directorySides {
          let tombstones = TransferManifestStore.pendingTombstones(
            forRecordPath: side.path, size: side.size, modifiedAt: side.modifiedAt, among: names)
          guard !tombstones.isEmpty else { continue }
          // With the original back in place, or its record already deleted, the
          // tombstone is all that is left to remove.
          var discardsTombstones = FileManager.default.fileExists(atPath: side.path)
          if !discardsTombstones {
            discardsTombstones = await store.record(for: side.recordID)?.status == .deleted
          }
          for tombstone in tombstones {
            if discardsTombstones {
              try? FileManager.default.removeItem(at: tombstone)
            } else {
              _ = await store.restoreTombstoneIfSafe(id: side.recordID, path: side.path, tombstone: tombstone)
            }
          }
        }
      }
      return accesses
    }.value
    defer { FolderBackup.endAccess(accesses) }
    applyFolderAccesses(accesses)
  }

  /// A crash, or a failed write after a declined or failed PhotoKit delete, can leave a
  /// record `.deleted` while its asset is still in the library. Such records go back to
  /// `.sent` so the asset is neither forgotten nor treated as gone.
  private func reconcileDeletedLibraryRecords() async {
    guard isAuthorized, !isCleaningUp else { return }
    let deleted = await manifestStore.allRecords().filter {
      $0.status == .deleted && $0.sourcePath == nil && $0.assetLocalIdentifier != nil
    }
    guard !deleted.isEmpty else { return }
    let identifiers = deleted.compactMap(\.assetLocalIdentifier)
    let present = await Task.detached(priority: .utility) { Self.fetchableAssetIdentifiers(identifiers) }.value
    let ids = deleted.filter { record in record.assetLocalIdentifier.map { present.contains($0) } ?? false }.map(\.id)
    guard !ids.isEmpty, !isCleaningUp else { return }
    if await manifestStore.restoreSent(ids: ids) {
      await refreshRecords()
    }
  }

  /// Recently Deleted items do not fetch, so only assets still in the library count.
  private nonisolated static func fetchableAssetIdentifiers(_ identifiers: [String]) -> Set<String> {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: AssetExportService.allFramesFetchOptions())
    var found = Set<String>()
    for index in 0..<assets.count {
      found.insert(assets.object(at: index).localIdentifier)
    }
    return found
  }

  // MARK: - Cleanup

  private struct EligibleCleanup: Sendable {
    var staged: [TransferRecord] = []
    /// In an enabled backed-up folder. Protection, the files themselves and free space
    /// are checked under the folder's scope by `openFolderCleanup(_:)`.
    var folder: [TransferRecord] = []
    var library: [TransferRecord] = []
  }

  /// Records this account may remove now, split into the app's staged copies, files in
  /// backed-up folders and photo-library assets. Shared-sheet items are owned by the
  /// share queue.
  private func eligibleCleanupRecords(accountEmail: String) async -> EligibleCleanup {
    guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else { return EligibleCleanup() }
    await manifestStore.setRetention(settings.autoDeleteDelay)
    // A folder's free space is measured on its own volume, so the store's home-volume
    // "low on space" gate is applied below to everything else instead.
    let prefix = "\(accountEmail)|"
    let candidates = await manifestStore.eligibleForDeletion(
      delay: settings.autoDeleteDelay,
      smartDelete: false,
      accountEmail: accountEmail,
      accountEmails: Set(accounts.map(\.email)).union([accountEmail]),
      excludingAccounts: Set(accounts.filter { !$0.mirrorEnabled && $0.email != accountEmail }.map(\.email)),
      includesFoundItems: settings.removesItemsAlreadyInGooglePhotos
    ).filter { $0.id.hasPrefix(prefix) && $0.sharedEntryID == nil }
    // Photos opened recently stay, like Optimize Storage keeps what's in use.
    let recentlyViewed = settings.keepsRecentlyViewed.interval.map { RecentlyViewed.assetIDs(within: $0) } ?? []
    let unused = candidates.filter { record in
      guard let asset = record.assetLocalIdentifier else { return true }
      return !recentlyViewed.contains(asset)
    }
    guard !Task.isCancelled, allowsAccountWork else { return EligibleCleanup() }
    let eligible = await remoteCopyVerifier.confirmed(unused, accountEmail: accountEmail)
    let homeIsLow = settings.smartDeleteEnabled ? await manifestStore.bytesNeededToRecover() > 0 : true
    let stagedRoots = stagedSourceRoots()
    let folderRoots = folderRootPaths.enabled
    // A file that could not be removed is left alone for a while, not retried and
    // reported again on every pass.
    let backingOff = DeletionFailureBackoff.idsBackingOff()
    // Checking a staged copy stats it, so the split runs off the main actor.
    return await Task.detached(priority: .utility) {
      var result = EligibleCleanup()
      for record in eligible where record.id.hasPrefix(prefix) && record.sharedEntryID == nil {
        if let sourcePath = record.sourcePath {
          guard !backingOff.contains(record.id) else { continue }
          if FolderBackup.isPath(sourcePath, insideAny: folderRoots) {
            result.folder.append(record)
          } else if homeIsLow, Self.validatedSourceFileURL(atPath: sourcePath, roots: stagedRoots) != nil {
            result.staged.append(record)
          }
        } else if homeIsLow, record.assetLocalIdentifier != nil {
          result.library.append(record)
        }
      }
      return result
    }.value
  }

  /// Works out what Clean Up would remove, without changing anything. Library facts are
  /// read off the main actor; with "Only When Low on Space" the plan stops once it frees
  /// enough to get back above the threshold.
  public func prepareLibraryCleanup() async -> CleanupPlan {
    await withAccountWork { await self.planLibraryCleanup() } ?? CleanupPlan()
  }

  private func planLibraryCleanup() async -> CleanupPlan {
    guard settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email else { return CleanupPlan() }
    let eligible = await eligibleCleanupRecords(accountEmail: accountEmail)
    let staged = eligible.staged
    let library = eligible.library
    let folderPass = await openFolderCleanup(eligible.folder)
    FolderBackup.endAccess(folderPass.accesses)
    let folderItems = folderPass.items
    let stagedBytes = staged.reduce(Int64(0)) { $0 + max(0, $1.byteCount ?? 0) }
    let folderBytes = folderItems.reduce(Int64(0)) { $0 + $1.bytes }
    var bytesNeeded: Int64?
    if settings.smartDeleteEnabled {
      // Folder files on this iPhone's own volume free the same space as library items.
      let homeVolume = await Task.detached(priority: .utility) { FolderBackup.homeVolume() }.value
      let folderHomeBytes = folderItems.filter { $0.volume != nil && $0.volume == homeVolume }.reduce(Int64(0)) { $0 + $1.bytes }
      bytesNeeded = max(0, await manifestStore.bytesNeededToRecover() - stagedBytes - folderHomeBytes)
    }
    var libraryRecords: [TransferRecord] = []
    if isAuthorized, !library.isEmpty {
      libraryRecords = await planLibraryRecords(library, accountEmail: accountEmail, bytesNeeded: bytesNeeded)
    }
    guard !Task.isCancelled, allowsAccountWork, settings.autoDeleteDelay != .never, selectedAccount?.email == accountEmail else {
      return CleanupPlan()
    }
    return CleanupPlan(
      libraryRecords: libraryRecords,
      stagedRecords: staged,
      folderRecords: folderItems.map(\.record),
      totalBytes: stagedBytes + folderBytes + libraryRecords.reduce(Int64(0)) { $0 + max(0, $1.byteCount ?? 0) }
    )
  }

  /// What the planner needs from PhotoKit, read once so a deletion can re-plan against
  /// the same view of the library.
  private struct LibrarySnapshot: Sendable {
    var facts: [String: LibraryAssetFacts] = [:]
    var burstMembers: [String: Set<String>] = [:]
  }

  private func planLibraryRecords(_ records: [TransferRecord], accountEmail: String, bytesNeeded: Int64?) async -> [TransferRecord] {
    let snapshot = await readLibrarySnapshot(for: records, accountEmail: accountEmail)
    return planLibraryRecords(records, snapshot: snapshot, bytesNeeded: bytesNeeded)
  }

  private func planLibraryRecords(_ records: [TransferRecord], snapshot: LibrarySnapshot, bytesNeeded: Int64?) -> [TransferRecord] {
    LibraryCleanupPlanner.plan(
      records: records,
      facts: snapshot.facts,
      burstMembers: snapshot.burstMembers,
      protectedAlbumIDs: settings.protectedAlbumIDs,
      protectsFavorites: settings.protectsFavorites,
      bytesNeeded: bytesNeeded
    )
  }

  private func readLibrarySnapshot(for records: [TransferRecord], accountEmail: String) async -> LibrarySnapshot {
    let ids = Array(Set(records.compactMap(\.assetLocalIdentifier)))
    guard !ids.isEmpty else { return LibrarySnapshot() }
    let readsAlbums = !settings.protectedAlbumIDs.isEmpty
    let needsUneditedOriginals = settings.backsUpUneditedOriginals
    // Read from the store, not the published copy, so a RAW reset since the last
    // refresh is not taken as uploaded.
    let uploadedAlternatePhotos = Self.verifiedAlternatePhotoAssetIDs(
      in: await manifestStore.allRecords(), accountEmail: accountEmail)
    return await Task.detached(priority: .userInitiated) {
      Self.librarySnapshot(
        for: ids, readsAlbums: readsAlbums, uploadedAlternatePhotos: uploadedAlternatePhotos,
        needsUneditedOriginals: needsUneditedOriginals)
    }.value
  }

  /// Assets whose RAW record is uploaded to this account: sent, by this account, with a
  /// media key, under the ID the scan gives an asset's RAW.
  private nonisolated static func verifiedAlternatePhotoAssetIDs(
    in records: [TransferRecord],
    accountEmail: String
  ) -> Set<String> {
    var assetIDs = Set<String>()
    for record in records where record.resourceRole == .alternatePhoto && record.status == .sent {
      guard let assetID = record.assetLocalIdentifier,
        record.id
          == TransferRecord.alternatePhotoID(
            forPrimaryID: TransferRecord.accountScopedID(assetID, accountEmail: accountEmail)),
        record.sentAccountEmails.contains(accountEmail),
        let mediaKey = record.mediaKeysByAccount[accountEmail], !mediaKey.isEmpty
      else { continue }
      assetIDs.insert(assetID)
    }
    return assetIDs
  }

  /// Album membership costs one query per asset, so it is only read while some album
  /// is protected. Every frame of each burst involved is listed, so the planner can
  /// keep a burst whole.
  private nonisolated static func librarySnapshot(
    for identifiers: [String],
    readsAlbums: Bool,
    uploadedAlternatePhotos: Set<String>,
    needsUneditedOriginals: Bool
  ) -> LibrarySnapshot {
    var snapshot = LibrarySnapshot()
    guard !identifiers.isEmpty else { return snapshot }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: AssetExportService.allFramesFetchOptions())
    snapshot.facts.reserveCapacity(assets.count)
    for index in 0..<assets.count {
      let asset = assets.object(at: index)
      var albumIDs = Set<String>()
      if readsAlbums {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        for collectionIndex in 0..<collections.count {
          albumIDs.insert(collections.object(at: collectionIndex).localIdentifier)
        }
      }
      let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
      let resources = PHAssetResource.assetResources(for: asset)
      let rawIsUploaded = uploadedAlternatePhotos.contains(asset.localIdentifier)
      let burstIdentifier = asset.burstIdentifier
      if let burstIdentifier, snapshot.burstMembers[burstIdentifier] == nil {
        let frames = PHAsset.fetchAssets(withBurstIdentifier: burstIdentifier, options: AssetExportService.allFramesFetchOptions())
        var members = Set<String>()
        for frameIndex in 0..<frames.count {
          members.insert(frames.object(at: frameIndex).localIdentifier)
        }
        snapshot.burstMembers[burstIdentifier] = members
      }
      snapshot.facts[asset.localIdentifier] = LibraryAssetFacts(
        localIdentifier: asset.localIdentifier,
        albumIDs: albumIDs,
        isFavorite: asset.isFavorite,
        modificationDate: asset.modificationDate,
        isLivePhoto: isLivePhoto,
        hasUnuploadedResources: resources.contains {
          $0.type == .alternatePhoto ? !rawIsUploaded : !Self.isUploadedResource($0.type, isLivePhoto: isLivePhoto)
        },
        hasAlternatePhoto: AssetExportService.alternatePhotoResource(in: resources) != nil,
        needsUneditedOriginal: needsUneditedOriginals && asset.hasAdjustments,
        burstIdentifier: burstIdentifier,
        canDelete: asset.canPerform(.delete)
      )
    }
    return snapshot
  }

  /// Resource types `AssetExportService` and the Live Photo export send, plus edit
  /// bookkeeping whose rendered result is what gets uploaded. The RAW of a RAW+JPEG pair
  /// is checked against its own record by the caller; anything else, such as an unknown
  /// future type, exists only on this device.
  private nonisolated static func isUploadedResource(_ type: PHAssetResourceType, isLivePhoto: Bool) -> Bool {
    switch type {
    case .photo, .fullSizePhoto, .video, .fullSizeVideo, .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo, .photoProxy:
      true
    // Motion is checked against the record's paired hash; without the Live subtype the
    // uploader never sends it.
    case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
      isLivePhoto
    default:
      false
    }
  }

  /// Removes what `plan` lists after re-checking each item: staged copies and folder
  /// files through the verified file path, library assets in a single PhotoKit request
  /// so the system asks once. A declined or failed request leaves every record as it was.
  public func performCleanup(plan: CleanupPlan) async {
    await withAccountWork { await self.applyCleanup(plan: plan) }
  }

  private func applyCleanup(plan: CleanupPlan) async {
    guard !Task.isCancelled, !isCleaningUp else { return }
    isCleaningUp = true
    defer { isCleaningUp = false }
    cleanupMessage = nil
    await recoverDeletionTombstones()
    guard settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email else { return }
    // The plan may be minutes old; only what is still eligible now goes ahead.
    let current = await eligibleCleanupRecords(accountEmail: accountEmail)
    let stagedIDs = Set(current.staged.map(\.id))
    let folderIDs = Set(current.folder.map(\.id))
    let libraryIDs = Set(current.library.map(\.id))
    let files = await removeStagedCopies(plan.stagedRecords.filter { stagedIDs.contains($0.id) }, accountEmail: accountEmail)
    let folderFiles = await removeFolderFiles(plan.folderRecords.filter { folderIDs.contains($0.id) }, accountEmail: accountEmail)
    let library = await deleteLibraryAssets(
      plan.libraryRecords.filter { libraryIDs.contains($0.id) }, accountEmail: accountEmail)
    await refreshRecords()

    let removed = files.removed + folderFiles.removed + library.removedCount
    let failed = files.failed + folderFiles.failed
    switch library {
    case .failed(let reason):
      cleanupMessage = String(localized: "Couldn't remove photos from this iPhone. \(reason)")
    case .cancelled where removed == 0:
      break
    case .cancelled, .removed:
      if failed > 0 {
        cleanupMessage = String(localized: "Removed \(removed) items from this iPhone; \(failed) couldn't be removed.")
      } else if removed > 0 {
        cleanupMessage = String(
          localized:
            "Removed \(removed) items from this iPhone. They stay in Google Photos; deleted photos go to Recently Deleted for 30 days."
        )
      } else {
        cleanupMessage = String(localized: "Nothing to clean up right now.")
      }
    }
    scheduleCleanupRekey(files.deletedRecords + folderFiles.deletedRecords + library.deletedRecords, accountEmail: accountEmail)
  }

  private func scheduleCleanupRekey(_ records: [TransferRecord], accountEmail: String) {
    guard !records.isEmpty, canUseSelectedAccount,
      let cloudLibrary, cloudLibrary.accountEmail == accountEmail
    else { return }
    LibraryIndexer.scheduleRekeyDeleted(records, cloud: cloudLibrary)
  }

  private struct FileCleanupResult {
    var failed = 0
    var deletedRecords: [TransferRecord] = []
    var removed: Int { deletedRecords.count }
  }

  /// Staged copies are the app's own files, so they need no prompt.
  private func removeStagedCopies(_ records: [TransferRecord], accountEmail: String) async -> FileCleanupResult {
    guard !records.isEmpty else { return FileCleanupResult() }
    var result = FileCleanupResult()
    let roots = stagedSourceRoots()
    let files = await Task.detached(priority: .utility) { () -> [(id: String, url: URL)] in
      records.compactMap { record in
        guard record.sharedEntryID == nil,
          let sourcePath = record.sourcePath,
          let fileURL = Self.validatedSourceFileURL(atPath: sourcePath, roots: roots)
        else { return nil }
        return (record.id, fileURL)
      }
    }.value
    let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for file in files {
      guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else { break }
      guard await manifestStore.claimForDeletion(id: file.id) else { continue }
      if let record = recordsByID[file.id] { await KeptThumbnails.keep(record, fileURL: file.url) }
      guard !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail else {
        await manifestStore.releaseDeletionClaim(id: file.id)
        break
      }
      if await manifestStore.deleteSourceFiles(id: file.id, fileURL: file.url) {
        DeletionFailureBackoff.clear(file.id)
        if let record = recordsByID[file.id] { result.deletedRecords.append(record) }
      } else {
        result.failed += 1
        DeletionFailureBackoff.recordFailure(file.id)
      }
    }
    return result
  }

  private enum LibraryDeletion {
    case removed(count: Int, records: [TransferRecord])
    case cancelled
    case failed(String)

    var removedCount: Int {
      if case .removed(let count, _) = self { return count }
      return 0
    }

    var deletedRecords: [TransferRecord] {
      if case .removed(_, let records) = self { return records }
      return []
    }
  }

  /// Claims every record, re-reads the library so nothing edited, newly favorited or
  /// added to a protected album since planning is touched, and marks the survivors
  /// deleted before the one PhotoKit request. An asset goes only if every record it
  /// needs (its RAW, the rest of its burst) was marked too. Any error, including the
  /// user declining the system prompt, restores every record and releases every claim.
  private func deleteLibraryAssets(_ records: [TransferRecord], accountEmail: String) async -> LibraryDeletion {
    let prefix = "\(accountEmail)|"
    var claimed: [TransferRecord] = []
    for record in records
    where record.id.hasPrefix(prefix) && record.sourcePath == nil && record.assetLocalIdentifier != nil {
      guard !Task.isCancelled, allowsAccountWork else { break }
      if await manifestStore.claimForDeletion(id: record.id) { claimed.append(record) }
    }
    guard !claimed.isEmpty else { return .removed(count: 0, records: []) }

    let snapshot = await readLibrarySnapshot(for: claimed, accountEmail: accountEmail)
    let confirmed = planLibraryRecords(claimed, snapshot: snapshot, bytesNeeded: nil).map(\.id)
    var markedIDs = Set<String>()
    if !Task.isCancelled, allowsAccountWork, selectedAccount?.email == accountEmail {
      markedIDs = await manifestStore.markDeleted(ids: confirmed)
    }
    // A record the store refused to mark takes its whole asset, and burst, back out.
    let complete = Set(
      planLibraryRecords(claimed.filter { markedIDs.contains($0.id) }, snapshot: snapshot, bytesNeeded: nil).map(\.id))
    let incomplete = markedIDs.subtracting(complete)
    if !incomplete.isEmpty {
      let restoreIDs = Array(incomplete)
      if !(await manifestStore.restoreSent(ids: restoreIDs)) {
        await manifestStore.restoreSent(ids: restoreIDs)
      }
      markedIDs = complete
    }
    for record in claimed where !markedIDs.contains(record.id) {
      await manifestStore.releaseDeletionClaim(id: record.id)
    }
    let marked = claimed.filter { markedIDs.contains($0.id) }
    guard !marked.isEmpty else { return .removed(count: 0, records: []) }

    // An asset's primary and RAW records name it once.
    var seen = Set<String>()
    let identifiers = marked.compactMap(\.assetLocalIdentifier).filter { seen.insert($0).inserted }
    // The library keeps showing these from Google Photos with a thumbnail kept here.
    await KeptThumbnails.keepAll(marked, accountEmail: accountEmail)
    do {
      try Task.checkCancellation()
      guard allowsAccountWork, selectedAccount?.email == accountEmail else { throw CancellationError() }
      try await Self.removeFromPhotoLibrary(identifiers)
    } catch {
      // A second failure is left for the launch reconcile, which sees the asset still
      // in the library and restores the record then.
      let restoreIDs = marked.map(\.id)
      if !(await manifestStore.restoreSent(ids: restoreIDs)) {
        await manifestStore.restoreSent(ids: restoreIDs)
      }
      for record in marked {
        await manifestStore.releaseDeletionClaim(id: record.id)
      }
      let nsError = error as NSError
      let declined =
        error is CancellationError || (nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.userCancelled.rawValue)
        || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
      return declined ? .cancelled : .failed(error.localizedDescription)
    }
    for record in marked {
      await manifestStore.releaseDeletionClaim(id: record.id)
    }
    return .removed(count: identifiers.count, records: marked)
  }

  /// Formed off the main actor: PhotoKit runs the change block on its own queue.
  @concurrent
  private nonisolated static func removeFromPhotoLibrary(_ identifiers: [String]) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.deleteAssets(
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: AssetExportService.allFramesFetchOptions()))
    }
  }

  // MARK: - Automatic cleanup

  /// After a batch or background pass: staged copies and verified files in backed-up
  /// folders go without asking; library items
  /// need the system prompt, so the user is invited at most once per quiet period (a
  /// notification in the background, the in-app prompt in the foreground). Reading the
  /// library is the expensive part, so it runs at most hourly and only when the set of
  /// eligible records changed, unless the quiet period has passed since the last plan.
  public func runCleanupMaintenance() async {
    await withAccountWork(wake: ("cleanup", { [weak self] in await self?.runCleanupMaintenance() })) {
      await self.applyCleanupMaintenance()
    }
  }

  private func applyCleanupMaintenance() async {
    guard !isRunningCleanupMaintenance, !isCleaningUp, !isRunning, !Task.isCancelled,
      settings.autoDeleteDelay != .never, let accountEmail = selectedAccount?.email
    else { return }
    isRunningCleanupMaintenance = true
    var deletedRecords: [TransferRecord] = []
    defer {
      isRunningCleanupMaintenance = false
      scheduleCleanupRekey(deletedRecords, accountEmail: accountEmail)
    }

    await recoverDeletionTombstones()
    let eligible = await eligibleCleanupRecords(accountEmail: accountEmail)
    if !eligible.staged.isEmpty || !eligible.folder.isEmpty {
      let staged = await removeStagedCopies(eligible.staged, accountEmail: accountEmail)
      let folders = await removeFolderFiles(eligible.folder, accountEmail: accountEmail)
      deletedRecords = staged.deletedRecords + folders.deletedRecords
      await refreshRecords()
    }
    let library = eligible.library
    guard isAuthorized, !library.isEmpty, !Task.isCancelled else { return }
    let isForeground = UIApplication.shared.applicationState == .active
    guard cleanupAnnouncementMayBeDue(upTo: library.count, isForeground: isForeground) else { return }
    let planKey = Self.cleanupPlanKey(for: library)
    guard libraryPlanIsDue(key: planKey) else { return }

    let bytesNeeded: Int64? = settings.smartDeleteEnabled ? await manifestStore.bytesNeededToRecover() : nil
    let planned = await planLibraryRecords(library, accountEmail: accountEmail, bytesNeeded: bytesNeeded)
    // A RAW+JPEG asset has two records but is one photo.
    let plannedAssetCount = Set(planned.compactMap(\.assetLocalIdentifier)).count
    let isForegroundNow = UIApplication.shared.applicationState == .active
    guard !planned.isEmpty, !Task.isCancelled, !isCleaningUp,
      settings.autoDeleteDelay != .never, selectedAccount?.email == accountEmail,
      cleanupAnnouncementMayBeDue(upTo: plannedAssetCount, isForeground: isForegroundNow)
    else { return }
    recordCleanupAnnouncement(count: plannedAssetCount)
    if isForegroundNow {
      pendingCleanupPrompt = true
    } else {
      let bytes = planned.reduce(Int64(0)) { $0 + max(0, $1.byteCount ?? 0) }
      await Self.postCleanupNotification(count: plannedAssetCount, bytes: bytes)
    }
  }

  private enum CleanupAnnouncement {
    static let dateKey = "cleanupAnnouncementDate"
    static let countKey = "cleanupAnnouncementCount"
    static let planDateKey = "cleanupPlanDate"
    static let planKeyKey = "cleanupPlanKey"
    static let quietPeriod: TimeInterval = 24 * 60 * 60
    static let planInterval: TimeInterval = 60 * 60
    static let notificationID = "cleanup-due"
    static let action = "cleanup"
  }

  /// Checked before the library is read, with the eligible count as an upper bound on
  /// what a plan could find. The in-app prompt is shown once per quiet period; a
  /// notification may come sooner when more items have become due.
  private func cleanupAnnouncementMayBeDue(upTo maximumCount: Int, isForeground: Bool) -> Bool {
    let defaults = UserDefaults.standard
    guard let last = defaults.object(forKey: CleanupAnnouncement.dateKey) as? Date,
      Date().timeIntervalSince(last) < CleanupAnnouncement.quietPeriod
    else { return true }
    return !isForeground && maximumCount > defaults.integer(forKey: CleanupAnnouncement.countKey)
  }

  private func recordCleanupAnnouncement(count: Int) {
    let defaults = UserDefaults.standard
    defaults.set(Date(), forKey: CleanupAnnouncement.dateKey)
    defaults.set(count, forKey: CleanupAnnouncement.countKey)
  }

  /// Persisted, since background launches start a fresh process. An unchanged set is
  /// re-planned once the quiet period passes so the same items are offered again daily.
  private func libraryPlanIsDue(key: String) -> Bool {
    let defaults = UserDefaults.standard
    if let last = defaults.object(forKey: CleanupAnnouncement.planDateKey) as? Date {
      let age = Date().timeIntervalSince(last)
      if age < CleanupAnnouncement.planInterval { return false }
      if age < CleanupAnnouncement.quietPeriod, defaults.string(forKey: CleanupAnnouncement.planKeyKey) == key {
        return false
      }
    }
    defaults.set(Date(), forKey: CleanupAnnouncement.planDateKey)
    defaults.set(key, forKey: CleanupAnnouncement.planKeyKey)
    return true
  }

  /// Stable across launches, unlike `Hasher`.
  private static func cleanupPlanKey(for records: [TransferRecord]) -> String {
    let joined = records.map(\.id).sorted().joined(separator: "\n")
    return Data(SHA256.hash(data: Data(joined.utf8))).base64EncodedString()
  }

  private nonisolated static func postCleanupNotification(count: Int, bytes: Int64) async {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "\(count) backed-up photos are ready to remove")
    content.body = String(localized: "Tap to free up about \(ByteFormat.string(bytes)) on this iPhone.")
    content.userInfo = ["action": CleanupAnnouncement.action]
    let request = UNNotificationRequest(identifier: CleanupAnnouncement.notificationID, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }

  /// Whether a notification's payload asks for the cleanup flow.
  public nonisolated static func isCleanupNotification(userInfo: [AnyHashable: Any]) -> Bool {
    userInfo["action"] as? String == CleanupAnnouncement.action
  }

  // MARK: - Protected items

  public func userAlbums() async -> [AlbumSummary] {
    guard isAuthorized else { return [] }
    return await Task.detached(priority: .userInitiated) { Self.fetchUserAlbums() }.value
  }

  /// User-created albums, the same set album mirroring uses.
  private nonisolated static func fetchUserAlbums() -> [AlbumSummary] {
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
    var albums: [AlbumSummary] = []
    for index in 0..<collections.count {
      let collection = collections.object(at: index)
      guard
        collection.assetCollectionSubtype == .albumRegular
          || collection.assetCollectionSubtype == .albumImported
      else { continue }
      let estimated = collection.estimatedAssetCount
      let count = estimated == NSNotFound ? PHAsset.fetchAssets(in: collection, options: nil).count : estimated
      let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      albums.append(
        AlbumSummary(
          id: collection.localIdentifier,
          title: title.isEmpty ? String(localized: "Untitled Album") : title,
          count: count
        ))
    }
    return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  public func setAlbumExcluded(_ albumID: String, _ isExcluded: Bool) {
    var copy = settings
    if isExcluded {
      copy.excludedAlbumIDs.insert(albumID)
    } else {
      copy.excludedAlbumIDs.remove(albumID)
    }
    guard copy != settings else { return }
    updateSettings(copy)
  }

  public func setAlbumProtected(_ albumID: String, _ isProtected: Bool) {
    var copy = settings
    if isProtected {
      copy.protectedAlbumIDs.insert(albumID)
    } else {
      copy.protectedAlbumIDs.remove(albumID)
    }
    guard copy != settings else { return }
    updateSettings(copy)
  }

  public func setProtectsFavorites(_ protects: Bool) {
    guard settings.protectsFavorites != protects else { return }
    var copy = settings
    copy.protectsFavorites = protects
    updateSettings(copy)
  }

  /// Protects a folder picked in the Files app: nothing inside it is ever removed.
  public func addIgnoredFolder(_ url: URL) {
    let location = FolderBackup.makeIgnoredFolder(from: url)
    var copy = settings
    if let index = copy.ignoredFolders.firstIndex(where: { $0.path == location.path }) {
      if let bookmark = location.bookmarkData { copy.ignoredFolders[index].bookmarkData = bookmark }
    } else {
      copy.ignoredFolders.append(location)
    }
    guard copy != settings else { return }
    updateSettings(copy)
  }

  public func removeIgnoredFolder(_ id: String) {
    var copy = settings
    copy.ignoredFolders.removeAll { $0.id == id }
    guard copy != settings else { return }
    updateSettings(copy)
  }

  // MARK: - Backed-up folders

  public var hasEnabledFolders: Bool {
    backedUpFolders.contains(where: \.isEnabled)
  }

  public func status(of folder: BackedUpFolder) -> BackedUpFolderStatus {
    if foldersNeedingAccess.contains(folder.id) { return .needsAccess }
    if !folder.isEnabled || !settings.autoSyncEnabled || stopRequested { return .paused }
    if selectedAccount == nil { return .waitingForSignIn }
    return .backingUp
  }

  /// Adds a folder picked in the Files app. Returns why it was refused, if it was.
  public func addBackedUpFolder(_ url: URL) async -> String? {
    let made = await makeBackedUpFolder(from: url, comparingWith: backedUpFolders)
    let folder: BackedUpFolder
    switch made {
    case .failure(let error): return error.message
    case .success(let value): folder = value
    }
    guard !backedUpFolders.contains(where: { $0.id == folder.id }) else {
      return FolderAdditionError.duplicate.message
    }
    backedUpFolders.append(folder)
    FolderBackup.save(backedUpFolders)
    refreshFolderRootPaths()
    await folderListDidChange(scans: true)
    return nil
  }

  /// The entry for a picked folder, refused as a duplicate when it is one of `others`
  /// under another spelling or through a link. Both steps touch the file system.
  private func makeBackedUpFolder(from url: URL, comparingWith others: [BackedUpFolder]) async -> FolderAddition {
    let existing = others.map { (folder: $0, resolved: resolvedFolderRoots[$0.id]) }
    return await Task.detached(priority: .userInitiated) {
      FolderBackup.makeFolder(from: url).flatMap { folder -> FolderAddition in
        let started = url.startAccessingSecurityScopedResource()
        defer {
          if started { url.stopAccessingSecurityScopedResource() }
        }
        return FolderBackup.isDuplicate(url, of: existing) ? .failure(.duplicate) : .success(folder)
      }
    }.value
  }

  /// "Choose Again…" for a folder whose access was lost: the picked folder takes the
  /// entry's place and keeps its on/off state.
  public func reauthorizeBackedUpFolder(id: String, url: URL) async -> String? {
    let made = await makeBackedUpFolder(from: url, comparingWith: backedUpFolders.filter { $0.id != id })
    var replacement: BackedUpFolder
    switch made {
    case .failure(let error): return error.message
    case .success(let value): replacement = value
    }
    guard let index = backedUpFolders.firstIndex(where: { $0.id == id }) else { return nil }
    if replacement.id != id, backedUpFolders.contains(where: { $0.id == replacement.id }) {
      return FolderAdditionError.duplicate.message
    }
    replacement.isEnabled = backedUpFolders[index].isEnabled
    backedUpFolders[index] = replacement
    if replacement.id != id {
      folderGeneration += 1
      resolvedFolderRoots[id] = nil
      foldersNeedingAccess.remove(id)
    }
    FolderBackup.save(backedUpFolders)
    refreshFolderRootPaths()
    await folderListDidChange(scans: replacement.isEnabled)
    return nil
  }

  /// Stops backing up a folder. Its files and their records stay; files outside every
  /// enabled folder are never removed.
  public func removeBackedUpFolder(id: String) {
    folderGeneration += 1
    backedUpFolders.removeAll { $0.id == id }
    resolvedFolderRoots[id] = nil
    foldersNeedingAccess.remove(id)
    FolderBackup.save(backedUpFolders)
    refreshFolderRootPaths()
    // A running batch keeps its scopes until it finishes reading the files.
    releaseFolderUploadAccessIfIdle()
  }

  public func setFolderEnabled(id: String, isEnabled: Bool) {
    guard let index = backedUpFolders.firstIndex(where: { $0.id == id }),
      backedUpFolders[index].isEnabled != isEnabled
    else { return }
    if !isEnabled { folderGeneration += 1 }
    backedUpFolders[index].isEnabled = isEnabled
    FolderBackup.save(backedUpFolders)
    refreshFolderRootPaths()
    if isEnabled {
      Task { await folderListDidChange(scans: true) }
    }
  }

  /// A new or newly enabled folder is scanned at once while auto-sync is on; otherwise
  /// only its access is checked, so the list can show "Needs Access".
  private func folderListDidChange(scans: Bool) async {
    if scans, settings.autoSyncEnabled, !stopRequested, selectedAccount != nil {
      await syncFoldersAutomatically()
    } else {
      await refreshFolderStatus()
    }
  }

  /// Re-resolves every folder's bookmark to find the ones that need access again.
  public func refreshFolderStatus() async {
    let folders = backedUpFolders
    guard !folders.isEmpty else { return }
    let accesses = await Task.detached(priority: .utility) { () -> [FolderAccess] in
      let accesses = FolderBackup.beginAccess(folders)
      FolderBackup.endAccess(accesses)
      return accesses
    }.value
    applyFolderAccesses(accesses)
  }

  /// Records where each folder resolved, which ones need access again, and any stale
  /// bookmark that was recreated, if the folder still holds the one it replaced.
  private func applyFolderAccesses(_ accesses: [FolderAccess]) {
    var needing = foldersNeedingAccess
    var bookmarksChanged = false
    let previousRoots = resolvedFolderRoots
    for access in accesses {
      if let url = access.readableURL {
        resolvedFolderRoots[access.folderID] = url
        needing.remove(access.folderID)
      } else {
        resolvedFolderRoots[access.folderID] = nil
        needing.insert(access.folderID)
      }
      if let refreshed = access.refreshedBookmark,
        let index = backedUpFolders.firstIndex(where: { $0.id == access.folderID }),
        backedUpFolders[index].bookmarkData == access.previousBookmark
      {
        backedUpFolders[index].bookmarkData = refreshed
        bookmarksChanged = true
      }
    }
    needing.formIntersection(backedUpFolders.map(\.id))
    if needing != foldersNeedingAccess { foldersNeedingAccess = needing }
    if bookmarksChanged { FolderBackup.save(backedUpFolders) }
    if resolvedFolderRoots != previousRoots { refreshFolderRootPaths() }
  }

  /// Rebuilds `folderRootPaths`: the plain spellings at once, so no check in between
  /// misses a folder, then the link-resolved set once it is worked out.
  private func refreshFolderRootPaths() {
    let all = allFolderLocations()
    let enabled = enabledFolderLocations()
    folderRootPaths = FolderRootPaths(
      all: FolderBackup.rootPaths(all, resolvesSymlinks: false),
      enabled: FolderBackup.rootPaths(enabled, resolvesSymlinks: false)
    )
    folderRootPathsGeneration &+= 1
    let generation = folderRootPathsGeneration
    Task { @MainActor [weak self] in
      let resolved = await Task.detached(priority: .utility) {
        FolderRootPaths(all: FolderBackup.rootPaths(all), enabled: FolderBackup.rootPaths(enabled))
      }.value
      guard let self, generation == self.folderRootPathsGeneration else { return }
      self.folderRootPaths = resolved
    }
  }

  /// Enabled folders as last resolved. A folder that hasn't resolved yet, or needs
  /// access, contributes nothing.
  private func enabledFolderRoots() -> [URL] {
    backedUpFolders.filter(\.isEnabled).compactMap { resolvedFolderRoots[$0.id] }
  }

  /// Every location an enabled folder may be known by, for path checks that must not
  /// resolve bookmarks.
  private func enabledFolderLocations() -> [URL] {
    folderLocations(backedUpFolders.filter(\.isEnabled))
  }

  private func allFolderLocations() -> [URL] {
    folderLocations(backedUpFolders)
  }

  private func folderLocations(_ folders: [BackedUpFolder]) -> [URL] {
    folders.flatMap { folder in
      [URL(fileURLWithPath: folder.path, isDirectory: true)] + (resolvedFolderRoots[folder.id].map { [$0] } ?? [])
    }
  }

  /// Background passes, foreground activation and folder changes. Sync Now calls
  /// `syncFolders()` directly, so it also scans while auto-sync is off.
  private func syncFoldersAutomatically(using foregroundRead: FolderMediaScanner.ForegroundRead? = nil) async {
    guard !stopRequested, settings.autoSyncEnabled else { return }
    await syncFolders(using: foregroundRead)
  }

  private func resumeRequestedFolderScan() async {
    guard folderRescanRequested, !stopRequested, !Task.isCancelled, selectedAccount != nil, !isScanningFolders,
      !workerPool.isRunning, !workerPool.isBatchFinalizing
    else { return }
    await syncFolders()
  }

  /// Scans every enabled folder off the main actor and queues what isn't backed up yet,
  /// with the same identity rules as the Mac's watched folders. The scan's folder scopes
  /// are handed to the upload batch, which reads the files in place.
  public func syncFolders(
    resumingOnly: Bool = false, using foregroundRead: FolderMediaScanner.ForegroundRead? = nil
  ) async {
    let wake: AccountWake = (
      resumingOnly ? "folderResume" : "folderScan",
      { [weak self] in await self?.syncFolders(resumingOnly: resumingOnly) }
    )
    guard !replaysAfterAccountChange(wake) else { return }
    guard canUseSelectedAccount, !stopRequested, !Task.isCancelled, let account = selectedAccount else { return }
    let enabled = backedUpFolders.filter(\.isEnabled)
    guard !enabled.isEmpty else { return }
    // A resume never asks for a full scan: that would find new files with Auto-Sync off, and
    // the lost-network retry runs the resume again anyway.
    guard !isScanningFolders else {
      if !resumingOnly { folderRescanRequested = true }
      return
    }
    isScanningFolders = true
    folderRescanRequested = false
    let generation = accountGeneration
    let folderGeneration = self.folderGeneration
    defer {
      isScanningFolders = false
      if !stopRequested {
        replayInterruptedFolderScan(accountEmail: account.email, generation: generation, wake: wake)
      }
      // A request made while the pool is busy is resumed when its batch completes.
      if folderRescanRequested, !stopRequested, !workerPool.isRunning, !workerPool.isBatchFinalizing {
        folderRescanRequested = false
        Task { @MainActor [weak self] in
          await self?.syncFolders()
        }
      }
    }
    let exclusions = settings.folderExclusions
    let scanTask = Task.detached(priority: .utility) { () -> FolderScanResult in
      let accesses = FolderBackup.beginAccess(enabled)
      let media = await FolderBackup.collectMedia(in: accesses, excluding: exclusions, using: foregroundRead)
      return FolderScanResult(accesses: accesses, media: media)
    }
    // A detached task does not inherit cancellation. Cancelled, it still returns the
    // accesses it took, so every one of them is ended below.
    let scan = await withTaskCancellationHandler {
      await scanTask.value
    } onCancel: {
      scanTask.cancel()
    }
    var heldAccesses = scan.accesses
    defer { FolderBackup.endAccess(heldAccesses) }
    applyFolderAccesses(scan.accesses)
    guard canUseSelectedAccount, !stopRequested, !Task.isCancelled, accountGeneration == generation,
      self.folderGeneration == folderGeneration, selectedAccount?.email == account.email
    else {
      if !stopRequested, self.folderGeneration != folderGeneration, !resumingOnly {
        folderRescanRequested = true
      }
      return
    }
    if scan.media.deferredRecentWrites, !resumingOnly {
      scheduleDeferredFolderRescan()
    } else {
      deferredFolderRescanDelay = FolderMediaScanner.writeSettleInterval
    }
    await removeUnfinishedFolderRecordsWithoutFile(
      accountEmail: account.email, accesses: scan.accesses, scannedFiles: scan.media.files, exclusions: exclusions)
    guard !scan.media.files.isEmpty else { return }
    if await queueFolderFiles(
      scan.media.files,
      accountEmail: account.email,
      generation: generation,
      folderGeneration: folderGeneration,
      accesses: scan.accesses,
      resumingOnly: resumingOnly
    ) {
      heldAccesses = []
    }
  }

  /// A pending or failed folder file that's gone, or that iCloud has since moved off this
  /// device, is never picked up by a scan, and would wait forever with nothing to act on.
  /// Neither status proves an upload, and the file gets a new record if it comes back.
  /// Also drops items queued from what the rules now leave out: nothing was sent.
  private func removeUnfinishedFolderRecordsWithoutFile(
    accountEmail: String, accesses: [FolderAccess], scannedFiles: [LocalMediaFile], exclusions: FolderExclusions
  ) async {
    let roots = accesses.compactMap(\.readableURL)
    let prefix = "\(accountEmail)|"
    let candidates = records.filter {
      ($0.status == .pending || $0.status == .failed) && $0.sourcePath != nil && $0.id.hasPrefix(prefix)
    }
    guard !roots.isEmpty, !candidates.isEmpty else { return }
    let rootPaths = FolderBackup.rootPaths(roots)
    let gone = await Task.detached(priority: .utility) {
      // The scan just listed these folders; only what it didn't list needs looking at.
      let scanned = Set(scannedFiles.map { FolderBackup.comparisonKey($0.url.path) })
      return candidates.filter { record in
        guard let path = record.sourcePath, !scanned.contains(FolderBackup.comparisonKey(path)),
          FolderBackup.isPath(path, insideAny: rootPaths)
        else { return false }
        let url = URL(fileURLWithPath: path)
        if roots.contains(where: { exclusions.excludes(url, below: $0) }) { return true }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
          .ubiquitousItemDownloadingStatus
        return status != nil && status != .current
      }
    }.value
    guard !gone.isEmpty else { return }
    for record in gone { await manifestStore.removeIfUnfinished(id: record.id) }
    await refreshRecords()
  }

  /// Returns whether `accesses` were handed to the upload batch, which then owns them.
  private func queueFolderFiles(
    _ files: [LocalMediaFile],
    accountEmail: String,
    generation: Int,
    folderGeneration: Int,
    accesses: [FolderAccess],
    resumingOnly: Bool = false
  ) async -> Bool {
    func isCurrent() -> Bool {
      canUseSelectedAccount && !stopRequested && !Task.isCancelled && accountGeneration == generation
        && self.folderGeneration == folderGeneration && selectedAccount?.email == accountEmail
    }
    let currentRecords = await manifestStore.allRecords()
    guard isCurrent() else { return false }
    let pairLivePhotos = settings.pairLivePhotos
    let createAlbumsFromFolders = settings.createAlbumsFromFolders
    let retriesFailedNow = retriesFolderFailuresNow
    retriesFolderFailuresNow = false
    defer {
      if retriesFailedNow, !stopRequested, shouldReplayFolderScan(accountEmail: accountEmail, generation: generation) {
        retriesFolderFailuresNow = true
      }
    }
    // Matching a whole folder tree against the manifest and pairing Live Photos (which
    // stats every candidate) must not block the main actor.
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
    guard isCurrent(), !plan.items.isEmpty else { return false }
    var planned = plan.items
    if resumingOnly {
      // Only what was already on its way: finding new files is for Auto-Sync.
      let pending = Set(currentRecords.filter { $0.status == .pending }.map(\.id))
      planned = planned.filter { pending.contains($0.id) }
    } else {
      guard await manifestStore.upsertBatch(plan.newRecords) else { return false }
    }
    guard isCurrent() else { return false }
    let claimedIDs = await manifestStore.claimForUpload(ids: planned.map(\.id))
    let claimedItems = planned.filter { claimedIDs.contains($0.id) }
    await refreshRecords()
    guard isCurrent(), !claimedItems.isEmpty else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      return false
    }
    workerPool.setConcurrency(settings.uploadThreads)
    guard isCurrent() else {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      return false
    }
    // A running batch for this account takes the items in; one that is finishing
    // refuses them, and they are picked up once it has.
    if workerPool.start(items: claimedItems, quality: 3, accountEmail: accountEmail) == .rejected {
      await manifestStore.releaseUploadClaims(ids: claimedItems.map(\.id))
      if !stopRequested, !resumingOnly { folderRescanRequested = true }
      return false
    }
    folderUploadAccesses.append(contentsOf: accesses)
    return true
  }

  /// Ends the folder scopes held for uploads once no batch can still read the files.
  private func releaseFolderUploadAccessIfIdle() {
    guard !folderUploadAccesses.isEmpty, !workerPool.isRunning, !workerPool.isBatchFinalizing else { return }
    FolderBackup.endAccess(folderUploadAccesses)
    folderUploadAccesses.removeAll()
  }

  /// Files still being written are skipped by a scan; this picks them up once they have
  /// settled. A newer deferral replaces the pending one, and each consecutive one waits
  /// twice as long.
  private func scheduleDeferredFolderRescan() {
    deferredFolderRescanTask?.cancel()
    let delay = deferredFolderRescanDelay
    deferredFolderRescanDelay = min(delay * 2, Self.maxDeferredFolderRescanDelay)
    deferredFolderRescanTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.deferredFolderRescanTask = nil
      await self.syncFoldersAutomatically()
    }
  }

  // MARK: - Folder cleanup

  /// Opens every enabled folder and works out which of `records` may go: inside a
  /// readable folder, outside every protected folder, and within each volume's
  /// low-space budget. The caller must end the returned accesses.
  private func openFolderCleanup(_ records: [TransferRecord]) async -> FolderCleanupPass {
    let folders = backedUpFolders.filter(\.isEnabled)
    guard !records.isEmpty, !folders.isEmpty else { return FolderCleanupPass() }
    let ignored = settings.ignoredFolders
    let smartDelete = settings.smartDeleteEnabled
    let pass = await Task.detached(priority: .utility) { () -> FolderCleanupPass in
      let accesses = FolderBackup.beginAccess(folders)
      // A protected folder that can be found neither way could hold any of these files,
      // so nothing goes until it can be.
      guard let protectedPaths = IgnoredFolderLocation.protectedPaths(ignored) else {
        return FolderCleanupPass(accesses: accesses, items: [], ignoredFolders: ignored)
      }
      let items = FolderBackup.planCleanup(
        records: records,
        accesses: accesses,
        protectedPaths: protectedPaths,
        smartDelete: smartDelete
      )
      return FolderCleanupPass(accesses: accesses, items: items, ignoredFolders: ignored)
    }.value
    applyFolderAccesses(pass.accesses)
    return pass
  }

  /// Files are deleted without a prompt, so only verified uploads to this account go,
  /// through the store's tombstone-safe delete, while the folder's scope is held. The
  /// plan was checked off the main actor and the store re-verifies each file, so nothing
  /// here stats one. The pass stops if the folders or protected folders change
  /// underneath it.
  private func removeFolderFiles(_ records: [TransferRecord], accountEmail: String) async -> FileCleanupResult {
    let folderGeneration = self.folderGeneration
    let pass = await openFolderCleanup(records)
    defer { FolderBackup.endAccess(pass.accesses) }
    func planStillHolds() -> Bool {
      !Task.isCancelled && allowsAccountWork && selectedAccount?.email == accountEmail
        && settings.autoDeleteDelay != .never && settings.ignoredFolders == pass.ignoredFolders
        && self.folderGeneration == folderGeneration
    }
    var result = FileCleanupResult()
    for item in pass.items {
      guard planStillHolds() else { break }
      let id = item.record.id
      guard await manifestStore.claimForDeletion(id: id) else { continue }
      // Claiming suspends, and a folder may have been protected or removed meanwhile.
      guard planStillHolds() else {
        await manifestStore.releaseDeletionClaim(id: id)
        break
      }
      await KeptThumbnails.keep(item.record, fileURL: item.fileURL)
      let current = settings
      let isDue = await manifestStore.isStillDue(id: id, settings: current, accountEmail: accountEmail, accounts: accounts)
      guard isDue, settings == current, planStillHolds() else {
        await manifestStore.releaseDeletionClaim(id: id)
        break
      }
      let policy = cleanupPolicy.current
      if await manifestStore.deleteSourceFiles(
        id: id, fileURL: item.fileURL, pairedFileURL: item.pairedFileURL, mayRemove: cleanupPolicy.check(root: item.root))
      {
        DeletionFailureBackoff.clear(id)
        result.deletedRecords.append(item.record)
      } else if cleanupPolicy.current == policy {
        result.failed += 1
        DeletionFailureBackoff.recordFailure(id)
      }
    }
    return result
  }
}

private struct FolderScanResult: Sendable {
  let accesses: [FolderAccess]
  let media: MediaScan
}

private struct FolderCleanupPass: Sendable {
  var accesses: [FolderAccess] = []
  var items: [FolderCleanupItem] = []
  /// The protected folders the plan was checked against.
  var ignoredFolders: [IgnoredFolderLocation] = []
}

/// One side of a record whose file may have been set aside by an interrupted delete.
private struct TombstoneSide: Sendable {
  let recordID: String
  let path: String
  let size: Int64?
  let modifiedAt: Date?
}

private typealias FolderAddition = Result<BackedUpFolder, FolderAdditionError>

/// See `AppModel.folderRootPaths`.
private struct FolderRootPaths: Sendable {
  var all: [String] = []
  var enabled: [String] = []
}
