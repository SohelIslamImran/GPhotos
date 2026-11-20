import Foundation

// MARK: - Message types

public struct CommitToken: Sendable, Equatable {
  public let field1: Int64
  public let field2: Data

  public init(field1: Int64, field2: Data) {
    self.field1 = field1
    self.field2 = field2
  }
}

public struct ScottyFinalizeToken: Sendable, Equatable {
  public let raw: Data

  public init(raw: Data) {
    self.raw = raw
  }

  public static func parse(_ data: Data) throws -> ScottyFinalizeToken {
    var reader = ProtobufReader(data: data)
    var field1Count = 0
    var field2Count = 0
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      switch field {
      case 1 where wireType == .varint:
        let v = try reader.readInt64()
        if v != 2 {
          throw GPhotosError.protobufDecode("Unsupported Scotty finalize token version \(v)")
        }
        field1Count += 1
      case 2 where wireType == .lengthDelimited:
        let bytes = try reader.readBytes()
        if bytes.isEmpty {
          throw GPhotosError.protobufDecode("Scotty finalize token field 2 is empty")
        }
        field2Count += 1
      default:
        try reader.skipField(wireType: wireType)
      }
    }
    guard field1Count == 1 && field2Count == 1 else {
      throw GPhotosError.protobufDecode("Invalid Scotty finalize token structure")
    }
    return ScottyFinalizeToken(raw: data)
  }

  public func commitToken() throws -> CommitToken {
    try GooglePhotosMessages.decodeCommitToken(raw)
  }
}

public struct LivePhotoCreateRequest: Sendable {
  public let photoToken: ScottyFinalizeToken
  public let videoToken: ScottyFinalizeToken
  public let fileName: String
  public let photoSHA1: Data
  public let videoSHA1: Data
  public let createdAt: Date
  public let modifiedAt: Date
  public let storagePolicy: Int64
  public let uploadQuality: Int64
  public let device: DeviceProfile

  public init(
    photoToken: ScottyFinalizeToken,
    videoToken: ScottyFinalizeToken,
    fileName: String,
    photoSHA1: Data,
    videoSHA1: Data,
    createdAt: Date,
    modifiedAt: Date,
    storagePolicy: Int64 = 3,
    uploadQuality: Int64 = 1,
    device: DeviceProfile = .metered
  ) {
    self.photoToken = photoToken
    self.videoToken = videoToken
    self.fileName = fileName
    self.photoSHA1 = photoSHA1
    self.videoSHA1 = videoSHA1
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.storagePolicy = storagePolicy
    self.uploadQuality = uploadQuality
    self.device = device
  }
}

public struct LivePhotoReconcileRequest: Sendable {
  public let videoToken: ScottyFinalizeToken
  public let fileName: String
  public let photoSHA1: Data
  public let videoSHA1: Data
  public let createdAt: Date
  public let modifiedAt: Date
  public let storagePolicy: Int64
  public let uploadQuality: Int64
  public let device: DeviceProfile

  public init(
    videoToken: ScottyFinalizeToken,
    fileName: String,
    photoSHA1: Data,
    videoSHA1: Data,
    createdAt: Date,
    modifiedAt: Date,
    storagePolicy: Int64 = 3,
    uploadQuality: Int64 = 1,
    device: DeviceProfile = .metered
  ) {
    self.videoToken = videoToken
    self.fileName = fileName
    self.photoSHA1 = photoSHA1
    self.videoSHA1 = videoSHA1
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.storagePolicy = storagePolicy
    self.uploadQuality = uploadQuality
    self.device = device
  }
}

// MARK: - Encode & Decode

public enum GooglePhotosMessages {
  private static let livePhotoResultItemMaskBase64 =
    "CnsKAggBEAEaAggBIgIIASoQCgIIARICCAEaAggBIgIIATICCAGCAQIIAYoBAggBmgECCAGiAQIIAaoBCggBKgIgATICCAHKAQIIAfIBBggBEgIIAfoBAggBggICCAGKAgQKAggBkgIGCAESAggBogICCAGqAgC6AgDCAgAQASpiCAESKggBEhIIARoGCAESAggBIgQIASIAKAEiBggBEgIQASoGCAESAggBMAE4ARoWCAESDAgBGgIIASICCAEoARoCCAEwASIKCAESBggBEgIIASoOCgQIATABEgYIARICCAE6AggBQgIIAUoKCAESAggBGgISAFoSEgIIARoCCAEiCAgBEgQIARACYgIIAXISEgIIARoCCAEiCAgBEgQIARACeggKAggBIgIIAYoBBAoCCAGSAQQIARABqgECCgA="

