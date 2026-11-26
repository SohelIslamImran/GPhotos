import AppIntents
import CoreSpotlight
import Foundation

/// A person the app recognized on this device and the user named, from People in Search.
@AppEntity(schema: .photos.recognizedPerson)
public struct PersonEntity: IndexedEntity {
  public static let defaultQuery = PersonEntityQuery()

  /// The person's number in the index, as text.
  public let id: String
  public var name: String
  public var isFavorite: Bool
  @Property(title: "Photo Count")
  public var photoCount: Int

  public init(_ person: Person) {
    id = String(person.id)
    name = person.name ?? ""
    isFavorite = false
    photoCount = person.faceCount
  }

  public init(_ person: LibraryIndexStore.NamedPerson) {
    id = String(person.id)
    name = person.name
    isFavorite = false
    photoCount = person.photoCount
  }

  public var personID: Int64? { Int64(id) }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)", subtitle: "\(photoCount) photos", image: .init(systemName: "person.crop.circle"))
  }

  public var attributeSet: CSSearchableItemAttributeSet {
    let attributes = defaultAttributeSet
    attributes.displayName = name
    attributes.keywords = [name]
    return attributes
  }
}

public struct PersonEntityQuery: EntityStringQuery, EnumerableEntityQuery, IndexedEntityQuery {
  public init() {}

  /// Only named people: Siri finds people by name.
  public func allEntities() async throws -> [PersonEntity] {
    try await SiriLibrary.shared.store.namedPeople().map(PersonEntity.init)
  }

  public func entities(for identifiers: [String]) async throws -> [PersonEntity] {
    let wanted = Set(identifiers)
    return try await allEntities().filter { wanted.contains($0.id) }
  }

  public func entities(matching string: String) async throws -> [PersonEntity] {
    try await allEntities().filter { $0.name.localizedStandardContains(string) }
  }

  public func suggestedEntities() async throws -> [PersonEntity] {
    try await allEntities()
  }

  public func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
    await SiriLibrary.shared.spotlight.reindexPeople()
  }

  public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    await SiriLibrary.shared.spotlight.reindexPeople()
  }
}
