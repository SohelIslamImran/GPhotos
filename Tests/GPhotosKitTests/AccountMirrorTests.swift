import Foundation
import Testing

@testable import GPhotosKit

@Suite("Account Mirror and Multi-Account Tests")
struct AccountMirrorTests {

  @Test("Off-main account snapshots keep Activity and cleanup counts equivalent")
  func accountBucketParity() async {
    let email = "primary@example.com"
    let records = [TransferStatus.pending, .sending, .sent, .deleted, .failed, .failed, .sent].enumerated().map { index, status in
      var record = TransferRecord(
        id: "\(index == 6 ? "other" : email)|\(index)", filename: "image-\(index).jpg", mediaType: "Photo",
        status: status, byteCount: 100)
      record.isSkipped = index == 5
      if index == 2 || index == 3 || index == 6 { record.foundInAccounts.insert(email) }
      return record
    }
    let (snapshot, found) = await Task.detached {
      (AccountTransferBuckets(records: records, accountEmail: email), SyncEngine.foundCounts(in: records))
    }.value
    let scoped = records.filter { $0.id.hasPrefix("\(email)|") && !$0.isSkipped }
    #expect(snapshot.all == scoped)
    #expect(snapshot.activityCounts == ActivityFilter.counts(in: scoped))
    #expect(snapshot.queued == scoped.filter { $0.status == .pending })
    #expect(snapshot.completedBytes == 200)
    #expect(found[email] == 2)
    #expect(AccountTransferBuckets(records: records, accountEmail: nil).all.isEmpty)
  }

  // MARK: - Keychain Account Model Round Trip

  @Test("An account list that no longer decodes reads as signed out")
  func undecodableKeychainPayloadIsEmpty() {
    let stale = Data(#"{"accounts":[{"email":"a@example.com"}],"primaryEmail":"a@example.com"}"#.utf8)
    #expect(KeychainStore.decodePayload(stale) == KeychainAccountPayload())
    #expect(KeychainStore.decodePayload(Data()) == KeychainAccountPayload())
  }

  @Test("Keychain account payload encodes and decodes round-trip preserving all properties")
  func testKeychainAccountPayloadRoundTrip() throws {
    let acc1 = GoogleAccount(
      email: "primary@example.com",
      androidId: "0123456789abcdef",
      credentialString: "oauth2_4/token1",
      mirrorEnabled: true
    )
    let acc2 = GoogleAccount(
      email: "secondary@example.com",
      androidId: "fedcba9876543210",
      credentialString: "oauth2_4/token2",
      mirrorEnabled: false
    )
    let payload = KeychainAccountPayload(
      accounts: [acc1, acc2],
      primaryEmail: "primary@example.com"
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(payload)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(KeychainAccountPayload.self, from: data)

    #expect(decoded.primaryEmail == "primary@example.com")
    #expect(decoded.accounts.count == 2)
    #expect(decoded.accounts[0].email == "primary@example.com")
    #expect(decoded.accounts[0].androidId == "0123456789abcdef")
    #expect(decoded.accounts[0].credentialString == "oauth2_4/token1")
    #expect(decoded.accounts[0].mirrorEnabled == true)

    #expect(decoded.accounts[1].email == "secondary@example.com")
    #expect(decoded.accounts[1].androidId == "fedcba9876543210")
    #expect(decoded.accounts[1].credentialString == "oauth2_4/token2")
    #expect(decoded.accounts[1].mirrorEnabled == false)
  }

  // MARK: - Work-List Selection

  @Test("Mirror work-list selection filters records accurately")
  func testMirrorWorkListSelection() {
    let primaryEmail = "primary@example.com"
    let secondaryEmail = "secondary@example.com"

    let sentPrimaryRecord = TransferRecord(
      id: TransferRecord.accountScopedID("asset-1", accountEmail: primaryEmail),
      filename: "photo1.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "key-1"],
      assetLocalIdentifier: "asset-1"
    )

    let alreadyCopiedPrimary = TransferRecord(
      id: TransferRecord.accountScopedID("asset-2", accountEmail: primaryEmail),
      filename: "photo2.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "key-2"],
      assetLocalIdentifier: "asset-2"
    )

    let secondaryCopy = TransferRecord(
      id: TransferRecord.accountScopedID("asset-2", accountEmail: secondaryEmail),
      filename: "photo2.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAccountEmails: [secondaryEmail],
      mediaKeysByAccount: [secondaryEmail: "sec-key-2"],
      assetLocalIdentifier: "asset-2"
    )

    let deletedPrimary = TransferRecord(
      id: TransferRecord.accountScopedID("asset-3", accountEmail: primaryEmail),
      filename: "photo3.jpg",
      mediaType: "image/jpeg",
      status: .deleted,
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "key-3"],
      assetLocalIdentifier: "asset-3"
    )

    let failedPrimary = TransferRecord(
      id: TransferRecord.accountScopedID("asset-4", accountEmail: primaryEmail),
      filename: "photo4.jpg",
      mediaType: "image/jpeg",
      status: .failed,
      sentAccountEmails: [],
      assetLocalIdentifier: "asset-4"
    )

    let missingSourcePrimary = TransferRecord(
      id: TransferRecord.accountScopedID("asset-5", accountEmail: primaryEmail),
      filename: "photo5.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "key-5"],
      assetLocalIdentifier: "asset-5"
    )

    let allRecords = [
      sentPrimaryRecord,
      alreadyCopiedPrimary,
      secondaryCopy,
      deletedPrimary,
      failedPrimary,
      missingSourcePrimary,
    ]

    let eligible = AccountMirror.eligiblePrimaryRecords(
      from: allRecords,
      primaryEmail: primaryEmail,
      secondaryEmail: secondaryEmail
    ) { record in
      record.assetLocalIdentifier != "asset-5"
    }

    #expect(eligible.count == 1)
    #expect(eligible.first?.assetLocalIdentifier == "asset-1")
  }

  @Test("A different version or missing motion requires a new secondary copy")
  func mirrorChecksTheCopiedVersion() {
    let editDate = Date()
    let primary = TransferRecord(
      id: "primary@example.com|asset", filename: "photo.heic", mediaType: "Live Photo", status: .sent,
      sha1: "still", assetLocalIdentifier: "asset", assetModifiedAt: editDate, pairedSourceSHA1: "motion")
    var copy = TransferRecord(copying: primary, id: "secondary@example.com|asset")
    #expect(AccountMirror.matches(copy, source: primary))
    copy.pairedSourceSHA1 = nil
    #expect(!AccountMirror.matches(copy, source: primary))
    copy.pairedSourceSHA1 = primary.pairedSourceSHA1
    copy.assetModifiedAt = editDate.addingTimeInterval(-1)
    #expect(!AccountMirror.matches(copy, source: primary))
  }

  // MARK: - Deletion Safety & Multi-Account Manifest

  @Test("Deletion stays blocked until secondary copy exists, and removing account unblocks")
  func testDeletionBlockedUntilSecondaryExistsAndUnblockedOnRemoval() async throws {
    let tmpDir = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let manifestURL = tmpDir.appendingPathComponent("manifest.json")
    let store = TransferManifestStore(fileURL: manifestURL)

    let primaryEmail = "primary@example.com"
    let secondaryEmail = "secondary@example.com"
    let localID = "photo-100"

    let primaryRecord = TransferRecord(
      id: TransferRecord.accountScopedID(localID, accountEmail: primaryEmail),
      filename: "photo-100.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAt: Date(),
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "pkey-100"],
      assetLocalIdentifier: localID
    )

    await store.upsert(primaryRecord)

    // With secondaryEmail configured in accountEmails, primary deletion must be blocked
    let eligibleBefore = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: primaryEmail,
      accountEmails: [primaryEmail, secondaryEmail]
    )
    #expect(eligibleBefore.isEmpty, "Deletion should stay blocked until secondary copy exists")

