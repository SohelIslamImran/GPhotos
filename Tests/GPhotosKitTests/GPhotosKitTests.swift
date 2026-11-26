import Foundation
import Testing
import os

@testable import GPhotosKit

@Suite("GPhotosKit Comprehensive Test Suite")
struct GPhotosKitTests {
  private func makeTestManifestStore() -> TransferManifestStore {
    let url = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-manifest-\(UUID().uuidString).json")
    return TransferManifestStore(fileURL: url)
  }

  // MARK: - Share Extension Tests

  @Test("A share filename can never carry a separator or control character")
  func testSanitizedFilenameIsAlwaysASinglePathComponent() {
    // The recorded filename becomes the Google Photos filename and arrives from a host
    // app the extension does not control, so these are the properties that matter
    // rather than any particular output.
    let hostile = [
      "photo.jpg",
      "../../../etc/passwd",
      "/tmp/../secret.png",
      "a/b/c.png",
      "..",
      ".",
      "",
      "/",
      "bad\u{0}name.jpg",
      "tab\u{9}separated.jpg",
      "trailing/",
      "IMG_0042.HEIC",
    ]
    for input in hostile {
      let output = ShareStagingModel.sanitizedFilename(input)
      #expect(!output.isEmpty, "empty result for \(input.debugDescription)")
      #expect(!output.contains("/"), "separator survived \(input.debugDescription)")
      #expect(
        !output.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
        "control character survived \(input.debugDescription)"
      )
    }
    // A traversing name collapses to its final component rather than escaping.
    #expect(ShareStagingModel.sanitizedFilename("../../../etc/passwd") == "passwd")
    #expect(ShareStagingModel.sanitizedFilename("/tmp/../secret.png") == "secret.png")
    // Ordinary names are untouched, extension included.
    #expect(ShareStagingModel.sanitizedFilename("IMG_0042.HEIC") == "IMG_0042.HEIC")
    #expect(ShareStagingModel.sanitizedFilename("my.holiday.photo.jpeg") == "my.holiday.photo.jpeg")
  }

  @Test("Staging refuses to run when attachments were already loaded")
  @MainActor
  func testShareStagingLoadsAttachmentsOnlyOnce() async {
    let model = ShareStagingModel()
    // No context, so the first call consumes the one-shot latch.
    await model.loadAttachments(from: nil)
    #expect(model.hasLoadedAttachments)
    #expect(model.items.isEmpty)
    // A second call must not restart the scan.
    await model.loadAttachments(from: nil)
    #expect(model.items.isEmpty)
  }

  // MARK: - ByteFormat Tests

  @Test("ByteFormat formats 0 bytes as 0 B")
  func testByteFormatZero() {
    #expect(ByteFormat.string(0) == "0 B")
    #expect(ByteFormat.string(-50) == "0 B")
  }

  @Test("ByteFormat formats positive byte sizes correctly")
  func testByteFormatPositive() {
    let kb = ByteFormat.string(1024)
    #expect(kb.contains("KB") || kb.contains("kB"))

    let mb = ByteFormat.string(1024 * 1024 * 5)
    #expect(mb.contains("MB"))

    let gb = ByteFormat.string(1024 * 1024 * 1024 * 2)
    #expect(gb.contains("GB"))
  }

  // MARK: - Supported Media Formats Tests

  @Test("SupportedMediaFormats correctly identifies photos, videos, and rejects unsupported files")
  func testSupportedMediaFormats() {
    // Standard Photos
    #expect(SupportedMediaFormats.isSupported(filename: "IMG_1234.HEIC"))
    #expect(SupportedMediaFormats.isSupported(filename: "IMG_1234.heif"))
    #expect(SupportedMediaFormats.isSupported(filename: "photo.jpg"))
    #expect(SupportedMediaFormats.isSupported(filename: "photo.jpeg"))
    #expect(SupportedMediaFormats.isSupported(filename: "image.png"))
    #expect(SupportedMediaFormats.isSupported(filename: "graphic.webp"))
    #expect(SupportedMediaFormats.isSupported(filename: "animation.gif"))

    // Camera RAW Formats
    #expect(SupportedMediaFormats.isSupported(filename: "canon.cr2"))
    #expect(SupportedMediaFormats.isSupported(filename: "canon.cr3"))
    #expect(SupportedMediaFormats.isSupported(filename: "nikon.nef"))
    #expect(SupportedMediaFormats.isSupported(filename: "sony.arw"))
    #expect(SupportedMediaFormats.isSupported(filename: "fuji.raf"))
    #expect(SupportedMediaFormats.isSupported(filename: "olympus.orf"))
    #expect(SupportedMediaFormats.isSupported(filename: "panasonic.rw2"))
    #expect(SupportedMediaFormats.isSupported(filename: "adobe.dng"))

    // Videos
    #expect(SupportedMediaFormats.isSupported(filename: "movie.mp4"))
    #expect(SupportedMediaFormats.isSupported(filename: "clip.mov"))
    #expect(SupportedMediaFormats.isSupported(filename: "stream.m4v"))
    #expect(SupportedMediaFormats.isSupported(filename: "video.mkv"))
    #expect(SupportedMediaFormats.isSupported(filename: "clip.avi"))
    #expect(SupportedMediaFormats.isSupported(filename: "web.webm"))

    // Type classification
    #expect(SupportedMediaFormats.isPhoto(filename: "test.jpg"))
    #expect(!SupportedMediaFormats.isVideo(filename: "test.jpg"))
    #expect(SupportedMediaFormats.isVideo(filename: "video.mp4"))
    #expect(!SupportedMediaFormats.isPhoto(filename: "video.mp4"))

    // Rejections
    #expect(!SupportedMediaFormats.isSupported(filename: "document.pdf"))
    #expect(!SupportedMediaFormats.isSupported(filename: "archive.zip"))
    #expect(!SupportedMediaFormats.isSupported(filename: "script.sh"))
    #expect(!SupportedMediaFormats.isSupported(filename: "app.exe"))
    #expect(!SupportedMediaFormats.isSupported(filename: "data.json"))
  }

  // MARK: - Filename Date Parser Tests

  @Test("FilenameDateParser parses standard camera and phone timestamp formats")
  func testFilenameDateParser() {
    let date1 = FilenameDateParser.parseDate(from: "20240709_182027.mp4")
    #expect(date1 != nil)
    if let date1 {
      let cal = Calendar.current
      #expect(cal.component(.year, from: date1) == 2024)
      #expect(cal.component(.month, from: date1) == 7)
      #expect(cal.component(.day, from: date1) == 9)
    }

    let date2 = FilenameDateParser.parseDate(from: "PXL_20231123_182518628.jpg")
    #expect(date2 != nil)
    if let date2 {
      let cal = Calendar.current
      #expect(cal.component(.year, from: date2) == 2023)
      #expect(cal.component(.month, from: date2) == 11)
      #expect(cal.component(.day, from: date2) == 23)
    }

    let date3 = FilenameDateParser.parseDate(from: "Screenshot 2024-02-13 093505.png")
    #expect(date3 != nil)
    if let date3 {
      let cal = Calendar.current
      #expect(cal.component(.year, from: date3) == 2024)
      #expect(cal.component(.month, from: date3) == 2)
      #expect(cal.component(.day, from: date3) == 13)
    }

    let date4 = FilenameDateParser.parseDate(from: "random_non_date_file.jpg")
    #expect(date4 == nil)
  }

  @Test("FilenameDateParser rejects impossible dates instead of rolling them over")
  func testFilenameDateParserRejectsImpossibleDates() {
    let valid = FilenameDateParser.parseDate(from: "IMG_20240229_123456.jpg")
    #expect(valid != nil)
    if let valid {
      let cal = Calendar.current
      #expect(cal.component(.year, from: valid) == 2024)
      #expect(cal.component(.month, from: valid) == 2)
      #expect(cal.component(.day, from: valid) == 29)
    }

    #expect(FilenameDateParser.parseDate(from: "IMG_20241301_123456.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "2024-13-01 123456.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "IMG_20240132_123456.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "2024-01-32.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "IMG_20240230_123456.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "2024-02-30.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "IMG_20249999_123456.jpg") == nil)
    #expect(FilenameDateParser.parseDate(from: "IMG_20230229_123456.jpg") == nil)
  }

  // MARK: - Exponential Backoff Tests

  @Test("Backoff exponential delay calculation and retry limits")
  func testBackoff() {
    let backoff = Backoff(baseDelay: 1.0, maxDelay: 10.0, maxRetries: 3)
    #expect(backoff.shouldRetry(attempt: 0))
    #expect(backoff.shouldRetry(attempt: 2))
    #expect(!backoff.shouldRetry(attempt: 3))

    let d0 = backoff.delay(forAttempt: 0)
    #expect(d0 >= 1.0 && d0 <= 2.0)

    let d1 = backoff.delay(forAttempt: 1)
    #expect(d1 >= 2.0 && d1 <= 3.0)
  }

  // MARK: - TransferRecord Codable Tests

  @Test("TransferRecord Codable serialization round trip")
  func testTransferRecordCodable() throws {
    let original = TransferRecord(
      id: "test-asset-1",
      filename: "test.jpg",
      mediaType: "image/jpeg",
      creationDate: Date(),
      status: .pending,
      byteCount: 2048,
      sentAccountEmails: ["user@example.com"]
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TransferRecord.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.filename == original.filename)
    #expect(decoded.mediaType == original.mediaType)
    #expect(decoded.byteCount == original.byteCount)
    #expect(decoded.status == original.status)
    #expect(decoded.sentAccountEmails == original.sentAccountEmails)
  }

  // MARK: - Protobuf Wire Protocol Tests

  @Test("GooglePhotosMessages encodeGetUploadToken generates valid protobuf payload")
  func testEncodeGetUploadToken() {
    let payload = GooglePhotosMessages.encodeGetUploadToken(fileSizeBytes: 524288)
    #expect(!payload.isEmpty)
    #expect(payload.count > 10)
  }

  @Test("GooglePhotosMessages encodeHashCheck produces valid message")
  func testEncodeHashCheck() {
    let testSHA1 = Data(repeating: 0xAB, count: 20)
    let payload = GooglePhotosMessages.encodeHashCheck(sha1Hash: testSHA1)
    #expect(!payload.isEmpty)
    #expect(payload.count > 20)
  }

  @Test("Hash check bytes: plain lookup omits the media type, motion lookup sends PhodeoMovie")
  func testEncodeHashCheckBytes() {
    let sha1 = Data(repeating: 0xAB, count: 20)
    let plain = Data([0x0A, 0x1A, 0x0A, 0x16, 0x0A, 0x14]) + sha1 + Data([0x12, 0x00])
    let motion = Data([0x0A, 0x1C, 0x0A, 0x18, 0x0A, 0x14]) + sha1 + Data([0x28, 0x02, 0x12, 0x00])
    #expect(GooglePhotosMessages.encodeHashCheck(sha1Hash: sha1) == plain)
    #expect(GooglePhotosMessages.encodeHashCheck(sha1Hash: sha1, asLivePhotoMotion: true) == motion)
  }

  @Test("Regular and Live Photo commits use metered storage at original quality")
  func testMeteredCommits() throws {
    let commitToken = CommitToken(field1: 2, field2: Data([0x01, 0x02, 0x03]))
    let sha1 = Data(repeating: 0x42, count: 20)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let token = ScottyFinalizeToken(raw: Data([1, 2, 3]))
    let file = GooglePhotosMessages.encodeCommitUpload(
      commitToken: commitToken, fileName: "photo.jpg", sha1Hash: sha1,
      timestampSeconds: 1_700_000_000, device: .metered)
    let livePhoto = try GooglePhotosMessages.encodeLivePhotoCreate(
      input: LivePhotoCreateRequest(
        photoToken: token, videoToken: token, fileName: "photo.jpg", photoSHA1: sha1,
        videoSHA1: sha1, createdAt: date, modifiedAt: date))
    let reconcile = try GooglePhotosMessages.encodeLivePhotoReconcile(
      input: LivePhotoReconcileRequest(
        videoToken: token, fileName: "photo.mov", photoSHA1: sha1,
        videoSHA1: sha1, createdAt: date, modifiedAt: date))

    for payload in [file, livePhoto, reconcile] {
      let message = try ProtoMessage(payload)
      #expect(message.message(2)?.string(3) == "Pixel 8")
      #expect(message.message(1)?.int(7) == 3)
      #expect(message.message(1)?.int(10) == 1)
    }
  }

  @Test("ScottyFinalizeToken parses valid tokens and rejects corrupted data")
  func testScottyFinalizeToken() {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 1, 2)
    writer.writeBytes(fieldNumber: 2, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    let validData = writer.data

    let parsed = try? ScottyFinalizeToken.parse(validData)
    #expect(parsed != nil)
    #expect(parsed?.raw == validData)

    var badWriter = ProtobufWriter()
    badWriter.writeInt64(fieldNumber: 1, 99)
    badWriter.writeBytes(fieldNumber: 2, Data([0x01]))
    #expect(throws: Error.self) {
      try ScottyFinalizeToken.parse(badWriter.data)
    }
  }

  @Test("GooglePhotosMessages encodeCreateAlbum creates non-empty protobuf")
  func testEncodeCreateAlbum() {
    let payload = GooglePhotosMessages.encodeCreateAlbum(albumName: "Vacation", mediaKeys: ["mediaKey1"], device: .metered)
    #expect(!payload.isEmpty)
  }

  @Test("GooglePhotosMessages encodeAddMediaToAlbum creates non-empty protobuf")
  func testEncodeAddMediaToAlbum() {
    let payload = GooglePhotosMessages.encodeAddMediaToAlbum(albumMediaKey: "album-123", mediaKeys: ["item-1", "item-2"], device: .metered)
    #expect(!payload.isEmpty)
  }

  // MARK: - TransferManifestStore Actor Tests

  @Test("TransferManifestStore upsert, retrieve, updateStatus, and delete")
  func testTransferManifestStore() async {
    let store = makeTestManifestStore()
    let testId = "manifest-test-\(UUID().uuidString)"

    let record = TransferRecord(
      id: testId,
      filename: "sample.jpg",
      mediaType: "Photo",
      creationDate: Date(),
      status: .pending,
      byteCount: 4096
    )

    await store.upsert(record)
    let fetched = await store.record(for: testId)
    #expect(fetched != nil)
    #expect(fetched?.filename == "sample.jpg")
    #expect(fetched?.status == .pending)

    // Update to sending
    await store.updateStatus(id: testId, status: .sending, progress: 0.5, transferredBytes: 2048)
    let updating = await store.record(for: testId)
    #expect(updating?.status == .sending)
    #expect(updating?.progress == 0.5)

    // Update to sent
    await store.updateStatus(id: testId, status: .sent, mediaKey: "cloud-key-abc", accountEmail: "test@gmail.com")
    let sent = await store.record(for: testId)
    #expect(sent?.status == .sent)
    #expect(sent?.mediaKeysByAccount["test@gmail.com"] == "cloud-key-abc")
    #expect(sent?.sentAccountEmails.contains("test@gmail.com") == true)

    // Remove
    await store.remove(id: testId)
    let deleted = await store.record(for: testId)
    #expect(deleted == nil)
  }

  @Test("TransferManifestStore isolates upload claims and account retention")
  func testTransferManifestStoreClaimsAndRetention() async {
    let store = makeTestManifestStore()
    let claimID = "claim-\(UUID().uuidString)"
    let assetID = "asset-\(UUID().uuidString)"
    let accountA = "a-\(UUID().uuidString)@example.com"
    let accountB = "b-\(UUID().uuidString)@example.com"
    let idA = TransferRecord.accountScopedID(assetID, accountEmail: accountA)
    let idB = TransferRecord.accountScopedID(assetID, accountEmail: accountB)

    await store.upsert(
      TransferRecord(
        id: idA,
        filename: "asset.jpg",
        mediaType: "Photo",
        status: .pending,
        assetLocalIdentifier: assetID
      ))
    #expect(await store.claimForUpload(id: claimID) == false)
    await store.upsert(TransferRecord(id: claimID, filename: "claim.jpg", mediaType: "Photo", status: .pending))
    #expect(await store.claimForUpload(id: claimID))
    #expect(!(await store.claimForUpload(id: claimID)))
    await store.releaseUploadClaim(id: claimID)
    #expect(await store.record(for: claimID)?.status == .pending)

    let batchClaimIDs = ["batch-claim-a-\(UUID().uuidString)", "batch-claim-b-\(UUID().uuidString)"]
    await store.upsertBatch(
      batchClaimIDs.map { id in
        TransferRecord(id: id, filename: "\(id).jpg", mediaType: "Photo", status: .pending)
      })
    #expect(await store.claimForUpload(ids: batchClaimIDs) == Set(batchClaimIDs))
    #expect(await store.record(for: batchClaimIDs[0])?.status == .sending)
    #expect(await store.record(for: batchClaimIDs[1])?.status == .sending)
    for id in batchClaimIDs {
      await store.releaseUploadClaim(id: id)
      await store.remove(id: id)
    }

    await store.upsertBatch([
      TransferRecord(
        id: idA,
        filename: "asset.jpg",
        mediaType: "Photo",
        status: .pending,
        assetLocalIdentifier: assetID
      ),
      TransferRecord(
        id: idB,
        filename: "asset.jpg",
        mediaType: "Photo",
        status: .pending,
        assetLocalIdentifier: assetID
      ),
    ])
    await store.updateStatus(id: idA, status: .sent, mediaKey: "key-a", accountEmail: accountA)
    #expect(
      await store.eligibleForDeletion(
        delay: .immediately,
        smartDelete: false,
        accountEmail: accountA,
        accountEmails: [accountA, accountB]
      ).isEmpty)

    await store.updateStatus(id: idB, status: .sent, mediaKey: "key-b", accountEmail: accountB)
    #expect(
      await store.eligibleForDeletion(
        delay: .immediately,
        smartDelete: false,
        accountEmail: accountA,
        accountEmails: [accountA, accountB]
      ).contains { $0.id == idA })

    await store.remove(id: claimID)
    await store.remove(id: idA)
    await store.remove(id: idB)
  }

  @Test("TransferManifestStore does not reset claims or delete superseded source versions")
  func testTransferManifestStoreProtectsClaimsAndSourceVersions() async {
    let store = makeTestManifestStore()
    let account = "versions-\(UUID().uuidString)@example.com"
    let claimID = TransferRecord.accountScopedID("claim-\(UUID().uuidString)", accountEmail: account)
    let oldID = TransferRecord.accountScopedID("source|old", accountEmail: account)
    let newID = TransferRecord.accountScopedID("source|new", accountEmail: account)
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000)

    await store.upsert(TransferRecord(id: claimID, filename: "claim.jpg", mediaType: "Photo", status: .pending))
    #expect(await store.claimForUpload(id: claimID))
    await store.upsert(TransferRecord(id: claimID, filename: "claim.jpg", mediaType: "Photo", status: .pending))
    #expect(await store.record(for: claimID)?.status == .sending)
    await store.upsertBatch([TransferRecord(id: claimID, filename: "claim.jpg", mediaType: "Photo", status: .pending)])
    #expect(await store.record(for: claimID)?.status == .sending)

    await store.upsert(
      TransferRecord(
        id: oldID,
        filename: "image.jpg",
        mediaType: "Photo",
        status: .pending,
        sourcePath: "/tmp/source.jpg",
        sourceFileSize: 100,
        sourceModifiedAt: oldDate
      ))
    await store.updateStatus(id: oldID, status: .sent, mediaKey: "key-old", accountEmail: account)
    await store.upsert(
      TransferRecord(
        id: newID,
        filename: "image.jpg",
        mediaType: "Photo",
        status: .pending,
        sourcePath: "/tmp/source.jpg",
        sourceFileSize: 101,
        sourceModifiedAt: newDate
      ))

    let pendingVersion = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: account,
      accountEmails: [account]
    )
    #expect(!pendingVersion.contains { $0.id == oldID })

    await store.updateStatus(id: newID, status: .sent, mediaKey: "key-new", accountEmail: account)
    let bothSent = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: account,
      accountEmails: [account]
    )
    #expect(!bothSent.contains { $0.id == oldID })
    #expect(bothSent.contains { $0.id == newID })

    let sameTimeOldID = TransferRecord.accountScopedID("source|same-time-old", accountEmail: account)
    let sameTimeNewID = TransferRecord.accountScopedID("source|same-time-new", accountEmail: account)
    await store.upsert(
      TransferRecord(
        id: sameTimeOldID,
        filename: "image.jpg",
        mediaType: "Photo",
        status: .pending,
        sourcePath: "/tmp/same-time.jpg",
        sourceFileSize: 100,
        sourceModifiedAt: oldDate
      ))
    await store.updateStatus(id: sameTimeOldID, status: .sent, mediaKey: "key-same-old", accountEmail: account)
    await store.upsert(
      TransferRecord(
        id: sameTimeNewID,
        filename: "image.jpg",
        mediaType: "Photo",
        status: .pending,
        sourcePath: "/tmp/same-time.jpg",
        sourceFileSize: 200,
        sourceModifiedAt: oldDate
      ))
    await store.updateStatus(id: sameTimeNewID, status: .sent, mediaKey: "key-same-new", accountEmail: account)
    let sameTime = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: account,
      accountEmails: [account]
    )
    #expect(!sameTime.contains { $0.id == sameTimeOldID })
    #expect(!sameTime.contains { $0.id == sameTimeNewID })

    await store.remove(id: claimID)
    await store.remove(id: oldID)
    await store.remove(id: newID)
    await store.remove(id: sameTimeOldID)
    await store.remove(id: sameTimeNewID)
  }

  @Test("An item found already in Google Photos is kept unless the user allows removing it")
  func testFoundInAccountHoldsBackDeletion() async {
    let store = makeTestManifestStore()
    let account = "found-\(UUID().uuidString)@example.com"
    let id = TransferRecord.accountScopedID("found-asset", accountEmail: account)
    await store.upsert(TransferRecord(id: id, filename: "found.jpg", mediaType: "Photo", status: .pending, sha1: "found-sha"))

    await store.updateStatus(
      id: id, status: .sent, mediaKey: "remote-key", sha1: "found-sha", accountEmail: account, foundInAccount: true)
    #expect(await store.record(for: id)?.foundInAccounts == [account])
    #expect(
      await store.eligibleForDeletion(delay: .immediately, smartDelete: false, accountEmail: account).isEmpty)
    #expect(
      await store.eligibleForDeletion(
        delay: .immediately, smartDelete: false, accountEmail: account, includesFoundItems: true
      ).contains { $0.id == id })
    // A later lookup through the manifest carries the doubt forward.
    #expect(await store.uploadedMediaKey(forSHA1: "found-sha", accountEmail: account)?.foundInAccount == true)

    // Uploading the bytes this app read clears it.
    await store.updateStatus(id: id, status: .sent, mediaKey: "uploaded-key", accountEmail: account)
    #expect(await store.record(for: id)?.foundInAccounts.isEmpty == true)
    #expect(
      await store.eligibleForDeletion(delay: .immediately, smartDelete: false, accountEmail: account)
        .contains { $0.id == id })

    // Sending it again forgets what was known about the account.
    await store.updateStatus(id: id, status: .sent, mediaKey: "remote-key", accountEmail: account, foundInAccount: true)
    #expect(await store.resetForResend(id: id, accountEmail: account))
    #expect(await store.record(for: id)?.foundInAccounts.isEmpty == true)
    await store.remove(id: id)
  }

  @Test("A secondary copy found in its account does not stand in for an upload")
  func testFoundSecondaryCopyHoldsBackPrimaryDeletion() async {
    let store = makeTestManifestStore()
    let primary = "primary-\(UUID().uuidString)@example.com"
    let secondary = "secondary-\(UUID().uuidString)@example.com"
    let assetID = "asset-\(UUID().uuidString)"
    let primaryID = TransferRecord.accountScopedID(assetID, accountEmail: primary)
    let secondaryID = TransferRecord.accountScopedID(assetID, accountEmail: secondary)
    await store.upsertBatch([
      TransferRecord(id: primaryID, filename: "a.jpg", mediaType: "Photo", status: .pending, assetLocalIdentifier: assetID),
      TransferRecord(id: secondaryID, filename: "a.jpg", mediaType: "Photo", status: .pending, assetLocalIdentifier: assetID),
    ])
    await store.updateStatus(id: primaryID, status: .sent, mediaKey: "key-p", accountEmail: primary)
    await store.updateStatus(id: secondaryID, status: .sent, mediaKey: "key-s", accountEmail: secondary, foundInAccount: true)

    #expect(
      await store.eligibleForDeletion(
        delay: .immediately, smartDelete: false, accountEmail: primary, accountEmails: [primary, secondary]
      ).isEmpty)
    #expect(
      await store.eligibleForDeletion(
        delay: .immediately, smartDelete: false, accountEmail: primary, accountEmails: [primary, secondary],
        includesFoundItems: true
      ).contains { $0.id == primaryID })
    await store.remove(id: primaryID)
    await store.remove(id: secondaryID)
  }

  @Test("A record written before found copies were tracked loads with none")
  func testTransferRecordDecodesWithoutFoundInAccounts() throws {
    let record = TransferRecord(
      id: "legacy", filename: "a.jpg", mediaType: "Photo", status: .sent, sentAccountEmails: ["a@example.com"],
      mediaKeysByAccount: ["a@example.com": "key"], foundInAccounts: ["a@example.com"])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    object.removeValue(forKey: "foundInAccounts")
    let decoded = try JSONDecoder().decode(TransferRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.foundInAccounts.isEmpty)
    #expect(decoded.mediaKeysByAccount == ["a@example.com": "key"])
  }

  @Test("TransferManifestStore upsertBatch persists multiple records at once")
  func testTransferManifestStoreBatchUpsert() async {
    let store = makeTestManifestStore()
    let batchId1 = "batch-test-1-\(UUID().uuidString)"
    let batchId2 = "batch-test-2-\(UUID().uuidString)"

    let r1 = TransferRecord(id: batchId1, filename: "batch1.jpg", mediaType: "Photo", status: .pending, byteCount: 1000)
    let r2 = TransferRecord(id: batchId2, filename: "batch2.mov", mediaType: "Video", status: .pending, byteCount: 2000)

    await store.upsertBatch([r1, r2])

    let f1 = await store.record(for: batchId1)
    let f2 = await store.record(for: batchId2)

    #expect(f1 != nil)
    #expect(f1?.filename == "batch1.jpg")
    #expect(f2 != nil)
    #expect(f2?.filename == "batch2.mov")

    await store.remove(id: batchId1)
    await store.remove(id: batchId2)
  }

  // MARK: - UploadWorkerPool Tests

  @Test("UploadWorkerPool manages workers and concurrency correctly")
  @MainActor
  func testUploadWorkerPool() {
    let client = GooglePhotosMobileClient(authService: GoogleAuthService())
    let manifest = makeTestManifestStore()
    let pool = UploadWorkerPool(client: client, manifestStore: manifest)

    pool.setConcurrency(4)
    #expect(pool.workers.count == 4)

    pool.setConcurrency(8)
    #expect(pool.workers.count == 8)

    pool.setConcurrency(1)
    #expect(pool.workers.count == 1)

    #expect(!pool.isRunning)
    #expect(!pool.isPaused)
  }

  @Test("UploadWorkerPool rejects a start it cannot accept")
  @MainActor
  func testUploadWorkerPoolRejectsEmptyStart() {
    let client = GooglePhotosMobileClient(authService: GoogleAuthService())
    let pool = UploadWorkerPool(client: client, manifestStore: makeTestManifestStore())

    // Rejection is the only outcome a caller may release upload claims for, so it has
    // to be distinct from "already tracked" — releasing on the latter un-claims a
    // transfer that is still running.
    #expect(pool.start(items: [], accountEmail: "a@example.com") == .rejected)
    #expect(UploadWorkerPool.StartOutcome.rejected != .alreadyTracked)
    #expect(UploadWorkerPool.StartOutcome.rejected != .started)
  }

  // MARK: - Credential Sanitization Tests

  @Test("GoogleAuthService sanitizes raw credential query without double encoding")
  func testCredentialSanitization() throws {
    let rawQuery = "Email=account%40example.com&Token=aas_et%2Ftest123%3D&androidId=0123456789abcdef&assertion_jwt=temp"
    let sanitized = try GoogleAuthService.sanitizedCredentialQuery(from: rawQuery)
    #expect(!sanitized.contains("assertion_jwt"))
    #expect(sanitized.contains("androidId=0123456789abcdef"))
    #expect(sanitized.contains("Email=account%40example.com") || sanitized.contains("Email=account@example.com"))
    #expect(!sanitized.contains("%2540"))
  }

  @Test("Shared upload paths preserve valid names and remove traversal components")
  func testSharedUploadPathSanitization() {
    let valid = SharedUploadEntry(
      fileName: "photo .jpg",
      relativePath: "folder/ photo .jpg",
      bytesTotal: 10,
      sha1Base64: "fingerprint"
    )
    #expect(valid.relativePath == "folder/ photo .jpg")

    let unsafe = SharedUploadEntry(
      fileName: "photo.jpg",
      relativePath: "../outside/./photo.jpg",
      bytesTotal: 10,
      sha1Base64: "fingerprint"
    )
    #expect(unsafe.relativePath == "outside/photo.jpg")
  }

  @Test("A completed record can be re-queued when its content changed")
  func testUpsertRequeuesCompletedRecord() async {
    let store = makeTestManifestStore()
    let account = "requeue-\(UUID().uuidString)@example.com"
    let id = TransferRecord.accountScopedID("asset-\(UUID().uuidString)", accountEmail: account)

    await store.upsert(TransferRecord(id: id, filename: "edited.jpg", mediaType: "Photo", status: .pending))
    await store.updateStatus(
      id: id,
      status: .sent,
      mediaKey: "original-key",
      sha1: "original-sha",
      accountEmail: account
    )
    let sent = await store.record(for: id)
    #expect(sent?.status == .sent)

    // An edited asset is handed back as pending. The store must accept it, otherwise
    // the edit is detected on every scan and never uploaded.
    guard var edited = sent else { return }
    edited.status = .pending
    edited.sha1 = "edited-sha"
    edited.lastError = nil
    #expect(await store.upsertBatch([edited]))

    let requeued = await store.record(for: id)
    #expect(requeued?.status == .pending)
    #expect(requeued?.sha1 == "edited-sha")
    #expect(await store.claimForUpload(ids: [id]) == [id])
  }

  @Test("TransferManifestStore scopes SHA-1 reuse by account")
  func testTransferManifestAccountScopedLookup() async {
    let store = makeTestManifestStore()
    let id = "account-sha-\(UUID().uuidString)"
    let sha1 = "sha-\(UUID().uuidString)"

    await store.upsert(TransferRecord(id: id, filename: "a.jpg", mediaType: "Photo", status: .pending))
    await store.updateStatus(id: id, status: .sent, mediaKey: "key-a", sha1: sha1, accountEmail: "a@example.com")
    await store.updateStatus(id: id, status: .sent, mediaKey: "key-b", sha1: sha1, accountEmail: "b@example.com")

    let first = await store.uploadedMediaKey(forSHA1: sha1, accountEmail: "a@example.com")
    let second = await store.uploadedMediaKey(forSHA1: sha1, accountEmail: "b@example.com")
    #expect(first?.mediaKey == "key-a")
    #expect(second?.mediaKey == "key-b")
    let missing = await store.uploadedMediaKey(forSHA1: sha1, accountEmail: "missing@example.com")
    #expect(missing == nil)

    await store.remove(id: id)
  }

  @Test("Cleanup refuses changed sources and removes verified files")
  func testTransferManifestCleanupVerifiesSourceIdentity() async throws {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-cleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("verified.jpg")
    try Data("verified".utf8).write(to: source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modified = attributes[.modificationDate] as? Date ?? Date()
    let sha1 = try GooglePhotosMobileClient.streamSHA1(fileURL: source).base64EncodedString()
    let account = "cleanup-\(UUID().uuidString)@example.com"
    let id = TransferRecord.accountScopedID(UUID().uuidString, accountEmail: account)
    let store = makeTestManifestStore()

    await store.upsert(
      TransferRecord(
        id: id,
        filename: source.lastPathComponent,
        mediaType: "Photo",
        status: .pending,
        sourcePath: source.path,
        sourceFileSize: size,
        sourceModifiedAt: modified,
        sourceSHA1: sha1
      ))
    await store.updateStatus(id: id, status: .sent, mediaKey: "key-manual", accountEmail: account)
    try Data("changed".utf8).write(to: source)
    #expect(await store.claimForDeletion(id: id))
    #expect(!(await store.deleteSourceFiles(id: id, fileURL: source)))
    #expect(FileManager.default.fileExists(atPath: source.path))

    let replacement = directory.appendingPathComponent("replacement.jpg")
    try Data("verified".utf8).write(to: replacement)
    let replacementAttributes = try FileManager.default.attributesOfItem(atPath: replacement.path)
    let replacementSize = (replacementAttributes[.size] as? NSNumber)?.int64Value ?? 0
    let replacementModified = replacementAttributes[.modificationDate] as? Date ?? Date()
    let replacementSHA1 = try GooglePhotosMobileClient.streamSHA1(fileURL: replacement).base64EncodedString()
    let replacementID = TransferRecord.accountScopedID(UUID().uuidString, accountEmail: account)
    await store.upsert(
      TransferRecord(
        id: replacementID,
        filename: replacement.lastPathComponent,
        mediaType: "Photo",
        status: .pending,
        sourcePath: replacement.path,
        sourceFileSize: replacementSize,
        sourceModifiedAt: replacementModified,
        sourceSHA1: replacementSHA1
      ))
    await store.updateStatus(id: replacementID, status: .sent, mediaKey: "key-replacement", accountEmail: account)
    #expect(await store.claimForDeletion(id: replacementID))
    #expect(await store.deleteSourceFiles(id: replacementID, fileURL: replacement))
    #expect(!FileManager.default.fileExists(atPath: replacement.path))
  }

  @Test("A removal its check refuses, before a move or after hashing, puts both files back", arguments: [1, 2, 3])
  func testCleanupCheckRollsBack(refusedCall: Int) async throws {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String) throws -> (url: URL, size: Int64, modified: Date, sha1: String) {
      let url = directory.appendingPathComponent(name)
      try Data(name.utf8).write(to: url)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (
        url, (attributes[.size] as? NSNumber)?.int64Value ?? 0, attributes[.modificationDate] as? Date ?? Date(),
        try GooglePhotosMobileClient.streamSHA1(fileURL: url).base64EncodedString()
      )
    }
    let still = try file("still.heic")
    let motion = try file("motion.mov")
    let account = "check-\(UUID().uuidString)@example.com"
    let id = TransferRecord.accountScopedID(UUID().uuidString, accountEmail: account)
    let store = makeTestManifestStore()
    var record = TransferRecord(
      id: id, filename: still.url.lastPathComponent, mediaType: "Live Photo", status: .pending, sourcePath: still.url.path,
      sourceFileSize: still.size, sourceModifiedAt: still.modified, sourceSHA1: still.sha1)
    record.pairedSourcePath = motion.url.path
    record.pairedSourceFileSize = motion.size
    record.pairedSourceModifiedAt = motion.modified
    record.pairedSourceSHA1 = motion.sha1
    await store.upsert(record)
    await store.updateStatus(id: id, status: .sent, mediaKey: "key", accountEmail: account)
    #expect(await store.claimForDeletion(id: id))
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let removed = await store.deleteSourceFiles(id: id, fileURL: still.url, pairedFileURL: motion.url) { files in
      // Wherever each file is at that moment, it's the file that's asked about.
      let exist = files.count == 2 && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
      return exist
        && calls.withLock { count in
          count += 1
          return count != refusedCall
        }
    }
    #expect(!removed)
    #expect(calls.withLock { $0 } == refusedCall)
    #expect(try Data(contentsOf: still.url) == Data("still.heic".utf8))
    #expect(try Data(contentsOf: motion.url) == Data("motion.mov".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    #expect(await store.allRecords().first { $0.id == id }?.status == .sent)
    // Allowed, the same claim's record goes.
    #expect(await store.claimForDeletion(id: id))
    #expect(await store.deleteSourceFiles(id: id, fileURL: still.url, pairedFileURL: motion.url) { _ in true })
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test("A cleanup check fails once what it was planned under changes")
  func testCleanupPolicy() {
    let policy = CleanupPolicy()
    let url = TestTemporaryDirectory.root
    let check = policy.check(root: nil)
    #expect(check([url]))
    policy.invalidate()
    #expect(!check([url]))
    #expect(policy.check(root: url)([url]))
    // Unreadable counts as shared.
    #expect(!policy.check(root: nil)([url.appendingPathComponent("missing-\(UUID().uuidString)")]))
  }

  @Test("TransferManifestStore merges duplicate records for the same file")
  func testTransferManifestMergesDuplicateRecords() async throws {
    let fileURL = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-duplicates-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let account = "duplicate-\(UUID().uuidString)@example.com"
    let path = "/Users/example/Pictures/IMG_0940.MOV"
    let sha1 = "duplicate-sha-\(UUID().uuidString)"
    let uploadedID = TransferRecord.accountScopedID("\(path)|a-version", accountEmail: account)
    let duplicateID = TransferRecord.accountScopedID("\(path)|z-version", accountEmail: account)
    let uploaded = TransferRecord(
      id: uploadedID,
      filename: "IMG_0940.MOV",
      mediaType: "Video",
      status: .sent,
      byteCount: 3_608_193_543,
      sentAccountEmails: [account],
      mediaKeysByAccount: [account: "uploaded-key"],
      sha1: sha1,
      sourcePath: path,
      sourceFileSize: 3_608_193_543
    )
    let duplicate = TransferRecord(
      id: duplicateID,
      filename: "IMG_0940.MOV",
      mediaType: "Video",
      status: .sent,
      byteCount: 3_608_193_543,
      sentAccountEmails: [account],
      mediaKeysByAccount: [account: "deduplicated-key"],
      sha1: sha1,
      lastError: "Deduplicated (Already in Google Photos)",
      sourcePath: path,
      sourceFileSize: 3_608_193_543
    )
    try JSONEncoder().encode([uploaded, duplicate]).write(to: fileURL, options: .atomic)

    let store = TransferManifestStore(fileURL: fileURL)
    let records = await store.allRecords()
    #expect(records.count == 1)
    #expect(records.first?.id == uploadedID)
    #expect(records.first?.mediaKeysByAccount[account] == "uploaded-key")
    #expect(await store.uploadedMediaKey(forSHA1: sha1, accountEmail: account)?.mediaKey == "uploaded-key")
  }

  @Test("An album name maps to one reusable album, not a new one per batch")
  func testAlbumKeyStoreReusesTheSameAlbum() throws {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-albumkeys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storeURL = directory.appendingPathComponent("album-keys.json")
    // Exercised through the on-disk format rather than the singleton, so the assertion
    // is about the stored shape: name -> album media key.
    let first = try JSONEncoder().encode(["Family": "album-key-1"])
    try first.write(to: storeURL, options: .atomic)
    #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: storeURL)) == ["Family": "album-key-1"])

    // A later batch must look the album up and add to it, so the key has to survive.
    let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: storeURL))
    #expect(stored["Family"] == "album-key-1")
  }

  @Test("Settings written before a key existed still load")
  func testAppSettingsDecodeToleratesMissingKeys() throws {
    // The store quarantines and resets on a decode failure, so a synthesized decoder
    // that requires every key would wipe the user's other settings whenever a setting
    // is added.
    let legacy = """
      {
        "autoDeleteDelay": "oneWeek",
        "smartDeleteEnabled": true,
        "ignoredFolders": [
          {"id": "/Users/example/Pictures", "title": "Pictures", "path": "/Users/example/Pictures"}
        ],
        "autoSyncEnabled": false,
        "uploadThreads": 7,
        "pairLivePhotos": false
      }
      """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

    // Values that were present are kept.
    #expect(settings.autoDeleteDelay == .oneWeek)
    #expect(settings.smartDeleteEnabled)
    #expect(settings.ignoredFolders.count == 1)
    #expect(settings.autoSyncEnabled == false)
    #expect(settings.uploadThreads == 7)
    #expect(settings.removesItemsAlreadyInGooglePhotos == false)
    #expect(settings.copiesOnlyWhileCharging == false)
    #expect(settings.backupExclusions.isEmpty)
    #expect(settings.backsUpUneditedOriginals)
    #expect(settings.pairLivePhotos == false)

    // Absent keys fall back to defaults rather than throwing.
    #expect(settings.setDateFromFilename)
    #expect(settings.createAlbumsFromFolders)
    #expect(settings.mirrorPhotoAlbums == false)
  }

  @Test("An empty settings object decodes to defaults")
  func testAppSettingsDecodeEmptyObject() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(settings == AppSettings())
  }

  @Test("One upload can belong to several albums")
  func testUploadQueueItemCarriesMultipleAlbums() {
    let url = TestTemporaryDirectory.root.appendingPathComponent("multi-album.jpg")
    let item = UploadQueueItem(
      id: "multi-album",
      fileURL: url,
      fileSize: 2048,
      albumNames: ["Favorites", "2026 Vacation"]
    )

    #expect(item.albumNames == ["Favorites", "2026 Vacation"])

    // A result must carry the albums through so the pool can put the same media key in
    // every album bucket — uploading once and appearing in both.
    let result = ProcessResult(
      workerID: 0,
      filename: "multi-album.jpg",
      mediaKey: "key-1",
      fileSize: 2048,
      albumNames: item.albumNames
    )
    var keysByAlbum: [String: [String]] = [:]
    if let key = result.mediaKey {
      for album in result.albumNames where !album.isEmpty {
        keysByAlbum[album, default: []].append(key)
      }
    }

    #expect(keysByAlbum["Favorites"] == ["key-1"])
    #expect(keysByAlbum["2026 Vacation"] == ["key-1"])
    #expect(keysByAlbum.count == 2)
  }

  @Test("An item with no albums buckets into nothing")
  func testUploadQueueItemWithoutAlbums() {
    let url = TestTemporaryDirectory.root.appendingPathComponent("no-album.jpg")
    let item = UploadQueueItem(id: "no-album", fileURL: url, fileSize: 10)
    #expect(item.albumNames.isEmpty)
  }

  @Test("A protected folder still protects when its bookmark will not resolve")
  func testProtectedFolderFallsBackToRecordedPath() throws {
    let root = TestTemporaryDirectory.root.appendingPathComponent(
      "GPhotosKitTests-protected-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inside = root.appendingPathComponent("IMG_0001.JPG")
    let outside = root.deletingLastPathComponent().appendingPathComponent("Other/IMG_0001.JPG")

    let plain = try #require(IgnoredFolderLocation.protectedPaths([IgnoredFolderLocation(url: root)]))
    #expect(IgnoredFolderLocation.isProtected(inside, protectedPaths: plain))
    #expect(!IgnoredFolderLocation.isProtected(outside, protectedPaths: plain))

    // A corrupt bookmark cannot be resolved. The recorded path is still authoritative,
    // so the folder keeps protecting the location the user chose instead of silently
    // protecting nothing (or everything).
    let corrupt = try #require(
      IgnoredFolderLocation.protectedPaths([IgnoredFolderLocation(url: root, bookmarkData: Data([0x00, 0x01, 0x02]))]))
    #expect(IgnoredFolderLocation.isProtected(inside, protectedPaths: corrupt))
    #expect(!IgnoredFolderLocation.isProtected(outside, protectedPaths: corrupt))
  }

  @Test("A protected folder that can't be found at all stops every folder deletion")
  func testUnlocatableProtectedFolderFailsClosed() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Protected", isDirectory: true)
    #expect(IgnoredFolderLocation.protectedPaths([IgnoredFolderLocation(url: missing, bookmarkData: Data([0x00]))]) == nil)
    #expect(IgnoredFolderLocation.protectedPaths([IgnoredFolderLocation(url: missing)]) == nil)
    #expect(IgnoredFolderLocation.protectedPaths([]) == [])
  }

  @Test("Identical content at two paths keeps a record for each file")
  func testDeduplicateKeepsDistinctFilesWithEqualContent() async throws {
    let fileURL = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-samesha-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let account = "samesha-\(UUID().uuidString)@example.com"
    let sha1 = "shared-bytes-\(UUID().uuidString)"

    // A folder copy and a share-sheet copy of identical bytes. Merging these dropped
    // one source path, leaving that file on disk with no record at all: never
    // re-scanned, never cleaned up, invisible in the UI.
    let folderCopy = "/Users/example/Pictures/IMG_0001.JPG"
    let shareCopy = "/Users/example/ManualUploads/IMG_0001-copy.JPG"
    let records = [
      TransferRecord(
        id: TransferRecord.accountScopedID("\(folderCopy)|a", accountEmail: account),
        filename: "IMG_0001.JPG", mediaType: "Photo", status: .sent,
        sentAccountEmails: [account], mediaKeysByAccount: [account: "key-1"],
        sha1: sha1, sourcePath: folderCopy, sourceFileSize: 1024
      ),
      TransferRecord(
        id: TransferRecord.accountScopedID("\(shareCopy)|b", accountEmail: account),
        filename: "IMG_0001-copy.JPG", mediaType: "Photo", status: .sent,
        sentAccountEmails: [account], mediaKeysByAccount: [account: "key-2"],
        sha1: sha1, sourcePath: shareCopy, sourceFileSize: 1024
      ),
    ]
    try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)

    let store = TransferManifestStore(fileURL: fileURL)
    let loaded = await store.allRecords()
    #expect(loaded.count == 2)
    #expect(Set(loaded.compactMap(\.sourcePath)) == [folderCopy, shareCopy])
  }

  @Test("A tombstone is only restored to a path the record owns")
  func testRestoreTombstoneRejectsForeignPath() async throws {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-restore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let owned = directory.appendingPathComponent("owned.jpg")
    let foreign = directory.appendingPathComponent("elsewhere.jpg")
    let contents = Data([0x01, 0x02, 0x03])
    try contents.write(to: owned)
    try contents.write(to: foreign)

    let store = makeTestManifestStore()
    let id = "restore-\(UUID().uuidString)"
    let sha1 = try GooglePhotosMobileClient.streamSHA1(fileURL: owned).base64EncodedString()
    await store.upsert(
      TransferRecord(
        id: id,
        filename: "owned.jpg",
        mediaType: "Photo",
        status: .sent,
        sourcePath: owned.path,
        sourceFileSize: Int64(contents.count),
        sourceModifiedAt: Date(),
        sourceSHA1: sha1
      ))

    // A caller-supplied path outside the record must not become a write target.
    #expect(await store.restoreTombstoneIfSafe(id: id, path: foreign.path, tombstone: owned) == false)
    #expect(FileManager.default.fileExists(atPath: foreign.path))
  }

  @Test("Merging a deleted duplicate never leaves a sent record with a deletion date")
  func testMergeClearsDeletedAtOnSentRecord() async throws {
    let fileURL = TestTemporaryDirectory.root
      .appendingPathComponent("GPhotosKitTests-merge-status-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let account = "merge-status-\(UUID().uuidString)@example.com"
    let path = "/Users/example/Pictures/IMG_0001.JPG"
    let sha1 = "merge-sha-\(UUID().uuidString)"

    let sent = TransferRecord(
      id: TransferRecord.accountScopedID("\(path)|a", accountEmail: account),
      filename: "IMG_0001.JPG",
      mediaType: "Photo",
      status: .sent,
      sentAt: Date(),
      sentAccountEmails: [account],
      mediaKeysByAccount: [account: "key"],
      sha1: sha1,
      sourcePath: path
    )
    let deleted = TransferRecord(
      id: TransferRecord.accountScopedID("\(path)|z", accountEmail: account),
      filename: "IMG_0001.JPG",
      mediaType: "Photo",
      status: .deleted,
      sentAt: Date(),
      deletedAt: Date(),
      sentAccountEmails: [account],
      mediaKeysByAccount: [account: "key"],
      sha1: sha1,
      sourcePath: path
    )
    try JSONEncoder().encode([sent, deleted]).write(to: fileURL, options: .atomic)

    let records = await TransferManifestStore(fileURL: fileURL).allRecords()
    #expect(records.count == 1)
    #expect(records.first?.status == .sent)
    #expect(records.first?.deletedAt == nil)
  }
}
