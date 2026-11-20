import Foundation
import Observation
import Photos

/// Part of the photo library as a grid data source, newest first. A `PHFetchResult` is
/// lazy, so even a 100k-asset library costs nothing until cells ask for items.
@MainActor
@Observable
public final class PhotoLibraryGridModel: NSObject, PhotoGridDataSource {
  public let scope: LibraryScope
  public private(set) var filter: LibraryFilter = .all
  public private(set) var reloadToken = 0
  public private(set) var badgeToken = 0
  public private(set) var itemCount = 0
  public private(set) var isLoaded = false
  /// Month sections for date-ordered scopes; empty until built after each fetch.
  public private(set) var timeline = TimelineIndex()
  @ObservationIgnored public let thumbnailSource: any ThumbnailSource
  @ObservationIgnored private let imageSource: PhotoKitImageSource
  @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
  @ObservationIgnored private var backupStates: [String: PhotoGridBadges.Backup] = [:]
  @ObservationIgnored private var isObserving = false
  @ObservationIgnored private var fetchGeneration = 0
  @ObservationIgnored private var fetchInProgress = false
  @ObservationIgnored private var keyIndexCache: [Int: Int] = [:]
  @ObservationIgnored private var pendingApply: Task<Void, Never>?
  /// The newest fetch after a change, waiting for `applySoon`.
  @ObservationIgnored private var pendingFetch: PHFetchResult<PHAsset>?

  /// Off for the merged Library's device side, which builds one timeline for both.
  @ObservationIgnored let buildsTimeline: Bool

  public init(
    scope: LibraryScope = .all, filter: LibraryFilter = .all, buildsTimeline: Bool = true,
    imageSource: PhotoKitImageSource = .shared
  ) {
    self.buildsTimeline = buildsTimeline
    self.scope = scope
    self.filter = filter
    self.imageSource = imageSource
    self.thumbnailSource = imageSource
    super.init()
  }

  isolated deinit {
    if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
  }