  /// GetUploadToken: f1=1→2, f2=2→2, f3=3→1, f4=4→3, file_size_bytes=7→size
  public static func encodeGetUploadToken(fileSizeBytes: Int64) -> Data {
    var writer = ProtobufWriter()
    writer.writeInt32(fieldNumber: 1, 2)
    writer.writeInt32(fieldNumber: 2, 2)
    writer.writeInt32(fieldNumber: 3, 1)
    writer.writeInt32(fieldNumber: 4, 3)
    writer.writeInt64(fieldNumber: 7, fileSizeBytes)
    return writer.data
  }

  /// HashCheck: field1{ field1{ sha1Hash=1, sha1MediaType=5 }, field2{} }. The media type
  /// is omitted for ordinary items (StandaloneMedia is the default); a Live Photo's motion
  /// is looked up as PhodeoMovie (2) and resolves only once it is attached to its still.
  public static func encodeHashCheck(sha1Hash: Data, asLivePhotoMotion: Bool = false) -> Data {
    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { outer in
      outer.writeMessage(fieldNumber: 1) { inner in
        inner.writeBytes(fieldNumber: 1, sha1Hash)
        if asLivePhotoMotion { inner.writeInt32(fieldNumber: 5, 2) }
      }
      outer.writeEmptyMessage(fieldNumber: 2)
    }
    return writer.data
  }

  /// CommitUpload nested structure per Google Photos mobile upload protocol.
  public static func encodeCommitUpload(
    commitToken: CommitToken,
    fileName: String,
    sha1Hash: Data,
    timestampSeconds: Int64,
    device: DeviceProfile,
    quality: Int64 = 3
  ) -> Data {
    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { root in
      root.writeMessage(fieldNumber: 1) { tokenMsg in
        tokenMsg.writeInt64(fieldNumber: 1, commitToken.field1)
        tokenMsg.writeBytes(fieldNumber: 2, commitToken.field2)
      }
      root.writeString(fieldNumber: 2, fileName)
      root.writeBytes(fieldNumber: 3, sha1Hash)
      root.writeMessage(fieldNumber: 4) { ts in
        ts.writeInt64(fieldNumber: 1, timestampSeconds)
        ts.writeInt64(fieldNumber: 2, 46_000_000)
      }
      root.writeInt64(fieldNumber: 7, quality)
      root.writeInt32(fieldNumber: 10, 1)
    }
    writer.writeMessage(fieldNumber: 2) { deviceMsg in
      deviceMsg.writeString(fieldNumber: 3, device.model)
      deviceMsg.writeString(fieldNumber: 4, device.make)
      deviceMsg.writeInt32(fieldNumber: 5, device.androidAPIVersion)
    }
    writer.writeBytes(fieldNumber: 3, Data([1, 3]))
    return writer.data
  }

  /// Splits a date into protobuf Timestamp seconds and nanos. Flooring keeps nanos in
  /// `0..<1e9` for dates before 1970, as the Timestamp message requires.
  static func timestampComponents(_ date: Date) -> (seconds: Int64, nanos: Int64) {
    let interval = date.timeIntervalSince1970
    let seconds = interval.rounded(.down)
    let nanos = min(Int64(((interval - seconds) * 1_000_000_000).rounded(.down)), 999_999_999)
    return (Int64(seconds), nanos)
  }

  private static func writeTimestamp(_ date: Date, into writer: inout ProtobufWriter) {
    let (seconds, nanos) = timestampComponents(date)
    // proto3 omits zero scalars; the official client's encoder does the same.
    if seconds != 0 { writer.writeInt64(fieldNumber: 1, seconds) }
    if nanos != 0 { writer.writeInt64(fieldNumber: 2, nanos) }
  }

  /// CreateMediaItemsRequest for Live Photos (Photo + Video pair)
  public static func encodeLivePhotoCreate(input: LivePhotoCreateRequest) throws -> Data {
    guard let maskData = Data(base64Encoded: livePhotoResultItemMaskBase64) else {
      throw GPhotosError.protobufDecode("Invalid result item mask")
    }

    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { blueprint in
      blueprint.writeBytes(fieldNumber: 1, input.photoToken.raw)
      blueprint.writeString(fieldNumber: 2, input.fileName)
      blueprint.writeBytes(fieldNumber: 3, input.photoSHA1)
      blueprint.writeMessage(fieldNumber: 5) { writeTimestamp(input.createdAt, into: &$0) }
      blueprint.writeMessage(fieldNumber: 6) { writeTimestamp(input.modifiedAt, into: &$0) }
      blueprint.writeInt64(fieldNumber: 7, input.storagePolicy)
      blueprint.writeInt64(fieldNumber: 10, input.uploadQuality)
      blueprint.writeMessage(fieldNumber: 24) { livePhotoInfo in
        livePhotoInfo.writeBytes(fieldNumber: 1, input.videoToken.raw)
        livePhotoInfo.writeBytes(fieldNumber: 2, input.videoSHA1)
      }
    }
    writer.writeMessage(fieldNumber: 2) { dev in
      dev.writeString(fieldNumber: 3, input.device.model)
      dev.writeString(fieldNumber: 4, input.device.make)
      dev.writeInt32(fieldNumber: 5, input.device.androidAPIVersion)
    }
    writer.writeBytes(fieldNumber: 5, maskData)
    return writer.data
  }

