import Foundation
import Observation

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
  public var badgeToken: Int { badgeRevision &+ thumbnailRevision }
  public var thumbnailRevision: Int { library.localCopyRevision }
  public private(set) var isLoaded = false
  public private(set) var timeline = TimelineIndex()
  /// Media keys the device also has (from the backup manifest), shown with a badge.
  @ObservationIgnored private var onDevice: Set<String> = []
  @ObservationIgnored private var loadedRevision = -1
  @ObservationIgnored private var loadGeneration = 0

  public init(library: CloudLibrary, scope: RemoteScope) {
    self.library = library
    self.scope = scope
  }

  public var itemCount: Int { items.count }
  public var thumbnailSource: any ThumbnailSource { library.localFirstThumbnails }

  public func reloadIfNeeded() async {
    guard library.revision != loadedRevision else { return }
    loadedRevision = library.revision
    loadGeneration &+= 1
    let generation = loadGeneration
    let loaded = await library.summaries(scope)
    guard generation == loadGeneration else { return }
    // Comparing and indexing 100k summaries happens off the main actor.
    let current = items
    let change = await Task.detached(priority: .userInitiated) { () -> Change in
      guard loaded != current else { return .none }
      guard loaded.count != current.count || !zip(loaded, current).allSatisfy({ $0.mediaKey == $1.mediaKey }) else {
        return .flags
      }
      return .items(TimelineIndex.build(count: loaded.count) { loaded[$0].takenAt })
    }.value
    guard generation == loadGeneration else { return }
    isLoaded = true
    switch change {
    case .none: break
    // Same items in the same order with new flags (a favorite) only refreshes badges.
    case .flags:
      items = loaded
      badgeRevision &+= 1
    case .items(let index):
      items = loaded
      timeline = index
      reloadToken &+= 1
    }
  }

  private enum Change: Sendable {
    case none
    case flags
    case items(TimelineIndex)
  }

  /// Marks items that were backed up from this device, by media key in the manifest.
  public func updateDeviceMatches(from records: [TransferRecord]) async {
    let email = library.accountEmail
    let (keys, assets) = await Task.detached(priority: .utility) {
      let keys = Set(records.compactMap { $0.mediaKeysByAccount[email] })
      let assets = Dictionary(
        records.compactMap { record -> (String, String)? in
          guard let id = record.assetLocalIdentifier, let key = record.mediaKeysByAccount[email], record.isTerminalSuccess else {
            return nil
          }
          return (key, id)
        }, uniquingKeysWith: { first, _ in first })
      return (keys, assets)
    }.value
    library.registerLocalCopies(assets: assets)
    guard keys != onDevice else { return }
    onDevice = keys
    badgeRevision &+= 1
  }

  public func item(at index: Int) -> RemoteItemSummary? {
    items.indices.contains(index) ? items[index] : nil
  }

  public func items(at indices: Set<Int>) -> [RemoteItemSummary] { indices.sorted().compactMap(item(at:)) }

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
