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
  /// The model Collections uses on iPhone, loaded at launch so the screen's first frame
  /// already has its albums and sections.
  public static let shared = PhotoCollectionsModel()

  public private(set) var albums: [AlbumSummary] = []
  public private(set) var mediaKinds: [MediaKindSummary] = []
  public private(set) var photoCount = 0
  public private(set) var videoCount = 0
  /// The cover of Recently Added: the newest photo added, as in Photos.
  public private(set) var recentlyAddedKeyID: String?
  public private(set) var isLoaded = false
  @ObservationIgnored private var isObserving = false
  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var loading: Task<Void, Never>?
  /// A reload asked for while one runs: that one may have read the library before the change.
  @ObservationIgnored private var reloadsAgain = false

  public override init() {
    super.init()
  }

  isolated deinit {
    if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
  }

  /// Loads once; a load already running is joined, and later changes arrive through the
  /// library's change observer.
  public func loadIfNeeded(priority: TaskPriority = .userInitiated) async {
    guard !isLoaded else { return }
    if let loading { return await loading.value }
    await load(priority: priority)
  }

  /// Reads the library again. Calls during a load are folded into one more read after it.
  public func load(priority: TaskPriority = .userInitiated) async {
    if let loading {
      reloadsAgain = true
      return await loading.value
    }
    let task = Task {
      repeat {
        reloadsAgain = false
        await loadOnce(priority: priority)
      } while reloadsAgain
      loading = nil
    }
    loading = task
    await task.value
  }

  private func loadOnce(priority: TaskPriority) async {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return }
    let snapshot = await Task.detached(priority: priority) { Self.snapshot() }.value
    apply(snapshot)
    if !isObserving {
      PHPhotoLibrary.shared().register(self)
      isObserving = true
    }
  }

  /// Observation tells every reader on each assignment, equal or not, so only what changed
  /// is assigned: a reload that finds the same albums redraws nothing.
  func apply(_ snapshot: Snapshot) {
    if albums != snapshot.albums { albums = snapshot.albums }
    if mediaKinds != snapshot.kinds { mediaKinds = snapshot.kinds }
    if photoCount != snapshot.photos { photoCount = snapshot.photos }
    if videoCount != snapshot.videos { videoCount = snapshot.videos }
    if recentlyAddedKeyID != snapshot.recentlyAddedKeyID { recentlyAddedKeyID = snapshot.recentlyAddedKeyID }
    if !isLoaded { isLoaded = true }
  }

  struct Snapshot: Sendable {
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
