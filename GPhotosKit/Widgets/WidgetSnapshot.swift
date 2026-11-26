import CoreGraphics
import Foundation
import ImageIO

/// What the photo widgets show, written by the app into the App Group: the widgets can't
/// read the photo library, Google Photos or the index themselves, so the app picks the
/// photos, saves a small JPEG of each and lists them here.
public struct WidgetPhotoSnapshot: Codable, Sendable, Equatable {
  public var generatedAt: Date
  /// The browsed Google Photos account when this snapshot was built, if any.
  public var accountEmail: String?
  /// On This Day and trips first, then the best photos when there are no memories today.
  public var memories: [WidgetPhotoSet]
  /// The most photographed people, most photos first.
  public var people: [WidgetPhotoSet]

  public init(
    generatedAt: Date = Date(), accountEmail: String? = nil, memories: [WidgetPhotoSet] = [], people: [WidgetPhotoSet] = []
  ) {
    self.generatedAt = generatedAt
    self.accountEmail = accountEmail
    self.memories = memories
    self.people = people
  }

  public var isEmpty: Bool { memories.isEmpty && people.isEmpty }

  /// Everything but the timestamp, to skip disk writes and WidgetKit reloads when nothing changed.
  public func sameContent(as other: WidgetPhotoSnapshot) -> Bool {
    accountEmail == other.accountEmail && memories == other.memories && people == other.people
  }
}

/// A memory or a person: a title and a few photos the widget rotates through.
public struct WidgetPhotoSet: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case onThisDay
    case trip
    case featured
    case person
  }

  public var id: String
  public var kind: Kind
  public var title: String
  public var subtitle: String
  public var photos: [WidgetPhoto]
  /// The person's index id, for opening them in Search.
  public var personID: Int64?

  public init(
    id: String, kind: Kind, title: String, subtitle: String, photos: [WidgetPhoto], personID: Int64? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.photos = photos
    self.personID = personID
  }
}

public struct WidgetPhoto: Codable, Sendable, Equatable, Hashable {
  /// The item's index id, which the app opens in the viewer.
  public var itemID: String
  /// The JPEG's name in the widget folder.
  public var file: String
  public var date: Date
  /// What the crop keeps in view (a person's face), normalized with the origin at the top
  /// left; the middle when nil.
  public var focusX: Double?
  public var focusY: Double?

  public init(itemID: String, file: String, date: Date, focus: CGPoint? = nil) {
    self.itemID = itemID
    self.file = file
    self.date = date
    focusX = focus.map { Double($0.x) }
    focusY = focus.map { Double($0.y) }
  }
}

/// The backup status the Backup widget shows, written whenever it changes.
public struct WidgetBackupSnapshot: Codable, Sendable, Equatable {
  public var title: String
  public var subtitle: String
  public var symbol: String
  /// One of `BackupStatus.Tone`'s colours, by name, so the widget draws the app's colour.
  public var tone: String
  public var isSignedIn: Bool
  public var isHealthy: Bool
  public var backedUpCount: Int
  public var updatedAt: Date

  public init(
    title: String, subtitle: String, symbol: String, tone: String, isSignedIn: Bool, isHealthy: Bool,
    backedUpCount: Int, updatedAt: Date = Date()
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.tone = tone
    self.isSignedIn = isSignedIn
    self.isHealthy = isHealthy
    self.backedUpCount = backedUpCount
    self.updatedAt = updatedAt
  }

  /// Everything but the time, to skip writes that change nothing on screen.
  func sameContent(as other: WidgetBackupSnapshot) -> Bool {
    var other = other
    other.updatedAt = updatedAt
    return self == other
  }
}

/// The widget folder in the App Group, shared by the app (which writes) and the widgets.
public enum WidgetStore {
  public static let memoriesKind = "Memories"
  public static let peopleKind = "People"
  public static let backupKind = "BackupStatus"

  static let photosFileName = "photos.json"
  static let backupFileName = "backup.json"

  public static var directory: URL {
    AppGroupConstants.storageDirectory().appendingPathComponent("Widgets", isDirectory: true)
  }

