import CoreGraphics
import Foundation
import Observation
import Photos
import os

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Routes thumbnail requests to the photo library or Google Photos by id.
final class CompositeThumbnailSource: ThumbnailSource, Sendable {
  private let device: any ThumbnailSource
  private let cloud = OSAllocatedUnfairLock<(any ThumbnailSource)?>(initialState: nil)

  init(device: any ThumbnailSource) {
    self.device = device
    // The title's count is in the first frame; its noun's forms are worked out ahead of it,
    // off the main thread (the first agreement of a launch is the slow one).
    Task.detached(priority: .userInitiated) {
      for count in [1, 2] { _ = ProductCopy.inflected("^[\(count) Item](inflect: true)") }
    }
  }

  func setCloud(_ source: (any ThumbnailSource)?) { cloud.withLock { $0 = source } }

  private func source(for id: String) -> (any ThumbnailSource)? {
    if id.hasPrefix(FolderItemInfo.idPrefix) { return FolderLibrary.shared.thumbnails }
    return RemoteThumbnailID(id) != nil ? cloud.withLock { $0 } : device
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let source = source(for: id) else {
      onUnavailable()
      return .none
    }
    return source.requestImage(id: id, pixelSize: pixelSize, quality: quality, onUnavailable: onUnavailable, deliver: deliver)
  }

  func cachingTarget(for id: String) -> ThumbnailCachingTarget? {
    source(for: id)?.cachingTarget(for: id)
  }
}

/// The merged Library: this device's photos, the files in backed-up folders and the Google
/// Photos library in one timeline. Without a signed-in account it's the device's own.
@MainActor
@Observable
public final class UnifiedLibraryModel: MediaViewerSource {
  public let device: PhotoLibraryGridModel
  public private(set) var cloud: RemoteLibraryGridModel?
  public private(set) var entries: [UnifiedEntry] = []
  public private(set) var filter: LibraryFilter = .all
  public private(set) var reloadToken = 0
  /// Advances when the merged snapshot includes a new device or Google Photos revision.
  public private(set) var indexMetadataToken = 0
  @ObservationIgnored private var indexedMetadataSource: (device: Int, cloud: Int?) = (-1, nil)
  public private(set) var timeline = TimelineIndex()
  public private(set) var isLoaded = false
  /// The full snapshot is ready for indexing and pruning.
  public private(set) var hasMerged = false
  private(set) var hasResolvedFilter = false
  private(set) var displayedFilter: LibraryFilter = .all
  private(set) var hasPublishedCompleteTimeline = false
  public private(set) var mirrorReadFailed = false

  enum MirrorRetry {
    case empty, banner
  }

  var mirrorRetry: MirrorRetry? {
    guard mirrorReadFailed else { return nil }
    return itemCount == 0 ? .empty : .banner
  }
  /// An item Siri asked to show, by index id; the counter repeats a request for the same item.
  public private(set) var openRequest: (id: String, token: Int, madeAt: ContinuousClock.Instant)?
  @ObservationIgnored private var openRequestToken = 0

  public func requestOpen(indexID: String) {
    openRequestToken &+= 1
    openRequest = (indexID, openRequestToken, .now)
  }

  /// Clears a request the Library carried out (or gave up on), so it isn't repeated when
  /// the Library appears again.
  public func finishOpenRequest(token: Int) {
    if openRequest?.token == token { openRequest = nil }
  }

  /// The timeline position of an index id.
  public func position(ofIndexID id: String) -> Int? { positions[id] }
  /// Years, Months or All. Kept here so the iPhone tab bar's accessory can switch it.
  public var timelineMode: LibraryTimelineMode = .all {
    didSet { previousTimelineMode = oldValue }
  }
  /// The mode before the last change, for the zoom between the two. Read while the old
  /// view leaves, so it isn't tracked.
  @ObservationIgnored public private(set) var previousTimelineMode: LibraryTimelineMode = .all
  /// Whether the last change of `timelineMode` went closer (Years to Months to All).
  public var timelineZoomsIn: Bool { timelineMode.depth >= previousTimelineMode.depth }
  /// Bumped when Library is chosen again in the tab bar: the grid goes to the newest items.
  public private(set) var showNewestRequest = 0

  public func showNewest() { showNewestRequest &+= 1 }
  /// Select mode, which puts its own bar where the tab bar was.
  public var isSelecting = false
  /// The iPhone tab bar has shrunk with the scroll, which is when Photos shows
  /// Years / Months / All between Library and Search.
  public var isTabBarMinimized = false
  /// The All grid shows its newest row, where Photos grows the tab bar back.
  public var isAtNewest = true
  /// Whether Years / Months / All apply: the whole library, with something in it, and not
  /// while selecting.
  public var showsModes: Bool { filter == .all && itemCount > 0 && !isSelecting }
  private var mergeBadgeToken = 0
  @ObservationIgnored private let composite = CompositeThumbnailSource(device: PhotoKitImageSource.shared)
  @ObservationIgnored private var deviceInfos: [DeviceItemInfo] = []
  @ObservationIgnored private var mergedDevice: [DeviceItemInfo] = []
  @ObservationIgnored private var mergedFetch: PHFetchResult<PHAsset>?
  @ObservationIgnored private var mergedFetchIndices: [Int]?
  @ObservationIgnored private var deviceInfosToken = -1
  @ObservationIgnored private var hasFullPhotoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
  @ObservationIgnored private var preloadTask: Task<Void, Never>?
  @ObservationIgnored private var uploadedMediaKeys: [String: Set<String>] = [:]
  @ObservationIgnored private var uploadedSHA1s: [String: Set<Data>] = [:]
  @ObservationIgnored private var backup = PhotoBackupEvidence()
  @ObservationIgnored private var recordsGeneration = 0
  @ObservationIgnored private var hasRecords = false
  @ObservationIgnored private var primaryRecords: [TransferRecord] = []
  @ObservationIgnored private var accountReady = false
  @ObservationIgnored private var folderRecords: [String: [TransferRecord]] = [:]
  @ObservationIgnored private var mirrorKeys: Set<String> = []
  @ObservationIgnored private var mirrorHashes: Set<Data> = []
  @ObservationIgnored private var preparedHashKey: MatchInput?
  @ObservationIgnored private var backupIsActive = false
  @ObservationIgnored private var hasActiveTransfers = false
  @ObservationIgnored private var matchReceiptRevision = 0
  @ObservationIgnored private var localEvidence = LocalAssetHashes.Evidence()
  @ObservationIgnored private var fileSHA1s: [String: Set<Data>] = [:]
  @ObservationIgnored private var contentHashTask: Task<Void, Never>?
  @ObservationIgnored private var matchRequest: MatchRequest?
  @ObservationIgnored private var probedHashKey: MatchInput?
  @ObservationIgnored private var contentHashKey: MatchInput?
  @ObservationIgnored private var probingContent = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var keyIndexCache: [Int: Int] = [:]
  @ObservationIgnored private var dayTitleCache: (day: Date, title: String)?
  @ObservationIgnored private var isRebuilding = false
  @ObservationIgnored private var rebuildPending = false
  /// Index ids (device local identifiers, `g:` media keys) to timeline positions.
  @ObservationIgnored private var positions: [String: Int] = [:]
  @ObservationIgnored private var folders: [LibraryFolder] = []
  @ObservationIgnored private var pairFolderLivePhotos = AppSettingsStore.load().pairLivePhotos
  @ObservationIgnored private var disabledFolderIDs: Set<String> = []
  @ObservationIgnored private var foldersAreSettled = true
  /// The latest folder read; the next merge takes it in.
  @ObservationIgnored private var folderItems: [FolderItemInfo] = []
  /// The folder and Google Photos lists the current `entries` index into. A newer list
  /// waits for the merge that uses it, so an entry never points into a list it wasn't
  /// built from.
  @ObservationIgnored private var mergedFolder: [FolderItemInfo] = []
  @ObservationIgnored private var mergedCloud: [RemoteItemSummary] = []
  /// What the current `entries` were merged from, for a full timeline when they're filtered.
  @ObservationIgnored private var mergedInputs = MergeInputs()
  /// Google Photos media keys of backed-up folder files, by path.
  @ObservationIgnored private var uploadedFileKeys: [String: String] = [:]
  @ObservationIgnored private var additionalFileKeys: [String: Set<String>] = [:]
  /// Upload state of folder files not (yet) in Google Photos, by path.
  @ObservationIgnored private var fileStates: [String: PhotoGridBadges.Backup] = [:]
  @ObservationIgnored private var confirmedFileIDs = Set<String>()
  /// How many folder files the upload records know, to read the folders again when the
  /// backup finds new ones.
  @ObservationIgnored private var recordedFileCount = -1
  /// The folder read in progress: the first merge waits for it a moment, so folder
  /// files arrive with the rest instead of popping in after.
  @ObservationIgnored private var folderRead: Task<Void, Never>?
  /// The last launch's folder read, drawn while the folders are read again.
  @ObservationIgnored private var folderCacheRead: Task<Void, Never>?
  /// A folder list (read now or saved from before) is in `folderItems`.
  @ObservationIgnored private var hasFolderItems = false
  @ObservationIgnored private var folderGeneration = 0
  @ObservationIgnored private var folderContentRevision = 0
  @ObservationIgnored private var durationRead: Task<[String: TimeInterval], Never>?
  /// Set when the view can publish local rows.
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var launchFallback: Task<Void, Never>?
  @ObservationIgnored private(set) var launchWaitExpired = false
  /// The launch's local rows were tried too and there are none yet.
  private(set) var launchIsStillEmpty = false
  /// The view is showing the last session's screen.
  @ObservationIgnored var showsSavedScreen = false
  @ObservationIgnored private var waitsForFolders: Bool

