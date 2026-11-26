import Foundation
import Testing

@testable import GPhotosKit

@Suite("Live Photo Metadata and Pairing Tests")
struct LivePhotoMetadataTests {

  @Test("Byte scanner parses Apple MakerNote tag 17 content identifier")
  func testByteScanner() throws {
    let testUUID = "E5B4B27C-8E6E-4F35-8F37-5867D9C7EB9F"
    let buffer = craftAppleMakerNoteBuffer(uuid: testUUID)
    let extracted = LivePhotoMetadata.readPhotoContentIdentifier(data: buffer)
    #expect(extracted == testUUID)
  }

  @Test("QuickTime MP4 box walker extracts content identifier")
  func testQuickTimeMetadata() throws {
    let testUUID = "B6A68FE4-213E-41F6-B2FA-0129B7F1296A"
    let buffer = craftQuickTimeData(contentID: testUUID)
    let meta = LivePhotoMetadata.readVideoLivePhotoMetadata(data: buffer)
    #expect(meta?.contentIdentifier == testUUID)
  }

  @Test("Pairing matches by content identifier even when filenames differ")
  func testPairingByAppleIdentifierRenamed() throws {
    let tempDir = TestTemporaryDirectory.root
      .appendingPathComponent("LivePhotoTest-renamed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sharedUUID = "C4A27B08-3B5D-4EA6-86F0-A2268D721E01"
    let photoURL = tempDir.appendingPathComponent("renamed_vacation_photo.jpg")
    let videoURL = tempDir.appendingPathComponent("completely_different_movie.mov")

    try craftAppleMakerNoteBuffer(uuid: sharedUUID).write(to: photoURL)
    try craftQuickTimeData(contentID: sharedUUID).write(to: videoURL)

    let (pairs, singles) = LivePhotoManager.findLivePhotoPairs(in: [photoURL, videoURL])
    #expect(pairs.count == 1)
    #expect(singles.isEmpty)
    #expect(pairs.first?.photoFilename == "renamed_vacation_photo.jpg")
    #expect(pairs.first?.videoFilename == "completely_different_movie.mov")
    let pair = try #require(pairs.first)
    let files = [
      LocalMediaFile(url: photoURL, size: pair.photoSize, created: pair.creationDate, modified: pair.modificationDate),
      LocalMediaFile(url: videoURL, size: pair.videoSize, created: pair.creationDate, modified: pair.videoModificationDate),
    ]
    let paired = FolderLibrary.items(from: files, pairLivePhotos: true)
    #expect(paired.map(\.fileName) == [pair.photoFilename])
    #expect(paired.first?.motion?.path == pair.videoURL.standardizedFileURL.path)
    let separate = FolderLibrary.items(from: files, pairLivePhotos: false)
    #expect(Set(separate.map(\.fileName)) == [pair.photoFilename, pair.videoFilename])
    #expect(separate.allSatisfy { !$0.isLivePhoto })
  }

  @Test("Pairing is blocked when filename stems match but identifiers mismatch")
  func testPairingBlockedByIdentifierMismatch() throws {
    let tempDir = TestTemporaryDirectory.root
      .appendingPathComponent("LivePhotoTest-mismatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let uuid1 = "11111111-1111-1111-1111-111111111111"
    let uuid2 = "22222222-2222-2222-2222-222222222222"
    let photoURL = tempDir.appendingPathComponent("IMG_5000.jpg")
    let videoURL = tempDir.appendingPathComponent("IMG_5000.mov")

    try craftAppleMakerNoteBuffer(uuid: uuid1).write(to: photoURL)
    try craftQuickTimeData(contentID: uuid2).write(to: videoURL)

    let (pairs, singles) = LivePhotoManager.findLivePhotoPairs(in: [photoURL, videoURL])
    #expect(pairs.isEmpty)
    #expect(singles.count == 2)
  }

  @Test("Pairing falls back to stem match when identifier is missing")
  func testPairingFallsBackToStem() throws {
    let tempDir = TestTemporaryDirectory.root
      .appendingPathComponent("LivePhotoTest-stem-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let photoURL = tempDir.appendingPathComponent("IMG_1234.jpg")
    let videoURL = tempDir.appendingPathComponent("IMG_1234.mov")

    // Empty or non-identifying files
    try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: photoURL)
    try Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]).write(to: videoURL)

    let (pairs, singles) = LivePhotoManager.findLivePhotoPairs(in: [photoURL, videoURL])
    #expect(pairs.count == 1)
    #expect(singles.isEmpty)
    #expect(pairs.first?.photoFilename == "IMG_1234.jpg")
    #expect(pairs.first?.videoFilename == "IMG_1234.mov")
  }

  @Test("Malformed co64 chunk offsets with bit 63 set are ignored instead of trapping")
  func testMalformedCo64ChunkOffset() {
    let valid = craftStillImageTimeVideo(co64Offset: 8)
    #expect(LivePhotoMetadata.readVideoLivePhotoMetadata(data: valid)?.hasStillImageTime == true)

    let bit63Set = craftStillImageTimeVideo(co64Offset: 0x8000_0000_0000_0000)
    #expect(LivePhotoMetadata.readVideoLivePhotoMetadata(data: bit63Set) == nil)

    let maxUInt64 = craftStillImageTimeVideo(co64Offset: .max)
    #expect(LivePhotoMetadata.readVideoLivePhotoMetadata(data: maxUInt64) == nil)
  }