  /// Fetches the scope once access is granted. After that the change observer keeps it
  /// current, so calling again does nothing.
  /// Whether the app may read the photo library (all of it, or the photos chosen).
  public nonisolated static var hasAccess: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
  }

  public func load() async {
    guard Self.hasAccess, fetchResult == nil else { return }
    await fetch()
    if !isObserving {
      PHPhotoLibrary.shared().register(self)
      isObserving = true
    }
  }

  public func setFilter(_ filter: LibraryFilter) async {
    guard filter != self.filter else { return }
    self.filter = filter
    await fetch()
  }

  private func fetch() async {
    fetchGeneration &+= 1
    pendingApply?.cancel()
    pendingFetch = nil
    let generation = fetchGeneration
    fetchInProgress = true
    defer { if generation == fetchGeneration { fetchInProgress = false } }
    let scope = scope
    let filter = filter
    let backedUp = filter.dependsOnBackup ? Set(backupStates.filter { $0.value == .backedUp }.keys) : []
    let result = await Task.detached(priority: .userInitiated) {
      LibraryFetch.assets(scope: scope, filter: filter, backedUpIDs: backedUp)
    }.value
    guard generation == fetchGeneration else { return }
    apply(result)
  }

  private func apply(_ result: PHFetchResult<PHAsset>) {
    keyIndexCache = [:]
    fetchResult = result
    itemCount = result.count
    isLoaded = true
    reloadToken &+= 1
    rebuildTimeline(result)
  }

  private func rebuildTimeline(_ result: PHFetchResult<PHAsset>) {
    guard scope.isDateOrdered, buildsTimeline else {
      timeline = TimelineIndex()
      return
    }
    let generation = fetchGeneration
    Task {
      let index = await Task.detached(priority: .utility) {
        TimelineIndex.build(count: result.count) { result.object(at: $0).creationDate }
      }.value
      guard generation == fetchGeneration, fetchResult === result else { return }
      timeline = index
    }
  }

  /// "October 2026" for the item at `index`.
  public func monthTitle(at index: Int) -> String? {
    guard let month = timeline.month(containing: index) else { return nil }
    return month.start.formatted(.dateTime.month(.wide).year())
  }

  /// The current fetch, for reading many assets off the main actor.
  var currentFetch: PHFetchResult<PHAsset>? { fetchResult }

  public func index(of asset: PHAsset) -> Int? {
    guard let fetchResult else { return nil }
    let index = fetchResult.index(of: asset)
    return index == NSNotFound ? nil : index
  }

  public func assets(at indices: Set<Int>) -> [PHAsset] {
    indices.sorted().compactMap(asset(at:))
  }

  /// `assets(at:)` off the main actor, for a selection that may be the whole library.
  public func resolveAssets(at indices: Set<Int>) async -> [PHAsset] {
    guard let fetch = fetchResult, !indices.isEmpty else { return [] }
    return await Task.detached(priority: .userInitiated) {
      indices.sorted().compactMap { $0 < fetch.count ? fetch.object(at: $0) : nil }
    }.value
  }

  /// Dates, sizes and flags of every item, for merging with Google Photos. Read off the
  /// main actor; the whole library comes from the saved snapshot and PhotoKit's history.
  public func deviceInfos() async -> [DeviceItemInfo] {
    guard let result = fetchResult else { return [] }
    let usesSnapshot = scope == .all && filter == .all
    return await Task.detached(priority: .userInitiated) {
      usesSnapshot ? DeviceInfoSnapshot.infos(for: result) : DeviceInfoSnapshot.readAll(result)
    }.value
  }

  nonisolated static func kindWords(_ info: DeviceItemInfo) -> [String] {
    var words = [info.isVideo ? "video" : "photo"]
    let subtypes = PHAssetMediaSubtype(rawValue: info.subtypes)
    if subtypes.contains(.photoLive) { words += ["live", "livephoto"] }
    if subtypes.contains(.photoScreenshot) { words.append("screenshot") }
    if subtypes.contains(.photoPanorama) { words.append("panorama") }
    if subtypes.contains(.photoDepthEffect) { words.append("portrait") }
    if subtypes.contains(.videoHighFrameRate) { words.append("slomo") }
    if subtypes.contains(.videoTimelapse) { words.append("timelapse") }
    if subtypes.contains(.videoCinematic) { words.append("cinematic") }
    if subtypes.contains(.spatialMedia) { words.append("spatial") }
    if info.isFavorite { words.append("favorite") }
    return words
  }

  /// The cover for a period: its newest favorite, else its newest photo.
  public func keyIndex(in range: Range<Int>) -> Int {
    if let cached = keyIndexCache[range.lowerBound] { return cached }
    let key = findKeyIndex(in: range)
    keyIndexCache[range.lowerBound] = key
    return key
  }

  private func findKeyIndex(in range: Range<Int>) -> Int {
    let window = range.prefix(300)
    var firstPhoto: Int?
    for index in window {
      guard let asset = asset(at: index) else { continue }
      if asset.isFavorite { return index }
      if firstPhoto == nil, asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoScreenshot) {
        firstPhoto = index
      }
    }
    return firstPhoto ?? range.lowerBound
  }

  public func backupState(at index: Int) -> PhotoGridBadges.Backup? {
    guard let asset = asset(at: index) else { return nil }
    return backupStates[asset.localIdentifier]
  }

  public func asset(at index: Int) -> PHAsset? {
    guard let fetchResult, index >= 0, index < fetchResult.count else { return nil }
    return fetchResult.object(at: index)
  }

  public func itemID(at index: Int) -> String {
    guard let asset = asset(at: index) else { return "" }
    imageSource.remember(asset)
    return asset.localIdentifier
  }

  public func aspectRatio(at index: Int) -> CGFloat? {
    guard let asset = asset(at: index), asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
    return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
  }

  public func badges(at index: Int) -> PhotoGridBadges {
    guard let asset = asset(at: index) else { return PhotoGridBadges() }
    return PhotoGridBadges(
      videoDuration: asset.mediaType == .video ? asset.duration : nil, isFavorite: asset.isFavorite,
      backup: backupStates[asset.localIdentifier])
  }

  public func accessibilityLabel(at index: Int) -> String {
    guard let asset = asset(at: index) else { return "" }
    let kind =
      switch asset.mediaType {
      case .video: String(localized: "Video")
      default: asset.mediaSubtypes.contains(.photoLive) ? String(localized: "Live Photo") : String(localized: "Photo")
      }
    var parts = [kind]
    if let date = asset.creationDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
    if asset.isFavorite { parts.append(String(localized: "Favorite")) }
    if let state = backupStates[asset.localIdentifier] { parts.append(state.title) }
    return parts.joined(separator: ", ")
  }

  /// Backup badges from the manifest. An asset with several records (RAW, Live Photo
  /// parts, several accounts) shows its worst state.
  @ObservationIgnored private var backupStateGeneration = 0

  public func updateBackupStates(
    from records: [TransferRecord], confirmedCloudAssets: [String: String] = [:], accountEmail: String? = nil
  ) async {
    backupStateGeneration &+= 1
    let generation = backupStateGeneration
    let states = await Task.detached(priority: .utility) {
      Self.backupStates(from: records, confirmedCloudIDs: Set(confirmedCloudAssets.values), accountEmail: accountEmail)
    }.value
    guard generation == backupStateGeneration, states != backupStates else { return }
    backupStates = states
    badgeToken &+= 1
    if filter.dependsOnBackup && (fetchResult != nil || fetchInProgress) { await fetch() }
  }

  nonisolated static func backupStates(
    from records: [TransferRecord], confirmedCloudIDs: Set<String> = [], accountEmail: String? = nil
  ) -> [String: PhotoGridBadges.Backup] {
    var states: [String: PhotoGridBadges.Backup] = [:]
    states.reserveCapacity(records.count)
    for record in records {
      if let accountEmail, !record.id.hasPrefix(accountEmail + "|") { continue }
      guard let id = record.assetLocalIdentifier else { continue }
      let state: PhotoGridBadges.Backup
      switch record.status {
      case .sent, .deleted: state = .backedUp
      case .failed: state = .failed
      default: state = .pending
      }
      switch (states[id], state) {
      case (.failed?, _), (.pending?, .backedUp): continue
      default: states[id] = state
      }
    }
    for id in confirmedCloudIDs where states[id] == nil { states[id] = .backedUp }
    return states
  }
}

extension PhotoLibraryGridModel: PHPhotoLibraryChangeObserver {
  nonisolated public func photoLibraryDidChange(_ changeInstance: PHChange) {
    let change = changeInstance
    Task { @MainActor in
      guard let current = self.pendingFetch ?? self.fetchResult, let details = change.changeDetails(for: current)
      else { return }
      let after = details.fetchResultAfterChanges
      if self.pendingFetch == nil, details.hasIncrementalChanges, !details.hasMoves, details.insertedIndexes == nil,
        details.removedIndexes == nil
      {
        // Only properties changed (favorites, edits): keep the layout, refresh badges.
        self.fetchResult = after
        self.badgeToken &+= 1
      } else {
        self.applySoon(after)
      }
    }
  }

  /// Bursts of changes (an import, iCloud catching up) re-lay out the grid once they
  /// pause. Lookups keep using the fetch the grid was laid out from until then: an insert
  /// shifts every index after it, so the newer fetch would put other photos in the cells.
  private func applySoon(_ result: PHFetchResult<PHAsset>) {
    pendingFetch = result
    pendingApply?.cancel()
    pendingApply = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let latest = pendingFetch else { return }
      pendingFetch = nil
      apply(latest)
    }
  }
}
