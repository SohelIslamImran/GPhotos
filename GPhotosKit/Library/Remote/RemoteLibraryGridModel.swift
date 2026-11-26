import Foundation
import Observation
import Photos

/// A Google Photos scope as a grid data source. Items are an in-memory array of
/// summaries read from the mirror, reloaded whenever the library's revision changes.
@MainActor
@Observable
public final class RemoteLibraryGridModel: PhotoGridDataSource {
  public let library: CloudLibrary
  public let scope: RemoteScope
  public private(set) var items: [RemoteItemSummary] = []
  public private(set) var reloadToken = 0
  private var badgeRevision = 0
  private(set) var matchRevision = 0
  public var badgeToken: Int { badgeRevision &+ thumbnailRevision }
  public var thumbnailRevision: Int { library.localCopyRevision }
  public private(set) var isLoaded = false
  /// The mirror couldn't be read last time. The items are those read before, and
  /// `reloadIfNeeded` tries again.
  public private(set) var loadFailed = false
  /// Month sections, for a grid that shows month titles; empty without `buildsTimeline`.
  public private(set) var timeline = TimelineIndex()
  /// The merged Library builds its own timeline from these items, so it doesn't ask.
  private let buildsTimeline: Bool
  /// Media keys the device also has (from the backup manifest), shown with a badge.
  @ObservationIgnored private var positionsByMediaKey: [String: Int] = [:]
  @ObservationIgnored private var onDevice: Set<String> = []
  /// The library revision the items were read at, set once they're in place.
  @ObservationIgnored private var loadedRevision = -1
  @ObservationIgnored private var loading: Task<Bool, Never>?

  public init(library: CloudLibrary, scope: RemoteScope, buildsTimeline: Bool = false) {
    self.library = library
    self.scope = scope
    self.buildsTimeline = buildsTimeline
  }

  public var itemCount: Int { items.count }
  public var thumbnailSource: any ThumbnailSource { library.localFirstThumbnails }

  /// Returns once the items are those of the library's current revision, or the mirror
  /// couldn't be read. Callers that arrive during a load wait for it rather than returning
  /// early with older items.
  public func reloadIfNeeded() async {
    while library.revision != loadedRevision {
      let task: Task<Bool, Never>
      if let loading {
        task = loading
      } else {
        let revision = library.revision
        task = Task {
          defer { loading = nil }
          return await load(revision: revision)
        }
        loading = task
      }
      guard await task.value else { return }
    }
  }

  /// False when the mirror couldn't be read; nothing changes then.
  private func load(revision: Int) async -> Bool {
    guard let loaded = try? await library.summaries(scope) else {
      // A library switched away from has nothing more to read.
      if !library.isRetired { loadFailed = true }
      return false
    }
    if loadFailed { loadFailed = false }
    // Comparing and indexing 100k summaries happens off the main actor.
    let current = items
    let buildsTimeline = buildsTimeline
    let change = await Task.detached(priority: .userInitiated) { () -> Change in
      guard loaded != current else { return .none }
      guard
        loaded.count != current.count
          || !zip(loaded, current).allSatisfy({
            $0.mediaKey == $1.mediaKey && $0.contentVersion == $1.contentVersion && $0.takenAt == $1.takenAt
          })
      else {
        let affectsMatching = !zip(loaded, current).allSatisfy { new, old in
          new.hasSameMatchingMetadata(as: old)
        }
        return .flags(affectsMatching: affectsMatching)
      }
      let positions = Dictionary(loaded.enumerated().map { ($0.element.mediaKey, $0.offset) }, uniquingKeysWith: min)
      let timeline = buildsTimeline ? TimelineIndex.build(count: loaded.count) { loaded[$0].takenAt } : TimelineIndex()
      return .items(timeline, positions)
    }.value
    loadedRevision = revision
    if !isLoaded { isLoaded = true }
    switch change {
    case .none: break
    // Same items in the same order with new flags (a favorite) only refreshes badges.
    case .flags(let affectsMatching):
      items = loaded
      badgeRevision &+= 1
      if affectsMatching { matchRevision &+= 1 }
    case .items(let index, let positions):
      positionsByMediaKey = positions
      items = loaded
      timeline = index
      reloadToken &+= 1
      matchRevision &+= 1
    }
    return true
  }

  private enum Change: Sendable {
    case none
    case flags(affectsMatching: Bool)
    case items(TimelineIndex, [String: Int])
  }

  @ObservationIgnored private var deviceMatchesRevision = 0

