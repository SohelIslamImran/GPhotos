import Foundation

// MARK: - Generic message view

/// A protobuf message read lazily by field number, for responses whose schema is only
/// partly known. Length-delimited values stay raw until asked for as a message, so unknown
/// parts of a large sync page cost nothing.
struct ProtoMessage {
  enum Value {
    case varint(UInt64)
    case fixed32(UInt32)
    case fixed64(UInt64)
    case bytes(Data)
  }

  private(set) var fields: [(number: Int, value: Value)] = []

  init(_ data: Data) throws {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (number, wireType) = try reader.readTag()
      switch wireType {
      case .varint: fields.append((number, .varint(try reader.readVarint())))
      case .lengthDelimited: fields.append((number, .bytes(try reader.readBytes())))
      case .fixed32:
        let bytes = try reader.readFixed(4)
        fields.append((number, .fixed32(bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })))
      case .fixed64:
        let bytes = try reader.readFixed(8)
        fields.append((number, .fixed64(bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) })))
      }
    }
  }

  func values(_ number: Int) -> [Value] { fields.lazy.filter { $0.number == number }.map(\.value) }

  func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }

  func bytes(_ number: Int) -> Data? {
    for case .bytes(let data) in values(number) { return data }
    return nil
  }

  func string(_ number: Int) -> String? { bytes(number).flatMap { String(data: $0, encoding: .utf8) } }

  /// Any numeric wire type as raw bits.
  func integer(_ number: Int) -> UInt64? {
    for value in values(number) {
      switch value {
      case .varint(let raw), .fixed64(let raw): return raw
      case .fixed32(let raw): return UInt64(raw)
      case .bytes: continue
      }
    }
    return nil
  }

  func int(_ number: Int) -> Int? { integer(number).map { Int(truncatingIfNeeded: Int64(bitPattern: $0)) } }

  func message(_ number: Int) -> ProtoMessage? { bytes(number).flatMap { try? ProtoMessage($0) } }

  func messages(_ number: Int) -> [ProtoMessage] {
    values(number).compactMap { value in
      guard case .bytes(let data) = value else { return nil }
      return try? ProtoMessage(data)
    }
  }

  /// Follows nested messages: `message(at: 2, 13)` is field 13 of field 2.
  func message(at path: Int...) -> ProtoMessage? {
    var current: ProtoMessage? = self
    for number in path { current = current?.message(number) }
    return current
  }
}

// MARK: - Sync requests

/// A library request with its token fields cut out. The bodies contain hundreds of
/// hard-coded field masks. Keeping those bytes and splicing only the tokens back in is
/// the surest way to stay byte for byte identical (checked against fixtures in the tests).
struct LibrarySyncTemplate {
  /// Fields of message 1 before the token fields.
  let prefix: Data
  /// Fields of message 1 after the token fields.
  let suffix: Data
  /// Top-level field 2, complete.
  let trailer: Data

  init(prefix: String, suffix: String, trailer: String) {
    func decode(_ string: String) -> Data {
      Data(base64Encoded: string.filter { !$0.isWhitespace })!
    }
    self.prefix = decode(prefix)
    self.suffix = decode(suffix)
    self.trailer = decode(trailer)
  }

  func body(resumeToken: String?, syncToken: String?) -> Data {
    var tokens = ProtobufWriter()
    if let resumeToken { tokens.writeString(fieldNumber: 4, resumeToken) }
    if let syncToken { tokens.writeString(fieldNumber: 6, syncToken) }
    var writer = ProtobufWriter()
    writer.writeBytes(fieldNumber: 1, prefix + tokens.data + suffix)
    return writer.data + trailer
  }
}

/// Library sync and item actions in the mobile protocol.
public enum LibraryMessages {
  /// `get_library_state`: the first page of a full sync (empty token) or of a delta.
  static func libraryState(syncToken: String) -> Data {
    LibrarySyncTemplate.state.body(resumeToken: nil, syncToken: syncToken)
  }

  /// `get_library_page_init`: later pages of the first full sync.
  static func initialPage(resumeToken: String) -> Data {
    LibrarySyncTemplate.initialPage.body(resumeToken: resumeToken, syncToken: nil)
  }

  /// `get_library_page`: later pages of a delta sync.
  static func deltaPage(resumeToken: String, syncToken: String) -> Data {
    LibrarySyncTemplate.deltaPage.body(resumeToken: resumeToken, syncToken: syncToken)
  }

