import AppIntents
import Foundation
import Photos

/// An album on this device or in the browsed Google Photos account.
@AppEntity(schema: .photos.album)
public struct AlbumEntity: AppEntity {
  public static let defaultQuery = AlbumEntityQuery()

  /// Which album, as the app opens it.
  public enum Reference: Equatable, Hashable, Sendable {
    case device(localIdentifier: String, title: String)
    case google(mediaKey: String, title: String)
  }

  /// `d:` + a local identifier or `g:` + a Google media key.
  public let id: String
  public var name: String
  public var creationDate: Date?
  public var albumType: PhotoAlbumType
  @Property(title: "Item Count")
  public var itemCount: Int

  public init(_ reference: Reference, itemCount: Int, creationDate: Date? = nil) {
    switch reference {
    case .device(let localIdentifier, let title):
      id = "d:" + localIdentifier
      name = title
    case .google(let mediaKey, let title):
      id = "g:" + mediaKey
      name = title
    }
    albumType = .custom
    self.itemCount = itemCount
    self.creationDate = creationDate
  }

  public var reference: Reference? {
    if id.hasPrefix("d:") { return .device(localIdentifier: String(id.dropFirst(2)), title: name) }
    if id.hasPrefix("g:") { return .google(mediaKey: String(id.dropFirst(2)), title: name) }
    return nil
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: id.hasPrefix("g:")
        ? "Google Photos · \(itemCount) items" : "On this device · \(itemCount) items",
      image: .init(systemName: "rectangle.stack"))
  }
}

@AppEnum(schema: .photos.albumType)
public enum PhotoAlbumType: String, AppEnum {
  case custom

  public static let caseDisplayRepresentations: [PhotoAlbumType: DisplayRepresentation] = [.custom: "Album"]
}

extension AlbumEntity.Reference {
  /// Where Collections shows the album.
  public var collectionRoute: CollectionRoute {
    switch self {
    case .device(let localIdentifier, let title): .scope(.album(id: localIdentifier, title: title), .all)
    case .google(let mediaKey, let title): .cloud(.album(key: mediaKey, title: title))
    }
  }
}

public struct AlbumEntityQuery: EntityStringQuery, EnumerableEntityQuery {
  public init() {}

  public func allEntities() async throws -> [AlbumEntity] {
    let device = await Task.detached(priority: .userInitiated) { Self.deviceAlbums() }.value
    let google = await SiriLibrary.shared.browsedCloud()?.albums() ?? []
    return device
      + google.map {
        AlbumEntity(.google(mediaKey: $0.mediaKey, title: $0.title), itemCount: $0.itemCount, creationDate: $0.startDate)
      }
  }

  public func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
    let wanted = Set(identifiers)
    return try await allEntities().filter { wanted.contains($0.id) }
  }

  public func entities(matching string: String) async throws -> [AlbumEntity] {
    try await allEntities().filter { $0.name.localizedStandardContains(string) }
  }

  public func suggestedEntities() async throws -> [AlbumEntity] {
    try await allEntities()
  }

  /// The device's own albums, as Collections lists them.
  nonisolated static func deviceAlbums() -> [AlbumEntity] {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return [] }
    var albums: [AlbumEntity] = []
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
      albums.append(
        AlbumEntity(
          .device(
            localIdentifier: collection.localIdentifier,
            title: collection.localizedTitle ?? String(localized: "Untitled Album")),
          itemCount: collection.estimatedAssetCount == NSNotFound
            ? PHAsset.fetchAssets(in: collection, options: nil).count : collection.estimatedAssetCount,
          creationDate: collection.startDate))
    }
    return albums
  }
}
