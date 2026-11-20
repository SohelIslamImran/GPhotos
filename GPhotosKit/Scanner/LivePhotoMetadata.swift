import Foundation
import ImageIO

public struct VideoLivePhotoMetadata: Sendable, Equatable {
  public let contentIdentifier: String?
  public let hasStillImageTime: Bool

  public init(contentIdentifier: String?, hasStillImageTime: Bool) {
    self.contentIdentifier = contentIdentifier
    self.hasStillImageTime = hasStillImageTime
  }
}

public enum LivePhotoMetadata {
  public static let appleMakerNoteHeader = "Apple iOS\0"
  public static let maxMakerNoteScanSize = 64 * 1024 * 1024
  public static let maxContentIdentifier = 256
  public static let maxMP4BoxDepth = 32

  // MARK: - Photo Metadata

  /// Reads the Apple Live Photo content identifier from a photo file (HEIC or JPEG).
  /// Tries ImageIO properties first. The byte scan is skipped for photos ImageIO reports
  /// as taken by another maker: they carry no Apple identifier, and scanning every such
  /// file up to 64 MB on each folder pass would be wasteful.
  public nonisolated static func readPhotoContentIdentifier(from url: URL) -> String? {
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    {
      if let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
        let rawID = (makerApple["17"] as? String) ?? (makerApple["17"] as? CustomStringConvertible)?.description
      {
        let trimmed = cleanIdentifier(rawID)
        if isCanonicalUUID(trimmed) { return trimmed.uppercased() }
      }
      let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
      if let make = tiff?[kCGImagePropertyTIFFMake] as? String,
        !make.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveContains("apple")
      {
        return nil
      }
    }

    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxMakerNoteScanSize)) ?? Data()
    return readPhotoContentIdentifier(data: data)
  }

  /// Byte scanner for Apple MakerNote content identifier in raw photo data.
  public nonisolated static func readPhotoContentIdentifier(data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    let scanLimit = min(data.count, maxMakerNoteScanSize)
    let marker = Array(appleMakerNoteHeader.utf8)

    var searchOffset = 0
    while searchOffset + marker.count <= scanLimit {
      guard let matchIndex = findBytes(marker, in: data, startingAt: searchOffset, limit: scanLimit) else {
        break
      }
      if let identifier = parseAppleMakerNoteIdentifier(in: data, startingAt: matchIndex, limit: scanLimit) {
        return identifier
      }
      searchOffset = matchIndex + marker.count
    }

    return nil
  }

  private nonisolated static func findBytes(_ needle: [UInt8], in data: Data, startingAt start: Int, limit: Int) -> Int? {
    guard !needle.isEmpty, start + needle.count <= limit else { return nil }
    let base = data.startIndex
    return data.range(of: Data(needle), in: (base + start)..<(base + limit)).map { $0.lowerBound - base }
  }

  private nonisolated static func parseAppleMakerNoteIdentifier(
    in data: Data,
    startingAt offset: Int,
    limit: Int
  ) -> String? {
    let headerLen = 16
    guard offset + headerLen <= limit else { return nil }

    let orderByte0 = data[offset + 12]
    let orderByte1 = data[offset + 13]
    let isBigEndian: Bool
    if orderByte0 == 0x4D && orderByte1 == 0x4D {
      isBigEndian = true
    } else if orderByte0 == 0x49 && orderByte1 == 0x49 {
      isBigEndian = false
    } else {
      return nil
    }

    let entryCount = Int(readUInt16(in: data, at: offset + 14, bigEndian: isBigEndian))
    let entriesEnd = offset + headerLen + entryCount * 12
    guard entryCount > 0, entriesEnd <= limit else { return nil }

    for i in 0..<entryCount {
      let entryStart = offset + headerLen + i * 12
      let tag = readUInt16(in: data, at: entryStart, bigEndian: isBigEndian)
      guard tag == 17 else { continue }
      let type = readUInt16(in: data, at: entryStart + 2, bigEndian: isBigEndian)
      guard type == 2 else { return nil }
      let valLen = Int(readUInt32(in: data, at: entryStart + 4, bigEndian: isBigEndian))
      guard valLen > 0, valLen <= maxContentIdentifier else { return nil }

      let valueBytes: Data
      if valLen <= 4 {
        valueBytes = data.subdata(in: (entryStart + 8)..<(entryStart + 8 + valLen))
      } else {
        let valOffset = Int(readUInt32(in: data, at: entryStart + 8, bigEndian: isBigEndian))
        let absOffset = offset + valOffset
        guard absOffset >= 0, absOffset + valLen <= data.count else { return nil }
        valueBytes = data.subdata(in: absOffset..<(absOffset + valLen))
      }

      if let str = String(data: valueBytes, encoding: .utf8) ?? String(data: valueBytes, encoding: .isoLatin1) {
        let trimmed = cleanIdentifier(str)
        if isCanonicalUUID(trimmed) {
          return trimmed.uppercased()
        }
      }
      return nil
    }

    return nil
  }

  // MARK: - Video Metadata

  /// Reads QuickTime / MP4 Live Photo metadata (content identifier and still-image-time).
  public nonisolated static func readVideoLivePhotoMetadata(from url: URL) -> VideoLivePhotoMetadata? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    guard size >= 8 else { return nil }
    return readVideoLivePhotoMetadata(reader: FileHandleReader(handle: handle, size: size))
  }

  /// Reads QuickTime / MP4 Live Photo metadata from raw data.
  public nonisolated static func readVideoLivePhotoMetadata(data: Data) -> VideoLivePhotoMetadata? {
    guard data.count >= 8 else { return nil }
    return readVideoLivePhotoMetadata(reader: DataReader(data: data))
  }

  private nonisolated static func readVideoLivePhotoMetadata(reader: RandomAccessReader) -> VideoLivePhotoMetadata? {
    var contentID: String?
    var hasStillImage = false

    _ = walkBoxes(reader: reader, start: 0, end: reader.size, depth: 0) { box in
      let typeStr = box.typeString
      if typeStr == "meta" {
        if let id = readQuickTimeContentIdentifier(reader: reader, meta: box) {
          contentID = id
        }
      } else if typeStr == "stbl" {
        if readStillImageTimeTrack(reader: reader, sampleTable: box) {
          hasStillImage = true
        }
      }
      return true
    }

    if contentID != nil || hasStillImage {
      return VideoLivePhotoMetadata(contentIdentifier: contentID, hasStillImageTime: hasStillImage)
    }
    return nil
  }

  // MARK: - Box Parsing

  private struct MP4Box {
    let type: [UInt8]
    let payloadStart: Int64
    let end: Int64

    var typeString: String {
      String(bytes: type, encoding: .ascii) ?? ""
    }
  }

  private nonisolated static func walkBoxes(
    reader: RandomAccessReader,
    start: Int64,
    end: Int64,
    depth: Int,
    visit: (MP4Box) -> Bool
  ) -> Bool {
    guard depth <= maxMP4BoxDepth else { return false }
    var offset = start
    while offset < end {
      guard let box = readMP4Box(reader: reader, offset: offset, parentEnd: end) else { break }
      if !visit(box) { return false }
      if isMP4Container(box.type) {
        var childStart = box.payloadStart
        if box.typeString == "meta" {
          if let detected = quickTimeMetaChildrenStart(reader: reader, box: box) {
            childStart = detected
          }
        }
        if childStart <= box.end {
          _ = walkBoxes(reader: reader, start: childStart, end: box.end, depth: depth + 1, visit: visit)
        }
      }
      offset = box.end
    }
    return true
  }

  private nonisolated static func readMP4Box(reader: RandomAccessReader, offset: Int64, parentEnd: Int64) -> MP4Box? {
    guard offset >= 0, parentEnd - offset >= 8 else { return nil }
    guard let header = try? reader.read(at: offset, count: 16) else { return nil }
    guard header.count >= 8 else { return nil }

    var boxSize = Int64(readBigUInt32(in: header, at: 0))
    var headerSize: Int64 = 8
    if boxSize == 1 {
      guard parentEnd - offset >= 16, header.count >= 16 else { return nil }
      boxSize = Int64(exactly: readBigUInt64(in: header, at: 8)) ?? -1
      headerSize = 16
    } else if boxSize == 0 {
      boxSize = parentEnd - offset
    }

    guard boxSize >= headerSize, boxSize <= parentEnd - offset else { return nil }
    let boxType = [header[4], header[5], header[6], header[7]]
    return MP4Box(type: boxType, payloadStart: offset + headerSize, end: offset + boxSize)
  }

  private nonisolated static func isMP4Container(_ type: [UInt8]) -> Bool {
    guard let str = String(bytes: type, encoding: .ascii) else { return false }
    switch str {
    case "moov", "trak", "mdia", "minf", "stbl", "udta", "meta":
      return true
    default:
      return false
    }
  }

  private nonisolated static func quickTimeMetaChildrenStart(reader: RandomAccessReader, box: MP4Box) -> Int64? {
    let payloadSize = box.end - box.payloadStart
    guard payloadSize >= 8 else { return nil }
    guard let header = try? reader.read(at: box.payloadStart, count: 8), header.count >= 4 else { return nil }
    let firstChildSize = Int64(readBigUInt32(in: header, at: 0))
    if firstChildSize >= 8 && firstChildSize <= payloadSize {
      return box.payloadStart
    }
    guard payloadSize >= 12 else { return nil }
    return box.payloadStart + 4
  }

  private nonisolated static func readDirectBoxes(reader: RandomAccessReader, start: Int64, end: Int64) -> [MP4Box] {
    var boxes: [MP4Box] = []
    var offset = start
    while offset < end {
      guard let box = readMP4Box(reader: reader, offset: offset, parentEnd: end) else { break }
      boxes.append(box)
      offset = box.end
    }
    return boxes
  }

  private nonisolated static func readQuickTimeContentIdentifier(reader: RandomAccessReader, meta: MP4Box) -> String? {
    guard let childrenStart = quickTimeMetaChildrenStart(reader: reader, box: meta) else { return nil }
    let children = readDirectBoxes(reader: reader, start: childrenStart, end: meta.end)

    var keysBox: MP4Box?
    var itemListBox: MP4Box?
    for child in children {
      if child.typeString == "keys" { keysBox = child }
      if child.typeString == "ilst" { itemListBox = child }
    }
    guard let keysBox, let itemListBox else { return nil }

    guard let keys = readQuickTimeKeys(reader: reader, box: keysBox) else { return nil }
    var contentIndex: UInt32 = 0
    for (i, key) in keys.enumerated() {
      if key == "com.apple.quicktime.content.identifier" {
        contentIndex = UInt32(i + 1)
        break
      }
    }
    guard contentIndex > 0 else { return nil }

    guard let raw = readQuickTimeItemValue(reader: reader, itemList: itemListBox, wantedIndex: contentIndex) else {
      return nil
    }
    let trimmed = cleanIdentifier(raw)
    guard isCanonicalUUID(trimmed) else { return nil }
    return trimmed.uppercased()
  }

  private nonisolated static func readQuickTimeKeys(reader: RandomAccessReader, box: MP4Box) -> [String]? {
    let size = box.end - box.payloadStart
    guard size >= 8, size <= 4 * 1024 * 1024 else { return nil }
    guard let payload = try? reader.read(at: box.payloadStart, count: Int(size)), payload.count >= 8 else { return nil }

    let entryCount = Int(readBigUInt32(in: payload, at: 4))
    guard entryCount >= 0, entryCount <= (payload.count - 8) / 8 else { return nil }

    var offset = 8
    var keys: [String] = []
    keys.reserveCapacity(entryCount)
    for _ in 0..<entryCount {
      guard payload.count - offset >= 8 else { return nil }
      let entrySize = Int(readBigUInt32(in: payload, at: offset))
      guard entrySize >= 8, entrySize <= payload.count - offset else { return nil }
      let tag = String(bytes: payload[offset + 4..<offset + 8], encoding: .ascii)
      if tag == "mdta" {
        let keyString = String(bytes: payload[offset + 8..<offset + entrySize], encoding: .utf8) ?? ""
        keys.append(keyString)
      } else {
        keys.append("")
      }
      offset += entrySize
    }
    return keys
  }

  private nonisolated static func readQuickTimeItemValue(
    reader: RandomAccessReader,
    itemList: MP4Box,
    wantedIndex: UInt32
  ) -> String? {
    let items = readDirectBoxes(reader: reader, start: itemList.payloadStart, end: itemList.end)
    for item in items {
      guard item.type.count == 4 else { continue }
      let itemIndex = readBigUInt32(in: item.type, at: 0)
      guard itemIndex == wantedIndex else { continue }

      let values = readDirectBoxes(reader: reader, start: item.payloadStart, end: item.end)
      for value in values {
        guard value.typeString == "data", value.end - value.payloadStart >= 8 else { continue }
        let size = Int(value.end - value.payloadStart)
        guard size <= maxContentIdentifier + 8 else { continue }
        guard let payload = try? reader.read(at: value.payloadStart, count: size), payload.count >= 8 else { continue }
        return String(bytes: payload[8...], encoding: .utf8)
      }
    }
    return nil
  }

  private nonisolated static func readStillImageTimeTrack(reader: RandomAccessReader, sampleTable: MP4Box) -> Bool {
    let children = readDirectBoxes(reader: reader, start: sampleTable.payloadStart, end: sampleTable.end)
    var sampleDescription: MP4Box?
    var sampleSizes: MP4Box?
    var chunkOffsets: MP4Box?

    for child in children {
      switch child.typeString {
      case "stsd": sampleDescription = child
      case "stsz": sampleSizes = child
      case "stco", "co64": chunkOffsets = child
      default: break
      }
    }
    guard let sampleDescription, let sampleSizes, let chunkOffsets else { return false }

    guard sampleDescriptionContainsStillImageTime(reader: reader, box: sampleDescription) else { return false }
    guard let sampleSize = readFirstSampleSize(reader: reader, box: sampleSizes), sampleSize >= 9, sampleSize <= 1024 * 1024 else {
      return false
    }
    guard let sampleOffset = readFirstChunkOffset(reader: reader, box: chunkOffsets) else { return false }

    guard let sample = try? reader.read(at: sampleOffset, count: Int(sampleSize)), sample.count >= Int(sampleSize) else {
      return false
    }
    return sampleContainsStillImageTime(sample)
  }

  private nonisolated static func sampleDescriptionContainsStillImageTime(
    reader: RandomAccessReader,
    box: MP4Box
  ) -> Bool {
    let size = box.end - box.payloadStart
    guard size >= 8, size <= 4 * 1024 * 1024 else { return false }
    guard let payload = try? reader.read(at: box.payloadStart, count: Int(size)), payload.count >= 8 else { return false }

    let entryCount = Int(readBigUInt32(in: payload, at: 4))
    var offset = 8
    let needle = Array("com.apple.quicktime.still-image-time".utf8)

    for _ in 0..<entryCount {
      guard payload.count - offset >= 8 else { return false }
      let entrySize = Int(readBigUInt32(in: payload, at: offset))
      guard entrySize >= 8, entrySize <= payload.count - offset else { return false }
      let format = String(bytes: payload[offset + 4..<offset + 8], encoding: .ascii)
      if format == "mebx" {
        let entryPayload = payload.subdata(in: (offset + 8)..<(offset + entrySize))
        if findBytes(needle, in: entryPayload, startingAt: 0, limit: entryPayload.count) != nil {
          return true
        }
      }
      offset += entrySize
    }
    return false
  }

  private nonisolated static func readFirstSampleSize(reader: RandomAccessReader, box: MP4Box) -> UInt32? {
    let size = box.end - box.payloadStart
    guard size >= 12, size <= 1024 * 1024 else { return nil }
    guard let payload = try? reader.read(at: box.payloadStart, count: Int(size)), payload.count >= 12 else { return nil }

    let fixedSize = readBigUInt32(in: payload, at: 4)
    let sampleCount = readBigUInt32(in: payload, at: 8)
    guard sampleCount > 0 else { return nil }
    if fixedSize != 0 { return fixedSize }
    guard payload.count >= 16 else { return nil }
    return readBigUInt32(in: payload, at: 12)
  }

  private nonisolated static func readFirstChunkOffset(reader: RandomAccessReader, box: MP4Box) -> Int64? {
    let size = box.end - box.payloadStart
    guard size >= 12, size <= 1024 * 1024 else { return nil }
    guard let payload = try? reader.read(at: box.payloadStart, count: Int(size)), payload.count >= 12 else { return nil }
    let count = readBigUInt32(in: payload, at: 4)
    guard count > 0 else { return nil }

    if box.typeString == "co64" {
      guard payload.count >= 16 else { return nil }
      return Int64(exactly: readBigUInt64(in: payload, at: 8))
    }
    return Int64(readBigUInt32(in: payload, at: 8))
  }

  private nonisolated static func sampleContainsStillImageTime(_ sample: Data) -> Bool {
    var offset = 0
    while offset < sample.count {
      guard sample.count - offset >= 8 else { return false }
      let valueSize = Int(readBigUInt32(in: sample, at: offset))
      guard valueSize >= 9, valueSize <= sample.count - offset else { return false }
      let keyIndex = readBigUInt32(in: sample, at: offset + 4)
      if keyIndex == 1 && sample[offset + 8] == 0xFF {
        return true
      }
      offset += valueSize
    }
    return false
  }

  // MARK: - Helper Utilities

  public nonisolated static func isCanonicalUUID(_ value: String) -> Bool {
    guard value.count == 36 else { return false }
    let chars = Array(value)
    for (i, c) in chars.enumerated() {
      switch i {
      case 8, 13, 18, 23:
        if c != "-" { return false }
      default:
        if !c.isHexDigit { return false }
      }
    }
    return true
  }

  private nonisolated static func cleanIdentifier(_ raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
  }

  private nonisolated static func readUInt16(in data: Data, at offset: Int, bigEndian: Bool) -> UInt16 {
    let b0 = UInt16(data[offset])
    let b1 = UInt16(data[offset + 1])
    return bigEndian ? ((b0 << 8) | b1) : ((b1 << 8) | b0)
  }

  private nonisolated static func readUInt32(in data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let b3 = UInt32(data[offset + 3])
    return bigEndian
      ? ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
      : ((b3 << 24) | (b2 << 16) | (b1 << 8) | b0)
  }

  private nonisolated static func readBigUInt32(in data: Data, at offset: Int) -> UInt32 {
    readUInt32(in: data, at: offset, bigEndian: true)
  }

  private nonisolated static func readBigUInt32(in bytes: [UInt8], at offset: Int) -> UInt32 {
    let b0 = UInt32(bytes[offset])
    let b1 = UInt32(bytes[offset + 1])
    let b2 = UInt32(bytes[offset + 2])
    let b3 = UInt32(bytes[offset + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  }

  private nonisolated static func readBigUInt64(in data: Data, at offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for i in 0..<8 {
      result = (result << 8) | UInt64(data[offset + i])
    }
    return result
  }
}

private protocol RandomAccessReader {
  var size: Int64 { get }
  func read(at offset: Int64, count: Int) throws -> Data
}

private struct FileHandleReader: RandomAccessReader {
  let handle: FileHandle
  let size: Int64

  func read(at offset: Int64, count: Int) throws -> Data {
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: count) ?? Data()
  }
}

private struct DataReader: RandomAccessReader {
  let data: Data
  var size: Int64 { Int64(data.count) }

  func read(at offset: Int64, count: Int) throws -> Data {
    let start = Int(offset)
    let end = min(start + count, data.count)
    guard start >= 0, start <= data.count else { return Data() }
    return data.subdata(in: start..<end)
  }
}