  private static func clientVersion(_ writer: inout ProtobufWriter, device: DeviceProfile) {
    writer.writeMessage(fieldNumber: 9) { info in
      info.writeInt64(fieldNumber: 1, 5)
      info.writeMessage(fieldNumber: 2) { version in
        version.writeInt64(fieldNumber: 1, Int64(device.clientVersionCode))
        version.writeString(fieldNumber: 2, String(device.androidAPIVersion))
      }
    }
  }

  /// `move_remote_media_to_trash`.
  static func trash(dedupKeys: [String], device: DeviceProfile) -> Data {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 2, 1)
    for key in dedupKeys { writer.writeString(fieldNumber: 3, key) }
    writer.writeInt64(fieldNumber: 4, 1)
    writer.writeMessage(fieldNumber: 8) { options in
      options.writeMessage(fieldNumber: 4) { mask in
        mask.writeEmptyMessage(fieldNumber: 2)
        mask.writeMessage(fieldNumber: 3) { $0.writeEmptyMessage(fieldNumber: 1) }
        mask.writeEmptyMessage(fieldNumber: 4)
        mask.writeMessage(fieldNumber: 5) { $0.writeEmptyMessage(fieldNumber: 1) }
      }
    }
    clientVersion(&writer, device: device)
    return writer.data
  }

  /// `delete_remote_media_permanently` sends field 9 as an empty string instead of the
  /// client version the other actions carry.
  static func deleteForever(dedupKeys: [String]) -> Data {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 2, 2)
    for key in dedupKeys { writer.writeString(fieldNumber: 3, key) }
    writer.writeInt64(fieldNumber: 4, 2)
    writer.writeMessage(fieldNumber: 8) { options in
      options.writeMessage(fieldNumber: 4) { mask in
        mask.writeEmptyMessage(fieldNumber: 2)
        mask.writeMessage(fieldNumber: 3) { $0.writeEmptyMessage(fieldNumber: 1) }
        mask.writeEmptyMessage(fieldNumber: 4)
        mask.writeMessage(fieldNumber: 5) { $0.writeEmptyMessage(fieldNumber: 1) }
      }
    }
    writer.writeString(fieldNumber: 9, "")
    return writer.data
  }

  /// `restore_from_trash`.
  static func restore(dedupKeys: [String], device: DeviceProfile) -> Data {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 2, 3)
    for key in dedupKeys { writer.writeString(fieldNumber: 3, key) }
    writer.writeInt64(fieldNumber: 4, 2)
    writer.writeMessage(fieldNumber: 8) { options in
      options.writeMessage(fieldNumber: 4) { mask in
        mask.writeEmptyMessage(fieldNumber: 2)
        mask.writeMessage(fieldNumber: 3) { $0.writeEmptyMessage(fieldNumber: 1) }
      }
    }
    clientVersion(&writer, device: device)
    return writer.data
  }

  /// `set_favorite`: one item per request.
  static func favorite(dedupKey: String, isFavorite: Bool) -> Data {
    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { $0.writeString(fieldNumber: 2, dedupKey) }
    writer.writeMessage(fieldNumber: 2) { $0.writeInt64(fieldNumber: 1, isFavorite ? 1 : 2) }
    writer.writeMessage(fieldNumber: 3) { $0.writeMessage(fieldNumber: 1) { $0.writeEmptyMessage(fieldNumber: 19) } }
    return writer.data
  }

  /// `set_archived`.
  static func archive(dedupKeys: [String], isArchived: Bool) -> Data {
    var writer = ProtobufWriter()
    for key in dedupKeys {
      writer.writeMessage(fieldNumber: 1) { item in
        item.writeString(fieldNumber: 1, key)
        item.writeMessage(fieldNumber: 2) { $0.writeInt64(fieldNumber: 1, isArchived ? 1 : 2) }
      }
    }
    writer.writeInt64(fieldNumber: 3, 1)
    return writer.data
  }

  /// `set_item_caption`.
  static func caption(dedupKey: String, caption: String) -> Data {
    var writer = ProtobufWriter()
    writer.writeString(fieldNumber: 2, caption)
    writer.writeString(fieldNumber: 3, dedupKey)
    return writer.data
  }

  /// `get_download_urls`.
  static func downloadURLs(mediaKey: String) -> Data {
    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { $0.writeMessage(fieldNumber: 1) { $0.writeString(fieldNumber: 1, mediaKey) } }
    writer.writeMessage(fieldNumber: 2) { options in
      options.writeMessage(fieldNumber: 1) { $0.writeMessage(fieldNumber: 7) { $0.writeEmptyMessage(fieldNumber: 2) } }
      options.writeMessage(fieldNumber: 5) { download in
        download.writeEmptyMessage(fieldNumber: 2)
        download.writeEmptyMessage(fieldNumber: 3)
        download.writeMessage(fieldNumber: 5) { inner in
          inner.writeEmptyMessage(fieldNumber: 1)
          inner.writeInt64(fieldNumber: 3, 0)
        }
      }
    }
    return writer.data
  }

  /// Download links from a `get_download_urls` response: 1.5.2.5 has edits applied,
  /// 1.5.2.6 is the original.
  static func decodeDownloadURLs(_ data: Data) throws -> (edited: URL?, original: URL?) {
    let links = try ProtoMessage(data).message(at: 1, 5, 2)
    return (links?.string(5).flatMap(URL.init(string:)), links?.string(6).flatMap(URL.init(string:)))
  }

  /// A page of library changes.
  static func decodeLibraryUpdate(_ data: Data) throws -> RemoteLibraryUpdate {
    let root = try ProtoMessage(data).message(1) ?? ProtoMessage(Data())
    let items = root.messages(2).compactMap(RemoteMediaItem.init(proto:))
    var deleted: [String] = []
    var deletedAlbums: [String] = []
    for deletion in root.messages(9) {
      // Type 1 is an item. Type 4 is a collection.
      switch deletion.message(1)?.int(1) {
      case 1: if let key = deletion.message(at: 1, 2)?.string(1) { deleted.append(key) }
      case 4: if let key = deletion.message(at: 1, 5)?.string(2) { deletedAlbums.append(key) }
      default: break
      }
    }
    return RemoteLibraryUpdate(
      syncToken: root.string(6) ?? "", resumeToken: root.string(1) ?? "", items: items, deletedMediaKeys: deleted,
      triggersNextSync: root.int(7) == 2, albums: root.messages(3).compactMap(RemoteAlbum.init(proto:)),
      deletedAlbumKeys: deletedAlbums)
  }
}

