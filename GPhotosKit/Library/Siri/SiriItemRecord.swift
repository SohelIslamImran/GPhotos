import Foundation

/// What Siri and Spotlight know about one Library item: its kind, date and place, plus what
/// on-device analysis found in it. Kept in the index database so entity lookups and search
/// work when Siri runs the app without its window.
public struct SiriItemRecord: Sendable, Equatable {
  public enum Source: String, Sendable {
    case device
    case google
    case folder
  }

  /// The item's index id: a device local identifier, `g:` + a Google media key, or a
  /// folder file id.
  public var id: String
  public var source: Source
  /// The file name, when there is one ("IMG_0042.HEIC").
  public var fileName: String
  public var date: Date?
  public var isVideo: Bool
  public var isFavorite: Bool
  public var latitude: Double?
  public var longitude: Double?
  /// Where it was taken, as Google Photos names it.
  public var place: String
  public var caption: String
  /// What Vision recognized ("dog", "beach").
  public var labels: [String]
  /// Text found in the photo.
  public var text: String
  /// Names of the people recognized in it.
  public var people: [String]

  public init(
    id: String, source: Source, fileName: String = "", date: Date?, isVideo: Bool, isFavorite: Bool,
    latitude: Double? = nil, longitude: Double? = nil, place: String = "", caption: String = "",
    labels: [String] = [], text: String = "", people: [String] = []
  ) {
    self.id = id
    self.source = source
    self.fileName = fileName
    self.date = date
    self.isVideo = isVideo
    self.isFavorite = isFavorite
    self.latitude = latitude
    self.longitude = longitude
    self.place = place
    self.caption = caption
    self.labels = labels
    self.text = text
    self.people = people
  }

  /// Spotlight caps how much it keeps per item; long receipts and documents are cut here.
  static let maximumTextLength = 2_000

  /// A stable hash of everything Spotlight shows or searches, plus `extra`, so a pass
  /// re-indexes only the items that changed. FNV-1a, since `Hasher` is seeded per launch.
  public func digest(including extra: [String] = []) -> Int64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ string: String) {
      for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
      }
      hash ^= 0x1f
      hash = hash &* 0x100_0000_01b3
    }
    mix(id)
    mix(source.rawValue)
    mix(fileName)
    mix(date.map { String($0.timeIntervalSince1970) } ?? "")
    mix(isVideo ? "v" : "p")
    mix(isFavorite ? "f" : "")
    mix(latitude.map { String($0) } ?? "")
    mix(longitude.map { String($0) } ?? "")
    mix(place)
    mix(caption)
    labels.forEach(mix)
    mix(text)
    people.forEach(mix)
    extra.forEach(mix)
    return Int64(bitPattern: hash)
  }

  /// A short name for lists: the place and day, or the file name.
  public var title: String {
    let kind = isVideo ? String(localized: "Video") : String(localized: "Photo")
    guard let date else { return fileName.isEmpty ? kind : fileName }
    let day = date.formatted(date: .abbreviated, time: .omitted)
    return place.isEmpty ? "\(kind), \(day)" : "\(place), \(day)"
  }

  /// Where the item lives, for the subtitle in Siri and Spotlight.
  public var sourceDescription: String {
    switch source {
    case .device: String(localized: "On this device")
    case .google: String(localized: "In Google Photos")
    case .folder: String(localized: "In a backed-up folder")
    }
  }
}

/// What analysis found in one item, read from the index for its record.
struct SiriItemFacts: Sendable, Equatable {
  var labels: [String] = []
  var text = ""
  var people: [String] = []
}

extension SiriItemRecord {
  /// One record per Library item, in timeline order. Facts and Google details are looked
  /// up by index id and media key; items without them get metadata only.
  static func records(
    from snapshot: UnifiedLibraryModel.IndexSnapshot, facts: [String: SiriItemFacts],
    googleDetails: [String: RemoteSiriDetails]
  ) -> [SiriItemRecord] {
    var records: [SiriItemRecord] = []
    records.reserveCapacity(snapshot.entries.count)
    for position in snapshot.entries.indices {
      guard let base = baseRecord(at: position, in: snapshot, googleDetails: googleDetails) else { continue }
      var record = base
      if let found = facts[record.id] {
        record.labels = found.labels
        record.text = String(found.text.prefix(maximumTextLength))
        record.people = found.people
      }
      records.append(record)
    }
    return records
  }

  private static func baseRecord(
    at position: Int, in snapshot: UnifiedLibraryModel.IndexSnapshot, googleDetails: [String: RemoteSiriDetails]
  ) -> SiriItemRecord? {
    switch snapshot.entries[position] {
    case .device(let index, _):
      guard snapshot.device.indices.contains(index) else { return nil }
      let info = snapshot.device[index]
      return SiriItemRecord(
        id: info.localIdentifier, source: .device, date: info.date, isVideo: info.isVideo, isFavorite: info.isFavorite,
        latitude: info.latitude, longitude: info.longitude)
    case .cloud(let index), .folder(_, cloud: .some(let index)):
      // A backed-up folder file is its Google Photos copy, as in search.
      guard snapshot.cloud.indices.contains(index) else { return nil }
      let item = snapshot.cloud[index]
      let details = googleDetails[item.mediaKey]
      return SiriItemRecord(
        id: LibraryIndexer.searchID(cloudMediaKey: item.mediaKey), source: .google, fileName: item.fileName,
        date: item.takenAt, isVideo: item.kind == .video, isFavorite: item.isFavorite, latitude: item.latitude,
        longitude: item.longitude, place: details?.place ?? "", caption: details?.caption ?? "")
    case .folder(let index, cloud: nil):
      guard snapshot.folder.indices.contains(index) else { return nil }
      let file = snapshot.folder[index]
      return SiriItemRecord(
        id: file.id, source: .folder, fileName: file.fileName, date: file.date, isVideo: file.isVideo, isFavorite: false)
    }
  }
}

/// The parts of a Google Photos item's metadata Siri shows: where it was taken and its
/// caption.
public struct RemoteSiriDetails: Sendable, Equatable {
  public var place: String
  public var caption: String

  public init(place: String, caption: String) {
    self.place = place
    self.caption = caption
  }
}