  // PhotoKit and the cached sources start together. Give them one short window to
  // produce the first screen before opening the grid on whatever is available.
  private static let launchWait: Duration = .milliseconds(500)

  public init(device: PhotoLibraryGridModel = PhotoLibraryGridModel(buildsTimeline: false), waitsForInitialFolders: Bool = false) {
    self.device = device
    waitsForFolders = waitsForInitialFolders
  }

  isolated deinit {
    contentHashTask?.cancel()
    launchFallback?.cancel()
  }

  #if DEBUG
    @ObservationIgnored private(set) var mergeCount = 0
    @ObservationIgnored private var tracedTail: [String] = []
    @ObservationIgnored private var tailPublishCount = 0

    private func traceLaunchPublish() {
      guard UserDefaults.standard.bool(forKey: "UITraceLibraryLaunch") else { return }
      let tail = (max(0, itemCount - 12)..<itemCount).map { itemID(at: $0) }
      let changed = tracedTail != tail
      if changed { tailPublishCount += 1 }
      tracedTail = tail
      NSLog("LIBRARY_LAUNCH rows=%d tailChanges=%d changed=%d complete=%d", itemCount, tailPublishCount, changed ? 1 : 0, hasMerged ? 1 : 0)
    }
  #endif

  public var badgeToken: Int { mergeBadgeToken &+ device.badgeToken &+ (cloud?.badgeToken ?? 0) }
  public var itemCount: Int { entries.count }
  public var thumbnailSource: any ThumbnailSource { composite }
  public var thumbnailRevision: Int { cloud?.thumbnailRevision ?? 0 }

  /// The main filters; the media types are in `LibraryFilter.mediaTypes`.
  public var availableFilters: [LibraryFilter] {
    cloud == nil ? LibraryFilter.deviceFilters : LibraryFilter.deviceFilters + [.cloudOnly]
  }

  /// View Options › Show Screenshots, as in Photos; kept between launches.
  public private(set) var showsScreenshots = UserDefaults.standard.object(forKey: "LibraryShowsScreenshots") as? Bool ?? true

  public func setShowsScreenshots(_ shows: Bool) async {
    guard shows != showsScreenshots else { return }
    showsScreenshots = shows
    UserDefaults.standard.set(shows, forKey: "LibraryShowsScreenshots")
    await rebuild()
  }

  public func setCloudLibrary(_ library: CloudLibrary?) {
    // Signing in again replaces the library of the same account; the old one is retired.
    guard library !== cloud?.library else { return }
    generation &+= 1
    hasResolvedFilter = false
    accountReady = false
    if cloud != nil {
      launchWaitExpired = true
      ThumbnailPipeline.shared.invalidateRemoteImages(where: { _ in true })
      // Another account (or none): the old account's items mustn't stay on screen while
      // thumbnails now come from the new one, so the timeline clears until the next merge.
      entries = []
      positions = [:]
      timeline = TimelineIndex()
      keyIndexCache = [:]
      isLoaded = false
      hasMerged = false
      mergedCloud = []
      reloadToken &+= 1
    }
    recordsGeneration &+= 1
    hasRecords = false
    primaryRecords = []
    hasActiveTransfers = false
    backup = PhotoBackupEvidence(accountEmail: library?.accountEmail)
    uploadedMediaKeys = [:]
    uploadedSHA1s = [:]
    uploadedFileKeys = [:]
    additionalFileKeys = [:]
    skippedFilePaths = []
    fileStates = [:]
    confirmedFileIDs = []
    mirrorKeys = []
    mirrorHashes = []
    mirrorReadFailed = false
    preparedHashKey = nil
    localEvidence = .init()
    fileSHA1s = [:]
    resetContentMatching()
    indexedMetadataSource.cloud = nil
    cloud = library.map { RemoteLibraryGridModel(library: $0, scope: .library, buildsTimeline: false) }
    composite.setCloud(library?.localFirstThumbnails)
    if library == nil, filter == .cloudOnly { filter = .all }
  }

  /// The backed-up folders whose photos and videos join the timeline.
  public func setFolders(_ folders: [LibraryFolder], disabledFolderIDs: Set<String> = []) async {
    let wasWaiting = waitsForFolders
    waitsForFolders = false
    let changed = folders != self.folders
    guard changed || disabledFolderIDs != self.disabledFolderIDs || wasWaiting else { return }
    self.folders = folders
    self.disabledFolderIDs = disabledFolderIDs
    if changed {
      hasFolderItems = false
      foldersAreSettled = false
      await refreshFolders()
    } else if wasWaiting || filter.dependsOnBackup {
      await rebuild()
    }
  }

  /// Reads the backed-up folders again (on launch, when the app comes back, when the
  /// backup finds new files) and re-merges if their files changed.
  public func refreshFolders(using foregroundRead: FolderMediaScanner.ForegroundRead? = nil) async {
    folderRead?.cancel()
    foldersAreSettled = false
    folderGeneration &+= 1
    let generation = folderGeneration
    let folders = folders
    let pairLivePhotos = AppSettingsStore.load().pairLivePhotos
    if pairLivePhotos != pairFolderLivePhotos {
      pairFolderLivePhotos = pairLivePhotos
      hasFolderItems = false
      guard generation == folderGeneration else { return }
    }
    let records = folderRecords
    let email = cloud?.library.accountEmail
    if !hasFolderItems {
      let revision = folderContentRevision
      folderCacheRead = Task { [weak self] in
        let cached = await Task.detached(priority: .userInitiated) { () -> [FolderItemInfo]? in
          FolderLibrary.cachedItems(for: folders, pairLivePhotos: pairLivePhotos)
        }.value
        guard let self, let cached, generation == self.folderGeneration, !self.hasFolderItems, self.folderContentRevision == revision else {
          return
        }
        await self.applyFolderItems(cached, generation: generation)
      }
    }
    let read = Task { [weak self] in
      let items = await Task.detached(priority: .userInitiated) { () -> [FolderItemInfo]? in
        FolderLibrary.shared.setFolders(folders)
        let items = await FolderLibrary.shared.scan(
          using: foregroundRead, pairLivePhotos: pairLivePhotos, records: records, accountEmail: email)
        return Task.isCancelled ? nil : items
      }.value
      guard let self, let items, generation == self.folderGeneration else { return }
      await self.applyFolderItems(items, generation: generation, authoritative: true)
    }
    folderRead = read
    await read.value
    guard generation == folderGeneration else { return }
    saveFolderCache()
    loadFolderDurations(generation: generation)
  }

  private func saveFolderCache() {
    let items = folderItems
    let folders = folders
    let pairLivePhotos = pairFolderLivePhotos
    Task.detached(priority: .utility) { FolderLibrary.saveCache(items, for: folders, pairLivePhotos: pairLivePhotos) }
  }

  /// New folder files keep the lengths already read for videos that were there before.
  private func applyFolderItems(_ scanned: [FolderItemInfo], generation: Int, authoritative: Bool = false) async {
    var known: [String: TimeInterval] = [:]
    for item in folderItems { if let duration = item.duration { known[item.path] = duration } }
    var items = scanned
    for index in items.indices where items[index].isVideo { items[index].duration = known[items[index].path] ?? items[index].duration }
    let revision = folderContentRevision
    if items != folderItems || !hasFolderItems {
      let scanned = items
      var recordsRevision: Int
      var evidence: FileUploads
      repeat {
        recordsRevision = recordsGeneration
        let records = folderRecords
        let email = cloud?.library.accountEmail
        evidence = await Task.detached(priority: .userInitiated) {
          Self.fileUploads(records, email: email, folder: scanned)
        }.value
        guard generation == folderGeneration, authoritative || !foldersAreSettled,
          authoritative || revision == folderContentRevision
        else { return }
      } while recordsRevision != recordsGeneration
      if items != folderItems {
        folderContentRevision &+= 1
        folderItems = items
      }
      applyFileEvidence(evidence)
    }
    hasFolderItems = true
    if authoritative { foldersAreSettled = true }
    await rebuild()
  }

