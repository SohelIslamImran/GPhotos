import Foundation
import Photos

/// What the merge needs to know about a photo-library asset.
public struct DeviceItemInfo: Sendable, Equatable {
  public let localIdentifier: String
  public let date: Date
  public let width: Int
  public let height: Int
  public let isVideo: Bool
  public let isFavorite: Bool
  public var latitude: Double?
  public var longitude: Double?
  /// PhotoKit's media subtypes, kept as one number; search words come from it only for
  /// items being indexed.
  public var subtypes: UInt = 0
  var source: PHAssetSourceType = .typeUserLibrary
  var isMedia = true
  var isHidden = false
  var version = PhotoBackupEvidence.Version(.init(modifiedAt: nil))

  public init(
    localIdentifier: String, date: Date, width: Int, height: Int, isVideo: Bool, isFavorite: Bool,
    latitude: Double? = nil, longitude: Double? = nil, subtypes: UInt = 0
  ) {
    self.localIdentifier = localIdentifier
    self.date = date
    self.width = width
    self.height = height
    self.isVideo = isVideo
    self.isFavorite = isFavorite
    self.latitude = latitude
    self.longitude = longitude
    self.subtypes = subtypes
  }
}

/// One cell of the merged timeline.
public enum UnifiedEntry: Hashable, Sendable {
  /// A device asset (index into the device list), with the Google Photos item that holds
  /// the same photo, if any.
  case device(Int, cloud: Int?)
  /// A Google Photos item (index into the cloud list) with no copy on this device.
  case cloud(Int)
  /// A file in a backed-up folder (index into the folder list), with its Google Photos
  /// copy, if it has been backed up.
  case folder(Int, cloud: Int?)
}

/// Merges the device library and the Google Photos library into one timeline, oldest first
/// with the newest at the end as in Photos,
/// the way Immich merges local and remote assets: an item on both shows once, as the
/// device copy (faster to load, works offline), with a "backed up" badge.
///
/// Display matches use upload receipts, byte identity or a unique capture-time and
/// dimension match. Folder files can match by receipt or bytes.
public enum TimelineMerge {
  public static func merge(
    device: [DeviceItemInfo], cloud: [RemoteItemSummary], uploadedMediaKeys: [String: Set<String>],
    uploadedSHA1s: [String: Set<Data>] = [:],
    folder: [FolderItemInfo] = [], uploadedFileKeys: [String: String] = [:],
    filter: LibraryFilter = .all, hidesScreenshots: Bool = false
  ) -> [UnifiedEntry] {
    project(
      device: device, cloud: cloud, uploadedMediaKeys: uploadedMediaKeys, uploadedSHA1s: uploadedSHA1s,
      folder: folder, uploadedFileKeys: uploadedFileKeys, filter: filter, hidesScreenshots: hidesScreenshots
    ).entries
  }

  struct Projection: Sendable {
    var entries: [UnifiedEntry] = []
    var copies = LocalFirstThumbnailSource.LocalCopies()
    var confirmedFileIDs: Set<String> = []
  }

