import Foundation
import Photos

struct PhotoBackupEvidence: Equatable, Sendable {
  var accountEmail: String?
  var scope = PhotoBackupScope()
  var states: [String: PhotoGridBadges.Backup] = [:]
  private var unfinishedAlternates: [String: PhotoGridBadges.Backup] = [:]
  private var unfinishedOriginals: [String: PhotoGridBadges.Backup] = [:]
  private(set) var excludedAlbumIDs: Set<String> = []
  private var skippedIDs: Set<String> = []
  private var albums: PHFetchResult<PHAssetCollection>?
  private var memberships: [PHFetchResult<PHAsset>] = []
  private var scopeReadAt: ContinuousClock.Instant?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.accountEmail == rhs.accountEmail && lhs.scope == rhs.scope && lhs.states == rhs.states
      && lhs.receipts == rhs.receipts && lhs.confirmedIDs == rhs.confirmedIDs
      && lhs.unfinishedAlternates == rhs.unfinishedAlternates && lhs.unfinishedOriginals == rhs.unfinishedOriginals
      && lhs.excludedAlbumIDs == rhs.excludedAlbumIDs
      && lhs.skippedIDs == rhs.skippedIDs
  }

  func affectsScope(_ change: PHChange) -> Bool {
    if let albums, change.changeDetails(for: albums) != nil { return true }
    return memberships.contains {
      guard let details = change.changeDetails(for: $0) else { return false }
      return !details.hasIncrementalChanges || details.insertedIndexes != nil || details.removedIndexes != nil
    }
  }

  func refreshedScope() -> Self {
    let readAt = ContinuousClock.now
    var evidence = self
    var ids = skippedIDs
    evidence.albums = nil
    evidence.memberships = []
    if PhotoBackupScope.backsUpPhotos, !excludedAlbumIDs.isEmpty {
      let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(excludedAlbumIDs), options: nil)
      evidence.albums = albums
      albums.enumerateObjects { album, _, _ in
        let members = PHAsset.fetchAssets(in: album, options: AssetExportService.allFramesFetchOptions())
        evidence.memberships.append(members)
        members.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
      }
    }
    evidence.scope = PhotoBackupScope(excludedIDs: ids)
    evidence.scopeReadAt = readAt
    return evidence
  }

  func usingNewerScope(from other: Self) -> Self {
    guard excludedAlbumIDs == other.excludedAlbumIDs, skippedIDs == other.skippedIDs,
      let readAt = other.scopeReadAt, scopeReadAt.map({ $0 < readAt }) ?? true
    else { return self }
    var evidence = self
    evidence.scope = other.scope
    evidence.albums = other.albums
    evidence.memberships = other.memberships
    evidence.scopeReadAt = readAt
    return evidence
  }

  struct Version: Hashable, Sendable {
    let modifiedAt: Date?
    let hasAdjustments: Bool?
    let adjustmentTimestamp: Date?

    init(_ version: TransferRecord.AssetVersion) {
      modifiedAt = version.modifiedAt
      hasAdjustments = version.hasAdjustments
      adjustmentTimestamp = version.adjustmentTimestamp
    }

    var assetVersion: TransferRecord.AssetVersion {
      .init(modifiedAt: modifiedAt, hasAdjustments: hasAdjustments, adjustmentTimestamp: adjustmentTimestamp)
    }
  }

  var receipts: [String: Set<Version>] = [:]
  var confirmedIDs: Set<String> = []

  static func read(
    _ records: [TransferRecord], confirmedCloudIDs: Set<String> = [], accountEmail: String?,
    excludedAlbumIDs: Set<String> = AppSettingsStore.load().excludedAlbumIDs,
    backsUpUneditedOriginals: Bool = AppSettingsStore.load().backsUpUneditedOriginals
  ) -> Self {
    var evidence = Self(accountEmail: accountEmail)
    var skippedIDs = Set<String>()
    if let accountEmail {
      for record in records where record.resourceRole == .primary {
        guard let id = record.assetLocalIdentifier else { continue }
        let hasReceipt =
          record.isTerminalSuccess
          && (record.sentAccountEmails.contains(accountEmail) || record.mediaKeysByAccount[accountEmail]?.isEmpty == false)
        let isCurrentQueue = TransferRecord.accountEmail(fromScopedID: record.id) == accountEmail
        if record.isSkipped, isCurrentQueue {
          skippedIDs.insert(id)
          if !hasReceipt { continue }
        }
        if hasReceipt { evidence.receipts[id, default: []].insert(Version(record.assetVersion)) }
        let state: PhotoGridBadges.Backup
        if hasReceipt {
          state = .backedUp
        } else if isCurrentQueue, !record.isTerminalSuccess {
          state = record.status == .failed ? .failed : .pending
        } else {
          continue
        }
        switch (evidence.states[id], state) {
        case (.failed?, _), (.pending?, .backedUp): continue
        default: evidence.states[id] = state
        }
      }
      evidence.confirmedIDs = confirmedCloudIDs
      for id in confirmedCloudIDs where evidence.states[id] == nil { evidence.states[id] = .backedUp }
    }
    if let accountEmail {
      for record in records where record.resourceRole != .primary && !record.isSkipped {
        guard let id = record.assetLocalIdentifier, TransferRecord.accountEmail(fromScopedID: record.id) == accountEmail,
          !record.isTerminalSuccess || !record.sentAccountEmails.contains(accountEmail) && record.mediaKeysByAccount[accountEmail] == nil
        else { continue }
        let state: PhotoGridBadges.Backup = record.status == .failed ? .failed : .pending
        switch record.resourceRole {
        case .alternatePhoto:
          if evidence.unfinishedAlternates[id] != .failed { evidence.unfinishedAlternates[id] = state }
        case .uneditedOriginal where backsUpUneditedOriginals:
          if evidence.unfinishedOriginals[id] != .failed { evidence.unfinishedOriginals[id] = state }
        default: break
        }
      }
    }
    evidence.excludedAlbumIDs = excludedAlbumIDs
    evidence.skippedIDs = skippedIDs
    return evidence.refreshedScope()
  }

  func state(for asset: PHAsset) -> PhotoGridBadges.Backup? {
    state(for: asset.localIdentifier, version: AssetExportService.version(of: asset))
  }

  func state(for id: String, version: TransferRecord.AssetVersion) -> PhotoGridBadges.Backup? {
    let alternate = unfinishedAlternates[id]
    let original = version.hasAdjustments == false ? nil : unfinishedOriginals[id]
    if alternate == .failed || original == .failed { return .failed }
    if let unfinished = alternate ?? original { return unfinished }
    let state = states[id]
    guard state == .backedUp else { return state }
    if confirmedIDs.contains(id) || receipts[id]?.contains(where: { !version.contentChanged(since: $0.assetVersion) }) == true {
      return .backedUp
    }
    return nil
  }
}