  /// Video lengths, for their cells, read in the background after the timeline is drawn
  /// (only badges change). A newer folder read replaces a pass still running.
  private func loadFolderDurations(generation: Int) {
    durationRead?.cancel()
    let missing = folderItems.filter { $0.isVideo && $0.duration == nil }
    guard !missing.isEmpty else { return }
    let read = Task.detached(priority: .utility) { await FolderLibrary.durations(of: missing) }
    durationRead = read
    Task { [weak self] in
      let durations = await read.value
      guard let self, generation == self.folderGeneration, !durations.isEmpty else { return }
      self.applyDurations(durations)
    }
  }

  private func applyDurations(_ durations: [String: TimeInterval]) {
    for index in folderItems.indices {
      if let duration = durations[folderItems[index].path] { folderItems[index].duration = duration }
    }
    for index in mergedFolder.indices {
      if let duration = durations[mergedFolder[index].path] { mergedFolder[index].duration = duration }
    }
    mergeBadgeToken &+= 1
    saveFolderCache()
  }

  public func setFilter(_ filter: LibraryFilter) async {
    guard filter != self.filter else { return }
    hasResolvedFilter = false
    self.filter = filter
    await rebuild()
  }

  /// Starts PhotoKit and allows a local first screen if the merged launch takes too long.
  public func startLocal(firstScreen: (count: Int, pixelSide: CGFloat)? = nil) async {
    if !hasStarted {
      hasStarted = true
      launchFallback = Task { [weak self] in
        try? await Task.sleep(for: Self.launchWait)
        // The saved screen is already up, so waiting for the whole timeline beats showing
        // part of it and moving it.
        if self?.showsSavedScreen == true, !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
        guard let self, !Task.isCancelled else { return }
        self.launchWaitExpired = true
        async let preview: Void = self.loadLaunchPreview(firstScreen: firstScreen)
        await self.rebuild()
        await preview
        // Rows still on their way keep the saved screen up, for a bounded time.
        let deadline = ContinuousClock.now + .seconds(3)
        while self.entries.isEmpty, self.isRebuilding || !self.device.isLoaded, ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(50))
          guard !Task.isCancelled else { return }
        }
        self.launchIsStillEmpty = self.entries.isEmpty && !self.isLoaded
      }
    }
    let fullAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    if hasFullPhotoAccess != fullAccess || (mergedFetch != nil && !PhotoLibraryGridModel.hasAccess) {
      hasFullPhotoAccess = fullAccess
      deviceInfosToken = -1
      mergedFetch = nil
      mergedFetchIndices = nil
      mergedDevice = []
      mergedCloud = []
      entries = []
      positions = [:]
      timeline = TimelineIndex()
      isLoaded = false
      hasMerged = false
      hasResolvedFilter = false
      resetContentMatching()
      preparedHashKey = nil
      localEvidence = .init()
      cloud?.library.clearLocalCopies()
      await device.reloadForAuthorization()
    }
    await preload()
    await rebuild()
  }

  public func start(records: [TransferRecord]) async {
    accountReady = true
    let target = cloud
    async let local: Void = startLocal()
    async let mirror: Void? = target?.reloadIfNeeded()
    await recordsChanged(records, rebuilds: false)
    await mirror
    if target === cloud {
      mirrorReadFailed = target?.loadFailed == true
      await rebuild()
    }
    await local
    await contentHashTask?.value
  }

  /// Supports launch prefetch before the Library view is mounted.
  public func preload() async {
    if let preloadTask {
      await preloadTask.value
      if deviceInfosToken == device.reloadToken || !PhotoLibraryGridModel.hasAccess { return }
    }
    let load = Task {
      if !device.isLoaded { await device.load() }
      guard device.currentFetch != nil else { return }
      let token = device.reloadToken
      guard token != deviceInfosToken else { return }
      if launchWaitExpired && !isLoaded {
        // PhotoKit may have finished its fetch after the launch timer fired.
        Task { await loadLaunchPreview(firstScreen: nil) }
      }
      let infos = await device.deviceInfos()
      guard token == device.reloadToken, PhotoLibraryGridModel.hasAccess else { return }
      deviceInfos = infos
      deviceInfosToken = token
    }
    preloadTask = load
    await load.value
    preloadTask = nil
  }

  private func loadLaunchPreview(firstScreen: (count: Int, pixelSide: CGFloat)?) async {
    guard !isLoaded, deviceInfosToken != device.reloadToken, device.itemCount > 0, filter == .all,
      let fetch = device.currentFetch
    else { return }
    let indices = device.currentFetchIndices
    let limit = max(96, firstScreen?.count ?? 0)
    let infos = await Task.detached(priority: .userInitiated) {
      DeviceInfoSnapshot.readAll(fetch, indices: indices, limit: limit)
    }.value
    await publishPreview(infos, fetch: fetch, indices: indices)
  }

  private func publishPreview(_ infos: [DeviceItemInfo], fetch: PHFetchResult<PHAsset>, indices: [Int]?) async {
    let hidesScreenshots = !showsScreenshots
    let result = await Task.detached(priority: .userInitiated) {
      let entries = TimelineMerge.merge(device: infos, cloud: [], uploadedMediaKeys: [:], hidesScreenshots: hidesScreenshots)
      return Self.index(entries, device: infos, cloud: [], folder: [])
    }.value
    guard !Task.isCancelled, !isLoaded, fetch === device.currentFetch, filter == .all,
      hidesScreenshots == !showsScreenshots, !result.positions.isEmpty
    else { return }
    mergedDevice = infos
    mergedFetch = fetch
    mergedFetchIndices = indices
    mergedInputs = MergeInputs(isComplete: false)
    entries = result.entries
    positions = result.positions
    timeline = result.timeline
    isLoaded = true
    launchIsStillEmpty = false
    reloadToken &+= 1
    // A merge under way began without these rows.
    if isRebuilding {
      generation &+= 1
      rebuildPending = true
    }
    #if DEBUG
      traceLaunchPublish()
    #endif
  }

  /// Upload records changed: backup badges and which device items are in Google Photos.
  public func recordsChanged(_ records: [TransferRecord], rebuilds: Bool = true) async {
    recordsGeneration &+= 1
    let current = recordsGeneration
    let email = cloud?.library.accountEmail
    let previousKeys = uploadedMediaKeys
    let previousHashes = uploadedSHA1s
    let previousFiles = uploadedFileKeys
    let previousAdditionalFiles = additionalFileKeys
    let previousFileHashes = fileSHA1s
    let previousSkipped = skippedFilePaths
    let previousBackup = backup
    let mirrorKeys = mirrorKeys
    let mirrorHashes = mirrorHashes
    let folder = folderItems
    let folderGeneration = folderGeneration
    let result = await Task.detached(priority: .utility) {
      let primary = records.filter { $0.resourceRole == .primary && $0.assetLocalIdentifier != nil }
      let evidence = Self.uploadEvidence(primary, email: email ?? "")
      let byPath = Self.folderRecordsByPath(records)
      let files = Self.fileUploads(byPath, email: email, folder: folder)
      let backup = PhotoBackupEvidence.read(records, accountEmail: email)
      let affectsMirror =
        Self.touchesMirror(previousKeys, evidence.keys, mirrorKeys)
        || Self.touchesMirror(previousHashes, evidence.hashes, mirrorHashes)
        || Self.touchesMirror(previousAdditionalFiles, files.allKeys, mirrorKeys)
        || Self.touchesMirror(previousFileHashes, files.hashes, mirrorHashes)
      let hasActiveTransfers = records.contains { $0.status == .sending }
      return (primary, evidence, byPath, files, backup, affectsMirror, backup != previousBackup, hasActiveTransfers)
    }.value
    guard current == recordsGeneration, email == cloud?.library.accountEmail else { return }
    let first = !hasRecords
    let (primary, evidence, byPath, files, backup, affectsMirror, backupChanged, hasActiveTransfers) = result
    let transferActivityChanged = self.hasActiveTransfers != hasActiveTransfers
    self.hasActiveTransfers = hasActiveTransfers

    primaryRecords = primary
    if affectsMirror { matchReceiptRevision &+= 1 }
    uploadedMediaKeys = evidence.keys
    uploadedSHA1s = evidence.hashes
    folderRecords = byPath
    self.backup = backup
    if folderGeneration == self.folderGeneration, folder == folderItems {
      applyFileEvidence(files)
    } else {
      await refreshFileEvidence()
    }
    guard current == recordsGeneration else { return }
    hasRecords = true
    let readsFolders = recordedFileCount != -1 && files.count != recordedFileCount
    recordedFileCount = files.count
    if readsFolders || AppSettingsStore.load().pairLivePhotos != pairFolderLivePhotos { await refreshFolders() }
    if transferActivityChanged { await contentProbeConditionsChanged() }
    if rebuilds,
      first || affectsMirror
        || (filter.dependsOnBackup && (backupChanged || files.keys != previousFiles || files.skipped != previousSkipped))
    {
      await rebuild()
    } else {
      await updateDeviceBadges()
    }
  }

  nonisolated static func touchesMirror<Key: Hashable, Value: Hashable>(
    _ old: [Key: Set<Value>], _ new: [Key: Set<Value>], _ mirror: Set<Value>
  ) -> Bool {
    guard !mirror.isEmpty else { return false }
    for (key, values) in old where values != new[key] {
      if !values.subtracting(new[key] ?? []).isDisjoint(with: mirror) { return true }
    }
    for (key, values) in new where values != old[key] {
      if !values.subtracting(old[key] ?? []).isDisjoint(with: mirror) { return true }
    }
    return false
  }

  private func updateDeviceBadges() async {
    var evidence = backup.usingNewerScope(from: device.currentBackupEvidence)
    evidence.confirmedIDs = cloud?.library.localFirstThumbnails.localCopies.confirmedAssetIDs ?? []
    await device.applyBackupEvidence(evidence)
  }

  struct FileUploads: Sendable {
    var keys: [String: String] = [:]
    var allKeys: [String: Set<String>] = [:]
    var hashes: [String: Set<Data>] = [:]
    var states: [String: PhotoGridBadges.Backup] = [:]
    var skipped: Set<String> = []
    var count = 0
  }

  @ObservationIgnored private var skippedFilePaths: Set<String> = []

  nonisolated static func folderRecordsByPath(_ records: [TransferRecord]) -> [String: [TransferRecord]] {
    var byPath: [String: [TransferRecord]] = [:]
    for record in records {
      guard record.assetLocalIdentifier == nil, record.sharedEntryID == nil, let path = record.sourcePath else { continue }
      byPath[TransferManifestStore.standardizedPath(path), default: []].append(record)
    }
    return byPath
  }

  nonisolated static func fileUploads(
    _ byPath: [String: [TransferRecord]], email: String?, folder: [FolderItemInfo]
  ) -> FileUploads {
    var uploads = FileUploads(count: byPath.count)
    guard let email else { return uploads }
    for item in folder {
      guard let records = byPath[item.path],
        let modified = item.modifiedAt
          ?? (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      else { continue }
      for record in records {
        guard matchesFile(record, size: item.size, modified: modified, motion: item.motion, isLivePhoto: item.isLivePhoto)
        else { continue }
        if let encoded = record.sourceSHA1 ?? record.sha1, let digest = Data(base64Encoded: encoded), digest.count == 20 {
          uploads.hashes[item.id, default: []].insert(digest)
        }
        if record.isTerminalSuccess, let key = record.mediaKeysByAccount[email], !key.isEmpty {
          uploads.allKeys[item.path, default: []].insert(key)
          if uploads.keys[item.path] == nil || key < (uploads.keys[item.path] ?? key) {
            uploads.keys[item.path] = key
          }
          uploads.states[item.path] = nil
          if record.isSkipped { uploads.skipped.insert(item.path) }
          continue
        }
        guard TransferRecord.accountEmail(fromScopedID: record.id) == email else { continue }
        if record.isSkipped { uploads.skipped.insert(item.path) }
        guard uploads.keys[item.path] == nil, !record.isSkipped, !record.isTerminalSuccess else { continue }
        if uploads.states[item.path] != .failed {
          uploads.states[item.path] = record.status == .failed ? .failed : .pending
        }
      }
    }
    return uploads
  }

  nonisolated static func matchesFile(
    _ record: TransferRecord, size: Int64, modified: Date, motion: FolderItemInfo.FileVersion? = nil, isLivePhoto: Bool
  ) -> Bool {
    guard (record.sourceFileSize ?? record.byteCount) == size, let recorded = record.sourceModifiedAt,
      abs(recorded.timeIntervalSince(modified)) < 1
    else { return false }
    guard isLivePhoto else { return record.pairedSourcePath == nil }
    guard let motion, let recordedPath = record.pairedSourcePath, let date = record.pairedSourceModifiedAt,
      TransferManifestStore.standardizedPath(recordedPath) == motion.path,
      motion.size == record.pairedSourceFileSize
    else { return false }
    return abs(date.timeIntervalSince(motion.modifiedAt)) < 1
  }

  private func applyFileEvidence(_ files: FileUploads) {
    let badgesChanged = files.states != fileStates || files.keys != uploadedFileKeys
    uploadedFileKeys = files.keys
    additionalFileKeys = files.allKeys
    fileSHA1s = files.hashes
    skippedFilePaths = files.skipped
    if badgesChanged {
      fileStates = files.states
      mergeBadgeToken &+= 1
    }
  }

  private func refreshFileEvidence() async {
    let records = folderRecords
    let folder = folderItems
    let email = cloud?.library.accountEmail
    let revision = recordsGeneration
    let folderRevision = folderGeneration
    let evidence = await Task.detached(priority: .utility) {
      Self.fileUploads(records, email: email, folder: folder)
    }.value
    guard revision == recordsGeneration, folderRevision == folderGeneration, folder == folderItems else { return }
    applyFileEvidence(evidence)
  }

  public func cloudChanged() async {
    guard let cloud else { return }
    let token = cloud.reloadToken
    let badges = cloud.badgeToken
    let hadLoaded = cloud.isLoaded
    let hadFailed = mirrorReadFailed
    await cloud.reloadIfNeeded()
    guard cloud === self.cloud else { return }
    mirrorReadFailed = cloud.loadFailed
    if token != cloud.reloadToken || badges != cloud.badgeToken || hadLoaded != cloud.isLoaded
      || mirrorReadFailed != hadFailed
    {
      await rebuild()
    }
  }

  /// What links device photos to Google copies, read in one pass over the records.
  nonisolated static func uploadEvidence(
    _ records: [TransferRecord], email: String, versions: [String: PhotoBackupEvidence.Version]? = nil
  ) -> (keys: [String: Set<String>], hashes: [String: Set<Data>]) {
    var keys: [String: Set<String>] = [:]
    var hashes: [String: Set<Data>] = [:]
    for record in records {
      // Originals and RAWs are separate cloud photos, not the displayed rendition.
      guard record.resourceRole == .primary, let asset = record.assetLocalIdentifier else { continue }
      let version = versions?[asset]?.assetVersion
      guard versions == nil || version != nil else { continue }
      if version?.contentChanged(since: record.assetVersion) != true {
        if record.isTerminalSuccess, let key = record.mediaKeysByAccount[email], !key.isEmpty {
          keys[asset, default: []].insert(key)
        }
        if let encoded = record.sha1, let digest = Data(base64Encoded: encoded), digest.count == 20 {
          hashes[asset, default: []].insert(digest)
        }
      }
      // The mirror proves which account has these bytes. A prepared export can already prove
      // a display match before the upload finishes.
      if let prepared = record.preparedAsset, version?.contentChanged(since: prepared.version) != true,
        let digest = Data(base64Encoded: prepared.sha1), digest.count == 20
      {
        hashes[asset, default: []].insert(digest)
      }
    }
    return (keys, hashes)
  }

  /// Re-merges both sides. A call while a merge runs is folded into one more pass after
  /// it, so bursts of changes cost at most two merges.
  public func rebuild() async {
    guard hasStarted else { return }
    generation &+= 1
    guard !isRebuilding else {
      rebuildPending = true
      return
    }
    isRebuilding = true
    defer { isRebuilding = false }
    repeat {
      rebuildPending = false
      await merge()
    } while rebuildPending
  }

  private func merge() async {
    let current = generation
    let token = device.reloadToken
    let hasAccess = PhotoLibraryGridModel.hasAccess
    let fetch = hasAccess && token == deviceInfosToken ? device.currentFetch : nil
    let fetchIndices = fetch == nil ? nil : device.currentFetchIndices
    let deviceReady = !hasAccess || fetch != nil
    if !deviceReady, device.currentFetch != nil, preloadTask == nil {
      Task {
        await preload()
        await rebuild()
      }
    }
    let device: [DeviceItemInfo] = if fetch != nil { deviceInfos } else if hasAccess { mergedDevice } else { [] }
    let gridFetch = fetch ?? (hasAccess ? mergedFetch : nil)
    let gridIndices = fetch == nil && hasAccess ? mergedFetchIndices : fetchIndices
    #if DEBUG
      mergeCount += 1
    #endif
    let cloud = cloud
    let folder = folderItems
    let mirrorLoaded = cloud?.isLoaded == true
    let remoteReady = mirrorLoaded && hasRecords
    let foldersReady = !waitsForFolders && (hasFolderItems || foldersAreSettled)
    let canPlan = remoteReady && deviceReady && (foldersReady || launchWaitExpired)
    // Google rows wait for the device list and the upload records: without them, what's on
    // this device would show again from Google.
    let canShowCloud = mirrorLoaded && hasRecords && deviceReady
    let remote: [RemoteItemSummary]
    if canShowCloud {
      remote = cloud?.items ?? []
    } else if mirrorLoaded, !mergedCloud.isEmpty, let items = cloud?.items {
      // Only additions wait: what left (or was locked) goes at once.
      let current = Set(items.map(\.mediaKey))
      remote = mergedCloud.filter { current.contains($0.mediaKey) }
    } else {
      remote = mergedCloud
    }
    let matchInput = MatchInput(
      deviceToken: token, hasPhotoAccess: fetch != nil, folderToken: folderContentRevision,
      receiptToken: matchReceiptRevision, cloudToken: cloud?.matchRevision ?? -1)
    let prepared = preparedHashKey
    let initialSyncDone = cloud?.library.syncState.initialSyncDone == true
    let launchIsComplete = Self.launchIsComplete(
      accountReady: accountReady && deviceReady, foldersReady: foldersReady, hasCloud: cloud != nil,
      mirrorReady: remoteReady && !mirrorReadFailed && initialSyncDone,
      matchingReady: prepared == matchInput)
    let canPublish = launchIsComplete || hasPublishedCompleteTimeline || launchWaitExpired || isLoaded
    guard canPlan || canPublish else { return }
    // Use the revisions for the summaries we are merging, before any local-copy badge updates.
    let cloudMetadata = cloud.map { $0.reloadToken &+ ($0.badgeToken &- $0.thumbnailRevision) }
    let metadataSource = (token, canShowCloud ? cloudMetadata : indexedMetadataSource.cloud)
    let primary = primaryRecords
    let email = cloud?.library.accountEmail ?? ""
    let localEvidence = localEvidence
    let fileSHA1s = fileSHA1s
    let uploadedFiles = uploadedFileKeys
    let extraFileKeys = additionalFileKeys
    let restrictFolders = !disabledFolderIDs.isEmpty
    var roots: [String] = []
    if restrictFolders {
      roots = FolderLibrary.shared.resolvedPaths(excluding: disabledFolderIDs)
      if !foldersAreSettled {
        for folder in folders where !disabledFolderIDs.contains(folder.id) {
          let path = TransferManifestStore.standardizedPath(folder.path)
          roots.append(path.hasSuffix("/") ? path : path + "/")
        }
      }
    }
    let enabledRoots = roots
    let skipped = skippedFilePaths
    let backup = backup.usingNewerScope(from: self.device.currentBackupEvidence)
    let filter = filter
    let hidesScreenshots = !showsScreenshots
    let previous = entries
    let previousDevice = mergedDevice
    let previousCloud = mergedCloud
    let previousFolder = mergedFolder
    let oldComplete = mergedInputs.isComplete
    let displayedFilter = displayedFilter
    let inputsComplete =
      accountReady && deviceReady && foldersAreSettled && !waitsForFolders
      && (cloud == nil || (remoteReady && prepared == matchInput && initialSyncDone))
    let filterReady =
      Self.filterIsReady(
        filter, accountReady: accountReady && deviceReady,
        hasRecords: hasRecords, foldersAreSettled: foldersAreSettled && !waitsForFolders,
        hasCloud: cloud != nil, mirrorLoaded: mirrorLoaded,
        initialSyncDone: initialSyncDone,
        syncFailed: {
          if case .failed = cloud?.library.status { return true }
          return false
        }())
    let result = await Task.detached(priority: .userInitiated) {
      let versions =
        primary.isEmpty
        ? [:]
        : Dictionary(
          uniqueKeysWithValues: device.lazy.filter { !$0.isHidden }.map {
            ($0.localIdentifier, $0.version)
          })
      let evidence = Self.uploadEvidence(primary, email: email, versions: versions)
      let receipts = evidence.hashes.merging(fileSHA1s, uniquingKeysWith: { $0.union($1) })
      let localHashes = localEvidence.current(device: device, folder: folder)
      let hashes = receipts.merging(localHashes, uniquingKeysWith: { $0.union($1) })
      var excludedFiles = skipped
      if restrictFolders {
        for file in folder where !enabledRoots.contains(where: { file.path.hasPrefix($0) }) {
          excludedFiles.insert(file.path)
        }
      }
      let projection = TimelineMerge.project(
        device: device, cloud: remote, uploadedMediaKeys: evidence.keys, uploadedSHA1s: hashes,
        folder: folder, uploadedFileKeys: uploadedFiles, filter: filter, hidesScreenshots: hidesScreenshots, backup: backup,
        excludedFilePaths: excludedFiles, extraFileKeys: extraFileKeys)
      let next = projection.entries
      let reindex =
        canPublish
        && (next != previous || displayedFilter != filter
          || Self.layoutsDiffer(
            new: device, old: previousDevice, fields: { ($0.localIdentifier, $0.date) }, samePixels: { $0.version == $1.version })
          || Self.layoutsDiffer(new: remote, old: previousCloud, fields: { ($0.thumbnailID, $0.takenAt) })
          || Self.layoutsDiffer(
            new: folder, old: previousFolder, fields: { ($0.id, $0.date) },
            samePixels: { $0.modifiedAt == $1.modifiedAt && $0.size == $1.size }))
      return (
        projection, reindex ? Self.index(next, device: device, cloud: remote, folder: folder, copies: projection.copies) : nil,
        evidence.keys, hashes, receipts, Set(remote.map(\.mediaKey)), Set(remote.compactMap(\.sha1))
      )
    }.value
    guard current == generation, token == self.device.reloadToken, fetch === self.device.currentFetch || fetch == nil else { return }
    let (projection, indexed, uploaded, hashes, receipts, keys, remoteHashes) = result
    if deviceReady && remoteReady {
      cloud?.library.replaceLocalCopies(projection.copies)
    }
    if canPlan {
      matchRequest = MatchRequest(input: matchInput, device: device, folder: folder, items: remote, receipts: receipts)
      prepareContentMatching()
    }
    guard canPublish else { return }
    if launchIsComplete {
      hasPublishedCompleteTimeline = true
      launchFallback?.cancel()
    }
    self.displayedFilter = filter
    mirrorKeys = keys
    mirrorHashes = remoteHashes
    hasMerged = inputsComplete
    hasResolvedFilter = filterReady
    isLoaded = !projection.entries.isEmpty || hasResolvedFilter
    if isLoaded, launchIsStillEmpty { launchIsStillEmpty = false }
    mergedDevice = device
    mergedFetch = gridFetch
    mergedFetchIndices = gridIndices
    mergedFolder = folder
    confirmedFileIDs = projection.confirmedFileIDs
    mergedCloud = remote
    mergedInputs = MergeInputs(
      uploadedMediaKeys: uploaded, uploadedSHA1s: hashes, uploadedFileKeys: uploadedFiles,
      isFiltered: filter != .all || hidesScreenshots, isComplete: inputsComplete, extraFileKeys: extraFileKeys
    )
    keyIndexCache = [:]
    dayTitleCache = nil
    if let indexed {
      entries = indexed.entries
      positions = indexed.positions
      timeline = indexed.timeline
      reloadToken &+= 1
      #if DEBUG
        traceLaunchPublish()
      #endif
    } else {
      mergeBadgeToken &+= 1
    }
    if metadataSource != indexedMetadataSource || oldComplete != inputsComplete {
      indexedMetadataSource = metadataSource
      indexMetadataToken &+= 1
    }
    await updateDeviceBadges()
  }

  nonisolated static func launchIsComplete(
    accountReady: Bool, foldersReady: Bool, hasCloud: Bool, mirrorReady: Bool, matchingReady: Bool
  ) -> Bool {
    accountReady && foldersReady && (!hasCloud || mirrorReady && matchingReady)
  }

  nonisolated static func filterIsReady(
    _ filter: LibraryFilter, accountReady: Bool, hasRecords: Bool, foldersAreSettled: Bool, hasCloud: Bool,
    mirrorLoaded: Bool, initialSyncDone: Bool, syncFailed: Bool
  ) -> Bool {
    guard accountReady, hasRecords else { return false }
    if filter == .notBackedUp || filter == .notIncludedInBackup { return foldersAreSettled }
    if filter != .cloudOnly && !foldersAreSettled { return false }
    return !hasCloud || syncFailed || (mirrorLoaded && initialSyncDone)
  }

  /// The host can block display probes while its backup engine is busy.
  public func setBackupActive(_ active: Bool) async {
    guard backupIsActive != active else { return }
    backupIsActive = active
    await contentProbeConditionsChanged()
  }

  private var allowsContentProbes: Bool {
    guard !backupIsActive, !hasActiveTransfers, cloud?.library.isSyncing != true, LibraryIndexer.pauseReason() == nil
    else { return false }
    #if os(iOS)
      return UIApplication.shared.applicationState != .background && !UIApplication.shared.isIdleTimerDisabled
    #else
      return NSApplication.shared.isActive
    #endif
  }

  func contentProbeConditionsChanged() async {
    updateContentProbePermission(allowsContentProbes)
  }

  func updateContentProbePermission(_ allowed: Bool) {
    if !allowed, probingContent {
      cancelContentProbes()
    }
    prepareContentMatching(allowsProbes: allowed)
  }

  private func cancelContentProbes() {
    contentHashTask?.cancel()
    contentHashTask = nil
    contentHashKey = nil
    probingContent = false
  }

  private func resetContentMatching() {
    cancelContentProbes()
    matchRequest = nil
    probedHashKey = nil
  }

  private struct MatchInput: Equatable, Sendable {
    let deviceToken: Int
    let hasPhotoAccess: Bool
    let folderToken: Int
    let receiptToken: Int
    let cloudToken: Int
  }

  private struct MatchRequest {
    let input: MatchInput
    let device: [DeviceItemInfo]
    let folder: [FolderItemInfo]
    let items: [RemoteItemSummary]
    let receipts: [String: Set<Data>]
  }

  private func prepareContentMatching(allowsProbes: Bool? = nil) {
    guard let request = matchRequest else { return }
    let input = request.input
    let canProbe = allowsProbes ?? self.allowsContentProbes
    if contentHashKey == input, !canProbe || probingContent { return }
    guard preparedHashKey != input || (canProbe && probedHashKey != input) else { return }
    cancelContentProbes()
    contentHashKey = input
    probingContent = canProbe
    let previous = localEvidence
    let store = SiriLibrary.shared.store
    let priority: TaskPriority = !isLoaded ? .userInitiated : .utility
    contentHashTask = Task.detached(priority: priority) { [weak self] in
      let plan = await LocalAssetHashes.prepare(
        device: request.device, folder: request.folder, cloud: request.items, store: store, previous: previous,
        receipts: request.receipts, allowsProbes: canProbe
      ) { [weak self] evidence in
        await self?.publishContentPlan(evidence, input: input, finished: false, probed: false)
      }
      guard !Task.isCancelled else { return }
      let readsContent = !plan.pendingKeys.isEmpty
      await self?.publishContentPlan(plan.known, input: input, finished: !readsContent, probed: canProbe)
      guard readsContent else { return }
      let result = await LocalAssetHashes.read(plan, store: store) { [weak self] in
        await self?.allowsContentProbes == true
      }
      guard !Task.isCancelled else { return }
      await self?.publishContentPlan(result.evidence, input: input, finished: true, probed: result.complete)
    }
  }

  private func publishContentPlan(
    _ evidence: LocalAssetHashes.Evidence, input: MatchInput, finished: Bool, probed: Bool
  ) async {
    guard !Task.isCancelled, contentHashKey == input else { return }
    if finished {
      contentHashTask = nil
      contentHashKey = nil
      probingContent = false
    }
    guard device.reloadToken == input.deviceToken, folderContentRevision == input.folderToken,
      matchReceiptRevision == input.receiptToken, cloud?.matchRevision == input.cloudToken
    else { return }
    let changed = (finished && preparedHashKey != input) || !localEvidence.matches(evidence)
    if finished {
      preparedHashKey = input
      if probed { probedHashKey = input }
    }
    localEvidence = evidence
    if changed { await rebuild() }
  }

  nonisolated static func layoutsDiffer<Item>(
    new: [Item], old: [Item], fields: (Item) -> (String, Date), samePixels: (Item, Item) -> Bool = { _, _ in true }
  ) -> Bool {
    new.count != old.count || !zip(new, old).allSatisfy { fields($0) == fields($1) && samePixels($0, $1) }
  }

  struct IndexedTimeline: Sendable {
    let entries: [UnifiedEntry]
    let positions: [String: Int]
    let timeline: TimelineIndex
  }

  nonisolated static func index(
    _ entries: [UnifiedEntry], device: [DeviceItemInfo], cloud: [RemoteItemSummary], folder: [FolderItemInfo],
    copies: LocalFirstThumbnailSource.LocalCopies = .init()
  ) -> IndexedTimeline {
    var positions: [String: Int] = [:]
    positions.reserveCapacity(entries.count)
    var dates: [Date] = []
    dates.reserveCapacity(entries.count)
    for (position, entry) in entries.enumerated() {
      switch entry {
      case .device(let index, let match):
        positions[device[index].localIdentifier] = position
        if let match { positions[LibraryIndexer.searchID(cloudMediaKey: cloud[match].mediaKey)] = position }
        dates.append(device[index].date)
      case .cloud(let index):
        positions[LibraryIndexer.searchID(cloudMediaKey: cloud[index].mediaKey)] = position
        dates.append(cloud[index].takenAt)
      case .folder(let index, let match):
        positions[folder[index].id] = position
        if let match {
          positions[LibraryIndexer.searchID(cloudMediaKey: cloud[match].mediaKey)] = position
          dates.append(cloud[match].takenAt)
        } else {
          dates.append(folder[index].date)
        }
      }
    }
    for (key, id) in copies.assets {
      let cloudID = LibraryIndexer.searchID(cloudMediaKey: key)
      if positions[cloudID] == nil { positions[cloudID] = positions[id] }
    }
    for (key, file) in copies.files {
      let cloudID = LibraryIndexer.searchID(cloudMediaKey: key)
      if positions[cloudID] == nil { positions[cloudID] = positions[file.id] }
    }
    return IndexedTimeline(
      entries: entries, positions: positions, timeline: TimelineIndex.build(count: dates.count) { dates[$0] })
  }

  /// Local identifiers of every device item in the library.
  public func deviceIDs() async -> Set<String> {
    let infos = deviceInfos
    return await Task.detached(priority: .utility) { Set(infos.map(\.localIdentifier)) }.value
  }

  /// What the indexer needs, as copy-on-write arrays it can read off the main actor.
  struct MergeInputs: Sendable {
    var uploadedMediaKeys: [String: Set<String>] = [:]
    var uploadedSHA1s: [String: Set<Data>] = [:]
    var uploadedFileKeys: [String: String] = [:]
    /// The entries leave items out (a filter, or screenshots hidden).
    var isFiltered = false
    /// The device and Google Photos lists had loaded when merged.
    var isComplete = true
    var extraFileKeys: [String: Set<String>] = [:]
  }

  public struct IndexSnapshot: Sendable {
    let entries: [UnifiedEntry]
    let device: [DeviceItemInfo]
    let cloud: [RemoteItemSummary]
    let folder: [FolderItemInfo]
    let cloudLibrary: CloudLibrary?
    var inputs = MergeInputs()

    /// Every item, whatever the Library's filter: what Siri and Spotlight know. Merges
    /// again only when the entries are filtered; call it off the main actor.
    func unfiltered() -> IndexSnapshot {
      guard inputs.isFiltered else { return self }
      var snapshot = IndexSnapshot(
        entries: TimelineMerge.project(
          device: device, cloud: cloud, uploadedMediaKeys: inputs.uploadedMediaKeys,
          uploadedSHA1s: inputs.uploadedSHA1s, folder: folder, uploadedFileKeys: inputs.uploadedFileKeys,
          filter: .all, hidesScreenshots: false, extraFileKeys: inputs.extraFileKeys
        ).entries,
        device: device, cloud: cloud, folder: folder, cloudLibrary: cloudLibrary, inputs: inputs)
      snapshot.inputs.isFiltered = false
      return snapshot
    }

    /// Date and place of every item, for Memories.
    func moments() -> [MemoryFinder.Moment] {
      entries.map { entry in
        switch entry {
        case .device(let index, _):
          let info = device[index]
          return MemoryFinder.Moment(date: info.date, latitude: info.latitude, longitude: info.longitude)
        case .cloud(let index), .folder(_, cloud: .some(let index)):
          let item = cloud.indices.contains(index) ? cloud[index] : nil
          return MemoryFinder.Moment(
            date: item?.takenAt ?? .distantPast, latitude: item?.latitude, longitude: item?.longitude)
        case .folder(let index, cloud: nil):
          return MemoryFinder.Moment(
            date: folder.indices.contains(index) ? folder[index].date : .distantPast, latitude: nil, longitude: nil)
        }
      }
    }

    /// The index id of the item at a timeline position.
    func indexID(at position: Int) -> String? {
      guard entries.indices.contains(position) else { return nil }
      switch entries[position] {
      case .device(let index, _): return device.indices.contains(index) ? device[index].localIdentifier : nil
      case .cloud(let index), .folder(_, cloud: .some(let index)):
        return cloud.indices.contains(index) ? LibraryIndexer.searchID(cloudMediaKey: cloud[index].mediaKey) : nil
      case .folder(let index, cloud: nil):
        return folder.indices.contains(index) ? folder[index].id : nil
      }
    }
  }

  public func indexSnapshot() -> IndexSnapshot {
    IndexSnapshot(
      entries: entries, device: mergedDevice, cloud: mergedCloud, folder: mergedFolder, cloudLibrary: cloud?.library,
      inputs: isLoaded ? mergedInputs : MergeInputs(isComplete: false))
  }

  /// Timeline positions of index ids, in the given order, skipping unknown and repeated ones.
  public func positions(of ids: [String]) -> [Int] {
    var seen = Set<Int>()
    return ids.compactMap { id in
      guard let position = positions[id], seen.insert(position).inserted else { return nil }
      return position
    }
  }

  /// The index id of the item at a timeline position.
  public func indexID(at position: Int) -> String? {
    switch entry(at: position) {
    case .device(let index, _): deviceInfo(at: index)?.localIdentifier
    case .cloud(let index), .folder(_, cloud: .some(let index)):
      cloudItem(at: index).map { LibraryIndexer.searchID(cloudMediaKey: $0.mediaKey) }
    case .folder(let index, cloud: nil): folderItem(at: index)?.id
    case nil: nil
    }
  }

  enum SelectionID: Hashable, Sendable {
    case device(String)
    case folder(ThumbnailIdentity)
    case cloud(ObjectIdentifier, String)

    var indexKey: String {
      switch self {
      case .device(let id): id
      case .folder(let identity): identity.id
      case .cloud(_, let key): LibraryIndexer.searchID(cloudMediaKey: key)
      }
    }
  }

  func selectionID(at position: Int) -> SelectionID? {
    guard let entry = entry(at: position) else { return nil }
    return Self.selectionID(
      for: entry, device: mergedDevice, cloud: mergedCloud, folder: mergedFolder, account: cloud.map { ObjectIdentifier($0.library) })
  }

  nonisolated static func selectionID(
    for entry: UnifiedEntry, device: [DeviceItemInfo], cloud: [RemoteItemSummary], folder: [FolderItemInfo],
    account: ObjectIdentifier?
  ) -> SelectionID? {
    switch entry {
    case .device(let index, _): return device.indices.contains(index) ? .device(device[index].localIdentifier) : nil
    case .folder(let index, _): return folder.indices.contains(index) ? .folder(folder[index].thumbnailIdentity) : nil
    case .cloud(let index):
      return cloud.indices.contains(index) ? account.map { .cloud($0, cloud[index].mediaKey) } : nil
    }
  }

  func selectionPositions(_ ids: Set<SelectionID>) -> Set<Int> {
    Self.selectionPositions(ids, in: positions, identityAt: selectionID(at:))
  }

  nonisolated static func selectionPositions(
    _ ids: Set<SelectionID>, in positions: [String: Int], identityAt: (Int) -> SelectionID?
  ) -> Set<Int> {
    // The navigation index includes aliases for Google copies. Selection must never follow them.
    Set(
      ids.compactMap { id in
        guard let position = positions[id.indexKey], identityAt(position) == id else { return nil }
        return position
      })
  }

  func dragItem(at position: Int) -> PhotoGridDragItem? {
    guard displayedFilter == filter, let id = selectionID(at: position),
      let current = selectionPositions([id]).first, let item = viewerItem(at: current)
    else { return nil }
    if case .cloud(let summary, let library, _) = item,
      library.isRetired || LockedItems.contains(summary.mediaKey, accountEmail: library.accountEmail)
    {
      return nil
    }
    let drag = item.dragItem
    return PhotoGridDragItem(fileName: drag.fileName, isVideo: drag.isVideo) { [weak self] in
      guard let self else { throw CocoaError(.fileNoSuchFile) }
      return try await self.exportSelectedRow(id)
    }
  }

  private func exportSelectedRow(_ id: SelectionID) async throws -> URL {
    let fresh = await resolveSelection([id])
    if let asset = fresh.device.first { return try await SharedAsset(asset).export() }
    if let item = fresh.cloud.first, let library = cloud?.library { return try await library.download(item) }
    if let file = fresh.files.first { return file.url }
    throw CocoaError(.fileNoSuchFile)
  }

  public func deviceInfo(at index: Int) -> DeviceItemInfo? {
    mergedDevice.indices.contains(index) ? mergedDevice[index] : nil
  }

  private func mergedAsset(at index: Int) -> PHAsset? {
    guard let fetch = mergedFetch, mergedDevice.indices.contains(index), PhotoLibraryGridModel.hasAccess else { return nil }
    return fetch.object(at: mergedFetchIndices?[index] ?? index)
  }

  private func mergedBackupState(at index: Int) -> PhotoGridBadges.Backup? {
    guard let item = deviceInfo(at: index) else { return nil }
    if let state = backup.state(for: item.localIdentifier, version: item.version.assetVersion) { return state }
    return cloud?.library.localFirstThumbnails.localCopies.confirmedAssetIDs.contains(item.localIdentifier) == true ? .backedUp : nil
  }

  private func folderBackupState(_ item: FolderItemInfo) -> PhotoGridBadges.Backup? {
    if uploadedFileKeys[item.path] != nil || confirmedFileIDs.contains(item.id) { return .backedUp }
    return fileStates[item.path]
  }

  public func folderItem(at index: Int) -> FolderItemInfo? {
    mergedFolder.indices.contains(index) ? mergedFolder[index] : nil
  }

  private func cloudItem(at index: Int) -> RemoteItemSummary? {
    mergedCloud.indices.contains(index) ? mergedCloud[index] : nil
  }

  /// Grid ids are device local identifiers, folder ids and Google thumbnail ids; the
  /// position map knows the first two as they are and Google items by media key.
  public func index(ofItemID id: String, near: Int) -> Int? {
    if let position = positions[id] { return position }
    guard let thumbnail = RemoteThumbnailID(id) else { return nil }
    return positions[LibraryIndexer.searchID(cloudMediaKey: thumbnail.mediaKey)]
  }

  public func entry(at index: Int) -> UnifiedEntry? { entries.indices.contains(index) ? entries[index] : nil }

  /// The day of the item at a position ("25 Oct 2026"), shown under the title while
  /// scrolling, as in Photos.
  public func dayTitle(at index: Int) -> String? {
    let date: Date? =
      switch entry(at: index) {
      case .device(let deviceIndex, _): deviceInfo(at: deviceIndex)?.date
      case .cloud(let cloudIndex), .folder(_, cloud: .some(let cloudIndex)): cloudItem(at: cloudIndex)?.takenAt
      case .folder(let folderIndex, cloud: nil): folderItem(at: folderIndex)?.date
      case nil: nil
      }
    guard let date else { return nil }
    // Called as the grid scrolls: most rows share a day, so the string is reused.
    let day = Calendar.current.startOfDay(for: date)
    if let cached = dayTitleCache, cached.day == day { return cached.title }
    let title = date.formatted(.dateTime.day().month(.abbreviated).year())
    dayTitleCache = (day, title)
    return title
  }

  public func monthTitle(at index: Int) -> String? {
    timeline.month(containing: index)?.start.formatted(.dateTime.month(.wide).year())
  }

  /// A selection resolved to its items, with what the selection toolbar shows.
  public struct Picked: Sendable {
    public var device: [PHAsset] = []
    public var cloud: [RemoteItemSummary] = []
    /// Folder files: they can be shared; the other actions are for the library's items.
    public var files: [FolderItemInfo] = []
    /// The Google Photos copies of the picked device items, which Delete also trashes.
    public var cloudCopies: [RemoteItemSummary] = []
    public var allFavorites = false
    public var isEmpty: Bool { device.isEmpty && cloud.isEmpty }
  }

  /// Resolves a selection off the main actor (Select All in a 100k library is 100k assets).
  func resolveSelection(_ ids: Set<SelectionID>) async -> Picked {
    guard displayedFilter == filter, !ids.isEmpty else { return .init() }
    let revision = reloadToken
    let library = cloud?.library
    let fresh = await picked(selectionPositions(ids), validating: true)
    guard revision == reloadToken, displayedFilter == filter, library === cloud?.library,
      library?.isRetired != true
    else { return .init() }
    return fresh
  }

  func picked(_ indices: Set<Int>, validating: Bool = false) async -> Picked {
    let entries = entries
    let fetch = mergedFetch
    let fetchIndices = mergedFetchIndices
    let cloudItems = mergedCloud
    let folder = mergedFolder
    let device = mergedDevice
    let receipts = mergedInputs.uploadedMediaKeys
    let accountEmail = cloud?.library.accountEmail
    let hasAccess = PhotoLibraryGridModel.hasAccess
    return await Task.detached(priority: .userInitiated) {
      let freshAssets: [String: PHAsset]
      if validating && hasAccess {
        let ids = indices.compactMap { index -> String? in
          guard entries.indices.contains(index), case .device(let deviceIndex, _) = entries[index] else { return nil }
          return device[deviceIndex].localIdentifier
        }
        let options = AssetExportService.allFramesFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let current = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var visible: [String: PHAsset] = [:]
        for index in 0..<current.count {
          let asset = current.object(at: index)
          if !asset.isHidden { visible[asset.localIdentifier] = asset }
        }
        freshAssets = visible
      } else {
        freshAssets = [:]
      }
      func isUnlocked(_ item: RemoteItemSummary) -> Bool {
        accountEmail.map { !LockedItems.contains(item.mediaKey, accountEmail: $0) } == true
      }
      var picked = Picked()
      for index in indices.sorted() where entries.indices.contains(index) {
        switch entries[index] {
        case .device(let deviceIndex, let match):
          let info = device[deviceIndex]
          let asset = validating ? freshAssets[info.localIdentifier] : fetch?.object(at: fetchIndices?[deviceIndex] ?? deviceIndex)
          guard let asset else { continue }
          picked.device.append(asset)
          if let match, let copy = Self.recordedCloudCopy(info, cloudItems[match], receipts: receipts), isUnlocked(copy),
            !validating || LocalFirstThumbnailSource.hasCurrentVersion(asset, info.version)
          {
            picked.cloudCopies.append(copy)
          }
        case .cloud(let cloudIndex):
          let item = cloudItems[cloudIndex]
          if isUnlocked(item) { picked.cloud.append(item) }
        case .folder(let folderIndex, _):
          let file = folder[folderIndex]
          if !validating || LocalFirstThumbnailSource.fileAliasIsCurrent(file) { picked.files.append(file) }
        }
      }
      picked.allFavorites = !picked.isEmpty && picked.device.allSatisfy(\.isFavorite) && picked.cloud.allSatisfy(\.isFavorite)
      return picked
    }.value
  }

  /// The selection split by where each item lives.
  public func split(_ indices: Set<Int>) -> (device: [PHAsset], cloud: [RemoteItemSummary]) {
    var deviceItems: [PHAsset] = []
    var cloudItems: [RemoteItemSummary] = []
    for index in indices.sorted() {
      switch entry(at: index) {
      case .device(let deviceIndex, _): if let asset = mergedAsset(at: deviceIndex) { deviceItems.append(asset) }
      case .cloud(let cloudIndex): if let item = cloudItem(at: cloudIndex) { cloudItems.append(item) }
      case .folder, nil: break
      }
    }
    return (deviceItems, cloudItems)
  }

  nonisolated static func recordedCloudCopy(
    _ device: DeviceItemInfo, _ item: RemoteItemSummary, receipts: [String: Set<String>]
  ) -> RemoteItemSummary? {
    receipts[device.localIdentifier]?.contains(item.mediaKey) == true ? item : nil
  }

  /// The recorded Google Photos copy of a device item, which deleting it also trashes.
  public func cloudCopy(at index: Int) -> (item: RemoteItemSummary, library: CloudLibrary)? {
    guard case .device(let index, cloud: .some(let match)) = entry(at: index), let cloud, let item = cloudItem(at: match),
      let copy = Self.recordedCloudCopy(mergedDevice[index], item, receipts: mergedInputs.uploadedMediaKeys)
    else { return nil }
    return (copy, cloud.library)
  }

  /// The folder files among `indices`.
  public func files(at indices: Set<Int>) -> [FolderItemInfo] {
    indices.sorted().compactMap { index in
      if case .folder(let folderIndex, _) = entry(at: index) { return folderItem(at: folderIndex) }
      return nil
    }
  }

  /// A period's cover: its newest favorite, from flags already in memory, remembered
  /// until the timeline changes.
  public func keyIndex(in range: Range<Int>) -> Int {
    if let cached = keyIndexCache[range.lowerBound] { return cached }
    // The timeline runs oldest first, so the newest are at the end of the range.
    var key = range.upperBound - 1
    for index in range.reversed().prefix(300) {
      let isFavorite =
        switch entry(at: index) {
        case .device(let deviceIndex, _): deviceInfo(at: deviceIndex)?.isFavorite == true
        case .cloud(let cloudIndex), .folder(_, cloud: .some(let cloudIndex)): cloudItem(at: cloudIndex)?.isFavorite == true
        case .folder(_, cloud: nil), nil: false
        }
      if isFavorite {
        key = index
        break
      }
    }
    keyIndexCache[range.lowerBound] = key
    return key
  }

  // MARK: PhotoGridDataSource and MediaViewerSource

  public func entityID(at index: Int) -> String? { indexID(at: index) }

  public func itemID(at index: Int) -> String {
    switch entry(at: index) {
    case .device(let deviceIndex, _):
      guard let asset = mergedAsset(at: deviceIndex) else { return "" }
      PhotoKitImageSource.shared.remember(asset)
      return asset.localIdentifier
    case .cloud(let cloudIndex): return cloudItem(at: cloudIndex)?.thumbnailID ?? ""
    case .folder(let folderIndex, _): return folderItem(at: folderIndex)?.id ?? ""
    case nil: return ""
    }
  }

  public func thumbnailIdentity(at index: Int) -> ThumbnailIdentity {
    switch entry(at: index) {
    case .device(let deviceIndex, _):
      guard let info = deviceInfo(at: deviceIndex) else { return ThumbnailIdentity(id: "") }
      return ThumbnailIdentity(
        id: itemID(at: index),
        version: PhotoKitImageSource.pixelVersion(modifiedAt: info.version.modifiedAt, adjustedAt: info.version.adjustmentTimestamp))
    case .folder(let folderIndex, _):
      return folderItem(at: folderIndex)?.thumbnailIdentity ?? ThumbnailIdentity(id: "")
    case .cloud(let cloudIndex):
      let id = cloudItem(at: cloudIndex)?.thumbnailID ?? ""
      return cloud?.library.localFirstThumbnails.thumbnailIdentity(for: id) ?? ThumbnailIdentity(id: id)
    case nil:
      return ThumbnailIdentity(id: "")
    }
  }

  public func badges(at index: Int) -> PhotoGridBadges {
    switch entry(at: index) {
    case .device(let deviceIndex, _):
      guard let asset = mergedAsset(at: deviceIndex) else { return PhotoGridBadges() }
      return PhotoGridBadges(
        videoDuration: asset.mediaType == .video ? asset.duration : nil, isFavorite: asset.isFavorite,
        backup: mergedBackupState(at: deviceIndex))
    case .cloud(let cloudIndex):
      guard let item = cloudItem(at: cloudIndex) else { return PhotoGridBadges() }
      return PhotoGridBadges(videoDuration: item.duration, isFavorite: item.isFavorite, backup: .cloudOnly)
    case .folder(let folderIndex, let match):
      guard let item = folderItem(at: folderIndex) else { return PhotoGridBadges() }
      let remote = match.flatMap(cloudItem(at:))
      return PhotoGridBadges(
        videoDuration: remote?.duration ?? item.duration, isFavorite: remote?.isFavorite ?? false,
        backup: folderBackupState(item))
    case nil:
      return PhotoGridBadges()
    }
  }

  public func accessibilityLabel(at index: Int) -> String {
    switch entry(at: index) {
    case .device(let deviceIndex, _):
      guard let asset = mergedAsset(at: deviceIndex) else { return "" }
      return PhotoLibraryGridModel.accessibilityLabel(for: asset, backup: mergedBackupState(at: deviceIndex))
    case .cloud(let cloudIndex):
      guard let item = cloudItem(at: cloudIndex) else { return "" }
      return RemoteLibraryGridModel.accessibilityLabel(for: item) + ", " + PhotoGridBadges.Backup.cloudOnly.title
    case .folder(let folderIndex, let match):
      guard let item = folderItem(at: folderIndex) else { return "" }
      let kind = item.isVideo ? String(localized: "Video") : String(localized: "Photo")
      let date = (match.flatMap { cloudItem(at: $0)?.takenAt } ?? item.date).formatted(date: .long, time: .shortened)
      let state = folderBackupState(item)?.title
      return [kind, date, item.fileName, state].compactMap(\.self).joined(separator: ", ")
    case nil:
      return ""
    }
  }

  public func aspectRatio(at index: Int) -> CGFloat? {
    let size: (Int?, Int?) =
      switch entry(at: index) {
      case .device(let deviceIndex, _): (deviceInfo(at: deviceIndex)?.width, deviceInfo(at: deviceIndex)?.height)
      case .cloud(let cloudIndex), .folder(_, cloud: .some(let cloudIndex)):
        (cloudItem(at: cloudIndex)?.width, cloudItem(at: cloudIndex)?.height)
      case .folder(_, cloud: nil), nil: (nil, nil)
      }
    guard let width = size.0, let height = size.1, width > 0, height > 0 else { return nil }
    return CGFloat(width) / CGFloat(height)
  }

  public func viewerItem(at index: Int) -> ViewerItem? {
    switch entry(at: index) {
    case .device(let deviceIndex, _):
      guard let asset = mergedAsset(at: deviceIndex) else { return nil }
      return .device(asset, backup: mergedBackupState(at: deviceIndex))
    case .cloud(let cloudIndex):
      guard let cloud, let item = cloudItem(at: cloudIndex) else { return nil }
      return .cloud(item, library: cloud.library, isOnDevice: false)
    case .folder(let folderIndex, let match):
      guard let item = folderItem(at: folderIndex) else { return nil }
      let copy = match.flatMap { index in cloud.flatMap { cloud in cloudItem(at: index).map { ($0, cloud.library) } } }
      return .file(item, backup: folderBackupState(item), cloud: copy)
    case nil:
      return nil
    }
  }
}