// MARK: - Decoded items

public struct RemoteLibraryUpdate: Sendable {
  public var syncToken: String
  public var resumeToken: String
  public var items: [RemoteMediaItem]
  public var deletedMediaKeys: [String]
  /// The server has more changes for another delta cycle (1.7 == 2).
  public var triggersNextSync: Bool
  public var albums: [RemoteAlbum] = []
  public var deletedAlbumKeys: [String] = []
}

/// A Google Photos album decoded from the library sync response.
public struct RemoteAlbum: Sendable, Equatable, Identifiable {
  public var mediaKey: String
  public var title: String
  public var itemCount: Int
  public var coverMediaKey: String?
  public var startDate: Date?
  public var endDate: Date?
  public var lastActivity: Date?

  public var id: String { mediaKey }

  public init(
    mediaKey: String, title: String, itemCount: Int, coverMediaKey: String?, startDate: Date?, endDate: Date?,
    lastActivity: Date?
  ) {
    self.mediaKey = mediaKey
    self.title = title
    self.itemCount = itemCount
    self.coverMediaKey = coverMediaKey
    self.startDate = startDate
    self.endDate = endDate
    self.lastActivity = lastActivity
  }

  init?(proto: ProtoMessage) {
    guard let key = proto.string(1), !key.isEmpty, let info = proto.message(2) else { return nil }
    mediaKey = key
    title = info.string(5) ?? ""
    itemCount = info.int(7) ?? 0
    coverMediaKey = info.message(17)?.string(1)
    let range = info.message(10)
    startDate = RemoteMediaItem.date(range?.message(6)?.int(1))
    endDate = RemoteMediaItem.date(range?.message(7)?.int(1))
    lastActivity = RemoteMediaItem.date(range?.int(10))
  }
}

/// One item of the Google Photos library, as the sync API describes it.
public struct RemoteMediaItem: Sendable, Equatable, Identifiable {
  public enum Kind: Int, Sendable {
    case photo = 1
    case video = 2
    /// A Motion Photo or Live Photo: a still with a short video attached.
    case motionPhoto = 3
  }

