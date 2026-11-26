import Foundation
import Photos

/// Which part of the library a grid shows.
public enum LibraryScope: Hashable, Sendable {
  case all
  case recentlyAdded
  case mediaKind(LibraryMediaKind)
  case album(id: String, title: String)
  /// A fixed set of items, such as the photos taken at one place.
  case assets(ids: [String], title: String)
  case hidden

  public var title: String {
    switch self {
    case .all: String(localized: "Library")
    case .recentlyAdded: String(localized: "Recently Added")
    case .mediaKind(let kind): kind.title
    case .album(_, let title), .assets(_, let title): title
    case .hidden: String(localized: "Hidden")
    }
  }

  /// Beside the count under the title, as in Photos.
  var symbol: String {
    switch self {
    case .all: "photo.on.rectangle"
    case .recentlyAdded: "clock"
    case .mediaKind(let kind): kind.symbol
    case .album: "rectangle.stack"
    case .assets: "mappin.and.ellipse"
    case .hidden: "eye.slash"
    }
  }

  /// Date-ordered scopes get month labels; albums keep their own order.
  var isDateOrdered: Bool {
    switch self {
    case .album, .recentlyAdded: false
    default: true
    }
  }
}

/// The filter menu over any scope.
public enum LibraryFilter: String, CaseIterable, Hashable, Sendable {
  case all
  case favorites
  case photos
  case videos
  case livePhotos
  case screenshots
  case notBackedUp
  case notIncludedInBackup
  case backedUp
  /// Merged timeline only: Google Photos items without a confirmed local copy.
  case cloudOnly

  /// The filters a device-only grid offers, as in Photos' menu: the main list, then the
  /// media types in their own submenu.
  public static let deviceFilters: [LibraryFilter] = [.all, .favorites, .notBackedUp, .backedUp, .notIncludedInBackup]
  public static let mediaTypes: [LibraryFilter] = [.photos, .videos, .livePhotos, .screenshots]

  public var isMediaType: Bool { Self.mediaTypes.contains(self) }

  public var emptyTitle: String {
    switch self {
    case .notBackedUp: String(localized: "No Items Need Backup")
    case .notIncludedInBackup: String(localized: "No Items Excluded from Backup")
    case .backedUp: String(localized: "Nothing Backed Up Yet")
    default: String(localized: "No \(title)")
    }
  }

  public var title: String {
    switch self {
    case .all: String(localized: "All Items")
    case .cloudOnly: String(localized: "Google Only")
    case .favorites: String(localized: "Favorites")
    case .photos: String(localized: "Photos")
    case .videos: String(localized: "Videos")
    case .livePhotos: String(localized: "Live Photos")
    case .screenshots: String(localized: "Screenshots")
    case .notBackedUp: String(localized: "Not Backed Up")
    case .notIncludedInBackup: String(localized: "Not Included in Backup")
    case .backedUp: String(localized: "Backed Up")
    }
  }

  public var symbol: String {
    switch self {
    case .all: "square.grid.3x3"
    case .favorites: "heart"
    case .photos: "photo"
    case .videos: "video"
    case .livePhotos: "livephoto"
    case .screenshots: "camera.viewfinder"
    case .notBackedUp: "icloud.slash"
    case .notIncludedInBackup: "minus.circle"
    case .backedUp: "checkmark.icloud"
    case .cloudOnly: "cloud"
    }
  }

  var dependsOnBackup: Bool { self == .notBackedUp || self == .backedUp || self == .notIncludedInBackup }

  func includesBackupItem(inScope: Bool, backedUp: Bool) -> Bool {
    switch self {
    case .notBackedUp: inScope && !backedUp
    case .notIncludedInBackup: !inScope && !backedUp
    case .backedUp: backedUp
    default: true
    }
  }
}

/// Media types Photos keeps as smart albums.
public enum LibraryMediaKind: String, CaseIterable, Hashable, Sendable {
  case favorites
  case videos
  case selfies
  case livePhotos
  case portrait
  case panoramas
  case timelapse
  case slomo
  case cinematic
  case spatial
  case bursts
  case screenshots
  case screenRecordings
  case animated
  case longExposure
  case raw