  static func project(
    device: [DeviceItemInfo], cloud: [RemoteItemSummary], uploadedMediaKeys: [String: Set<String>],
    uploadedSHA1s: [String: Set<Data>], folder: [FolderItemInfo], uploadedFileKeys: [String: String],
    filter: LibraryFilter, hidesScreenshots: Bool, backup: PhotoBackupEvidence? = nil,
    excludedFilePaths: Set<String> = [],
    extraFileKeys: [String: Set<String>] = [:]
  ) -> Projection {
    var projection = Projection()
    // A display preference must not hide work from the backup filters.
    let hidesScreenshots = hidesScreenshots && filter != .screenshots && !filter.dependsOnBackup
    var cloudIndexByKey: [String: Int] = [:]
    cloudIndexByKey.reserveCapacity(cloud.count)
    for (index, item) in cloud.enumerated() { cloudIndexByKey[item.mediaKey] = index }

    var matchOfDevice = [Int?](repeating: nil, count: device.count)
    var cloudMatched = [Bool](repeating: false, count: cloud.count)
    // Backup filters need to show the Google row if its local copy still needs backup.
    let separatesUnconfirmed = filter == .backedUp || filter == .cloudOnly
    var cloudHasBackedUpLocal = Set<Int>()
    var matchOfFolder = [Int?](repeating: nil, count: folder.count)
    // Byte identity and recorded uploads do not depend on dates, dimensions or which
    // local copy already claimed the cloud item. They are display evidence only.
    var cloudByHash: [Data: Int] = [:]
    var favoriteHashes = Set<Data>()
    var matchedHashes: [Data: String] = [:]
    if !uploadedSHA1s.isEmpty {
      for (index, item) in cloud.enumerated() {
        guard let hash = item.sha1, hash.count == 20 else { continue }
        if cloudByHash[hash] == nil { cloudByHash[hash] = index }
        if item.isFavorite { favoriteHashes.insert(hash) }
      }
    }

    var filesByHash: [Data: FolderItemInfo] = [:]
    var backedUpFileHashes = Set<Data>()
    for (index, item) in folder.enumerated() {
      let key = uploadedFileKeys[item.path]
      let keys = extraFileKeys[item.path] ?? key.map { [$0] } ?? []
      var match: Int?
      for key in keys {
        projection.copies.files[key] = item
        guard let index = cloudIndexByKey[key], !cloudMatched[index] else { continue }
        cloudMatched[index] = true
        match = min(match ?? index, index)
      }
      if uploadedFileKeys[item.path] != nil, separatesUnconfirmed {
        for key in keys { if let index = cloudIndexByKey[key] { cloudHasBackedUpLocal.insert(index) } }
      }
      for hash in uploadedSHA1s[item.id] ?? [] {
        guard let candidate = cloudByHash[hash] else { continue }
        if filesByHash[hash] == nil { filesByHash[hash] = item }
        if match == nil, !cloudMatched[candidate] { match = candidate }
        if !item.isLivePhoto { projection.confirmedFileIDs.insert(item.id) }
        if separatesUnconfirmed, !item.isLivePhoto || key != nil { backedUpFileHashes.insert(hash) }
      }
      guard let match else { continue }
      matchOfFolder[index] = match
      cloudMatched[match] = true
    }
    if !filesByHash.isEmpty {
      for (index, item) in cloud.enumerated() {
        guard let hash = item.sha1, let file = filesByHash[hash] else { continue }
        cloudMatched[index] = true
        if backedUpFileHashes.contains(hash) { cloudHasBackedUpLocal.insert(index) }
        if projection.copies.files[item.mediaKey] == nil { projection.copies.files[item.mediaKey] = file }
      }
    }
    // A copy collapsed into a device photo still makes that photo a favorite.
    var deviceHasFavoriteCopy = Set<Int>()
    // A folder file's claim doesn't count: the device copy of that photo still matches.
    var claimedByDevice = [Bool](repeating: false, count: cloud.count)
    var unmatchedDevice: [Int] = []
    var backedUpDeviceHashes = Set<Data>()
    func deviceIsBackedUp(_ item: DeviceItemInfo, confirmed: Bool) -> Bool {
      let state = backup?.state(for: item.localIdentifier, version: item.version.assetVersion)
      return state == .backedUp
        || (state == nil && confirmed)
        || (backup == nil && !(uploadedMediaKeys[item.localIdentifier]?.isEmpty ?? true))
    }
    for (index, item) in device.enumerated() where !item.isHidden {
      var matches = Set<Int>()
      var receiptMatch: Int?
      for key in uploadedMediaKeys[item.localIdentifier] ?? [] {
        if projection.copies.assets[key] == nil { projection.copies.assets[key] = item.localIdentifier }
        if let match = cloudIndexByKey[key] {
          receiptMatch = min(receiptMatch ?? match, match)
          matches.insert(match)
        }
      }
      for hash in uploadedSHA1s[item.localIdentifier] ?? [] {
        if let match = cloudByHash[hash] {
          matches.insert(match)
          if matchedHashes[hash] == nil { matchedHashes[hash] = item.localIdentifier }
          if !PHAssetMediaSubtype(rawValue: item.subtypes).contains(.photoLive) {
            projection.copies.confirmedAssetIDs.insert(item.localIdentifier)
          }
          if favoriteHashes.contains(hash) { deviceHasFavoriteCopy.insert(index) }
        }
      }
      if separatesUnconfirmed, deviceIsBackedUp(item, confirmed: projection.copies.confirmedAssetIDs.contains(item.localIdentifier)) {
        cloudHasBackedUpLocal.formUnion(matches)
        backedUpDeviceHashes.formUnion(uploadedSHA1s[item.localIdentifier] ?? [])
      }
      if matches.contains(where: { cloud[$0].isFavorite }) { deviceHasFavoriteCopy.insert(index) }
      if let match = receiptMatch ?? matches.min() {
        matchOfDevice[index] = match
        for match in matches {
          cloudMatched[match] = true
          claimedByDevice[match] = true
        }
      } else {
        unmatchedDevice.append(index)
      }
    }
    // Hide every byte-identical cloud copy in one pass, even when many local copies
    // share a hash. Expanding the whole hash group per device would be quadratic.
    if !matchedHashes.isEmpty {
      for (index, item) in cloud.enumerated() {
        if let hash = item.sha1, let id = matchedHashes[hash] {
          if projection.copies.assets[item.mediaKey] == nil { projection.copies.assets[item.mediaKey] = id }
          cloudMatched[index] = true
          claimedByDevice[index] = true
          if backedUpDeviceHashes.contains(hash) { cloudHasBackedUpLocal.insert(index) }
        }
      }
    }
    if !unmatchedDevice.isEmpty {
      // Count every device, including recorded matches, so removing a known burst
      // frame cannot make another frame look unique. Buckets bound work even for bursts.
      var cloudBuckets: [Signature: Bucket] = [:]
      var deviceBuckets: [Signature: Bucket] = [:]
      for (index, item) in cloud.enumerated() {
        let signature = Signature(item)
        if signature.isUsable { cloudBuckets[signature, default: Bucket()].add(index) }
      }
      for (index, item) in device.enumerated() {
        let signature = Signature(item)
        if signature.isUsable { deviceBuckets[signature, default: Bucket()].add(index) }
      }
      for index in unmatchedDevice {
        let signature = Signature(device[index])
        guard signature.isUsable,
          let match = uniqueCandidate(
            signature, date: device[index].date, buckets: cloudBuckets,
            dateAt: { cloud[$0].takenAt }),
          !claimedByDevice[match],
          uniqueCandidate(
            Signature(cloud[match]), date: cloud[match].takenAt, buckets: deviceBuckets,
            dateAt: { device[$0].date }) == index
        else { continue }
        matchOfDevice[index] = match
        cloudMatched[match] = true
        if separatesUnconfirmed, deviceIsBackedUp(device[index], confirmed: false) { cloudHasBackedUpLocal.insert(match) }
        projection.copies.assets[cloud[match].mediaKey] = device[index].localIdentifier
      }
    }

    func keepsDevice(_ index: Int) -> Bool {
      let item = device[index]
      let match = matchOfDevice[index].map { cloud[$0] }
      let subtypes = PHAssetMediaSubtype(rawValue: item.subtypes)
      if hidesScreenshots, subtypes.contains(.photoScreenshot) { return false }
      switch filter {
      case .all: return true
      case .favorites: return item.isFavorite || match?.isFavorite == true || deviceHasFavoriteCopy.contains(index)
      case .photos: return !item.isVideo
      case .videos: return item.isVideo
      case .livePhotos: return subtypes.contains(.photoLive)
      case .screenshots: return subtypes.contains(.photoScreenshot)
      case .notBackedUp, .notIncludedInBackup, .backedUp:
        let inScope =
          backup?.scope.includes(
            id: item.localIdentifier, source: item.source, isMedia: item.isMedia, isHidden: item.isHidden) ?? true
        let confirmed = projection.copies.confirmedAssetIDs.contains(item.localIdentifier)
        return filter.includesBackupItem(inScope: inScope, backedUp: deviceIsBackedUp(item, confirmed: confirmed))
      case .cloudOnly: return false
      }
    }
    func keepsCloud(_ index: Int) -> Bool {
      let item = cloud[index]
      if hidesScreenshots && Self.isScreenshot(item) { return false }
      switch filter {
      case .all, .backedUp, .cloudOnly: return true
      case .favorites: return item.isFavorite
      case .photos: return item.kind != .video
      case .videos: return item.kind == .video
      case .livePhotos: return item.kind == .motionPhoto
      case .screenshots: return Self.isScreenshot(item)
      case .notBackedUp, .notIncludedInBackup: return false
      }
    }

    func keepsFolder(_ index: Int) -> Bool {
      let item = folder[index]
      let match = matchOfFolder[index].map { cloud[$0] }
      let isScreenshot = !item.isVideo && Self.isScreenshot(fileName: item.fileName)
      if hidesScreenshots, isScreenshot { return false }
      switch filter {
      case .all: return true
      case .favorites: return match?.isFavorite == true
      case .photos: return !item.isVideo
      case .videos: return item.isVideo
      case .livePhotos: return item.isLivePhoto
      case .screenshots: return isScreenshot
      case .notBackedUp, .notIncludedInBackup, .backedUp:
        return filter.includesBackupItem(
          inScope: !excludedFilePaths.contains(item.path),
          backedUp: uploadedFileKeys[item.path] != nil || projection.confirmedFileIDs.contains(item.id))
      case .cloudOnly: return false
      }
    }

    // A backed-up file sorts by its Google Photos capture date, which is read from the
    // photo itself; the file's own dates are a fallback.
    var folderOrder: [(index: Int, date: Date)] = []
    folderOrder.reserveCapacity(folder.count)
    for index in folder.indices where keepsFolder(index) {
      folderOrder.append((index, matchOfFolder[index].map { cloud[$0].takenAt } ?? folder[index].date))
    }
    folderOrder.sort { $0.date > $1.date }

    var entries: [UnifiedEntry] = []
    entries.reserveCapacity(device.count + cloud.count + folderOrder.count)
    var f = 0
    var d = 0
    var c = 0
    while d < device.count || c < cloud.count {
      if c < cloud.count, separatesUnconfirmed ? cloudHasBackedUpLocal.contains(c) : cloudMatched[c] {
        c += 1
        continue
      }
      let takeDevice = c >= cloud.count || (d < device.count && device[d].date >= cloud[c].takenAt)
      let next = takeDevice ? device[d].date : cloud[c].takenAt
      while f < folderOrder.count, folderOrder[f].date > next {
        entries.append(.folder(folderOrder[f].index, cloud: matchOfFolder[folderOrder[f].index]))
        f += 1
      }
      if takeDevice {
        if keepsDevice(d) { entries.append(.device(d, cloud: matchOfDevice[d])) }
        d += 1
      } else {
        if keepsCloud(c) { entries.append(.cloud(c)) }
        c += 1
      }
    }
    for rest in folderOrder[f...] { entries.append(.folder(rest.index, cloud: matchOfFolder[rest.index])) }
    // Every list comes newest first.
    entries.reverse()
    if !projection.copies.assets.isEmpty {
      let ids = Set(projection.copies.assets.values)
      projection.copies.assetVersions = Dictionary(
        uniqueKeysWithValues: device.lazy.filter { ids.contains($0.localIdentifier) }.map { ($0.localIdentifier, $0.version) })
    }
    projection.entries = entries
    return projection
  }

