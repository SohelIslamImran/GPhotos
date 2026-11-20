import AppIntents
import CoreLocation
import CoreSpotlight
import CoreTransferable
import Foundation
import GeoToolbox
import UniformTypeIdentifiers

/// A Library item for Siri and Spotlight: a photo or video on this device, in Google Photos
/// or in a backed-up folder. Its id is the item's index id.
@AppEntity(schema: .photos.asset)
public struct PhotoEntity: IndexedEntity {
  public static let defaultQuery = PhotoEntityQuery()

  public let id: String
  public var title: String?
  public var creationDate: Date?
  public var location: PlaceDescriptor?
  public var assetType: PhotoAssetType?
  public var isFavorite: Bool
  public var isHidden: Bool
  public var hasSuggestedEdits: Bool
  // Editing settings the photos schema describes; the app doesn't edit photos.
  public var aperture: Double?
  public var exposure: Double?
  public var saturation: Double?
  public var warmth: Double?
  public var filter: PhotoFilterType?
  public var isPortraitModeEnabled: Bool?

  @Property(title: "Objects and Scenes")
  public var labels: [String]
  @Property(title: "Text in Photo")
  public var text: String?
  @Property(title: "People")
  public var people: [String]
  @Property(title: "Place")
  public var place: String?
  @Property(title: "Caption")
  public var caption: String?
  @Property(title: "Stored In")
  public var source: String

  private var coordinate: CLLocationCoordinate2D?

  public init(_ record: SiriItemRecord) {
    id = record.id
    title = record.title
    creationDate = record.date
    assetType = record.isVideo ? .video : .photo
    isFavorite = record.isFavorite
    isHidden = false
    hasSuggestedEdits = false
    labels = record.labels
    text = record.text.isEmpty ? nil : record.text
    people = record.people
    place = record.place.isEmpty ? nil : record.place
    caption = record.caption.isEmpty ? nil : record.caption
    source = record.sourceDescription
    if let latitude = record.latitude, let longitude = record.longitude {
      let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
      self.coordinate = coordinate
      location = PlaceDescriptor(representations: [.coordinate(coordinate)], commonName: place)
    }
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title ?? "")", subtitle: "\(source)",
      image: .init(systemName: assetType == .video ? "video" : "photo"))
  }

  /// What Spotlight's semantic index searches: the labels and people as keywords, the text
  /// found in the photo, the place and the date.
  public var attributeSet: CSSearchableItemAttributeSet {
    let attributes = defaultAttributeSet
    attributes.title = title
    attributes.displayName = title
    attributes.contentDescription = [caption, labels.prefix(8).joined(separator: ", ")]
      .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ". ")
    attributes.keywords = labels + people + [source]
    attributes.textContent = text
    attributes.namedLocation = place
    attributes.contentCreationDate = creationDate
    if let coordinate {
      attributes.latitude = NSNumber(value: coordinate.latitude)
      attributes.longitude = NSNumber(value: coordinate.longitude)
      attributes.supportsNavigation = false
    }
    attributes.contentType = (assetType == .video ? UTType.movie : UTType.image).identifier
    return attributes
  }
}

@AppEnum(schema: .photos.assetType)
public enum PhotoAssetType: String, AppEnum {
  case photo
  case video

  public static let caseDisplayRepresentations: [PhotoAssetType: DisplayRepresentation] = [
    .photo: "Photo", .video: "Video",
  ]
}

@AppEnum(schema: .photos.filterType)
public enum PhotoFilterType: String, AppEnum {
  case original

  public static let caseDisplayRepresentations: [PhotoFilterType: DisplayRepresentation] = [.original: "Original"]
}

extension PhotoEntity: Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .movie) { entity in
      SentTransferredFile(try await SiriLibrary.shared.exportFile(id: entity.id))
    }
    .exportingCondition { $0.assetType == .video }
    FileRepresentation(exportedContentType: .image) { entity in
      SentTransferredFile(try await SiriLibrary.shared.exportFile(id: entity.id))
    }
    .exportingCondition { $0.assetType != .video }
  }
}

public struct PhotoEntityQuery: EntityStringQuery, IndexedEntityQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [PhotoEntity] {
    try await SiriLibrary.shared.store.siriRecords(ids: identifiers).map(PhotoEntity.init)
  }

  /// Siri's words, matched against what the index found in each item.
  public func entities(matching string: String) async throws -> [PhotoEntity] {
    let ids = await SiriLibrary.shared.search(string, limit: 100)
    return try await entities(for: ids)
  }

  public func suggestedEntities() async throws -> [PhotoEntity] {
    try await SiriLibrary.shared.store.recentSiriRecords(limit: 30).map(PhotoEntity.init)
  }

  /// Thumbnails, asked for only when Siri or Shortcuts shows the results.
  public func displayRepresentations(for identifiers: [String]) async throws -> [String: DisplayRepresentation] {
    let entities = try await entities(for: identifiers)
    var result: [String: DisplayRepresentation] = [:]
    for entity in entities {
      var representation = entity.displayRepresentation
      if let data = await SiriLibrary.shared.thumbnailData(id: entity.id) {
        representation.image = .init(data: data)
      }
      result[entity.id] = representation
    }
    return result
  }

  public func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
    try await SiriLibrary.shared.spotlight.reindex(ids: identifiers)
  }

  public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    try await SiriLibrary.shared.spotlight.reindex(ids: nil)
  }
}
