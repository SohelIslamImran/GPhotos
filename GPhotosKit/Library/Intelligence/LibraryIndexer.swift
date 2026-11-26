import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import Observation
import Photos
import os

/// Builds and queries the on-device index for the merged library. Device items are
/// analyzed from small PhotoKit thumbnails. Google Photos items are found by their
/// metadata (place, camera, caption, file name, date) at once, and then analyzed the same
/// way from a small thumbnail each, fetched where uploads may use the network: most of a
/// backed-up library is no longer on the device, and search and People would miss it.
/// Indexing runs at utility priority, a few items at a time, and pauses in Low Power
/// Mode or when the device is hot.
@MainActor
@Observable
public final class LibraryIndexer {
  public enum State: Equatable, Sendable {
    case idle
    case indexing(done: Int, total: Int)
    case paused(reason: String)
  }

  public private(set) var state: State = .idle
  /// Bumped as indexing progresses, for progress text.
  public private(set) var revision = 0
  /// Bumped every few hundred items and when a pass ends: screens that run heavier
  /// queries (categories, People, similar photos) refresh on this instead.
  public private(set) var contentRevision = 0

  /// A person was named or hidden: screens showing people read them again, and a pass
  /// (quick when nothing is new) brings Siri's people and photos up to date.
  public func peopleDidChange() {
    contentRevision &+= 1
    peopleSignal &+= 1
    if let lastPass { schedule(lastPass) }
  }

  private struct ScheduledPass: Sendable {
    let snapshot: UnifiedLibraryModel.IndexSnapshot
    let libraryReloadToken: Int
    let libraryBadgeToken: Int
    let deviceReloadToken: Int
    let deviceBadgeToken: Int
    let cloudRevision: Int
    let cloudLocalCopyRevision: Int
    let cloudInitialSyncDone: Bool
    let cloudIsSyncing: Bool
    let localAssets: [String: String]
    let localFiles: [String: FolderItemInfo]

    var spotlightContext: SiriSpotlightIndexer.SyncContext {
      SiriSpotlightIndexer.SyncContext(
        libraryReloadToken: libraryReloadToken, deviceReloadToken: deviceReloadToken,
        deviceBadgeToken: deviceBadgeToken, cloudRevision: cloudRevision)
    }
  }

  private struct StructuralFingerprint: Equatable, Sendable {
    let libraryReloadToken: Int
    let deviceReloadToken: Int
    let cloud: ObjectIdentifier?
    let cloudRevision: Int
    let cloudLocalCopyRevision: Int
    let cloudInitialSyncDone: Bool
    let cloudIsSyncing: Bool
    let isComplete: Bool
    let isFiltered: Bool
    let allowsCloudAnalysis: Bool
  }

  private struct PassFingerprint: Equatable, Sendable {
    let structural: StructuralFingerprint
    let libraryBadgeToken: Int
    let deviceBadgeToken: Int
    let peopleSignal: Int
  }

  @ObservationIgnored private var lastPass: ScheduledPass?
  @ObservationIgnored private var peopleSignal = 0
  @ObservationIgnored private var lastCompletedFingerprint: PassFingerprint?
  @ObservationIgnored private var lastCompletedAt = ContinuousClock.now
  /// When people were last grouped during a pass.
  @ObservationIgnored private var lastPeopleUpdate = ContinuousClock.now
  @ObservationIgnored public let store: LibraryIndexStore
  /// Brought up to date after each pass, for Siri.
  @ObservationIgnored private let spotlight: SiriSpotlightIndexer?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var pendingPass: ScheduledPass?
  @ObservationIgnored private var searchPeopleRevision = -1
  @ObservationIgnored private var searchPeopleCache: [LibraryIndexStore.NamedPerson] = []

  nonisolated static let thumbnailSide: CGFloat = 512