  /// Google Photos doesn't say which items are screenshots; phones name them so.
  static func isScreenshot(_ item: RemoteItemSummary) -> Bool {
    item.kind == .photo && isScreenshot(fileName: item.fileName)
  }

  static func isScreenshot(fileName: String) -> Bool {
    fileName.range(of: "screenshot", options: [.caseInsensitive, .anchored]) != nil
  }

  private struct Bucket {
    var count = 0
    var index = 0

    mutating func add(_ index: Int) {
      count += 1
      self.index = index
    }
  }

  private static func uniqueCandidate(
    _ signature: Signature, date: Date, buckets: [Signature: Bucket], dateAt: (Int) -> Date
  ) -> Int? {
    var candidate: Int?
    for offset in -1...1 {
      var adjacent = signature
      adjacent.second += Int64(offset)
      guard let bucket = buckets[adjacent] else { continue }
      // A crowded bucket is ambiguous; never scan it or guess a burst frame.
      guard bucket.count == 1 else { return nil }
      guard abs(dateAt(bucket.index).timeIntervalSince(date)) < 1 else { continue }
      guard candidate == nil else { return nil }
      candidate = bucket.index
    }
    return candidate
  }

  struct Signature: Hashable {
    var second: Int64
    let isVideo: Bool
    let shortSide: Int
    let longSide: Int

    /// Without dimensions, a capture second alone is too weak to call two items the same.
    var isUsable: Bool { shortSide > 0 }

    init(_ item: DeviceItemInfo) {
      second = Int64(item.date.timeIntervalSince1970.rounded(.down))
      isVideo = item.isVideo
      shortSide = min(item.width, item.height)
      longSide = max(item.width, item.height)
    }

    init(_ item: RemoteItemSummary) {
      second = Int64(item.takenAt.timeIntervalSince1970.rounded(.down))
      isVideo = item.kind == .video
      shortSide = min(item.width ?? 0, item.height ?? 0)
      longSide = max(item.width ?? 0, item.height ?? 0)
    }
  }
}