  /// CreateMediaItemsRequest to reconcile an existing still photo into a Live Photo
  public static func encodeLivePhotoReconcile(input: LivePhotoReconcileRequest) throws -> Data {
    guard let maskData = Data(base64Encoded: livePhotoResultItemMaskBase64) else {
      throw GPhotosError.protobufDecode("Invalid result item mask")
    }

    var writer = ProtobufWriter()
    writer.writeMessage(fieldNumber: 1) { blueprint in
      blueprint.writeBytes(fieldNumber: 1, input.videoToken.raw)
      blueprint.writeString(fieldNumber: 2, input.fileName)
      blueprint.writeBytes(fieldNumber: 3, input.videoSHA1)
      blueprint.writeMessage(fieldNumber: 5) { writeTimestamp(input.createdAt, into: &$0) }
      blueprint.writeMessage(fieldNumber: 6) { writeTimestamp(input.modifiedAt, into: &$0) }
      blueprint.writeInt64(fieldNumber: 7, input.storagePolicy)
      blueprint.writeMessage(fieldNumber: 9) { reconcile in
        reconcile.writeInt32(fieldNumber: 2, 1)  // RECONCILE_TYPE_PHODEO
        reconcile.writeBytes(fieldNumber: 3, input.photoSHA1)
      }
      blueprint.writeInt64(fieldNumber: 10, input.uploadQuality)
    }
    writer.writeMessage(fieldNumber: 2) { dev in
      dev.writeString(fieldNumber: 3, input.device.model)
      dev.writeString(fieldNumber: 4, input.device.make)
      dev.writeInt32(fieldNumber: 5, input.device.androidAPIVersion)
    }
    writer.writeBytes(fieldNumber: 5, maskData)
    return writer.data
  }

  /// CreateAlbum: album_name(1), timestamp(2), field3=1, media_keys(4), field6={}, field7{field1=3}, device(8)
  public static func encodeCreateAlbum(albumName: String, mediaKeys: [String], device: DeviceProfile) -> Data {
    var writer = ProtobufWriter()
    writer.writeString(fieldNumber: 1, albumName)
    writer.writeInt64(fieldNumber: 2, Int64(Date().timeIntervalSince1970))
    writer.writeInt32(fieldNumber: 3, 1)
    for key in mediaKeys {
      writer.writeMessage(fieldNumber: 4) { f4 in
        f4.writeMessage(fieldNumber: 1) { f1 in
          f1.writeString(fieldNumber: 1, key)
        }
      }
    }
    writer.writeEmptyMessage(fieldNumber: 6)
    writer.writeMessage(fieldNumber: 7) { f7 in
      f7.writeInt32(fieldNumber: 1, 3)
    }
    writer.writeMessage(fieldNumber: 8) { dev in
      dev.writeString(fieldNumber: 3, device.model)
      dev.writeString(fieldNumber: 4, device.make)
      dev.writeInt32(fieldNumber: 5, device.androidAPIVersion)
    }
    return writer.data
  }

  /// AddMediaToAlbum: media_keys(1), album_media_key(2), field5{field1=2}, device(6), timestamp(7)
  public static func encodeAddMediaToAlbum(albumMediaKey: String, mediaKeys: [String], device: DeviceProfile) -> Data {
    var writer = ProtobufWriter()
    for key in mediaKeys {
      writer.writeString(fieldNumber: 1, key)
    }
    writer.writeString(fieldNumber: 2, albumMediaKey)
    writer.writeMessage(fieldNumber: 5) { f5 in
      f5.writeInt32(fieldNumber: 1, 2)
    }
    writer.writeMessage(fieldNumber: 6) { dev in
      dev.writeString(fieldNumber: 3, device.model)
      dev.writeString(fieldNumber: 4, device.make)
      dev.writeInt32(fieldNumber: 5, device.androidAPIVersion)
    }
    writer.writeInt64(fieldNumber: 7, Int64(Date().timeIntervalSince1970))
    return writer.data
  }

  // MARK: - Decoding

  /// The `google.rpc.Status` Google sends as an error body: a canonical code (field 1) and
  /// a message (field 2). Nil when the body is not one.
  public struct RPCStatus: Sendable, Equatable {
    public static let resourceExhausted: Int64 = 8
    public let code: Int64
    public let message: String?
  }

