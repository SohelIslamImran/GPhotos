import Foundation
import Photos
import Testing

@testable import GPhotosKit

@Suite("Unified timeline matching")
struct TimelineMatchingTests {
  @Test("Local content hashes survive reopening, invalidate edits, and defer unavailable resources")
  func localHashCache() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LibraryIndexStore(directory: directory)
    let now = Date(timeIntervalSince1970: 100_000)
    let digest = Data(repeating: 5, count: 20)
    try await store.saveResourceHash(id: "asset", fingerprint: "original", digest: digest, now: now)
    let reopened = LibraryIndexStore(directory: directory)
    #expect(
      try await reopened.resourceHash(id: "asset", fingerprint: "original", now: now.addingTimeInterval(86400 * 365)).digest == digest)
    #expect(try await reopened.resourceHash(id: "asset", fingerprint: "edited", now: now).checked == false)
    try await store.saveResourceHash(id: "unavailable", fingerprint: "v1", digest: nil, now: now)
    #expect(try await reopened.resourceHash(id: "unavailable", fingerprint: "v1", now: now.addingTimeInterval(60)).checked)
    #expect(try await reopened.resourceHash(id: "unavailable", fingerprint: "v1", now: now.addingTimeInterval(86401)).checked == false)
  }

  @Test("Local byte identity fixes shifted capture times and collapses every cloud duplicate")
  func localHashWithShiftedTime() {
    let remote = [cloud("one", time: 700, hash: hash), cloud("two", time: 701, hash: hash)]
    let evidence: [String: Set<Data>] = ["device": [hash]]
    #expect(
      TimelineMerge.merge(device: [device()], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: evidence) == [.device(0, cloud: 0)])
    #expect(
      TimelineMerge.merge(device: [device()], cloud: remote, uploadedMediaKeys: [:], uploadedSHA1s: evidence, filter: .notBackedUp).isEmpty)
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud("different", time: 700, hash: Data(repeating: 1, count: 20))], uploadedMediaKeys: [:],
        uploadedSHA1s: evidence, filter: .notBackedUp) == [.device(0, cloud: nil)])
  }

  @Test("Cloud confirmations fill missing device backup badges without hiding unfinished uploads")
  func cloudConfirmsDeviceCollection() {
    let pending = TransferRecord(
      id: "queued", filename: "photo.jpg", mediaType: "Photo", status: .pending,
      assetLocalIdentifier: "unfinished")
    let states = PhotoLibraryGridModel.backupStates(from: [pending], confirmedCloudIDs: ["uploaded-by-phone", "unfinished"])
    #expect(states["uploaded-by-phone"] == .backedUp)
    #expect(states["unfinished"] == .pending)
    #expect(states["unknown"] == nil)
    let otherAccount = TransferRecord(
      id: "other@example.com|asset", filename: "photo.jpg", mediaType: "Photo", status: .sent,
      assetLocalIdentifier: "only-in-other-account")
    #expect(PhotoLibraryGridModel.backupStates(from: [otherAccount], accountEmail: "current@example.com").isEmpty)
  }

  @Test("Recorded uploads remain backed up while the cloud mirror has not loaded their items")
  func backupBeforeMirrorArrives() {
    let keys: [String: Set<String>] = ["device": ["not-synced-yet"]]
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: keys, filter: .notBackedUp).isEmpty)
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: keys, filter: .backedUp).count == 1)
    #expect(TimelineMerge.merge(device: [device()], cloud: [], uploadedMediaKeys: [:], filter: .notBackedUp).count == 1)
  }

  private let email = "me@example.com"
  private let hash = Data(repeating: 7, count: 20)

  private func device(_ id: String = "device", time: Double = 100, video: Bool = false) -> DeviceItemInfo {
    DeviceItemInfo(
      localIdentifier: id, date: Date(timeIntervalSince1970: time), width: 4032, height: 3024,
      isVideo: video, isFavorite: false)
  }

  private func cloud(
    _ id: String = "cloud", time: Double = 100, width: Int? = 4032, height: Int? = 3024,
    kind: RemoteMediaItem.Kind = .photo, hash: Data? = nil
  ) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: id, dedupKey: id, sha1: hash, kind: kind, takenAt: Date(timeIntervalSince1970: time),
      contentVersion: 0, durationMs: nil, isFavorite: false, trashedAt: nil, width: width, height: height)
  }

  private func record(_ key: String, role: AssetResourceRole = .primary) -> TransferRecord {
    TransferRecord(
      id: key, filename: "IMG_1.HEIC", mediaType: "Photo", status: .sent,
      mediaKeysByAccount: [email: key], sha1: hash.base64EncodedString(),
      assetLocalIdentifier: "device", resourceRole: role)
  }

  @Test("Subseconds crossing rounding or whole-second boundaries still pair", arguments: [100.6, 99.9])
  func fractionalCaptureTimes(time: Double) {
    #expect(
      TimelineMerge.merge(device: [device(time: time)], cloud: [cloud()], uploadedMediaKeys: [:])
        == [.device(0, cloud: 0)])
  }

  @Test("A nearby burst is ambiguous across second boundaries")
  func adjacentBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a", time: 100.1), device("b", time: 99.9)], cloud: [cloud()], uploadedMediaKeys: [:])
    #expect(entries.count == 3)
    #expect(entries.contains(.cloud(0)))
  }

  @Test("A recorded burst frame cannot make its neighbour falsely unique")
  func recordedBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud("a"), cloud("b")], uploadedMediaKeys: ["a": ["a"]])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: nil)))
    #expect(entries.contains(.cloud(1)))
  }

  @Test("Rotation, motion photos and videos use the existing normalized type and size")
  func normalizedMetadata() {
    for kind in [RemoteMediaItem.Kind.photo, .motionPhoto, .video] {
      #expect(
        TimelineMerge.merge(
          device: [device(video: kind == .video)], cloud: [cloud(width: 3024, height: 4032, kind: kind)],
          uploadedMediaKeys: [:]) == [.device(0, cloud: 0)])
    }
  }

  @Test("Missing dimensions and timezone differences need stronger evidence")
  func missingMetadata() {
    let remote = cloud(time: 100 + 8 * 3600, width: nil, height: nil, hash: hash)
    #expect(TimelineMerge.merge(device: [device()], cloud: [remote], uploadedMediaKeys: [:]).count == 2)
    let hashes = UnifiedLibraryModel.uploadEvidence([record("staleKey")], email: "").hashes
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [remote], uploadedMediaKeys: ["device": ["staleKey"]], uploadedSHA1s: hashes)
        == [.device(0, cloud: 0)])
  }

  @Test("Stored hashes resolve a same-second burst without reading resources")
  func hashesResolveBurst() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud("a", hash: hash), cloud("b")],
      uploadedMediaKeys: [:], uploadedSHA1s: ["a": [hash]])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: nil)))
    #expect(entries.contains(.cloud(1)))
  }

  @Test("Every primary key survives, regardless of record order; RAW and original stay separate")
  func allPrimaryKeys() {
    let records = [
      record("first"), record("second"), record("raw", role: .alternatePhoto),
      record("original", role: .uneditedOriginal),
    ]
    let keys = UnifiedLibraryModel.uploadEvidence(records, email: email).keys
    #expect(keys == ["device": ["first", "second"]])
    #expect(UnifiedLibraryModel.uploadEvidence(records.reversed(), email: email).keys == keys)
    #expect(UnifiedLibraryModel.uploadEvidence(records, email: "other@example.com").keys.isEmpty)
    #expect(UnifiedLibraryModel.uploadEvidence(Array(records.suffix(2)), email: "").hashes.isEmpty)
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud("second", width: nil), cloud("first", width: nil)],
        uploadedMediaKeys: keys) == [.device(0, cloud: 0)])
  }

  @Test("An already claimed cloud copy can still badge another recorded device copy")
  func sharedCloudKey() {
    let entries = TimelineMerge.merge(
      device: [device("a"), device("b")], cloud: [cloud()], uploadedMediaKeys: ["a": ["cloud"], "b": ["cloud"]])
    #expect(entries.count == 2)
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.device(1, cloud: 0)))
  }

  @Test("A folder claim does not prevent matching the device")
  func folderClaim() {
    let entries = TimelineMerge.merge(
      device: [device()], cloud: [cloud()], uploadedMediaKeys: [:],
      folder: [FolderItemInfo(path: "/a.heic", date: Date(timeIntervalSince1970: 100), size: 1, isVideo: false)],
      uploadedFileKeys: ["/a.heic": "cloud"])
    #expect(entries.contains(.device(0, cloud: 0)))
    #expect(entries.contains(.folder(0, cloud: 0)))
    #expect(!entries.contains(.cloud(0)))
  }

  @Test("Malformed hashes and nonprimary resources provide no matching evidence")
  func malformedHashes() {
    var invalid = record("invalid")
    invalid.sha1 = Data([1]).base64EncodedString()
    #expect(UnifiedLibraryModel.uploadEvidence([invalid], email: "").hashes.isEmpty)
  }

  @Test("Display matches cannot authorize cleanup or change the manifest")
  func displayDoesNotAuthorizeDeletion() async throws {
    let directory = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TransferManifestStore(fileURL: directory.appendingPathComponent("manifest.json"))
    var pending = record("pending")
    pending.status = .pending
    pending.sentAt = .distantPast
    pending.sentAccountEmails = []
    pending.mediaKeysByAccount = [:]
    #expect(await store.upsert(pending))
    #expect(
      TimelineMerge.merge(device: [device()], cloud: [cloud()], uploadedMediaKeys: [:])
        == [.device(0, cloud: 0)])
    #expect(
      TimelineMerge.merge(
        device: [device()], cloud: [cloud(width: nil, hash: hash)], uploadedMediaKeys: [:],
        uploadedSHA1s: UnifiedLibraryModel.uploadEvidence([pending], email: "").hashes) == [.device(0, cloud: 0)])
    #expect(await store.eligibleForDeletion(delay: .immediately, smartDelete: false, accountEmail: email).isEmpty)
    #expect(await store.record(for: pending.id) == pending)
  }

  @Test("100,000 pairs merge with bounded metadata work")
  func largeLibrary() {
    let devices = (0..<100_000).reversed().map { device("d\($0)", time: Double($0) * 3 + 0.7) }
    let clouds = (0..<100_000).reversed().map { cloud("c\($0)", time: Double($0) * 3) }
    let clock = ContinuousClock()
    let start = clock.now
    let entries = TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:])
    print("Timeline merge: 100,000 device + 100,000 cloud items in \(start.duration(to: clock.now))")
    #expect(entries.count == 100_000)
    #expect(entries.first == .device(99_999, cloud: 99_999))
    #expect(entries.last == .device(0, cloud: 0))
  }

  @Test("Backed-up grid cells draw their cloud icon")
  @MainActor func backedUpIcon() {
    let cell = PhotoGridCellLayer()
    cell.apply(badges: PhotoGridBadges(backup: .backedUp), scale: 2)
    #expect(cell.sublayers?.contains { $0.contents != nil && !$0.isHidden } == true)
    cell.apply(badges: PhotoGridBadges(), scale: 2)
    #expect(cell.sublayers?.contains { $0.contents != nil && !$0.isHidden } == false)
  }
}
