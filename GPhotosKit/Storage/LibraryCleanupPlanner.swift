import Foundation

/// What PhotoKit reports about a library asset at cleanup time, as plain values so the
/// planning rules can run (and be tested) without a photo library.
public struct LibraryAssetFacts: Sendable, Equatable {
  public var localIdentifier: String
  public var albumIDs: Set<String>
  public var isFavorite: Bool
  public var modificationDate: Date?
  public var isLivePhoto: Bool
  /// A resource the uploader never sends, or a RAW whose own record is not verifiably
  /// uploaded to this account.
  public var hasUnuploadedResources: Bool
  /// The asset carries the RAW of a RAW+JPEG pair, which goes up as its own record.
  public var hasAlternatePhoto: Bool
  /// The asset is edited and its unedited original goes up as its own record.
  public var needsUneditedOriginal: Bool
  /// Shared by every frame of a burst; each frame is its own asset.
  public var burstIdentifier: String?
  public var canDelete: Bool

  public init(
    localIdentifier: String,
    albumIDs: Set<String> = [],
    isFavorite: Bool = false,
    modificationDate: Date? = nil,
    isLivePhoto: Bool = false,
    hasUnuploadedResources: Bool = false,
    hasAlternatePhoto: Bool = false,
    needsUneditedOriginal: Bool = false,
    burstIdentifier: String? = nil,
    canDelete: Bool = true
  ) {
    self.localIdentifier = localIdentifier
    self.albumIDs = albumIDs
    self.isFavorite = isFavorite
    self.modificationDate = modificationDate
    self.isLivePhoto = isLivePhoto
    self.hasUnuploadedResources = hasUnuploadedResources
    self.hasAlternatePhoto = hasAlternatePhoto
    self.needsUneditedOriginal = needsUneditedOriginal
    self.burstIdentifier = burstIdentifier
    self.canDelete = canDelete
  }
}

/// Decides which already-eligible library records may actually be removed from the
/// photo library. Eligibility (uploaded to this account, delay passed) is the manifest's
/// job; this applies what only the library knows.
///
/// Deletion works on whole assets: an asset goes only with every record it needs (its
/// primary and, for a RAW+JPEG pair, its RAW, for an edited asset its original), and a burst frame only with every other
/// frame of its burst.
public enum LibraryCleanupPlanner {
  /// PhotoKit and the manifest round modification dates differently.
  static let modificationTolerance: TimeInterval = 1

  /// - Parameter burstMembers: every asset in each burst, keyed by burst identifier. A
  ///   burst missing from it cannot be checked, so none of its frames is planned.
  public static func plan(
    records: [TransferRecord],
    facts: [String: LibraryAssetFacts],
    burstMembers: [String: Set<String>] = [:],
    protectedAlbumIDs: Set<String>,
    protectsFavorites: Bool,
    bytesNeeded: Int64?
  ) -> [TransferRecord] {
    var order: [String] = []
    var recordsByAsset: [String: [TransferRecord]] = [:]
    for record in records {
      guard let assetID = record.assetLocalIdentifier else { continue }
      if recordsByAsset[assetID] == nil { order.append(assetID) }
      recordsByAsset[assetID, default: []].append(record)
    }
    let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let deletable = Set(
      order.filter { assetID in
        guard let asset = facts[assetID], let assetRecords = recordsByAsset[assetID] else { return false }
        return isDeletable(
          asset, records: assetRecords, protectedAlbumIDs: protectedAlbumIDs, protectsFavorites: protectsFavorites)
      })

    var planned: [TransferRecord] = []
    var plannedBytes: Int64 = 0
    var handled = Set<String>()
    for assetID in order where !handled.contains(assetID) {
      if let bytesNeeded, plannedBytes >= bytesNeeded { break }
      let unit: [String]
      if let burstID = facts[assetID]?.burstIdentifier {
        // All or nothing: a frame left behind would be the only copy of its burst on
        // this device, and one removed alone splits the burst.
        let members = burstMembers[burstID] ?? []
        handled.insert(assetID)
        handled.formUnion(members)
        guard members.contains(assetID),
          members.allSatisfy({ deletable.contains($0) && facts[$0]?.burstIdentifier == burstID })
        else { continue }
        unit = members.sorted { (position[$0] ?? .max) < (position[$1] ?? .max) }
      } else {
        handled.insert(assetID)
        guard deletable.contains(assetID) else { continue }
        unit = [assetID]
      }
      for member in unit {
        for record in recordsByAsset[member] ?? [] {
          planned.append(record)
          plannedBytes += max(0, record.byteCount ?? 0)
        }
      }
    }
    return planned
  }

  /// One asset on its own: what the library says about it, and every record it has here.
  private static func isDeletable(
    _ asset: LibraryAssetFacts,
    records: [TransferRecord],
    protectedAlbumIDs: Set<String>,
    protectsFavorites: Bool
  ) -> Bool {
    guard asset.canDelete,
      !asset.hasUnuploadedResources,
      asset.albumIDs.isDisjoint(with: protectedAlbumIDs),
      !(protectsFavorites && asset.isFavorite),
      records.allSatisfy({ $0.status == .sent && !isEdited(asset, since: $0) })
    else { return false }
    let primaries = records.filter { $0.resourceRole == .primary }
    let originals = records.filter { $0.resourceRole == .uneditedOriginal }
    // A Live Photo uploaded without its motion half would lose the video.
    guard !primaries.isEmpty,
      (primaries + originals).allSatisfy({ !asset.isLivePhoto || $0.pairedSourceSHA1 != nil })
    else { return false }
    // The RAW and the original must themselves be uploaded and past their delay, not
    // merely recorded.
    if asset.hasAlternatePhoto, !records.contains(where: { $0.resourceRole == .alternatePhoto }) { return false }
    if asset.needsUneditedOriginal, originals.isEmpty { return false }
    return true
  }

  /// An edit after the upload means Google Photos holds an older version. A record with
  /// no recorded version cannot be compared, so it counts as edited.
  /// The unedited original stays the same whatever the edit, so it is never out of date.
  private static func isEdited(_ asset: LibraryAssetFacts, since record: TransferRecord) -> Bool {
    guard record.resourceRole != .uneditedOriginal, let modified = asset.modificationDate else { return false }
    guard let uploaded = record.assetModifiedAt else { return true }
    return modified > uploaded.addingTimeInterval(modificationTolerance)
  }
}
