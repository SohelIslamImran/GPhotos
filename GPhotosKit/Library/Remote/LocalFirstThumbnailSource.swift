import CoreGraphics
import Foundation
import Photos
import os

/// Keeps routing off the main actor while the library discovers local copies.
final class LocalFirstThumbnailSource: ThumbnailSource {
  struct LocalCopies: Sendable, Equatable {
    var assets: [String: String] = [:]
    var assetVersions: [String: PhotoBackupEvidence.Version] = [:]
    var files: [String: FolderItemInfo] = [:]
    var confirmedAssetIDs: Set<String> = []

    func route(for key: String) -> Route {
      if let id = assets[key] { return .asset(id) }
      if let file = files[key] { return .file(file.id) }
      return .remote
    }
  }

  enum Route: Hashable {
    case asset(String)
    case file(String)
    case remote
  }

  private let state = OSAllocatedUnfairLock(initialState: (copies: LocalCopies(), hasProjection: false))
  private let remote: any ThumbnailSource
  private let accountEmail: String?
  private let repairObserver = OSAllocatedUnfairLock<(@Sendable (LocalCopies, LocalCopies) -> Void)?>(initialState: nil)

  func observeRepairs(_ observer: @escaping @Sendable (LocalCopies, LocalCopies) -> Void) {
    repairObserver.withLock { $0 = observer }
  }
  #if DEBUG
    private let remoteRequests = OSAllocatedUnfairLock(initialState: 0)
    var remoteRequestCount: Int { remoteRequests.withLock { $0 } }
  #endif

  init(remote: any ThumbnailSource, accountEmail: String? = nil) {
    self.remote = remote
    self.accountEmail = accountEmail
  }

  func thumbnailIdentity(for id: String) -> ThumbnailIdentity {
    guard let key = RemoteThumbnailID(id)?.mediaKey else { return ThumbnailIdentity(id: id) }
    return identity(for: id, key: key, copies: localCopies)
  }

  private func identity(for id: String, key: String, copies: LocalCopies) -> ThumbnailIdentity {
    let route = copies.route(for: key)
    var version: Int64 = 0
    if route != .remote {
      var hasher = Hasher()
      hasher.combine(route)
      switch route {
      case .asset(let assetID): hasher.combine(copies.assetVersions[assetID])
      case .file: hasher.combine(copies.files[key]?.thumbnailIdentity.version)
      case .remote: break
      }
      version = Int64(hasher.finalize())
    }
    return ThumbnailIdentity(id: id, version: version, accountEmail: accountEmail)
  }

  var localCopies: LocalCopies { state.withLock { $0.copies } }
  var needsRegistration: Bool { state.withLock { !$0.hasProjection } }

  func clearProjection() {
    state.withLock { $0 = (LocalCopies(), false) }
  }

  func register(assets: [String: String], versions: [String: PhotoBackupEvidence.Version]) -> Bool {
    state.withLock {
      guard !$0.hasProjection else { return false }
      var next = $0.copies
      next.assets = assets
      next.assetVersions = versions
      guard next != $0.copies else { return false }
      $0.copies = next
      return true
    }
  }

  func replace(with copies: LocalCopies) -> Bool {
    state.withLock {
      $0.hasProjection = true
      guard $0.copies != copies else { return false }
      $0.copies = copies
      return true
    }
  }

  func route(for key: String) -> Route {
    state.withLock { $0.copies.route(for: key) }
  }

  static func visibleAsset(_ id: String) -> PHAsset? {
    guard PhotoLibraryGridModel.hasAccess else { return nil }
    let options = AssetExportService.allFramesFetchOptions()
    options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject, !asset.isHidden
    else { return nil }
    return asset
  }

  static func hasCurrentVersion(_ asset: PHAsset, _ version: PhotoBackupEvidence.Version?) -> Bool {
    guard let version else { return true }
    return LocalAssetHashes.Evidence.sameContent(.init(AssetExportService.version(of: asset)), version)
  }

  static func fileAliasIsCurrent(_ file: FolderItemInfo) -> Bool {
    do {
      let values = try file.url.resourceValues(forKeys: [.isReadableKey, .fileSizeKey, .contentModificationDateKey])
      if values.isReadable == false { return false }
      if let size = values.fileSize, Int64(size) != file.size { return false }
      if let expected = file.modifiedAt, let modified = values.contentModificationDate, modified != expected { return false }
      return true
    } catch let error as NSError {
      guard error.domain == NSCocoaErrorDomain else { return true }
      return ![NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(error.code)
    }
  }

  /// Repair only the alias we actually checked. A new projection may have supplied another copy.
  func discardAlias(for key: String, route: Route, checked: LocalCopies) {
    let change: (LocalCopies, LocalCopies)? = state.withLock {
      let previous = $0.copies
      guard previous.route(for: key) == route else { return nil }
      switch route {
      case .asset(let id):
        guard previous.assetVersions[id] == checked.assetVersions[id] else { return nil }
        $0.copies.assets[key] = nil
      case .file:
        guard previous.files[key] == checked.files[key] else { return nil }
        $0.copies.files[key] = nil
      case .remote:
        return nil
      }
      return (previous, $0.copies)
    }
    if let (previous, updated) = change {
      let observer = repairObserver.withLock { $0 }
      observer?(previous, updated)
    }
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let key = RemoteThumbnailID(id)?.mediaKey else {
      onUnavailable()
      return .none
    }
    if let accountEmail, LockedItems.contains(key, accountEmail: accountEmail) {
      onUnavailable()
      return .none
    }
    let checked = localCopies
    let identity = identity(for: id, key: key, copies: checked)
    let selected = checked.route(for: key)
    let deliverCurrent: @Sendable (CGImage, Bool) -> Void = { [self] image, final in
      guard !identity.isLocked, thumbnailIdentity(for: id) == identity else {
        if final { onUnavailable() }
        return
      }
      deliver(image, final)
    }
    let localUnavailable: @Sendable () -> Void = { [self] in
      Task.detached(priority: .userInitiated) {
        switch selected {
        case .asset(let id):
          if Self.visibleAsset(id).map({ Self.hasCurrentVersion($0, checked.assetVersions[id]) }) != true {
            self.discardAlias(for: key, route: selected, checked: checked)
          }
        case .file:
          if let file = checked.files[key], !Self.fileAliasIsCurrent(file) {
            self.discardAlias(for: key, route: selected, checked: checked)
          }
        case .remote:
          break
        }
        onUnavailable()
      }
    }
    switch selected {
    case .remote:
      #if DEBUG
        remoteRequests.withLock { $0 &+= 1 }
      #endif
      return remote.requestImage(
        id: id, pixelSize: pixelSize, quality: quality, onUnavailable: onUnavailable, deliver: deliverCurrent)
    case .file(let fileID):
      return FolderLibrary.shared.thumbnails.requestImage(
        id: fileID, pixelSize: pixelSize, quality: quality, alias: checked.files[key],
        onUnavailable: localUnavailable, deliver: deliverCurrent)
    case .asset(let assetID):
      return PhotoKitImageSource.shared.requestImage(
        id: assetID, pixelSize: pixelSize, quality: quality, allowsHidden: false,
        expectedVersion: checked.assetVersions[assetID], onUnavailable: localUnavailable, deliver: deliverCurrent)
    }
  }

  func cachingTarget(for id: String) -> ThumbnailCachingTarget? {
    guard let key = RemoteThumbnailID(id)?.mediaKey, case .asset(let assetID) = route(for: key) else { return nil }
    return PhotoKitImageSource.shared.cachingTarget(for: assetID)
  }
}
