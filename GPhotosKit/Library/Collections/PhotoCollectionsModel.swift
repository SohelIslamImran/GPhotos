import Foundation
import Observation
import Photos

public struct AlbumSummary: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let count: Int
  public let keyAssetID: String?
}

public struct MediaKindSummary: Identifiable, Hashable, Sendable {
  public let kind: LibraryMediaKind
  public let count: Int
  public let keyAssetID: String?
  public var id: LibraryMediaKind { kind }
}

/// Albums, media types and library totals for the Collections screen. Everything is
/// counted off the main actor and refreshed when the library changes.
@MainActor
@Observable
public final class PhotoCollectionsModel: NSObject {
  public private(set) var albums: [AlbumSummary] = []
  public private(set) var mediaKinds: [MediaKindSummary] = []
  public private(set) var photoCount = 0
  public private(set) var videoCount = 0
  /// The cover of Recently Added: the newest photo added, as in Photos.
  public private(set) var recentlyAddedKeyID: String?
  public private(set) var isLoaded = false
  @ObservationIgnored private var isObserving = false
  @ObservationIgnored private var reloadTask: Task<Void, Never>?

  public override init() {
    super.init()
  }

  isolated deinit {
    if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
  }

  public func load() async {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return }
    let snapshot = await Task.detached(priority: .userInitiated) { Self.snapshot() }.value
    albums = snapshot.albums
    mediaKinds = snapshot.kinds
    photoCount = snapshot.photos
    videoCount = snapshot.videos
    recentlyAddedKeyID = snapshot.recentlyAddedKeyID
    isLoaded = true
    if !isObserving {
      PHPhotoLibrary.shared().register(self)
      isObserving = true
    }
  }

  private struct Snapshot: Sendable {
    var albums: [AlbumSummary] = []
    var kinds: [MediaKindSummary] = []
    var photos = 0
    var videos = 0
    var recentlyAddedKeyID: String?
  }

  nonisolated private static func snapshot() -> Snapshot {
    var snapshot = Snapshot()
    let newestFirst = PHFetchOptions()
    newestFirst.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    newestFirst.fetchLimit = 1
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
    collections.enumerateObjects { collection, _, _ in
      let count = PHAsset.fetchAssets(in: collection, options: nil).count
      let key =
        PHAsset.fetchKeyAssets(in: collection, options: nil)?.firstObject
        ?? PHAsset.fetchAssets(in: collection, options: newestFirst).firstObject
      snapshot.albums.append(
        AlbumSummary(
          id: collection.localIdentifier, title: collection.localizedTitle ?? String(localized: "Untitled Album"),
          count: count, keyAssetID: key?.localIdentifier))
    }
    for kind in LibraryMediaKind.allCases {
      guard
        let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: kind.subtype, options: nil)
          .firstObject
      else { continue }
      let count = PHAsset.fetchAssets(in: album, options: nil).count
      guard count > 0 else { continue }
      let key = PHAsset.fetchAssets(in: album, options: newestFirst).firstObject
      snapshot.kinds.append(MediaKindSummary(kind: kind, count: count, keyAssetID: key?.localIdentifier))
    }
    if let recent = PHAssetCollection.fetchAssetCollections(
      with: .smartAlbum, subtype: .smartAlbumRecentlyAdded, options: nil
    ).firstObject {
      // The album lists in the order photos were added, newest last.
      snapshot.recentlyAddedKeyID =
        (PHAsset.fetchKeyAssets(in: recent, options: nil)?.firstObject
        ?? PHAsset.fetchAssets(in: recent, options: nil).lastObject)?.localIdentifier
    }
    snapshot.photos = PHAsset.fetchAssets(with: .image, options: nil).count
    snapshot.videos = PHAsset.fetchAssets(with: .video, options: nil).count
    return snapshot
  }

  public func summary(for kind: LibraryMediaKind) -> MediaKindSummary? {
    mediaKinds.first { $0.kind == kind }
  }
}

extension PhotoCollectionsModel: PHPhotoLibraryChangeObserver {
  nonisolated public func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor in
      // Bursts of changes (an import, iCloud sync) refresh once.
      self.reloadTask?.cancel()
      self.reloadTask = Task {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        await self.load()
      }
    }
  }
}