  /// Marks items that were backed up from this device, by media key in the manifest.
  public func updateDeviceMatches(from records: [TransferRecord]) async {
    deviceMatchesRevision &+= 1
    let revision = deviceMatchesRevision
    let email = library.accountEmail
    let needsRegistration = library.localFirstThumbnails.needsRegistration
    let (keys, assets, versions) = await Task.detached(priority: .utility) {
      () -> (Set<String>, [String: String], [String: PhotoBackupEvidence.Version]) in
      let keys = Set(records.compactMap { $0.mediaKeysByAccount[email] })
      guard needsRegistration else { return (keys, [:], [:]) }
      let ids = Set(
        records.lazy.compactMap { record in
          record.resourceRole == .primary && record.isTerminalSuccess && record.mediaKeysByAccount[email] != nil
            ? record.assetLocalIdentifier : nil
        })
      var versions: [String: PhotoBackupEvidence.Version] = [:]
      if !ids.isEmpty, PhotoLibraryGridModel.hasAccess {
        let options = AssetExportService.allFramesFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options).enumerateObjects { asset, _, _ in
          if !asset.isHidden { versions[asset.localIdentifier] = .init(AssetExportService.version(of: asset)) }
        }
      }
      let uploads = UnifiedLibraryModel.uploadEvidence(records, email: email, versions: versions)
      var assets: [String: String] = [:]
      for (id, copies) in uploads.keys {
        for key in copies { assets[key] = id }
      }
      return (keys, assets, versions)
    }.value
    guard revision == deviceMatchesRevision, !Task.isCancelled, !library.isRetired else { return }
    library.registerLocalCopies(assets: assets, versions: versions)
    guard keys != onDevice else { return }
    onDevice = keys
    badgeRevision &+= 1
  }

  public func item(at index: Int) -> RemoteItemSummary? {
    items.indices.contains(index) ? items[index] : nil
  }

  public func items(at indices: Set<Int>) -> [RemoteItemSummary] { indices.sorted().compactMap(item(at:)) }

  func positions(for keys: Set<String>) -> Set<Int> {
    Set(keys.compactMap { positionsByMediaKey[$0] })
  }

  func resolveSelection(_ keys: Set<String>) -> [RemoteItemSummary] {
    guard !library.isRetired else { return [] }
    return items(at: positions(for: keys)).filter {
      !LockedItems.contains($0.mediaKey, accountEmail: library.accountEmail)
    }
  }

  public func isOnDevice(_ item: RemoteItemSummary) -> Bool { onDevice.contains(item.mediaKey) }

  public func monthTitle(at index: Int) -> String? {
    guard scope != .trash, let month = timeline.month(containing: index) else { return nil }
    return month.start.formatted(.dateTime.month(.wide).year())
  }

  // MARK: PhotoGridDataSource

  public func itemID(at index: Int) -> String {
    guard let item = item(at: index) else { return "" }
    return RemoteThumbnailID(mediaKey: item.mediaKey, contentVersion: item.contentVersion).string
  }

  public func index(ofItemID id: String, near: Int) -> Int? {
    guard let id = RemoteThumbnailID(id), let index = positionsByMediaKey[id.mediaKey],
      items[index].contentVersion == id.contentVersion
    else { return nil }
    return index
  }

  public func thumbnailIdentity(at index: Int) -> ThumbnailIdentity {
    library.localFirstThumbnails.thumbnailIdentity(for: itemID(at: index))
  }

  public func aspectRatio(at index: Int) -> CGFloat? {
    guard let item = item(at: index), let width = item.width, let height = item.height, width > 0, height > 0
    else { return nil }
    return CGFloat(width) / CGFloat(height)
  }

  public func badges(at index: Int) -> PhotoGridBadges {
    guard let item = item(at: index) else { return PhotoGridBadges() }
    return PhotoGridBadges(
      videoDuration: item.kind == .video ? item.duration : nil, isFavorite: item.isFavorite,
      backup: onDevice.contains(item.mediaKey) ? .backedUp : nil)
  }

  public func accessibilityLabel(at index: Int) -> String {
    guard let item = item(at: index) else { return "" }
    return Self.accessibilityLabel(for: item)
  }

  static func accessibilityLabel(for item: RemoteItemSummary) -> String {
    let kind =
      switch item.kind {
      case .video: String(localized: "Video")
      case .motionPhoto: String(localized: "Motion Photo")
      case .photo: String(localized: "Photo")
      }
    var parts = [kind]
    parts.append(item.takenAt.formatted(date: .abbreviated, time: .shortened))
    if item.isFavorite { parts.append(String(localized: "Favorite")) }
    if let trashed = item.trashedAt { parts.append(Self.daysLeft(trashedAt: trashed)) }
    return parts.joined(separator: ", ")
  }

  /// "23 days left" for an item in Trash.
  nonisolated public static func daysLeft(trashedAt: Date, now: Date = Date()) -> String {
    let remaining = trashedAt.addingTimeInterval(CloudLibrary.trashRetention).timeIntervalSince(now)
    let days = max(0, Int((remaining / 86_400).rounded(.up)))
    return ProductCopy.inflected("^[\(days) day](inflect: true) left")
  }
}

extension RemoteItemSummary {
  public var duration: TimeInterval? { durationMs.map { Double($0) / 1000 } }
}
