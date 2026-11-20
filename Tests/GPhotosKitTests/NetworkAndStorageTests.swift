import Foundation
import Testing

@testable import GPhotosKit

@Suite("Network and storage hardening")
struct NetworkAndStorageTests {
  // MARK: - Protobuf

  @Test("A length larger than Int.max throws instead of trapping")
  func testHugeLengthThrows() {
    // Field 2, length-delimited, length = UInt64.max.
    var bytes: [UInt8] = [0x12]
    bytes += [UInt8](repeating: 0xFF, count: 9) + [0x01]
    var reader = ProtobufReader(data: Data(bytes))
    #expect(throws: GPhotosError.self) {
      _ = try reader.readTag()
      _ = try reader.readBytes()
    }
  }

  @Test("A length past the end of the buffer throws")
  func testLengthPastEndThrows() {
    var reader = ProtobufReader(data: Data([0x12, 0x05, 0x01, 0x02]))
    #expect(throws: GPhotosError.self) {
      _ = try reader.readTag()
      _ = try reader.readBytes()
    }
  }

  @Test(
    "Truncated fixed32 and fixed64 fields throw when skipped",
    arguments: [
      [UInt8]([0x0D, 0x01, 0x02]),
      [UInt8]([0x09, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
    ])
  func testTruncatedFixedSkipThrows(bytes: [UInt8]) {
    var reader = ProtobufReader(data: Data(bytes))
    #expect(throws: GPhotosError.self) {
      let (_, wireType) = try reader.readTag()
      try reader.skipField(wireType: wireType)
    }
  }

  @Test("Complete fixed fields skip cleanly")
  func testCompleteFixedSkip() throws {
    var reader = ProtobufReader(data: Data([0x0D, 1, 2, 3, 4, 0x09, 1, 2, 3, 4, 5, 6, 7, 8]))
    while !reader.isAtEnd {
      let (_, wireType) = try reader.readTag()
      try reader.skipField(wireType: wireType)
    }
    #expect(reader.isAtEnd)
  }

  @Test("Skipping a length-delimited field lands on the next field, from a slice too")
  func testLengthDelimitedSkip() throws {
    // Field 2 (3 bytes) skipped, then field 1 varint 7; prefixed so the slice's indices
    // don't start at zero.
    let bytes = Data([0xAA, 0xBB, 0x12, 0x03, 1, 2, 3, 0x08, 0x07])
    var reader = ProtobufReader(data: bytes[2...])
    let (_, wireType) = try reader.readTag()
    try reader.skipField(wireType: wireType)
    let (field, _) = try reader.readTag()
    #expect(field == 1)
    #expect(try reader.readVarint() == 7)
    #expect(reader.isAtEnd)
  }

  @Test(
    "Skipping a length-delimited field past the end, or of absurd length, throws",
    arguments: [
      [UInt8]([0x12, 0x05, 0x01, 0x02]),
      [UInt8]([0x12] + [UInt8](repeating: 0xFF, count: 9) + [0x01]),
    ])
  func testLengthDelimitedSkipPastEndThrows(bytes: [UInt8]) {
    var reader = ProtobufReader(data: Data(bytes))
    #expect(throws: GPhotosError.self) {
      let (_, wireType) = try reader.readTag()
      try reader.skipField(wireType: wireType)
    }
  }

  @Test("Records are looked up by ID, leaving out IDs with none")
  func testRecordsWithIDs() async throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent("manifest-\(UUID().uuidString).json")
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let record = TransferRecord(id: "me@example.com|a", filename: "a.jpg", mediaType: "Photo", status: .pending)
    _ = await store.upsert(record)
    let found = await store.records(withIDs: ["me@example.com|a", "me@example.com|missing"])
    #expect(found == ["me@example.com|a": record])
  }

  @Test("Reading a sliced Data honors its start index")
  func testReaderOnSlice() throws {
    var writer = ProtobufWriter()
    writer.writeString(fieldNumber: 1, "hello")
    let padded = Data([0xAA, 0xBB]) + writer.data
    var reader = ProtobufReader(data: padded.dropFirst(2))
    _ = try reader.readTag()
    #expect(try reader.readString() == "hello")
  }

  @Test("Malicious finalize tokens are rejected")
  func testMaliciousFinalizeToken() {
    let bytes: [UInt8] = [0x08, 0x02, 0x12] + [UInt8](repeating: 0xFF, count: 9) + [0x01]
    #expect(throws: GPhotosError.self) {
      try ScottyFinalizeToken.parse(Data(bytes))
    }
  }

  // MARK: - Timestamps

  @Test("Timestamps floor seconds so nanos stay non-negative before 1970")
  func testTimestampComponents() {
    let before = GooglePhotosMessages.timestampComponents(Date(timeIntervalSince1970: -1.25))
    #expect(before.seconds == -2)
    #expect(before.nanos == 750_000_000)
    let after = GooglePhotosMessages.timestampComponents(Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(after.seconds == 1_700_000_000)
    #expect(after.nanos == 500_000_000)
  }

  // MARK: - Form encoding

  @Test("Form encoding escapes everything outside the unreserved set")
  func testFormEncoding() {
    let encoded = FormURLEncoding.encode([("Token", "aas_et/ab+c=d&e f~-.")])
    #expect(encoded == "Token=aas_et%2Fab%2Bc%3Dd%26e%20f~-.")
  }

  @Test("Form decoding reads + as a space and round-trips encoded values")
  func testFormDecoding() {
    let fields = FormURLEncoding.decode("a=x+y&b=x%2By&c=&d")
    #expect(fields.map(\.name) == ["a", "b", "c", "d"])
    #expect(fields.map(\.value) == ["x y", "x+y", "", ""])

    let original: [(name: String, value: String)] = [("Token", "a+b/c=="), ("service", "oauth2:openid https://x")]
    let decoded = FormURLEncoding.decode(FormURLEncoding.encode(original))
    #expect(decoded.map(\.value) == original.map(\.value))
  }

  @Test("A master token containing + survives building and sanitizing the credential")
  func testCredentialPreservesPlus() throws {
    let credential = GoogleAuthService.buildGooglePhotosCredential(
      email: "user@example.com", masterToken: "aas_et/A+B==", androidId: "0123456789abcdef")
    #expect(credential.contains("Token=aas_et%2FA%2BB%3D%3D"))
    let sanitized = try GoogleAuthService.sanitizedCredentialQuery(from: credential)
    let token = FormURLEncoding.decode(sanitized).first { $0.name == "Token" }?.value
    #expect(token == "aas_et/A+B==")
  }

  @Test(
    "Profile photo URLs get the requested size",
    arguments: [
      ("https://lh3.googleusercontent.com/a/ACg8ocK=s96-c", "https://lh3.googleusercontent.com/a/ACg8ocK=s192-c"),
      ("https://lh3.googleusercontent.com/a/ACg8ocK=s96", "https://lh3.googleusercontent.com/a/ACg8ocK=s192-c"),
      ("https://lh3.googleusercontent.com/a/ACg8ocK", "https://lh3.googleusercontent.com/a/ACg8ocK=s192-c"),
    ])
  func sizedProfilePhotoURL(original: String, expected: String) {
    let sized = GoogleAuthService.sizedPhotoURL(URL(string: original)!, pixelSize: 192)
    #expect(sized.absoluteString == expected)
  }

  @Test("Android IDs are 16 hex characters")
  func testGenerateAndroidId() throws {
    let id = try GoogleAuthService.generateAndroidId()
    #expect(id.count == 16)
    #expect(id.allSatisfy { $0.isHexDigit })
  }

  // MARK: - Scotty

  private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: headers)!
  }

  @Test("A 308 without Range means nothing was received")
  func testPersistedOffsetWithoutRange() {
    #expect(GooglePhotosMobileClient.persistedOffset(from: response(308), totalSize: 100) == 0)
  }

  @Test("A 308 Range is trusted even when it moves backwards, and clamped to the file size")
  func testPersistedOffsetFromRange() {
    #expect(GooglePhotosMobileClient.persistedOffset(from: response(308, headers: ["Range": "bytes=0-49"]), totalSize: 100) == 50)
    #expect(GooglePhotosMobileClient.persistedOffset(from: response(308, headers: ["range": "0-9"]), totalSize: 100) == 10)
    #expect(GooglePhotosMobileClient.persistedOffset(from: response(308, headers: ["Range": "bytes=0-999"]), totalSize: 100) == 100)
    #expect(GooglePhotosMobileClient.persistedOffset(from: response(308, headers: ["Range": "garbage"]), totalSize: 100) == 0)
  }

  @Test("Only non-retryable client errors stop an upload")
  func testPermanentUploadFailure() {
    #expect(GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.httpError(status: 404, body: "")))
    #expect(GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.authFailed(status: 401, body: "")))
    #expect(!GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.httpError(status: 401, body: "")))
    #expect(!GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.httpError(status: 429, body: "")))
    #expect(!GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.httpError(status: 503, body: "")))
    #expect(!GooglePhotosMobileClient.isPermanentUploadFailure(URLError(.timedOut)))
  }

  // MARK: - Errors

  @Test("A missing keychain entitlement has a user-presentable message")
  func testKeychainEntitlementMessage() {
    let error = GPhotosError.keychain(operation: "read", status: errSecMissingEntitlement)
    #expect(error.errorDescription == "This build can't access the keychain. Reinstall a signed build.")
    #expect(
      GPhotosError.keychain(operation: "read", status: errSecInteractionNotAllowed).errorDescription?.hasPrefix("Keychain read failed")
        == true)
  }

  // MARK: - Manifest

  private func manifestURL() -> URL {
    TestTemporaryDirectory.root.appendingPathComponent("NetworkAndStorageTests-\(UUID().uuidString).json")
  }

  /// What a fresh launch would read back: the snapshot with its journal replayed.
  private func storedIDs(at url: URL) async -> Set<String> {
    Set(await TransferManifestStore(fileURL: url).allRecords().map(\.id))
  }

  private func removeManifest(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: url.appendingPathExtension("journal"))
  }

  @Test("One undecodable record does not discard the rest of the manifest")
  func testManifestLoadsRecordsAroundABadOne() async throws {
    let url = manifestURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let good = TransferRecord(id: "good", filename: "a.jpg", mediaType: "Photo", status: .pending)
    let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
    try Data("[\(goodJSON), {\"id\": 42}]".utf8).write(to: url)

    let records = await TransferManifestStore(fileURL: url).allRecords()
    #expect(records.map(\.id) == ["good"])
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
  }

  @Test("An unreadable manifest is quarantined rather than overwritten")
  func testManifestQuarantinesUnreadableFile() async throws {
    let url = manifestURL()
    let backup = url.appendingPathExtension("unreadable")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: backup)
    }
    try Data("not json".utf8).write(to: url)

    let records = await TransferManifestStore(fileURL: url).allRecords()
    #expect(records.isEmpty)
    #expect(FileManager.default.fileExists(atPath: backup.path))
  }

  @Test("Routine writes are coalesced; sent and deleted writes persist at once")
  func testManifestWriteCoalescingPersistsTerminalStates() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)

    #expect(await store.upsert(TransferRecord(id: "a", filename: "a.jpg", mediaType: "Photo", status: .pending)))
    #expect(await store.flush())
    #expect(await storedIDs(at: url) == ["a"])

    #expect(await store.upsert(TransferRecord(id: "b", filename: "b.jpg", mediaType: "Photo", status: .pending)))
    #expect(await storedIDs(at: url) == ["a"])
    #expect(await store.updateStatus(id: "a", status: .sent, mediaKey: "key", accountEmail: "a@example.com"))
    #expect(TransferManifestStore.storedRecords(fileURL: url)["a"]?.status == .sent)
    #expect(await store.updateStatus(id: "b", status: .deleted))
    #expect(TransferManifestStore.storedRecords(fileURL: url)["b"]?.status == .deleted)
    #expect(await store.remove(id: "b"))
    #expect(await storedIDs(at: url) == ["a"])
  }

  @Test("Small changes to a large manifest are journaled and read back after a relaunch")
  func testJournaledChangesSurviveRelaunch() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let initial = (0..<20).map { TransferRecord(id: "r\($0)", filename: "\($0).jpg", mediaType: "Photo", status: .pending) }
    #expect(await store.upsertBatch(initial))
    #expect(await store.flush())
    let snapshot = try Data(contentsOf: url)

    #expect(await store.updateStatus(id: "r1", status: .sent, mediaKey: "key", accountEmail: "a@example.com"))
    #expect(await store.remove(id: "r2"))
    #expect(await store.flush())
    // Appended, not rewritten.
    #expect(try Data(contentsOf: url) == snapshot)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("journal").path))

    let reloaded = TransferManifestStore(fileURL: url)
    #expect(await reloaded.record(for: "r1")?.status == .sent)
    #expect(await reloaded.record(for: "r1")?.mediaKeysByAccount["a@example.com"] == "key")
    #expect(await reloaded.record(for: "r2") == nil)
    #expect(await reloaded.allRecords().count == 19)
  }

  @Test("Thousands of saved uploads and cloud matches cannot be claimed again after relaunch")
  func completedUploadsSurviveRelaunch() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let email = "a@example.com"
    let records = (0..<4_000).map { index in
      TransferRecord(
        id: TransferRecord.accountScopedID("asset-\(index)", accountEmail: email),
        filename: "photo-\(index).heic", mediaType: "Photo", creationDate: nil, status: .pending,
        assetLocalIdentifier: "asset-\(index)", assetModifiedAt: Date(timeIntervalSince1970: 1_000), resourcesChecked: true)
    }
    #expect(await store.upsertBatch(records))
    #expect(await store.flush())
    for (index, record) in records.enumerated() {
      #expect(
        await store.updateStatus(
          id: record.id, status: .sent, mediaKey: record.id, accountEmail: email,
          foundInAccount: index.isMultiple(of: 2)))
    }
    #expect(await store.flush())
    let reloaded = TransferManifestStore(fileURL: url)
    let restored = await reloaded.allRecords()
    #expect(restored.count == records.count)
    #expect(restored.allSatisfy { $0.isTerminalSuccess && $0.resourcesChecked })
    #expect(await reloaded.claimForUpload(ids: records.map(\.id)).isEmpty)
  }

  @Test("A stale scan cannot overwrite an upload completed while it was describing assets")
  func scanPreservesConcurrentCompletion() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let pending = TransferRecord(
      id: "a@example.com|asset", filename: "photo.heic", mediaType: "Photo", creationDate: nil, status: .pending,
      assetLocalIdentifier: "asset", assetModifiedAt: Date(timeIntervalSince1970: 1_000))
    let emptySnapshot: [String: TransferRecord] = [:]
    #expect(await store.upsert(pending))
    #expect(await store.updateStatus(id: pending.id, status: .sent, mediaKey: "key", accountEmail: "a@example.com"))
    #expect(await store.upsertBatch([pending], ifUnchangedSince: emptySnapshot))
    #expect(await store.record(for: pending.id)?.status == .sent)
    #expect(await store.claimForUpload(ids: [pending.id]).isEmpty)

    let completed = try #require(await store.record(for: pending.id))
    var edited = completed
    edited.status = .pending
    edited.assetModifiedAt = Date(timeIntervalSince1970: 2_000)
    #expect(await store.upsertBatch([edited], ifUnchangedSince: [completed.id: completed]))
    #expect(await store.claimForUpload(ids: [pending.id]) == [pending.id])
  }

  @Test("A journal written for an earlier snapshot is never replayed")
  func testStaleJournalIsIgnored() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let initial = (0..<20).map { TransferRecord(id: "r\($0)", filename: "\($0).jpg", mediaType: "Photo", status: .pending) }
    #expect(await store.upsertBatch(initial))
    #expect(await store.flush())
    #expect(await store.updateStatus(id: "r1", status: .failed, error: "old"))
    #expect(await store.flush())
    let journalURL = url.appendingPathExtension("journal")
    let staleJournal = try Data(contentsOf: journalURL)

    // A later snapshot holds a newer state of r1; the old journal must not undo it.
    #expect(await store.updateStatus(id: "r1", status: .pending))
    #expect(await store.clearAll())
    #expect(await store.upsertBatch(initial))
    #expect(await store.flush())
    try staleJournal.write(to: journalURL)

    let reloaded = TransferManifestStore(fileURL: url)
    #expect(await reloaded.record(for: "r1")?.status == .pending)
    #expect(await reloaded.record(for: "r1")?.lastError == nil)
  }

  @Test("A journal cut off mid-line keeps its complete entries and is not appended to")
  func testTornJournalIsCompacted() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let initial = (0..<20).map { TransferRecord(id: "r\($0)", filename: "\($0).jpg", mediaType: "Photo", status: .pending) }
    #expect(await store.upsertBatch(initial))
    #expect(await store.flush())
    #expect(await store.updateStatus(id: "r1", status: .failed, error: "kept"))
    #expect(await store.flush())
    let journalURL = url.appendingPathExtension("journal")
    let handle = try FileHandle(forWritingTo: journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"record\":{\"id\":".utf8))
    try handle.close()

    let reloaded = TransferManifestStore(fileURL: url)
    #expect(await reloaded.record(for: "r1")?.lastError == "kept")
    #expect(await reloaded.updateStatus(id: "r3", status: .failed, error: "later"))
    #expect(await reloaded.flush())
    let again = TransferManifestStore(fileURL: url)
    #expect(await again.record(for: "r1")?.lastError == "kept")
    #expect(await again.record(for: "r3")?.lastError == "later")
  }

  @Test("A snapshot write cut short is removed at launch; other files are left alone")
  func testAbandonedSnapshotIsRemoved() async throws {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let directory = url.deletingLastPathComponent()
    let abandoned = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let unrelated = directory.appendingPathComponent(".other-\(UUID().uuidString).tmp")
    try Data("partial".utf8).write(to: abandoned)
    try Data("keep".utf8).write(to: unrelated)
    defer { try? FileManager.default.removeItem(at: unrelated) }

    await TransferManifestStore(fileURL: url).load()
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test("Records come back newest first, with ties in a stable order")
  func testSortedRecordsOrderIsStable() async {
    let url = manifestURL()
    defer { removeManifest(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let date = Date()
    #expect(
      await store.upsertBatch([
        TransferRecord(id: "b", filename: "b.jpg", mediaType: "Photo", creationDate: date, status: .pending),
        TransferRecord(id: "old", filename: "o.jpg", mediaType: "Photo", creationDate: date.addingTimeInterval(-60), status: .pending),
        TransferRecord(id: "a", filename: "a.jpg", mediaType: "Photo", creationDate: date, status: .pending),
        TransferRecord(id: "none", filename: "n.jpg", mediaType: "Photo", status: .pending),
      ]))
    #expect(await store.sortedRecords().map(\.id) == ["a", "b", "old", "none"])
    let first = await store.sortedRecords(ifChangedSince: nil)
    #expect(first != nil)
    #expect(await store.sortedRecords(ifChangedSince: first?.revision) == nil)
    #expect(await store.updateStatus(id: "a", status: .failed))
    #expect(await store.sortedRecords(ifChangedSince: first?.revision) != nil)
  }

  @Test("An upsert that loses to an in-flight upload reports failure")
  func testUpsertDroppedWhileSending() async {
    let url = manifestURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let record = TransferRecord(id: "s", filename: "s.jpg", mediaType: "Photo", status: .pending)
    #expect(await store.upsert(record))
    #expect(await store.claimForUpload(id: "s"))
    #expect(await store.upsert(record) == false)
    #expect(await store.record(for: "s")?.status == .sending)
  }

  @Test("A write that fails is reported and kept pending")
  func testFailedWriteIsReported() async throws {
    let directory = TestTemporaryDirectory.root.appendingPathComponent("NetworkAndStorageTests-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("manifest.json")
    let store = TransferManifestStore(fileURL: url)
    #expect(await store.remove(id: "missing") == false)
    #expect(await store.flush() == false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await store.flush())
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("A sent folder file takes its upload hash as its source hash; other records do not")
  func testSentFolderRecordGetsSourceSHA1() async {
    let url = manifestURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TransferManifestStore(fileURL: url)
    let folder = TransferRecord(
      id: "folder", filename: "a.jpg", mediaType: "Photo", status: .sending, sourcePath: "/Folder/a.jpg")
    let pair = TransferRecord(
      id: "pair", filename: "b.heic", mediaType: "Live Photo", status: .sending, sourcePath: "/Folder/b.heic",
      pairedSourcePath: "/Folder/b.mov")
    let library = TransferRecord(
      id: "library", filename: "c.jpg", mediaType: "Photo", status: .sending, assetLocalIdentifier: "asset-c")
    let staged = TransferRecord(
      id: "staged", filename: "d.jpg", mediaType: "Photo", status: .sending, sourcePath: "/Staged/d.jpg", sourceSHA1: "staged-hash")
    let failing = TransferRecord(
      id: "failing", filename: "e.jpg", mediaType: "Photo", status: .sending, sourcePath: "/Folder/e.jpg")
    #expect(await store.upsertBatch([folder, pair, library, staged, failing]))

    #expect(await store.updateStatus(id: "folder", status: .sent, sha1: "folder-hash", accountEmail: "a@example.com"))
    #expect(
      await store.updateStatus(
        id: "pair", status: .sent, sha1: "photo-hash", pairedSHA1: "video-hash", accountEmail: "a@example.com"))
    #expect(await store.updateStatus(id: "library", status: .sent, sha1: "library-hash", accountEmail: "a@example.com"))
    #expect(await store.updateStatus(id: "staged", status: .sent, sha1: "other-hash", accountEmail: "a@example.com"))
    #expect(await store.updateStatus(id: "failing", status: .failed, sha1: "failing-hash", accountEmail: "a@example.com"))

    #expect(await store.record(for: "folder")?.sourceSHA1 == "folder-hash")
    #expect(await store.record(for: "pair")?.sourceSHA1 == "photo-hash")
    #expect(await store.record(for: "pair")?.pairedSourceSHA1 == "video-hash")
    #expect(await store.record(for: "library")?.sourceSHA1 == nil)
    #expect(await store.record(for: "library")?.sha1 == "library-hash")
    #expect(await store.record(for: "staged")?.sourceSHA1 == "staged-hash")
    #expect(await store.record(for: "failing")?.sourceSHA1 == nil)
  }
}