  public init(store: LibraryIndexStore = SiriLibrary.shared.store, spotlight: SiriSpotlightIndexer? = SiriLibrary.shared.spotlight) {
    self.store = store
    self.spotlight = spotlight
    // Google Photos items waiting for Wi-Fi or Low Data Mode to turn off pick back up automatically.
    networkTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: NetworkStatusMonitor.didReconnect).map({ _ in () }) {
        guard let self else { return }
        if let lastPass = self.lastPass { self.schedule(lastPass) }
      }
    }
    constrainedTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: NetworkStatusMonitor.didChangeConstrained).map({ _ in () }) {
        guard let self else { return }
        if Self.allowsCloudAnalysis(), let lastPass = self.lastPass { self.schedule(lastPass) }
      }
    }
    purgeTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: LibraryIndexStore.didPurgeCloudIndex, object: store)
        .map({ _ in () })
      {
        guard let self else { return }
        self.contentRevision &+= 1
      }
    }
  }

  isolated deinit {
    task?.cancel()
    networkTask?.cancel()
    constrainedTask?.cancel()
    purgeTask?.cancel()
  }

  @ObservationIgnored private var networkTask: Task<Void, Never>?
  @ObservationIgnored private var constrainedTask: Task<Void, Never>?
  @ObservationIgnored private var purgeTask: Task<Void, Never>?

  public var isIndexing: Bool {
    if case .indexing = state { return true }
    return false
  }

  /// Indexes whatever in the library isn't indexed yet. Cheap to call on every library
  /// change: it snapshots the arrays (copy on write) and does the rest off the main
  /// actor; a call during a pass schedules one more pass afterwards.
  @ObservationIgnored private var hasRun = false

  public func update(from library: UnifiedLibraryModel) {
    let snapshot = library.indexSnapshot()
    let cloud = library.cloud?.library
    let pass = ScheduledPass(
      snapshot: snapshot,
      libraryReloadToken: library.reloadToken,
      libraryBadgeToken: library.badgeToken,
      deviceReloadToken: library.device.reloadToken,
      deviceBadgeToken: library.device.badgeToken,
      cloudRevision: cloud?.revision ?? 0,
      cloudLocalCopyRevision: cloud?.localCopyRevision ?? 0,
      cloudInitialSyncDone: cloud?.syncState.initialSyncDone ?? false,
      cloudIsSyncing: cloud?.isSyncing ?? false,
      localAssets: cloud?.localAssetIDs ?? [:],
      localFiles: cloud?.localFiles ?? [:])
    lastPass = pass
    schedule(pass)
  }

  private func schedule(_ pass: ScheduledPass) {
    guard task == nil else {
      pendingPass = pass
      return
    }
    let isFirstRun = !hasRun
    hasRun = true
    task = Task {
      // At launch the grid's first thumbnails come first: indexing reads the same
      // PhotoKit cache and the same main actor.
      if isFirstRun { try? await Task.sleep(for: .seconds(3)) }
      var next: ScheduledPass? = pendingPass ?? pass
      while let current = next, !Task.isCancelled {
        pendingPass = nil
        await run(current)
        next = pendingPass
      }
      task = nil
    }
  }

  public func stop() {
    task?.cancel()
  }

  struct WorkItem: Sendable {
    let id: String
    let metadata: ItemMetadata
    /// The device asset to analyze (with feature print); nil when not a primary device row.
    let assetID: String?
    /// A local backed-up folder file to decode directly instead of downloading from Google.
    var file: FolderItemInfo?
    /// A known local PhotoKit copy for a cloud row, decoded locally without feature print.
    var localAssetID: String?
    /// The Google Photos thumbnail to analyze, for an item that isn't on the device or whose
    /// local file couldn't be read.
    var cloud: RemoteThumbnailID?
  }

  /// Work for items not yet settled in the index. Words are built only for those.
  nonisolated static func workItems(
    _ snapshot: UnifiedLibraryModel.IndexSnapshot, settled: Set<String>,
    localAssets: [String: String] = [:], localFiles: [String: FolderItemInfo] = [:]
  ) -> [WorkItem] {
    let words = DateWords()
    var items: [WorkItem] = []
    for entry in snapshot.entries {
      switch entry {
      case .device(let index, _):
        guard snapshot.device.indices.contains(index) else { continue }
        let info = snapshot.device[index]
        guard !settled.contains(info.localIdentifier) else { continue }
        items.append(
          WorkItem(
            id: info.localIdentifier,
            metadata: ItemMetadata(
              id: info.localIdentifier, date: info.date, words: PhotoLibraryGridModel.kindWords(info) + words(info.date)),
            assetID: info.localIdentifier))
      case .folder(let index, cloud: nil):
        // Found by its name, folder, kind and date; a backed-up one is found as its
        // Google Photos copy.
        guard snapshot.folder.indices.contains(index) else { continue }
        let file = snapshot.folder[index]
        guard !settled.contains(file.id) else { continue }
        var fileWords = words(file.date)
        fileWords.append(file.isVideo ? "video" : "photo")
        for name in [file.fileName, file.folderName] {
          fileWords.append(contentsOf: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        items.append(WorkItem(id: file.id, metadata: ItemMetadata(id: file.id, date: file.date, words: fileWords), assetID: nil))
      case .folder(let folderIndex, cloud: .some(let cloudIndex)):
        guard snapshot.cloud.indices.contains(cloudIndex) else { continue }
        let item = snapshot.cloud[cloudIndex]
        let id = searchID(cloudMediaKey: item.mediaKey)
        guard !settled.contains(id) else { continue }
        let localFile = snapshot.folder.indices.contains(folderIndex) ? snapshot.folder[folderIndex] : localFiles[item.mediaKey]
        items.append(
          WorkItem(
            id: id, metadata: cloudMetadata(item, id: id, words: words), assetID: nil,
            file: localFile,
            cloud: RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion)))
      case .cloud(let index):
        guard snapshot.cloud.indices.contains(index) else { continue }
        let item = snapshot.cloud[index]
        let id = searchID(cloudMediaKey: item.mediaKey)
        guard !settled.contains(id) else { continue }
        items.append(
          WorkItem(
            id: id, metadata: cloudMetadata(item, id: id, words: words), assetID: nil,
            file: localFiles[item.mediaKey],
            localAssetID: localAssets[item.mediaKey],
            cloud: RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion)))
      }
    }
    return items
  }

  private nonisolated static func cloudMetadata(_ item: RemoteItemSummary, id: String, words: DateWords) -> ItemMetadata {
    var itemWords = words(item.takenAt)
    itemWords.append(item.kind == .video ? "video" : "photo")
    itemWords.append(
      contentsOf: item.fileName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    if item.isFavorite { itemWords.append("favorite") }
    itemWords.append("google")
    return ItemMetadata(id: id, date: item.takenAt, words: itemWords)
  }

  /// The index key of every item in the library, as `workItems` keys them.
  nonisolated static func indexIDs(_ snapshot: UnifiedLibraryModel.IndexSnapshot) -> Set<String> {
    var ids = Set<String>(minimumCapacity: snapshot.entries.count)
    for entry in snapshot.entries {
      switch entry {
      case .device(let index, _):
        if snapshot.device.indices.contains(index) { ids.insert(snapshot.device[index].localIdentifier) }
      case .folder(let index, cloud: nil):
        if snapshot.folder.indices.contains(index) { ids.insert(snapshot.folder[index].id) }
      case .cloud(let index), .folder(_, cloud: .some(let index)):
        if snapshot.cloud.indices.contains(index) { ids.insert(searchID(cloudMediaKey: snapshot.cloud[index].mediaKey)) }
      }
    }
    return ids
  }

  /// The index key of a Google Photos item.
  public nonisolated static func searchID(cloudMediaKey: String) -> String { "g:" + cloudMediaKey }

  /// Pairs `(from, to)` moving analysis from confirmed-deleted device/folder items to their
  /// Google Photos ids for the browsed account.
  nonisolated static func rekeyPairs(for records: [TransferRecord], accountEmail: String) -> [(from: String, to: String)] {
    var pairs: [(from: String, to: String)] = []
    var seen = Set<String>()
    for record in records where record.resourceRole == .primary {
      guard let mediaKey = record.mediaKeysByAccount[accountEmail], !mediaKey.isEmpty else { continue }
      let target = searchID(cloudMediaKey: mediaKey)
      if let assetID = record.assetLocalIdentifier, !assetID.isEmpty {
        if seen.insert(assetID).inserted { pairs.append((from: assetID, to: target)) }
      } else if let sourcePath = record.sourcePath, !sourcePath.isEmpty {
        let rawID = FolderItemInfo.idPrefix + sourcePath
        if seen.insert(rawID).inserted { pairs.append((from: rawID, to: target)) }
        let standardized = TransferManifestStore.standardizedPath(sourcePath)
        let standardizedID = FolderItemInfo.idPrefix + standardized
        if standardizedID != rawID, seen.insert(standardizedID).inserted {
          pairs.append((from: standardizedID, to: target))
        }
      }
    }
    return pairs
  }

  /// Call after deletion succeeds. The caller never waits on the mirror or index.
  @discardableResult
  public static func scheduleRekeyDeleted(
    _ records: [TransferRecord], cloud: CloudLibrary, store: LibraryIndexStore = SiriLibrary.shared.store
  ) -> Task<Void, Never>? {
    guard !records.isEmpty, !cloud.isRetired else { return nil }
    return Task(priority: .utility) {
      await rekeyDeleted(records, cloud: cloud, store: store)
    }
  }

  private static func rekeyDeleted(
    _ records: [TransferRecord], cloud: CloudLibrary, store: LibraryIndexStore
  ) async {
    let email = cloud.accountEmail
    guard !cloud.isRetired, LockedItems.isKnown(accountEmail: email) else { return }
    let pairs = await Task.detached(priority: .utility) {
      rekeyPairs(for: records, accountEmail: email)
    }.value
    let keys = pairs.map { String($0.to.dropFirst(2)) }
    guard let visible = try? await cloud.store.visibleMediaKeys(in: keys), !cloud.isRetired else { return }
    let confirmed = zip(pairs, keys).filter { visible.contains($0.1) }.map { $0.0 }
    try? await store.rekeyKnownUnlocked(confirmed, cloud: cloud)
  }

  /// Month, weekday and year words in English and the current language, from symbol
  /// tables built once instead of a date format per item.
  struct DateWords: Sendable {
    private let calendar = Calendar(identifier: .gregorian)
    private let months: [[String]]
    private let weekdays: [[String]]

    init() {
      var months: [[String]] = []
      var weekdays: [[String]] = []
      for locale in [Locale(identifier: "en_US"), Locale.current] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        months.append(calendar.monthSymbols)
        weekdays.append(calendar.weekdaySymbols)
      }
      self.months = months
      self.weekdays = weekdays
    }

    func callAsFunction(_ date: Date) -> [String] {
      let parts = calendar.dateComponents([.year, .month, .weekday], from: date)
      var words = Set<String>()
      if let month = parts.month { for table in months where table.indices.contains(month - 1) { words.insert(table[month - 1]) } }
      if let weekday = parts.weekday {
        for table in weekdays where table.indices.contains(weekday - 1) { words.insert(table[weekday - 1]) }
      }
      if let year = parts.year { words.insert(String(year)) }
      return Array(words)
    }
  }

  private func run(_ pass: ScheduledPass) async {
    await spotlight?.waitForAccountEviction()
    let snapshot = pass.snapshot
    guard snapshot.cloudLibrary?.isIndexingCurrent != false else { return }
    let networkAllowed = Self.allowsCloudAnalysis()
    let fingerprint = PassFingerprint(
      structural: StructuralFingerprint(
        libraryReloadToken: pass.libraryReloadToken,
        deviceReloadToken: pass.deviceReloadToken,
        cloud: snapshot.cloudLibrary.map(ObjectIdentifier.init),
        cloudRevision: pass.cloudRevision,
        cloudLocalCopyRevision: pass.cloudLocalCopyRevision,
        cloudInitialSyncDone: pass.cloudInitialSyncDone,
        cloudIsSyncing: pass.cloudIsSyncing,
        isComplete: snapshot.inputs.isComplete,
        isFiltered: snapshot.inputs.isFiltered,
        allowsCloudAnalysis: networkAllowed),
      libraryBadgeToken: pass.libraryBadgeToken,
      deviceBadgeToken: pass.deviceBadgeToken,
      peopleSignal: peopleSignal)
    let needsPeople = (try? await store.needsPeoplePass()) ?? true
    let retryDue = ContinuousClock.now - lastCompletedAt >= .seconds(3_600)
    if let last = lastCompletedFingerprint, last == fingerprint, !needsPeople, !retryDue {
      return
    }
    if let last = lastCompletedFingerprint, last.structural == fingerprint.structural, !retryDue {
      // Only People or badge metadata changed: skip scanning and pruning the whole library.
      if needsPeople, await updatePeople() { contentRevision &+= 1 }
      await syncSpotlight(pass)
      if !Task.isCancelled, pendingPass == nil {
        lastCompletedFingerprint = fingerprint
      }
      return
    }

    let store = store
    // Only a complete merge says what's gone; a list still loading (or a first sync
    // under way) would make loaded items look deleted.
    if snapshot.inputs.isComplete {
      let current = await Task.detached(priority: .utility) { Self.indexIDs(snapshot.unfiltered()) }.value
      let cloudSynced = snapshot.cloudLibrary != nil && snapshot.cloudLibrary?.isRetired == false && pass.cloudInitialSyncDone
      let pruned =
        (try? await store.prune(
          keeping: current, device: !snapshot.device.isEmpty, folder: !snapshot.folder.isEmpty, cloud: cloudSynced,
          source: snapshot.cloudLibrary)) ?? 0
      if pruned > 0 {
        FaceCropCache.removeAll()
        _ = await updatePeople()
        contentRevision &+= 1
      }
    }
    guard let settled = try? await store.settledIDs() else { return }
    let localAssets = pass.localAssets
    let localFiles = pass.localFiles
    let pending = await Task.detached(priority: .utility) {
      Self.workItems(snapshot, settled: settled, localAssets: localAssets, localFiles: localFiles)
    }.value
    // Google items wait here until their thumbnail has been analyzed; their metadata is
    // saved only the first time.
    let known = pending.isEmpty ? [] : ((try? await store.analyzedIDs()) ?? [])
    let metadataFirst = pending.filter { $0.assetID == nil && !known.contains($0.id) }
    // A device photo kept in iCloud that still needs its larger preview waits for the
    // network like a Google one does, instead of being analyzed again on every pass.
    let device = pending.filter { $0.assetID != nil && (networkAllowed || !known.contains($0.id)) }
    // Backed-up folder files and locally-matched cloud copies analyze locally regardless of network policy.
    let localFolderItems = pending.filter { $0.file != nil }
    let localAliasedDevice = pending.filter { $0.file == nil && $0.localAssetID != nil }
    let thumbnails = snapshot.cloudLibrary?.thumbnails as? GoogleThumbnailSource
    let remoteOnly = pending.filter { $0.file == nil && $0.localAssetID == nil && $0.cloud != nil }
    let waiting = thumbnails == nil ? [] : remoteOnly
    let cloud = networkAllowed ? waiting : []
    let total = metadataFirst.count + device.count + localFolderItems.count + localAliasedDevice.count + cloud.count
    guard total > 0 else {
      if await updatePeople() { contentRevision &+= 1 }
      state = waiting.isEmpty ? .idle : .paused(reason: Self.waitingForWiFi)
      await syncSpotlight(pass)
      if !Task.isCancelled, pendingPass == nil {
        lastCompletedFingerprint = fingerprint
        lastCompletedAt = .now
      }
      return
    }
    state = .indexing(done: 0, total: total)
    var completed = 0
    func progressed(by count: Int) {
      let before = completed
      completed += count
      if completed / 20 != before / 20 || completed == total {
        state = .indexing(done: completed, total: total)
        revision &+= 1
      }
      if completed / 500 != before / 500 { contentRevision &+= 1 }
    }

    // Metadata first, hundreds per transaction: everything is findable by date, name
    // and place before any pixels are read.
    for start in stride(from: 0, to: metadataFirst.count, by: 500) where !Task.isCancelled {
      let chunk = Array(metadataFirst[start..<min(start + 500, metadataFirst.count)])
      let metadata = await Self.metadata(for: chunk, in: snapshot)
      try? await store.saveAll(metadata.map { ($0, nil) }, pixelsPending: true, cloud: snapshot.cloudLibrary)
      progressed(by: chunk.count)
    }

    // Device items: assets fetched 64 at a time, analyzed two at a time, saved per chunk.
    var start = 0
    while start < device.count, !Task.isCancelled {
      if let reason = Self.pauseReason() {
        state = .paused(reason: reason)
        try? await Task.sleep(for: .seconds(30))
        continue
      }
      let chunk = Array(device[start..<min(start + 64, device.count)])
      start += chunk.count
      let assets = await Task.detached(priority: .utility) { Self.fetchAssets(chunk.compactMap(\.assetID)) }.value
      var results: [(metadata: ItemMetadata, analysis: ItemAnalysis?)] = []
      for pairStart in stride(from: 0, to: chunk.count, by: 2) where !Task.isCancelled {
        let pair = chunk[pairStart..<min(pairStart + 2, chunk.count)]
        let analyzed = await withTaskGroup(of: (ItemMetadata, ItemAnalysis?).self) { group in
          for item in pair {
            let asset = item.assetID.flatMap { assets[$0] }
            group.addTask(priority: .utility) {
              guard let asset, let image = await Self.thumbnail(asset: asset) else { return (item.metadata, nil) }
              let analysis = try? await ItemAnalyzer.analyze(image) {
                guard !Task.isCancelled, Self.pauseReason() == nil else { return nil }
                return await Self.thumbnail(asset: asset, side: 1536)
              }
              return (item.metadata, analysis)
            }
          }
          var collected: [(ItemMetadata, ItemAnalysis?)] = []
          for await result in group { collected.append(result) }
          return collected
        }
        results.append(contentsOf: analyzed.map { (metadata: $0.0, analysis: $0.1) })
        progressed(by: pair.count)
      }
      // Faces too small in the thumbnail, with the larger preview held back by the
      // network: tried again when it allows, not in a few days.
      let waits = !Self.allowsCloudAnalysis()
      try? await store.saveAll(results.filter { !(waits && $0.analysis?.facesIncomplete == true) })
      try? await store.saveAll(results.filter { waits && $0.analysis?.facesIncomplete == true }, pixelsPending: true)
      await updatePeopleIfDue()
    }

    // Backed-up folder files and locally-aliased cloud items: read local pixels directly,
    // falling back to Google only if a file is unreadable.
    var cloudFallback: [WorkItem] = []
    if !localFolderItems.isEmpty {
      cloudFallback += await analyzeLocalFiles(localFolderItems, in: snapshot, progressed: progressed)
    }
    if !localAliasedDevice.isEmpty {
      cloudFallback += await analyzeLocalAliasedAssets(localAliasedDevice, in: snapshot, progressed: progressed)
    }

    let cloudQueue = cloud + (Self.allowsCloudAnalysis() ? cloudFallback : [])
    var cloudFinished = true
    if let thumbnails, !cloudQueue.isEmpty {
      cloudFinished = await analyzeCloud(cloudQueue, in: snapshot, thumbnails: thumbnails, progressed: progressed)
    }
    await updatePeople()
    revision &+= 1
    contentRevision &+= 1
    let hasWaitingCloud = (!waiting.isEmpty || (!cloudFallback.isEmpty && thumbnails != nil)) && !Self.allowsCloudAnalysis()
    state = hasWaitingCloud ? .paused(reason: Self.waitingForWiFi) : .idle
    await syncSpotlight(pass)
    if cloudFinished, !Task.isCancelled, pendingPass == nil {
      lastCompletedFingerprint = fingerprint
      lastCompletedAt = .now
    } else {
      lastCompletedFingerprint = nil
    }
  }

  enum LocalFileAnalysis: Sendable {
    case analyzed(ItemAnalysis?)
    case unreadable
  }

  /// Decodes a local folder file directly (never downloading from Google), returning
  /// `.unreadable` if the file is unavailable so callers can fall back to Google if allowed.
  nonisolated static func analyzeFile(_ file: FolderItemInfo) async -> LocalFileAnalysis {
    let url = file.url
    let image: CGImage?
    if file.isVideo {
      image = await FolderThumbnailSource.videoFrame(url, side: thumbnailSide)
    } else {
      image = localFileImage(url, side: thumbnailSide)
    }
    guard let image else { return .unreadable }
    let analysis = try? await ItemAnalyzer.analyze(image, includesFeaturePrint: false) {
      guard !Task.isCancelled, pauseReason() == nil else { return nil }
      if file.isVideo { return await FolderThumbnailSource.videoFrame(url, side: 1536) }
      return localFileImage(url, side: 1536)
    }
    return .analyzed(analysis)
  }

  /// Single-pass ImageIO downsample of a local folder file at `side`, using an embedded
  /// preview only when the source is larger than `side` and the preview itself is big enough.
  nonisolated static func localFileImage(_ url: URL, side: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let maxPixel = Int(side.rounded(.up))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let sourceLongest = max(pixelWidth, pixelHeight)
    if sourceLongest == 0 || sourceLongest > maxPixel {
      let embeddedOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ]
      if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary),
        CGFloat(max(preview.width, preview.height)) >= side * 0.9
      {
        return preview
      }
    }
    let fullOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, fullOptions as CFDictionary)
  }

  /// Analyzes backed-up folder files locally without touching Google Photos. Returns any items
  /// whose local files were unreadable and have a Google copy to fall back on.
  func analyzeLocalFiles(
    _ items: [WorkItem], in snapshot: UnifiedLibraryModel.IndexSnapshot, progressed: (Int) -> Void
  ) async -> [WorkItem] {
    let store = store
    var fallback: [WorkItem] = []
    var start = 0
    while start < items.count, !Task.isCancelled {
      if let reason = Self.pauseReason() {
        state = .paused(reason: reason)
        try? await Task.sleep(for: .seconds(30))
        continue
      }
      let chunk = Array(items[start..<min(start + 32, items.count)])
      start += chunk.count
      let metadata = await Self.metadata(for: chunk, in: snapshot)
      var results: [(metadata: ItemMetadata, analysis: ItemAnalysis?)] = []
      for pairStart in stride(from: 0, to: chunk.count, by: 2) where !Task.isCancelled {
        let pairEnd = min(pairStart + 2, chunk.count)
        let analyzed = await withTaskGroup(of: (Int, LocalFileAnalysis).self) { group in
          for index in pairStart..<pairEnd {
            guard let file = chunk[index].file else { continue }
            group.addTask(priority: .utility) { (index, await Self.analyzeFile(file)) }
          }
          var collected: [(Int, LocalFileAnalysis)] = []
          for await result in group { collected.append(result) }
          return collected
        }
        for (index, outcome) in analyzed {
          switch outcome {
          case .analyzed(let analysis):
            results.append((metadata[index], analysis))
          case .unreadable:
            if chunk[index].cloud != nil { fallback.append(chunk[index]) }
          }
        }
        progressed(pairEnd - pairStart)
      }
      try? await store.saveAll(results, cloud: snapshot.cloudLibrary)
      await updatePeopleIfDue()
    }
    return fallback
  }

  private func analyzeLocalAliasedAssets(
    _ items: [WorkItem], in snapshot: UnifiedLibraryModel.IndexSnapshot, progressed: (Int) -> Void
  ) async -> [WorkItem] {
    let store = store
    var fallback: [WorkItem] = []
    var start = 0
    while start < items.count, !Task.isCancelled {
      if let reason = Self.pauseReason() {
        state = .paused(reason: reason)
        try? await Task.sleep(for: .seconds(30))
        continue
      }
      let chunk = Array(items[start..<min(start + 32, items.count)])
      start += chunk.count
      let metadata = await Self.metadata(for: chunk, in: snapshot)
      let assets = await Task.detached(priority: .utility) { Self.fetchAssets(chunk.compactMap(\.localAssetID)) }.value
      var results: [(metadata: ItemMetadata, analysis: ItemAnalysis?)] = []
      for pairStart in stride(from: 0, to: chunk.count, by: 2) where !Task.isCancelled {
        let pairEnd = min(pairStart + 2, chunk.count)
        let analyzed = await withTaskGroup(of: (Int, LocalFileAnalysis).self) { group in
          for index in pairStart..<pairEnd {
            let asset = chunk[index].localAssetID.flatMap { assets[$0] }
            group.addTask(priority: .utility) {
              guard let asset, let image = await Self.thumbnail(asset: asset) else { return (index, .unreadable) }
              let analysis = try? await ItemAnalyzer.analyze(image, includesFeaturePrint: false) {
                guard !Task.isCancelled, Self.pauseReason() == nil else { return nil }
                return await Self.thumbnail(asset: asset, side: 1536)
              }
              return (index, .analyzed(analysis))
            }
          }
          var collected: [(Int, LocalFileAnalysis)] = []
          for await result in group { collected.append(result) }
          return collected
        }
        for (index, outcome) in analyzed {
          switch outcome {
          case .analyzed(let analysis):
            results.append((metadata[index], analysis))
          case .unreadable:
            if chunk[index].cloud != nil { fallback.append(chunk[index]) }
          }
        }
        progressed(pairEnd - pairStart)
      }
      try? await store.saveAll(results, cloud: snapshot.cloudLibrary)
      await updatePeopleIfDue()
    }
    return fallback
  }

  /// Google Photos items, newest first as the timeline lists them, in groups of six whose
  /// thumbnails download two at a time (the Library's own have separate slots). It stops
  /// when the network no longer allows it or keeps failing (a 429 fails at once); what's
  /// left is picked up by a later pass. Returns whether all items were processed.
  private func analyzeCloud(
    _ items: [WorkItem], in snapshot: UnifiedLibraryModel.IndexSnapshot, thumbnails: GoogleThumbnailSource,
    progressed: (Int) -> Void
  ) async -> Bool {
    let store = store
    var start = 0
    var failures = 0
    // A library change waiting for its own pass goes first: new device photos are
    // indexed before the rest of these.
    while start < items.count, failures < 3, pendingPass == nil, !Task.isCancelled {
      if let reason = Self.pauseReason() {
        state = .paused(reason: reason)
        try? await Task.sleep(for: .seconds(30))
        continue
      }
      guard Self.allowsCloudAnalysis() else { return false }
      let chunk = Array(items[start..<min(start + 48, items.count)])
      start += chunk.count
      let metadata = await Self.metadata(for: chunk, in: snapshot)
      var results: [(metadata: ItemMetadata, analysis: ItemAnalysis?)] = []
      for groupStart in stride(from: 0, to: chunk.count, by: 6) where !Task.isCancelled {
        let analyzed = await withTaskGroup(of: (Int, CloudAnalysis).self) { group in
          for index in groupStart..<min(groupStart + 6, chunk.count) {
            guard let id = chunk[index].cloud else { continue }
            group.addTask(priority: .utility) { (index, await Self.analyze(id, from: thumbnails)) }
          }
          var collected: [(Int, CloudAnalysis)] = []
          for await result in group { collected.append(result) }
          return collected
        }
        for (index, outcome) in analyzed {
          switch outcome {
          case .analyzed(let analysis):
            failures = 0
            results.append((metadata[index], analysis))
          case .unavailable:
            failures += 1
          }
        }
        progressed(analyzed.count)
      }
      try? await store.saveAll(results, cloud: snapshot.cloudLibrary)
      await updatePeopleIfDue()
    }
    return start >= items.count && failures < 3
  }

  /// A pass over a whole library (after a new analysis version, hours for Google Photos
  /// items) groups the faces found so far every couple of minutes, so People fills in as
  /// it goes instead of staying empty until the end.
  private func updatePeopleIfDue() async {
    guard ContinuousClock.now - lastPeopleUpdate > .seconds(120) else { return }
    lastPeopleUpdate = .now
    if await updatePeople() { contentRevision &+= 1 }
  }

  nonisolated static var waitingForWiFi: String {
    String(localized: "Photos in Google Photos are analyzed when Wi-Fi is available.")
  }

  enum CloudAnalysis: Sendable {
    /// Nil when the thumbnail was there and couldn't be read: tried again in a few days.
    case analyzed(ItemAnalysis?)
    /// Not fetched (offline, signed out, told to slow down): left for a later pass.
    case unavailable
  }

  nonisolated static func analyze(_ id: RemoteThumbnailID, from thumbnails: GoogleThumbnailSource) async -> CloudAnalysis {
    do {
      guard let image = try await thumbnails.analysisImage(id, side: Int(thumbnailSide)) else { return .analyzed(nil) }
      // Similar Photos compares device photos only, so no feature print is made.
      let analysis = try? await ItemAnalyzer.analyze(image, includesFeaturePrint: false) {
        guard !Task.isCancelled, pauseReason() == nil, allowsCloudAnalysis() else { return nil }
        return try? await thumbnails.analysisImage(id, side: 1600)
      }
      return .analyzed(analysis)
    } catch GPhotosError.httpError(let status, _) where (400..<500).contains(status) && status != 429 && status != 401 {
      // Gone or refused for this item alone.
      return .analyzed(nil)
    } catch {
      return .unavailable
    }
  }

  /// Thumbnails for analysis are fetched where uploads are allowed: never in Low Data
  /// Mode, and on cellular or a personal hotspot only with that setting on.
  nonisolated static func allowsCloudAnalysis() -> Bool {
    let network = NetworkStatusMonitor.shared
    return network.isConnected && !network.isConstrained && (!network.isExpensive || usesMeteredNetworks.withLock { $0 })
  }

  /// The Use Cellular Data (Use Personal Hotspot) setting, kept current by each app.
  public nonisolated static let usesMeteredNetworks = OSAllocatedUnfairLock(initialState: false)

  /// The items' searchable words, with what the Google Photos mirror knows about its own
  /// (place, camera, caption).
  nonisolated static func metadata(
    for items: [WorkItem], in snapshot: UnifiedLibraryModel.IndexSnapshot
  ) async -> [ItemMetadata] {
    let keys = items.compactMap { $0.cloud?.mediaKey }
    let extra = keys.isEmpty ? [:] : await snapshot.cloudLibrary?.searchWords(mediaKeys: keys) ?? [:]
    return items.map { item in
      var metadata = item.metadata
      if let key = item.cloud?.mediaKey, let words = extra[key] {
        metadata.words += words.split(separator: " ").map(String.init)
      }
      return metadata
    }
  }

  private func syncSpotlight(_ pass: ScheduledPass) async {
    guard let spotlight, !Task.isCancelled else { return }
    let snapshot = pass.snapshot
    let context = pass.spotlightContext
    await Task.detached(priority: .utility) { _ = await spotlight.sync(snapshot, context: context) }.value
  }

  nonisolated static func fetchAssets(_ ids: [String]) -> [String: PHAsset] {
    var assets: [String: PHAsset] = [:]
    PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
      assets[asset.localIdentifier] = asset
    }
    return assets
  }

  nonisolated static func pauseReason() -> String? {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return String(localized: "Paused in Low Power Mode") }
    switch ProcessInfo.processInfo.thermalState {
    case .serious, .critical: return String(localized: "Paused while the device cools down")
    default: return nil
    }
  }

  /// A small thumbnail from what's on the device. A photo kept in iCloud often has only
  /// a smaller one here: its preview is fetched where data is free, and failing that the
  /// small local one is analyzed, which still finds what the photo shows.
  nonisolated static func thumbnail(asset: PHAsset, side: CGFloat = thumbnailSide) async -> CGImage? {
    if let image = await thumbnail(asset: asset, side: side, network: false, degraded: false) { return image }
    if allowsCloudAnalysis(), let image = await thumbnail(asset: asset, side: side, network: true, degraded: false) {
      return image
    }
    return side > thumbnailSide ? nil : await thumbnail(asset: asset, side: side, network: false, degraded: true)
  }

  /// Local-only PhotoKit image request without iCloud download.
  nonisolated static func localThumbnail(asset: PHAsset, side: CGFloat) async -> CGImage? {
    if let image = await thumbnail(asset: asset, side: side, network: false, degraded: false) { return image }
    return await thumbnail(asset: asset, side: side, network: false, degraded: true)
  }

  /// One delivery mode calls back once; the guard keeps a second call harmless.
  private nonisolated static func thumbnail(asset: PHAsset, side: CGFloat, network: Bool, degraded: Bool) async -> CGImage? {
    let options = PHImageRequestOptions()
    options.deliveryMode = degraded ? .fastFormat : .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = network
    options.isSynchronous = false
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(
        for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit,
        options: options
      ) { image, _ in
        guard
          resumed.withLock({ state in
            defer { state = true }
            return !state
          })
        else { return }
        continuation.resume(returning: image.flatMap(PhotoKitImageSource.cgImage))
      }
    }
  }

  // MARK: People

  /// Assigns faces found since the last run to people, then merges duplicate people.
  /// Skips the pass when no faces or cluster memberships changed since the last finished pass.
  @discardableResult
  func updatePeople() async -> Bool {
    var changed = false
    var mergeRounds = 0
    while !Task.isCancelled {
      guard (try? await store.needsPeoplePass()) == true else { break }
      if let reason = Self.pauseReason() {
        state = .paused(reason: reason)
        try? await Task.sleep(for: .seconds(30))
        continue
      }
      let pass = await peoplePass()
      changed = changed || pass.changed
      if pass.finished {
        if !Task.isCancelled, !pass.hadError, let cleanVersion = pass.cleanVersion {
          try? await store.markPeopleClean(version: cleanVersion)
        }
        // A merge during phase 2 bumps the clustering version; rerun until merges settle so
        // transitive merges finish and the final zero-merge pass marks the post-merge state clean.
        if pass.merged, !pass.hadError, !Task.isCancelled, mergeRounds < 8 {
          mergeRounds += 1
          continue
        }
        break
      }
    }
    return changed
  }

  /// One pass over unassigned faces and then every person; stops early if a pause starts.
  private func peoplePass() async -> (finished: Bool, changed: Bool, merged: Bool, hadError: Bool, cleanVersion: Int64?) {
    let store = store
    let work = Task.detached(priority: .utility) {
      () -> (finished: Bool, changed: Bool, merged: Bool, hadError: Bool, cleanVersion: Int64?) in
      var cursor: Int64 = 0
      var merging = false
      var changed = false
      var merged = false
      var cleanVersion = try? await store.peopleClusteringVersion()
      while !Task.isCancelled {
        guard Self.pauseReason() == nil else { return (false, changed, merged, false, nil) }
        let faces: [IndexedFace]
        if merging {
          let page: (faces: [IndexedFace], next: Int64)?
          do {
            page = try await store.peopleForMerging(after: cursor)
          } catch {
            return (true, changed, merged, true, nil)
          }
          guard let page else { return (true, changed, merged, false, cleanVersion) }
          faces = page.faces
          cursor = page.next
        } else {
          let page: [IndexedFace]
          do {
            page = try await store.facesForClustering(after: cursor)
          } catch {
            return (true, changed, merged, true, nil)
          }
          guard let last = page.filter({ $0.person == nil }).map(\.id).max() else {
            // Capture version after phase-1 assignments so a clean merge phase marks them clean,
            // while any concurrent external edit or actual merge during phase 2 stays dirty.
            cleanVersion = try? await store.peopleClusteringVersion()
            merging = true
            cursor = 0
            continue
          }
          faces = page
          cursor = last
        }
        let unassigned = faces.indices.filter { faces[$0].person == nil }
        let vectors = FeatureVectors(faces.map(\.featurePrint))
        var groups: [Int64: [Int]] = [:]
        for (index, face) in faces.enumerated() {
          if let person = face.person { groups[person, default: []].append(index) }
        }
        let next = ((try? await store.maxPersonID()) ?? 0) + 1
        let names = (try? await store.peopleNames()) ?? [:]
        let clustering = FaceClustering.assign(
          existing: groups.map { ($0.key, $0.value) }, unassigned: unassigned, nextPersonID: next,
          itemID: { faces[$0].itemID }, names: names, buckets: { faces[$0].buckets },
          // Merges run only in their own pass, where nothing is being assigned: the store
          // can still refuse one, and assignments must not depend on it.
          allowsMerging: merging
        ) { vectors.distance($0, $1) }
        var assignments: [Int64: Int64] = [:]
        for (index, person) in clustering.assignments { assignments[faces[index].id] = person }
        do {
          if try await store.mergePeople(clustering.merges) {
            changed = true
            merged = true
          }
          try await store.assignFaces(assignments)
          if !assignments.isEmpty { changed = true }
        } catch { return (true, changed, merged, true, nil) }
      }
      return (false, changed, merged, false, nil)
    }
    return await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
  }

  // MARK: Search

  /// Ids matching a free-text query. Each word also matches nearby words from the labels
  /// Vision found ("puppy" finds "dog"), using the on-device word embedding.
  public func search(_ query: String) async -> [String] {
    // The store caches its labels until the next write, so results follow indexing.
    let vocabulary = (try? await store.labelVocabulary()) ?? LibraryIndexStore.LabelVocabulary(labels: [])
    let ids = await Self.search(query, in: store, vocabulary: vocabulary, people: namedSearchPeople())
    return await SiriLibrary.shared.excludingLockedIDs(ids, cloud: lastPass?.snapshot.cloudLibrary)
  }

  /// The search behind `search(_:)`, also for callers without an indexer (Siri): `people`
  /// are the named people to match, read from the store when not given. While typing, the
  /// last word is completed ("bea" finds "beach"); Siri's words are whole.
  nonisolated static func search(
    _ query: String, in store: LibraryIndexStore, vocabulary: [String], people: [LibraryIndexStore.NamedPerson]? = nil,
    completingLastWord: Bool? = nil
  ) async -> [String] {
    await search(
      query, in: store, vocabulary: LibraryIndexStore.LabelVocabulary(labels: vocabulary), people: people,
      completingLastWord: completingLastWord)
  }

  nonisolated static func search(
    _ query: String, in store: LibraryIndexStore, vocabulary: LibraryIndexStore.LabelVocabulary,
    people: [LibraryIndexStore.NamedPerson]? = nil, completingLastWord: Bool? = nil
  ) async -> [String] {
    let words = SearchVocabulary.tokens(query)
    guard !words.isEmpty else { return [] }
    let terms = await Task.detached(priority: .userInitiated) { Self.expand(words, vocabulary: vocabulary) }.value
    let completes = completingLastWord ?? (query.last?.isWhitespace != true)
    var ids = (try? await store.search(terms, completingLastWord: completes)) ?? []
    let named: [LibraryIndexStore.NamedPerson]
    if let people {
      named = people
    } else {
      named = (try? await store.namedPeople()) ?? []
    }
    var matches: [String] = []
    for person in named {
      guard Self.matchesName(person.name, query: query) else { continue }
      matches += (try? await store.ids(ofPerson: person.id)) ?? []
    }
    var uniquePeople = Set<String>()
    matches = matches.filter { uniquePeople.insert($0).inserted }
    if !matches.isEmpty {
      let seen = Set(ids)
      ids = matches.filter { !seen.contains($0) } + ids
    }
    return ids
  }

  public func categories(limit: Int = 24, minimumCount: Int = 3) async -> [SearchCategory] {
    (try? await store.categories(limit: limit, minimumCount: minimumCount)) ?? []
  }

  /// The UI should debounce/cancel typing tasks. Person suggestions use the existing
  /// visible-People API; no new face grouping or naming behavior lives here.
  public func suggestions(for prefix: String, limit: Int = 12) async -> [SearchSuggestion] {
    let text = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard limit > 0, text.count >= 2 || SearchVocabulary.isUnspaced(text) else { return [] }
    let people = await namedSearchPeople()
    var suggestions: [SearchSuggestion] = []
    for person in people where suggestions.count < limit {
      guard Self.matchesName(person.name, query: prefix) else { continue }
      suggestions.append(
        SearchSuggestion(kind: .person, title: person.name, query: person.name, count: person.photoCount))
    }
    suggestions += (try? await store.suggestions(for: prefix, limit: limit)) ?? []
    return Array(suggestions.prefix(limit))
  }

  private func namedSearchPeople() async -> [LibraryIndexStore.NamedPerson] {
    if searchPeopleRevision != contentRevision {
      let revision = contentRevision
      searchPeopleCache = (try? await store.namedPeople()) ?? []
      searchPeopleRevision = revision
    }
    return searchPeopleCache
  }

  nonisolated static func matchesName(_ name: String, query: String) -> Bool {
    // Names written without spaces ("山田太郎") match a given name anywhere in them.
    if SearchVocabulary.isUnspaced(query) {
      let needle = SearchVocabulary.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
      return !needle.isEmpty && SearchVocabulary.folded(name).contains(needle)
    }
    let nameWords = SearchVocabulary.tokens(name.folding(options: .diacriticInsensitive, locale: .current))
    let words = SearchVocabulary.tokens(query.folding(options: .diacriticInsensitive, locale: .current))
    guard !words.isEmpty else { return false }
    return words.enumerated().allSatisfy { index, word in
      nameWords.contains { candidate in
        candidate == word || (index == words.count - 1 && word.count >= 2 && candidate.hasPrefix(word))
      }
    }
  }

  nonisolated static func semanticAlternatives(_ neighbors: [(String, Double)], labels: Set<String>) -> [String] {
    neighbors.filter { $0.1 < 0.35 && labels.contains($0.0) }.prefix(1).map(\.0)
  }

  /// Each word with what else finds it: its other forms ("mountains"), the labels Vision
  /// uses for it ("hill"), and failing those the nearest label by meaning.
  nonisolated static func expand(_ words: [String], vocabulary: [String]) -> [[String]] {
    expand(words, vocabulary: LibraryIndexStore.LabelVocabulary(labels: vocabulary))
  }

  nonisolated static func expand(_ words: [String], vocabulary: LibraryIndexStore.LabelVocabulary) -> [[String]] {
    let labels = vocabulary.labelSet
    let labelWords = vocabulary.labelWords
    return words.map { word in
      let forms = SearchVocabulary.forms(word)
      var alternatives = forms
      for key in [word] + forms {
        if let alias = SearchVocabulary.aliases[key], labels.contains(alias) { alternatives.append(alias) }
        alternatives += (SearchVocabulary.related[key] ?? []).filter(labels.contains)
      }
      // A recognized subject must not expand to a nearby, different subject (dog -> cat).
      if alternatives.count == forms.count, !([word] + forms).contains(where: labelWords.contains), word.count > 2 {
        alternatives += semanticAlternatives(
          EnglishEmbeddingCache.shared.neighbors(for: word, maximumCount: 8), labels: labelWords)
      }
      var seen: Set<String> = [word]
      return [word] + alternatives.filter { seen.insert($0).inserted }
    }
  }
}

/// Loads the system English word embedding once per process instead of per search keystroke.
private final class EnglishEmbeddingCache: @unchecked Sendable {
  static let shared = EnglishEmbeddingCache()
  private let lock = NSLock()
  private var loaded = false
  private var embedding: NLEmbedding?

  func neighbors(for word: String, maximumCount: Int) -> [(String, Double)] {
    lock.withLock {
      if !loaded {
        embedding = NLEmbedding.wordEmbedding(for: .english)
        loaded = true
      }
      return embedding?.neighbors(for: word, maximumCount: maximumCount) ?? []
    }
  }
}