  public var title: String {
    switch self {
    case .favorites: String(localized: "Favorites")
    case .videos: String(localized: "Videos")
    case .selfies: String(localized: "Selfies")
    case .livePhotos: String(localized: "Live Photos")
    case .portrait: String(localized: "Portrait")
    case .panoramas: String(localized: "Panoramas")
    case .timelapse: String(localized: "Time-lapse")
    case .slomo: String(localized: "Slo-mo")
    case .cinematic: String(localized: "Cinematic")
    case .spatial: String(localized: "Spatial")
    case .bursts: String(localized: "Bursts")
    case .screenshots: String(localized: "Screenshots")
    case .screenRecordings: String(localized: "Screen Recordings")
    case .animated: String(localized: "Animated")
    case .longExposure: String(localized: "Long Exposure")
    case .raw: String(localized: "RAW")
    }
  }

  public var symbol: String {
    switch self {
    case .favorites: "heart"
    case .videos: "video"
    case .selfies: "person.crop.square"
    case .livePhotos: "livephoto"
    case .portrait: "cube"
    case .panoramas: "pano"
    case .timelapse: "timelapse"
    case .slomo: "slowmo"
    case .cinematic: "film"
    case .spatial: "pano.badge.play"
    case .bursts: "square.stack.3d.down.right"
    case .screenshots: "camera.viewfinder"
    case .screenRecordings: "record.circle"
    case .animated: "square.stack.3d.forward.dottedline"
    case .longExposure: "plusminus.circle"
    case .raw: "r.square"
    }
  }

  var subtype: PHAssetCollectionSubtype {
    switch self {
    case .favorites: .smartAlbumFavorites
    case .videos: .smartAlbumVideos
    case .selfies: .smartAlbumSelfPortraits
    case .livePhotos: .smartAlbumLivePhotos
    case .portrait: .smartAlbumDepthEffect
    case .panoramas: .smartAlbumPanoramas
    case .timelapse: .smartAlbumTimelapses
    case .slomo: .smartAlbumSlomoVideos
    case .cinematic: .smartAlbumCinematic
    case .spatial: .smartAlbumSpatial
    case .bursts: .smartAlbumBursts
    case .screenshots: .smartAlbumScreenshots
    case .screenRecordings: .smartAlbumScreenRecordings
    case .animated: .smartAlbumAnimated
    case .longExposure: .smartAlbumLongExposures
    case .raw: .smartAlbumRAW
    }
  }
}

/// Builds the PhotoKit fetch for a scope and filter. Runs off the main actor.
enum LibraryFetch {
  static func assets(
    scope: LibraryScope, filter: LibraryFilter
  ) -> PHFetchResult<PHAsset> {
    let options = PHFetchOptions()
    if scope.isDateOrdered {
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    }
    options.predicate = predicate(for: filter)
    switch scope {
    case .all:
      options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
      return PHAsset.fetchAssets(with: options)
    case .recentlyAdded:
      return assets(inSmartAlbum: .smartAlbumRecentlyAdded, options: options)
    case .mediaKind(let kind):
      return assets(inSmartAlbum: kind.subtype, options: options)
    case .album(let id, _):
      guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
      else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
      return PHAsset.fetchAssets(in: album, options: options)
    case .assets(let ids, _):
      return PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
    case .hidden:
      options.includeHiddenAssets = true
      return assets(inSmartAlbum: .smartAlbumAllHidden, options: options)
    }
  }

  static func assets(inSmartAlbum subtype: PHAssetCollectionSubtype, options: PHFetchOptions?) -> PHFetchResult<PHAsset> {
    guard
      let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
    else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
    return PHAsset.fetchAssets(in: album, options: options)
  }

  static func predicate(for filter: LibraryFilter) -> NSPredicate? {
    switch filter {
    case .all: nil
    case .favorites: NSPredicate(format: "isFavorite == YES")
    case .photos: NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    case .videos: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
    case .livePhotos: NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
    case .screenshots: NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
    case .notBackedUp, .notIncludedInBackup, .backedUp, .cloudOnly: nil
    }
  }
}

/// The read-only classification shared by the Library and device collections.
struct PhotoBackupScope: Equatable, Sendable {
  var excludedIDs: Set<String> = []

  static var backsUpPhotos: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

  func includes(id: String, source: PHAssetSourceType, isMedia: Bool, isHidden: Bool = false) -> Bool {
    Self.backsUpPhotos && source.contains(.typeUserLibrary) && isMedia && !isHidden && !excludedIDs.contains(id)
  }

  func includes(_ asset: PHAsset) -> Bool {
    includes(
      id: asset.localIdentifier, source: asset.sourceType,
      isMedia: asset.mediaType == .image || asset.mediaType == .video, isHidden: asset.isHidden)
  }
}