  public var mediaKey: String
  public var dedupKey: String
  public var sha1: Data?
  public var fileName: String
  public var caption: String?
  public var kind: Kind
  public var sizeBytes: Int64
  public var quotaChargedBytes: Int64
  public var isOriginalQuality: Bool
  /// Capture time.
  public var takenAt: Date
  public var timezoneOffsetMinutes: Int?
  public var uploadedAt: Date?
  public var contentVersion: Int
  public var trashedAt: Date?
  public var isArchived: Bool
  public var isFavorite: Bool
  public var isLocked: Bool
  public var isCanonical: Bool
  public var isEdited: Bool
  public var origin: Int
  public var width: Int?
  public var height: Int?
  public var latitude: Double?
  public var longitude: Double?
  public var locationName: String?
  public var cameraMake: String?
  public var cameraModel: String?
  public var aperture: Double?
  public var shutterSpeed: Double?
  public var iso: Int?
  public var focalLength: Double?
  public var durationMs: Int?
  /// `collection_id` (2.1.1): the collection the item belongs to.
  public var collectionID: String?

  public var id: String { mediaKey }

  init?(proto item: ProtoMessage) {
    guard let mediaKey = item.string(1), !mediaKey.isEmpty else { return nil }
    let info = item.message(2) ?? (try! ProtoMessage(Data()))
    let media = item.message(5)
    self.mediaKey = mediaKey
    sha1 = info.message(13)?.bytes(1)
    if let key = info.message(21)?.string(1), !key.isEmpty {
      dedupKey = key
    } else if let sha1 {
      dedupKey = sha1.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "="))
    } else {
      dedupKey = mediaKey
    }
    fileName = info.string(4) ?? "\(mediaKey).bin"
    caption = info.string(3).flatMap { $0.isEmpty ? nil : $0 }
    sizeBytes = Int64(info.int(10) ?? 0)
    let quota = info.message(35)
    quotaChargedBytes = Int64(quota?.int(2) ?? 0)
    isOriginalQuality = quota?.int(3) == 2
    takenAt = Self.date(info.int(7)) ?? .distantPast
    timezoneOffsetMinutes = info.int(8).map { $0 / 60_000 }
    uploadedAt = Self.date(info.int(9))
    contentVersion = info.int(26) ?? 0
    trashedAt = Self.date(info.message(16)?.int(3))
    isArchived = info.message(29)?.int(1) == 1
    isFavorite = info.message(31)?.int(1) == 1
    isLocked = info.message(39)?.int(1) == 1
    isCanonical = !info.messages(5).contains { $0.int(1) == 27 }
    origin = info.message(30)?.int(1) ?? 1
    collectionID = info.message(1)?.string(1).flatMap { $0.isEmpty ? nil : $0 }

    let location = item.message(17)
    latitude = location?.message(1)?.integer(1).map(Self.scaledCoordinate)
    longitude = location?.message(1)?.integer(2).map(Self.scaledCoordinate)
    locationName = location?.message(at: 5, 2)?.string(1)

    kind = .photo
    isEdited = false
    if let photo = media?.message(2) {
      isEdited = photo.has(4)
      let details = photo.message(at: 1, 9)
      width = details?.int(1)
      height = details?.int(2)
      if let camera = details?.message(5) {
        cameraMake = camera.string(1)
        cameraModel = camera.string(2)
        aperture = camera.integer(4).map(Self.float32)
        shutterSpeed = camera.integer(5).map(Self.float32)
        iso = camera.int(6)
        focalLength = camera.integer(7).map(Self.float32)
      }
    }
    if let video = media?.message(3) {
      kind = .video
      if let details = video.message(4) {
        durationMs = details.int(1)
        width = details.int(4)
        height = details.int(5)
      }
    }
    if let motion = media?.message(at: 5, 2, 4) {
      kind = .motionPhoto
      durationMs = motion.int(1)
      if width == nil {
        width = motion.int(4)
        height = motion.int(5)
      }
    }
  }

  /// Google sends milliseconds; anything that small must already be seconds.
  static func date(_ value: Int?) -> Date? {
    guard let value, value > 0 else { return nil }
    let seconds = value > 100_000_000_000 ? Double(value) / 1000 : Double(value)
    return Date(timeIntervalSince1970: seconds)
  }

  /// Degrees × 10⁷ in a signed 32-bit field.
  static func scaledCoordinate(_ raw: UInt64) -> Double {
    Double(Int32(truncatingIfNeeded: raw)) / 10_000_000
  }

  /// A float sent as its 32-bit pattern.
  static func float32(_ raw: UInt64) -> Double {
    Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
  }

  public var isVideo: Bool { kind == .video }
  public var duration: TimeInterval? { durationMs.map { Double($0) / 1000 } }
}
