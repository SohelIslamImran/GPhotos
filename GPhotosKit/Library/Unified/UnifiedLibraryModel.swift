import CoreGraphics
import Foundation
import Observation
import Photos
import os

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
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    source(for: id)?.requestImage(id: id, pixelSize: pixelSize, quality: quality, deliver: deliver) ?? .none
  }

  func startCaching(ids: [String], pixelSize: CGSize) {
    let (cloudIDs, deviceIDs) = split(ids)
    if !deviceIDs.isEmpty { device.startCaching(ids: deviceIDs, pixelSize: pixelSize) }
    if !cloudIDs.isEmpty { cloud.withLock { $0 }?.startCaching(ids: cloudIDs, pixelSize: pixelSize) }
  }

  func stopCaching(ids: [String], pixelSize: CGSize) {
    let (cloudIDs, deviceIDs) = split(ids)
    if !deviceIDs.isEmpty { device.stopCaching(ids: deviceIDs, pixelSize: pixelSize) }
    if !cloudIDs.isEmpty { cloud.withLock { $0 }?.stopCaching(ids: cloudIDs, pixelSize: pixelSize) }
  }

  private func split(_ ids: [String]) -> (cloud: [String], device: [String]) {
    var cloud: [String] = []
    var device: [String] = []
    for id in ids where !id.hasPrefix(FolderItemInfo.idPrefix) {
      if id.hasPrefix("g:") { cloud.append(id) } else { device.append(id) }
    }
    return (cloud, device)
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
  public private(set) var timeline = TimelineIndex()
  public private(set) var isLoaded = false
  /// The first merge has finished: what the Library has is known, even without photo access.
  public private(set) var hasMerged = false
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
  @ObservationIgnored private var deviceInfosToken = -1
  @ObservationIgnored private var preloadTask: Task<Void, Never>?
  @ObservationIgnored private var uploadedMediaKeys: [String: Set<String>] = [:]
  @ObservationIgnored private var uploadedSHA1s: [String: Set<Data>] = [:]
  @ObservationIgnored private var localSHA1s: [String: Set<Data>] = [:]
  @ObservationIgnored private var contentHashTask: Task<Void, Never>?
  @ObservationIgnored private var contentHashKey: String?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var keyIndexCache: [Int: Int] = [:]
  @ObservationIgnored private var dayTitleCache: (day: Date, title: String)?
  @ObservationIgnored private var isRebuilding = false
  @ObservationIgnored private var rebuildPending = false
  /// Index ids (device local identifiers, `g:` media keys) to timeline positions.
  @ObservationIgnored private var positions: [String: Int] = [:]
  @ObservationIgnored private var folders: [LibraryFolder] = []
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
  /// Upload state of folder files not (yet) in Google Photos, by path.
  @ObservationIgnored private var fileStates: [String: PhotoGridBadges.Backup] = [:]
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
  @ObservationIgnored private var durationRead: Task<[String: TimeInterval], Never>?
  /// Set by `start`: until then nothing merges, so the first timeline drawn is the whole
  /// one (a merge of what loaded first would draw, then animate everything else in).
  @ObservationIgnored private var hasStarted = false

  public init(device: PhotoLibraryGridModel = PhotoLibraryGridModel(buildsTimeline: false)) {
    self.device = device
  }

  isolated deinit { contentHashTask?.cancel() }

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
    guard library?.accountEmail != cloud?.library.accountEmail else { return }
    if cloud != nil {
      // Another account (or none): the old account's items mustn't stay on screen while
      // thumbnails now come from the new one, so the timeline clears until the next merge.
      generation &+= 1
      entries = []
      positions = [:]
      timeline = TimelineIndex()
      keyIndexCache = [:]
      isLoaded = false
      reloadToken &+= 1
    }
    uploadedMediaKeys = [:]
    uploadedSHA1s = [:]
    localSHA1s = [:]
    contentHashTask?.cancel()
    contentHashTask = nil
    contentHashKey = nil
    cloud = library.map { RemoteLibraryGridModel(library: $0, scope: .library) }
    composite.setCloud(library?.localFirstThumbnails)
    if library == nil, filter == .cloudOnly { filter = .all }
  }

  /// The backed-up folders whose photos and videos join the timeline.
  public func setFolders(_ folders: [LibraryFolder]) async {
    guard folders != self.folders else { return }
    self.folders = folders
    await refreshFolders()
  }

  /// Reads the backed-up folders again (on launch, when the app comes back, when the
  /// backup finds new files) and re-merges if their files changed.
  public func refreshFolders() async {
    folderRead?.cancel()
    folderGeneration &+= 1
    let generation = folderGeneration
    let folders = folders
    if !hasFolderItems {
      folderCacheRead = Task { [weak self] in
        let cached = await Task.detached(priority: .userInitiated) { () -> [FolderItemInfo]? in
          // Thumbnails of the saved files need the folders' access too.
          FolderLibrary.shared.setFolders(folders)
          return FolderLibrary.cachedItems(for: folders)
        }.value
        guard let self, let cached, generation == self.folderGeneration, !self.hasFolderItems else { return }
        self.hasFolderItems = true
        await self.applyFolderItems(cached)
      }
    }
    let read = Task { [weak self] in
      let items = await Task.detached(priority: .userInitiated) { () -> [FolderItemInfo]? in
        FolderLibrary.shared.setFolders(folders)
        let items = FolderLibrary.shared.scan()
        return Task.isCancelled ? nil : items
      }.value
      guard let self, let items, generation == self.folderGeneration else { return }
      self.hasFolderItems = true
      await self.applyFolderItems(items)
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
    Task.detached(priority: .utility) { FolderLibrary.saveCache(items, for: folders) }
  }

  /// New folder files keep the lengths already read for videos that were there before.
  private func applyFolderItems(_ scanned: [FolderItemInfo]) async {
    var known: [String: TimeInterval] = [:]
    for item in folderItems { if let duration = item.duration { known[item.path] = duration } }
    var items = scanned
    for index in items.indices where items[index].isVideo { items[index].duration = known[items[index].path] ?? items[index].duration }
    guard items != folderItems else { return }
    folderItems = items
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
    self.filter = filter
    await rebuild()
  }

  /// First load: the device library (fetched once; its change observer keeps it current
  /// after that), the upload records and the Google Photos mirror. Safe to call again.
  public func start(records: [TransferRecord]) async {
    async let deviceReady: Void = preload()
    await cloud?.reloadIfNeeded()
    await deviceReady
    await waitForFolders(atMost: .milliseconds(400))
    await recordsChanged(records, rebuilds: false)
    hasStarted = true
    await rebuild()
  }

  /// A folder read still running after this long (a very large folder) joins the
  /// timeline when it finishes rather than holding back the rest.
  private func waitForFolders(atMost limit: Duration) async {
    guard !hasFolderItems else { return }
    let cacheRead = folderCacheRead
    let folderRead = folderRead
    let read = Task {
      await cacheRead?.value
      if !hasFolderItems { await folderRead?.value }
    }
    // A task group would wait for the read even after the timeout; whichever comes first
    // resumes this, once.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let resume = { @Sendable in
        if resumed.withLock({ done in
          defer { done = true }
          return !done
        }) {
          continuation.resume()
        }
      }
      Task {
        await read.value
        resume()
      }
      Task {
        try? await Task.sleep(for: limit)
        resume()
      }
    }
  }

  /// Reads the device library while accounts and upload records are still loading, so the
  /// first merge has everything and the grid draws once.
  ///
  /// With `firstScreen` (how many cells the grid shows first, and their size in pixels),
  /// the newest photos' thumbnails start loading too, so the grid draws with its images.
  public func preload(firstScreen: (count: Int, pixelSide: CGFloat)? = nil) async {
    // A preload before photo access was granted read nothing; it runs again once there is.
    if preloadTask != nil, !device.isLoaded, PhotoLibraryGridModel.hasAccess { preloadTask = nil }
    if preloadTask == nil {
      preloadTask = Task { [device] in
        if !device.isLoaded { await device.load() }
        if let firstScreen { warmNewest(firstScreen) }
        let token = device.reloadToken
        let infos = await device.deviceInfos()
        guard token == device.reloadToken, deviceInfosToken == -1 else { return }
        deviceInfosToken = token
        deviceInfos = infos
      }
    }
    await preloadTask?.value
  }

  /// The newest device photos are the timeline's end, where the grid opens. The pipeline
  /// keeps what arrives; the grid's own requests for them join these.
  private func warmNewest(_ firstScreen: (count: Int, pixelSide: CGFloat)) {
    let bucket = ThumbnailBucket.forPixelSide(firstScreen.pixelSide)
    var tickets: [ThumbnailTicket] = []
    for index in 0..<min(firstScreen.count, device.itemCount) {
      let key = ThumbnailKey(id: device.itemID(at: index), bucket: bucket)
      tickets.append(ThumbnailPipeline.shared.load(key, from: composite) { _, _ in })
    }
    // A request PhotoKit never answers is let go, or the grid's own request for the same
    // photo would wait on it for good.
    Task {
      try? await Task.sleep(for: .seconds(5))
      for ticket in tickets { ticket.cancel() }
    }
  }

  /// Upload records changed: backup badges and which device items are in Google Photos.
  public func recordsChanged(_ records: [TransferRecord], rebuilds: Bool = true) async {
    await device.updateBackupStates(from: records)
    let email = cloud?.library.accountEmail
    let files = await Task.detached(priority: .utility) { Self.fileUploads(records, email: email) }.value
    var changed = files.keys != uploadedFileKeys
    uploadedFileKeys = files.keys
    if files.states != fileStates {
      fileStates = files.states
      mergeBadgeToken &+= 1
    }
    let readsFolders = recordedFileCount != -1 && files.count != recordedFileCount
    recordedFileCount = files.count
    if let cloud, let email {
      let (keys, hashes) = await Task.detached(priority: .utility) { Self.uploadEvidence(records, email: email) }.value
      await cloud.updateDeviceMatches(from: records)
      if keys != uploadedMediaKeys || hashes != uploadedSHA1s {
        uploadedSHA1s = hashes
        uploadedMediaKeys = keys
        changed = true
      }
    }
    if readsFolders { await refreshFolders() }
    if changed, rebuilds { await rebuild() }
  }

  struct FileUploads: Sendable {
    var keys: [String: String] = [:]
    var states: [String: PhotoGridBadges.Backup] = [:]
    var count = 0
  }

  /// What the records say about folder files: media keys in the browsed account, and the
  /// state of those still on their way.
  nonisolated static func fileUploads(_ records: [TransferRecord], email: String?) -> FileUploads {
    var uploads = FileUploads()
    for record in records {
      guard record.assetLocalIdentifier == nil, record.sharedEntryID == nil, let path = record.sourcePath else { continue }
      uploads.count += 1
      if let email, let key = record.mediaKeysByAccount[email] {
        uploads.keys[path] = key
        uploads.states[path] = nil
        continue
      }
      guard uploads.keys[path] == nil else { continue }
      switch record.status {
      case .failed: uploads.states[path] = .failed
      case .sent, .deleted: break
      default: uploads.states[path] = .pending
      }
    }
    return uploads
  }

  /// The Google Photos mirror changed. Only a change in which items exist, or their order,
  /// re-merges; flag changes (a favorite) just refresh badges.
  public func cloudChanged() async {
    guard let cloud else { return }
    let token = cloud.reloadToken
    let badges = cloud.badgeToken
    await cloud.reloadIfNeeded()
    if cloud.reloadToken != token || (filter != .all && cloud.badgeToken != badges) { await rebuild() }
    scheduleContentMatching()
  }

  /// What links device photos to Google copies, read in one pass over the records.
  nonisolated static func uploadEvidence(
    _ records: [TransferRecord], email: String
  ) -> (keys: [String: Set<String>], hashes: [String: Set<Data>]) {
    var keys: [String: Set<String>] = [:]
    var hashes: [String: Set<Data>] = [:]
    for record in records {
      // Originals and RAWs are separate cloud photos, not the displayed rendition.
      guard record.resourceRole == .primary, let asset = record.assetLocalIdentifier else { continue }
      if let key = record.mediaKeysByAccount[email], !key.isEmpty { keys[asset, default: []].insert(key) }
      // The mirror itself proves which account has these bytes; no upload state is changed.
      if let encoded = record.sha1, let hash = Data(base64Encoded: encoded), hash.count == 20 {
        hashes[asset, default: []].insert(hash)
      }
    }
    return (keys, hashes)
  }

  /// Re-merges both sides. A call while a merge runs is folded into one more pass after
  /// it, so bursts of changes cost at most two merges.
  public func rebuild() async {
    guard hasStarted else { return }
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
    generation &+= 1
    let current = generation
    if device.reloadToken != deviceInfosToken || deviceInfos.count != device.itemCount {
      localSHA1s = [:]
      contentHashTask?.cancel()
      contentHashTask = nil
      contentHashKey = nil
      deviceInfosToken = device.reloadToken
      deviceInfos = await device.deviceInfos()
    }
    let device = deviceInfos
    let cloudItems = cloud?.items ?? []
    let uploaded = uploadedMediaKeys
    let uploadedHashes = uploadedSHA1s
    let localHashes = localSHA1s
    let hashes = await Task.detached(priority: .utility) {
      uploadedHashes.merging(localHashes, uniquingKeysWith: { $0.union($1) })
    }.value
    let folder = folderItems
    let uploadedFiles = uploadedFileKeys
    let filter = filter
    let hidesScreenshots = !showsScreenshots
    let previous = entries
    // Without photo access there is no device list to wait for: folders and Google Photos
    // are the whole library.
    let deviceReady = self.device.isLoaded || !PhotoLibraryGridModel.hasAccess
    let inputs = MergeInputs(
      uploadedMediaKeys: uploaded, uploadedSHA1s: hashes, uploadedFileKeys: uploadedFiles,
      isFiltered: filter != .all || hidesScreenshots,
      isComplete: deviceReady && (cloud?.isLoaded ?? true))
    // One pass off the main actor: merge, then (only if the result changed) the month
    // index and the id-to-position map.
    let result = await Task.detached(priority: .userInitiated) { () -> MergeResult? in
      let merged = TimelineMerge.merge(
        device: device, cloud: cloudItems, uploadedMediaKeys: uploaded, uploadedSHA1s: hashes,
        folder: folder, uploadedFileKeys: uploadedFiles,
        filter: filter, hidesScreenshots: hidesScreenshots)
      guard merged != previous else { return nil }
      var localAssets: [String: String] = [:]
      var deviceByHash: [Data: String] = [:]
      for (id, values) in hashes { for hash in values { deviceByHash[hash] = id } }
      for item in cloudItems {
        if let hash = item.sha1, let id = deviceByHash[hash] { localAssets[item.mediaKey] = id }
      }
      var localFiles: [String: FolderItemInfo] = [:]
      var positions: [String: Int] = [:]
      positions.reserveCapacity(merged.count)
      var dates: [Date] = []
      dates.reserveCapacity(merged.count)
      for (position, entry) in merged.enumerated() {
        switch entry {
        case .device(let index, let match):
          positions[device[index].localIdentifier] = position
          if let match {
            positions[LibraryIndexer.searchID(cloudMediaKey: cloudItems[match].mediaKey)] = position
            localAssets[cloudItems[match].mediaKey] = device[index].localIdentifier
          }
          dates.append(device[index].date)
        case .cloud(let index):
          positions[LibraryIndexer.searchID(cloudMediaKey: cloudItems[index].mediaKey)] = position
          dates.append(cloudItems[index].takenAt)
        case .folder(let index, let match):
          positions[folder[index].id] = position
          if let match {
            positions[LibraryIndexer.searchID(cloudMediaKey: cloudItems[match].mediaKey)] = position
            localFiles[cloudItems[match].mediaKey] = folder[index]
            dates.append(cloudItems[match].takenAt)
          } else {
            dates.append(folder[index].date)
          }
        }
      }
      return MergeResult(
        localAssets: localAssets, localFiles: localFiles, entries: merged, positions: positions,
        timeline: TimelineIndex.build(count: dates.count) { dates[$0] })
    }.value
    guard current == generation else { return }
    isLoaded = device.isEmpty && folder.isEmpty ? deviceReady : true
    hasMerged = true
    mergedFolder = folder
    mergedCloud = cloudItems
    mergedInputs = inputs
    if let result {
      keyIndexCache = [:]
      cloud?.library.registerLocalCopies(assets: result.localAssets, files: result.localFiles)
      entries = result.entries
      positions = result.positions
      timeline = result.timeline
      reloadToken &+= 1
    } else {
      mergeBadgeToken &+= 1
    }
    scheduleContentMatching()
  }

  private func scheduleContentMatching() {
    guard let cloud, cloud.isLoaded, !cloud.library.isSyncing, device.isLoaded, filter == .all else { return }
    let key = "\(cloud.library.accountEmail)|\(deviceInfosToken)|\(cloud.reloadToken)"
    guard key != contentHashKey else { return }
    contentHashTask?.cancel()
    contentHashKey = key
    let infos = deviceInfos
    let copies = cloud.library.localAssetIDs
    let items = cloud.items
    let store = SiriLibrary.shared.store
    contentHashTask = Task { [weak self] in
      let read = Task.detached(priority: .utility) {
        let matched = Set(copies.values)
        let ids = infos.filter { !$0.isVideo && !matched.contains($0.localIdentifier) }.map(\.localIdentifier)
        return await LocalAssetHashes.read(ids: ids, cloud: items, store: store)
      }
      let hashes = await withTaskCancellationHandler {
        await read.value
      } onCancel: {
        read.cancel()
      }
      guard !Task.isCancelled, let self, contentHashKey == key else { return }
      contentHashTask = nil
      guard !hashes.isEmpty else { return }
      localSHA1s.merge(hashes, uniquingKeysWith: { $0.union($1) })
      await rebuild()
    }
  }

  private struct MergeResult: Sendable {
    let localAssets: [String: String]
    let localFiles: [String: FolderItemInfo]
    let entries: [UnifiedEntry]
    let positions: [String: Int]
    let timeline: TimelineIndex
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
        entries: TimelineMerge.merge(
          device: device, cloud: cloud, uploadedMediaKeys: inputs.uploadedMediaKeys,
          uploadedSHA1s: inputs.uploadedSHA1s, folder: folder, uploadedFileKeys: inputs.uploadedFileKeys),
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
      entries: entries, device: deviceInfos, cloud: mergedCloud, folder: mergedFolder, cloudLibrary: cloud?.library,
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

  public func deviceInfo(at index: Int) -> DeviceItemInfo? {
    deviceInfos.indices.contains(index) ? deviceInfos[index] : nil
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
  public func picked(_ indices: Set<Int>) async -> Picked {
    let entries = entries
    let fetch = device.currentFetch
    let cloudItems = mergedCloud
    let folder = mergedFolder
    return await Task.detached(priority: .userInitiated) {
      var picked = Picked()
      for index in indices.sorted() where entries.indices.contains(index) {
        switch entries[index] {
        case .device(let deviceIndex, let match):
          if let fetch, deviceIndex < fetch.count { picked.device.append(fetch.object(at: deviceIndex)) }
          if let match, cloudItems.indices.contains(match) { picked.cloudCopies.append(cloudItems[match]) }
        case .cloud(let cloudIndex):
          if cloudItems.indices.contains(cloudIndex) { picked.cloud.append(cloudItems[cloudIndex]) }
        case .folder(let folderIndex, _):
          if folder.indices.contains(folderIndex) { picked.files.append(folder[folderIndex]) }
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
      case .device(let deviceIndex, _): if let asset = device.asset(at: deviceIndex) { deviceItems.append(asset) }
      case .cloud(let cloudIndex): if let item = cloudItem(at: cloudIndex) { cloudItems.append(item) }
      case .folder, nil: break
      }
    }
    return (deviceItems, cloudItems)
  }

  /// The Google Photos copies of the device items among `indices`.
  public func cloudCopies(_ indices: Set<Int>) -> [RemoteItemSummary] {
    indices.sorted().compactMap { index in
      if case .device(_, cloud: .some(let match)) = entry(at: index) { return cloudItem(at: match) }
      return nil
    }
  }

  /// The Google Photos copy of a device item, which deleting it also trashes.
  public func cloudCopy(at index: Int) -> (item: RemoteItemSummary, library: CloudLibrary)? {
    guard case .device(_, cloud: .some(let match)) = entry(at: index), let cloud, let item = cloudItem(at: match)
    else { return nil }
    return (item, cloud.library)
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
    case .device(let deviceIndex, _): device.itemID(at: deviceIndex)
    case .cloud(let cloudIndex): cloudItem(at: cloudIndex)?.thumbnailID ?? ""
    case .folder(let folderIndex, _): folderItem(at: folderIndex)?.id ?? ""
    case nil: ""
    }
  }

  public func badges(at index: Int) -> PhotoGridBadges {
    switch entry(at: index) {
    case .device(let deviceIndex, let match):
      var badges = device.badges(at: deviceIndex)
      if match != nil { badges.backup = .backedUp }
      return badges
    case .cloud(let cloudIndex):
      var badges = cloud?.badges(at: cloudIndex) ?? PhotoGridBadges()
      badges.backup = .cloudOnly
      return badges
    case .folder(let folderIndex, let match):
      if let match, var badges = cloud?.badges(at: match) {
        badges.backup = .backedUp
        return badges
      }
      let item = folderItem(at: folderIndex)
      return PhotoGridBadges(videoDuration: item?.duration, backup: item.flatMap { fileStates[$0.path] })
    case nil:
      return PhotoGridBadges()
    }
  }

  public func accessibilityLabel(at index: Int) -> String {
    switch entry(at: index) {
    case .device(let deviceIndex, let match):
      let label = device.accessibilityLabel(at: deviceIndex)
      return match != nil && device.backupState(at: deviceIndex) == nil
        ? label + ", " + PhotoGridBadges.Backup.backedUp.title : label
    case .cloud(let cloudIndex):
      return (cloud?.accessibilityLabel(at: cloudIndex) ?? "") + ", " + PhotoGridBadges.Backup.cloudOnly.title
    case .folder(let folderIndex, let match):
      guard let item = folderItem(at: folderIndex) else { return "" }
      let kind = item.isVideo ? String(localized: "Video") : String(localized: "Photo")
      let date = (match.flatMap { cloudItem(at: $0)?.takenAt } ?? item.date).formatted(date: .long, time: .shortened)
      let state = match != nil ? PhotoGridBadges.Backup.backedUp.title : fileStates[item.path]?.title
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
    case .device(let deviceIndex, let match):
      guard let asset = device.asset(at: deviceIndex) else { return nil }
      return .device(asset, backup: match != nil ? .backedUp : device.backupState(at: deviceIndex))
    case .cloud(let cloudIndex):
      guard let cloud, let item = cloudItem(at: cloudIndex) else { return nil }
      return .cloud(item, library: cloud.library, isOnDevice: false)
    case .folder(let folderIndex, let match):
      guard let item = folderItem(at: folderIndex) else { return nil }
      let copy = match.flatMap { index in cloud.flatMap { cloud in cloudItem(at: index).map { ($0, cloud.library) } } }
      return .file(item, backup: copy != nil ? .backedUp : fileStates[item.path], cloud: copy)
    case nil:
      return nil
    }
  }
}