  public static func photos(in directory: URL = directory) -> WidgetPhotoSnapshot? {
    read(WidgetPhotoSnapshot.self, from: directory.appendingPathComponent(photosFileName))
  }

  public static func backup(in directory: URL = directory) -> WidgetBackupSnapshot? {
    read(WidgetBackupSnapshot.self, from: directory.appendingPathComponent(backupFileName))
  }

  static func write(_ snapshot: WidgetPhotoSnapshot, in directory: URL = directory) throws {
    try write(snapshot, to: directory.appendingPathComponent(photosFileName))
  }

  static func write(_ snapshot: WidgetBackupSnapshot, in directory: URL = directory) throws {
    try write(snapshot, to: directory.appendingPathComponent(backupFileName))
  }

  /// A photo's image, downsampled to what the widget draws (widgets have little memory).
  public static func image(_ photo: WidgetPhoto, maxPixel: Int, in directory: URL = directory) -> CGImage? {
    let url = directory.appendingPathComponent(photo.file)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Takes these items off the widgets at once, on the calling thread: before the app
  /// records that they're locked, so ending right after leaves nothing to show.
  static func remove(_ itemIDs: Set<String>, in directory: URL = directory) {
    // Their files' names come from their ids: one may be there without being listed.
    var files = Set(itemIDs.map(WidgetPublisher.fileName(for:)))
    for file in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
    guard var snapshot = photos(in: directory) else { return }
    files = []
    func kept(_ sets: [WidgetPhotoSet]) -> [WidgetPhotoSet] {
      sets.compactMap { set in
        var set = set
        files.formUnion(set.photos.filter { itemIDs.contains($0.itemID) }.map(\.file))
        set.photos.removeAll { itemIDs.contains($0.itemID) }
        return set.photos.isEmpty ? nil : set
      }
    }
    snapshot.memories = kept(snapshot.memories)
    snapshot.people = kept(snapshot.people)
    guard !files.isEmpty else { return }
    for file in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
    if (try? write(snapshot, in: directory)) == nil {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(photosFileName))
    }
  }

  /// Removes images no longer listed.
  static func prune(keeping files: Set<String>, in directory: URL = directory) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    // Anything but the snapshots: an interrupted write leaves a temporary file too.
    for name in names where !name.hasSuffix(".json") && !files.contains(name) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(type, from: data)
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}

/// Links from a widget into the app: `gphotosapp://photo?id=…`, `person?id=…`, `backup`.
public enum WidgetLink: Equatable, Sendable {
  case photo(String)
  case person(Int64)
  case backup

  public static let scheme = "gphotosapp"

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    switch self {
    case .photo(let id):
      components.host = "photo"
      components.queryItems = [URLQueryItem(name: "id", value: id)]
    case .person(let id):
      components.host = "person"
      components.queryItems = [URLQueryItem(name: "id", value: String(id))]
    case .backup:
      components.host = "backup"
    }
    return components.url!
  }

  public init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let id = components.queryItems?.first { $0.name == "id" }?.value
    switch url.host {
    case "photo":
      guard let id, !id.isEmpty else { return nil }
      self = .photo(id)
    case "person":
      guard let id = id.flatMap(Int64.init) else { return nil }
      self = .person(id)
    case "backup":
      self = .backup
    default:
      return nil
    }
  }
}

/// Which of a set's photos a widget shows at a given time: a new one every hour, the same
/// one on every widget showing that set at once.
public enum WidgetRotation {
  public static let interval: TimeInterval = 3_600

  public static func index(count: Int, at date: Date) -> Int {
    guard count > 0 else { return 0 }
    return Int((date.timeIntervalSince1970 / interval).rounded(.down)) % count
  }

  /// The start of each hour from `date` for `hours` hours.
  public static func hours(from date: Date, count hours: Int) -> [Date] {
    let start = (date.timeIntervalSince1970 / interval).rounded(.down) * interval
    return (0..<max(hours, 1)).map { Date(timeIntervalSince1970: start + Double($0) * interval) }.map {
      max($0, date)
    }
  }
}