  public static func decodeRPCStatus(_ data: Data) -> RPCStatus? {
    guard !data.isEmpty else { return nil }
    var reader = ProtobufReader(data: data)
    var code: Int64?
    var message: String?
    do {
      while !reader.isAtEnd {
        let (field, wireType) = try reader.readTag()
        switch field {
        case 1 where wireType == .varint: code = try reader.readInt64()
        case 2 where wireType == .lengthDelimited: message = try reader.readString()
        default: try reader.skipField(wireType: wireType)
        }
      }
    } catch {
      return nil
    }
    // Canonical codes run 1...16; 0 is OK and cannot describe a failure.
    guard let code, (1...16).contains(code) else { return nil }
    return RPCStatus(code: code, message: message)
  }

  /// What an error body says, for an error message: the status message when it is a
  /// `google.rpc.Status`, the text when it is printable, otherwise nothing.
  public static func errorDetail(_ data: Data, limit: Int = 240) -> String {
    let text = decodeRPCStatus(data)?.message ?? String(decoding: data, as: UTF8.self)
    let printable = text.unicodeScalars.allSatisfy {
      $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F && $0 != "\u{FFFD}")
    }
    guard printable else { return "" }
    return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }

  /// RemoteMatches: field1(1)→field2(2)→field2(2)→media_key(1)
  public static func decodeRemoteMatches(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1, wireType == .lengthDelimited {
        let nested = try reader.readBytes()
        if let key = try decodeRemoteMatchEntry(nested) {
          return key
        }
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  private static func decodeRemoteMatchEntry(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 2, wireType == .lengthDelimited {
        let inner = try reader.readBytes()
        if let key = try decodeRemoteMatchInner(inner) {
          return key
        }
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  private static func decodeRemoteMatchInner(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 2, wireType == .lengthDelimited {
        let deepest = try reader.readBytes()
        return try decodeMediaKey(deepest)
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  private static func decodeMediaKey(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1, wireType == .lengthDelimited {
        return try reader.readString()
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  /// CommitToken: field1=1 (int64), field2=2 (bytes)
  public static func decodeCommitToken(_ data: Data) throws -> CommitToken {
    var field1: Int64?
    var field2: Data?
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      switch field {
      case 1 where wireType == .varint:
        field1 = try reader.readInt64()
      case 2 where wireType == .lengthDelimited:
        field2 = try reader.readBytes()
      default:
        try reader.skipField(wireType: wireType)
      }
    }
    guard let f1 = field1, let f2 = field2 else {
      throw GPhotosError.protobufDecode("CommitToken missing required fields")
    }
    return CommitToken(field1: f1, field2: f2)
  }

  /// CommitUploadResponse: field1(1)→field3(3)→media_key(1)
  public static func decodeCommitUploadResponse(_ data: Data) throws -> String {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1, wireType == .lengthDelimited {
        let nested = try reader.readBytes()
        if let key = try decodeCommitResponseRoot(nested) {
          return key
        }
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    throw GPhotosError.protobufDecode("CommitUploadResponse missing mediaKey")
  }

  private static func decodeCommitResponseRoot(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 3, wireType == .lengthDelimited {
        let nested = try reader.readBytes()
        return try decodeMediaKey(nested)
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  /// CreateMediaItemsResponse: item(1)→result_item(2)→media_key(1)
  public static func decodeCreateMediaItemsResponse(_ data: Data) throws -> String {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1, wireType == .lengthDelimited {
        let itemBytes = try reader.readBytes()
        if let key = try decodeCreateMediaItemEntry(itemBytes) {
          return key
        }
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    throw GPhotosError.protobufDecode("CreateMediaItemsResponse missing mediaKey")
  }

  private static func decodeCreateMediaItemEntry(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 3, wireType == .lengthDelimited {
        let resultBytes = try reader.readBytes()
        return try decodeMediaKey(resultBytes)
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    return nil
  }

  /// CreateAlbumResponse: field1(1)→album_media_key(1)
  public static func decodeCreateAlbumResponse(_ data: Data) throws -> String {
    var reader = ProtobufReader(data: data)
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1, wireType == .lengthDelimited {
        let nested = try reader.readBytes()
        var innerReader = ProtobufReader(data: nested)
        while !innerReader.isAtEnd {
          let (innerField, innerWire) = try innerReader.readTag()
          if innerField == 1, innerWire == .lengthDelimited {
            return try innerReader.readString()
          } else {
            try innerReader.skipField(wireType: innerWire)
          }
        }
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    throw GPhotosError.protobufDecode("CreateAlbumResponse missing albumMediaKey")
  }
}