  @Test("LivePhotoManager sanitizes exported resource filenames")
  func testLivePhotoExportFilenameSanitization() {
    #expect(
      LivePhotoManager.filename(original: "../../dir/IMG:0001.HEIC", rendition: "FullSizeRender.jpg", fallback: "photo.heic")
        == "IMG_0001.JPG")
    #expect(
      LivePhotoManager.filename(original: "dir/..", rendition: "FullSizeRender.heic", fallback: "photo.heic")
        == "FullSizeRender.heic")
    #expect(LivePhotoManager.filename(original: "..", rendition: ".", fallback: "photo.heic") == "photo.heic")
    #expect(LivePhotoManager.filename(original: nil, rendition: "../clip:1.mov", fallback: "video.mov") == "clip_1.mov")
  }

  // MARK: - Fixture Helpers

  private func craftStillImageTimeVideo(co64Offset: UInt64) -> Data {
    // 9-byte sample at byte offset 8 inside the leading free box: size=9, keyIndex=1, still-image flag=0xFF.
    let sample = Data([0, 0, 0, 9, 0, 0, 0, 1, 0xFF])
    let freeBox = makeBox("free", payload: sample)

    let mebxEntry = makeBox("mebx", payload: Data("com.apple.quicktime.still-image-time".utf8))
    var stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
    stsdPayload.append(mebxEntry)
    let stsdBox = makeBox("stsd", payload: stsdPayload)

    let stszPayload = Data([0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1])
    let stszBox = makeBox("stsz", payload: stszPayload)

    var co64Payload = Data([0, 0, 0, 0, 0, 0, 0, 1])
    for shift in stride(from: 56, through: 0, by: -8) {
      co64Payload.append(UInt8((co64Offset >> shift) & 0xFF))
    }
    let co64Box = makeBox("co64", payload: co64Payload)

    var stblPayload = Data()
    stblPayload.append(stsdBox)
    stblPayload.append(stszBox)
    stblPayload.append(co64Box)
    let stblBox = makeBox("stbl", payload: stblPayload)
    let moovBox = makeBox("moov", payload: makeBox("trak", payload: makeBox("mdia", payload: makeBox("minf", payload: stblBox))))

    var full = Data()
    full.append(freeBox)
    full.append(moovBox)
    return full
  }

  private func craftAppleMakerNoteBuffer(uuid: String) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xE1])
    let marker = Array(LivePhotoMetadata.appleMakerNoteHeader.utf8)
    data.append(contentsOf: marker)
    data.append(contentsOf: [0x00, 0x00])  // padding

    // Big endian TIFF: "MM", entryCount = 1
    data.append(contentsOf: [0x4D, 0x4D])
    data.append(contentsOf: [0x00, 0x01])

    // Entry 1: tag 17, type 2, length, offset
    data.append(contentsOf: [0x00, 0x11])  // Tag 17
    data.append(contentsOf: [0x00, 0x02])  // Type 2 (ASCII)
    let uuidData = uuid.data(using: .utf8)!
    let len = UInt32(uuidData.count + 1)
    data.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])

    // Offset relative to marker start: 16 (header) + 12 (1 entry) = 28
    let valOffset: UInt32 = 28
    data.append(contentsOf: [
      UInt8(valOffset >> 24), UInt8((valOffset >> 16) & 0xFF), UInt8((valOffset >> 8) & 0xFF), UInt8(valOffset & 0xFF),
    ])
    data.append(uuidData)
    data.append(0x00)  // null terminator
    return data
  }

  private func craftQuickTimeData(contentID: String) -> Data {
    let keyName = "com.apple.quicktime.content.identifier"
    let entrySize = 8 + keyName.utf8.count
    var keysPayload = Data()
    keysPayload.append(contentsOf: [0, 0, 0, 0])
    keysPayload.append(contentsOf: [0, 0, 0, 1])
    keysPayload.append(contentsOf: [
      UInt8(entrySize >> 24), UInt8((entrySize >> 16) & 0xFF), UInt8((entrySize >> 8) & 0xFF), UInt8(entrySize & 0xFF),
    ])
    keysPayload.append(contentsOf: Array("mdta".utf8))
    keysPayload.append(contentsOf: Array(keyName.utf8))
    let keysBox = makeBox("keys", payload: keysPayload)

    let idData = contentID.data(using: .utf8)!
    var dataPayload = Data()
    dataPayload.append(contentsOf: [0, 0, 0, 1])
    dataPayload.append(contentsOf: [0, 0, 0, 0])
    dataPayload.append(idData)
    let dataBox = makeBox("data", payload: dataPayload)

    let itemBox = makeBoxWithNumber(1, payload: dataBox)
    let ilstBox = makeBox("ilst", payload: itemBox)

    var metaPayload = Data()
    metaPayload.append(keysBox)
    metaPayload.append(ilstBox)
    let metaBox = makeBox("meta", payload: metaPayload)

    let moovBox = makeBox("moov", payload: metaBox)

    var ftypPayload = Data()
    ftypPayload.append(contentsOf: Array("qt  ".utf8))
    ftypPayload.append(contentsOf: [0, 0, 0, 0])
    let ftypBox = makeBox("ftyp", payload: ftypPayload)

    var full = Data()
    full.append(ftypBox)
    full.append(moovBox)
    return full
  }

  private func makeBox(_ type: String, payload: Data) -> Data {
    let size = UInt32(8 + payload.count)
    var box = Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
    box.append(contentsOf: Array(type.utf8))
    box.append(payload)
    return box
  }

  private func makeBoxWithNumber(_ number: UInt32, payload: Data) -> Data {
    let size = UInt32(8 + payload.count)
    var box = Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
    box.append(contentsOf: [UInt8(number >> 24), UInt8((number >> 16) & 0xFF), UInt8((number >> 8) & 0xFF), UInt8(number & 0xFF)])
    box.append(payload)
    return box
  }
}