    // Now insert a secondary copy that is also sent
    let secondaryRecord = TransferRecord(
      id: TransferRecord.accountScopedID(localID, accountEmail: secondaryEmail),
      filename: "photo-100.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAt: Date(),
      sentAccountEmails: [secondaryEmail],
      mediaKeysByAccount: [secondaryEmail: "skey-100"],
      assetLocalIdentifier: localID
    )
    await store.upsert(secondaryRecord)

    // Now deletion of primary record should be eligible
    let eligibleWithCopy = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: primaryEmail,
      accountEmails: [primaryEmail, secondaryEmail]
    )
    #expect(eligibleWithCopy.count == 1)
    #expect(eligibleWithCopy.first?.assetLocalIdentifier == localID)

    // Now test unblocking when secondary has not uploaded:
    // Create another asset photo-200, sent to primary only
    let localID2 = "photo-200"
    let primaryRecord2 = TransferRecord(
      id: TransferRecord.accountScopedID(localID2, accountEmail: primaryEmail),
      filename: "photo-200.jpg",
      mediaType: "image/jpeg",
      status: .sent,
      sentAt: Date(),
      sentAccountEmails: [primaryEmail],
      mediaKeysByAccount: [primaryEmail: "pkey-200"],
      assetLocalIdentifier: localID2
    )
    await store.upsert(primaryRecord2)

    // Create a pending secondary record for localID2
    let pendingSecondary2 = TransferRecord(
      id: TransferRecord.accountScopedID(localID2, accountEmail: secondaryEmail),
      filename: "photo-200.jpg",
      mediaType: "image/jpeg",
      status: .pending,
      sentAccountEmails: [],
      assetLocalIdentifier: localID2
    )
    await store.upsert(pendingSecondary2)

    let eligible2Blocked = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: primaryEmail,
      accountEmails: [primaryEmail, secondaryEmail]
    )
    #expect(!eligible2Blocked.contains { $0.assetLocalIdentifier == localID2 })

    // Switching copying off keeps finished copies but drops the unfinished one, and the
    // account is no longer waited for.
    await store.removeRecords(forAccountEmail: secondaryEmail, keepingSent: true)
    #expect(await store.record(for: secondaryRecord.id) != nil)
    #expect(await store.record(for: pendingSecondary2.id) == nil)
    let eligibleDisabled = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: primaryEmail,
      accountEmails: [primaryEmail, secondaryEmail],
      excludingAccounts: [secondaryEmail]
    )
    #expect(eligibleDisabled.contains { $0.assetLocalIdentifier == localID2 })

    // Now remove all records for secondaryEmail
    let didRemove = await store.removeRecords(forAccountEmail: secondaryEmail)
    #expect(didRemove == true)

    // And evaluate deletion with secondary account removed from configured accounts
    let eligibleAfterRemoval = await store.eligibleForDeletion(
      delay: .immediately,
      smartDelete: false,
      accountEmail: primaryEmail,
      accountEmails: [primaryEmail]
    )
    #expect(
      eligibleAfterRemoval.contains { $0.assetLocalIdentifier == localID2 },
      "Removing account records unblocks deletion")
  }
}
