import Foundation
import Testing

@testable import GPhotosKit

@Suite("Photo library cleanup planning")
struct LibraryCleanupTests {
  private let uploadedAt = Date(timeIntervalSince1970: 1_000_000)

  private func record(
    _ assetID: String,
    bytes: Int64 = 100,
    status: TransferStatus = .sent,
    assetModifiedAt: Date? = nil,
    pairedSHA1: String? = nil,
    role: AssetResourceRole = .primary
  ) -> TransferRecord {
    let primaryID = TransferRecord.accountScopedID(assetID, accountEmail: "me@example.com")
    let id =
      switch role {
      case .primary: primaryID
      case .alternatePhoto: TransferRecord.alternatePhotoID(forPrimaryID: primaryID)
      case .uneditedOriginal: TransferRecord.uneditedOriginalID(forPrimaryID: primaryID)
      }
    return TransferRecord(
      id: id,
      filename: role == .alternatePhoto ? "\(assetID).dng" : "\(assetID).jpg",
      mediaType: "Photo",
      status: status,
      byteCount: bytes,
      sentAt: uploadedAt,
      sentAccountEmails: ["me@example.com"],
      mediaKeysByAccount: ["me@example.com": "key-\(assetID)"],
      assetLocalIdentifier: assetID,
      assetModifiedAt: assetModifiedAt ?? uploadedAt,
      pairedSourceSHA1: pairedSHA1,
      resourceRole: role
    )
  }

  private func facts(
    _ assetID: String,
    albums: Set<String> = [],
    favorite: Bool = false,
    modified: Date? = nil,
    live: Bool = false,
    unuploadedResources: Bool = false,
    alternatePhoto: Bool = false,
    needsOriginal: Bool = false,
    burst: String? = nil,
    canDelete: Bool = true
  ) -> LibraryAssetFacts {
    LibraryAssetFacts(
      localIdentifier: assetID,
      albumIDs: albums,
      isFavorite: favorite,
      modificationDate: modified ?? uploadedAt,
      isLivePhoto: live,
      hasUnuploadedResources: unuploadedResources,
      hasAlternatePhoto: alternatePhoto,
      needsUneditedOriginal: needsOriginal,
      burstIdentifier: burst,
      canDelete: canDelete
    )
  }

  private func plan(
    _ records: [TransferRecord],
    _ facts: [LibraryAssetFacts],
    bursts: [String: Set<String>] = [:],
    protectedAlbums: Set<String> = [],
    protectsFavorites: Bool = true,
    bytesNeeded: Int64? = nil
  ) -> [String] {
    planned(records, facts, bursts: bursts, protectedAlbums: protectedAlbums, protectsFavorites: protectsFavorites, bytesNeeded: bytesNeeded)
      .compactMap(\.assetLocalIdentifier)
  }

  private func planned(
    _ records: [TransferRecord],
    _ facts: [LibraryAssetFacts],
    bursts: [String: Set<String>] = [:],
    protectedAlbums: Set<String> = [],
    protectsFavorites: Bool = true,
    bytesNeeded: Int64? = nil
  ) -> [TransferRecord] {
    LibraryCleanupPlanner.plan(
      records: records,
      facts: Dictionary(uniqueKeysWithValues: facts.map { ($0.localIdentifier, $0) }),
      burstMembers: bursts,
      protectedAlbumIDs: protectedAlbums,
      protectsFavorites: protectsFavorites,
      bytesNeeded: bytesNeeded
    )
  }

  @Test("An asset no longer in the library is skipped")
  func missingAssetIsSkipped() {
    #expect(plan([record("a"), record("gone")], [facts("a")]) == ["a"])
  }

  @Test("A record that is not uploaded is never planned")
  func unsentRecordIsSkipped() {
    #expect(plan([record("a", status: .pending), record("b", status: .deleted)], [facts("a"), facts("b")]).isEmpty)
  }

  @Test("Membership in any protected album keeps the asset")
  func protectedAlbumIsSkipped() {
    let result = plan(
      [record("a"), record("b")],
      [facts("a", albums: ["trip", "family"]), facts("b", albums: ["trip"])],
      protectedAlbums: ["family"]
    )
    #expect(result == ["b"])
  }

  @Test("Favorites are kept only while protected")
  func favoritesFollowTheSetting() {
    let records = [record("a"), record("b")]
    let library = [facts("a", favorite: true), facts("b")]
    #expect(plan(records, library, protectsFavorites: true) == ["b"])
    #expect(plan(records, library, protectsFavorites: false) == ["a", "b"])
  }

  @Test("An asset edited after its upload is kept; sub-second drift is not an edit")
  func editedAssetIsSkipped() {
    let result = plan(
      [record("edited"), record("drift"), record("same")],
      [
        facts("edited", modified: uploadedAt.addingTimeInterval(60)),
        facts("drift", modified: uploadedAt.addingTimeInterval(0.5)),
        facts("same"),
      ]
    )
    #expect(result == ["drift", "same"])
  }

  @Test("A record without an uploaded version cannot be compared, so it is kept")
  func unknownVersionIsSkipped() {
    var unknown = record("a")
    unknown.assetModifiedAt = nil
    #expect(plan([unknown], [facts("a")]).isEmpty)
  }

  @Test("A Live Photo is removed only when its motion half was uploaded too")
  func livePhotoNeedsPairedUpload() {
    let result = plan(
      [record("still-only"), record("paired", pairedSHA1: "c2hhMQ==")],
      [facts("still-only", live: true), facts("paired", live: true)]
    )
    #expect(result == ["paired"])
  }

  @Test("An asset with a resource that was never uploaded, like a RAW pair, is kept")
  func unuploadedResourcesAreSkipped() {
    let result = plan([record("raw"), record("jpeg")], [facts("raw", unuploadedResources: true), facts("jpeg")])
    #expect(result == ["jpeg"])
  }

  @Test("A RAW+JPEG asset without a RAW record is kept")
  func rawWithoutRecordIsSkipped() {
    let result = plan([record("pair"), record("a")], [facts("pair", alternatePhoto: true), facts("a")])
    #expect(result == ["a"])
  }

  @Test("A RAW+JPEG asset goes, with both records, once its RAW is uploaded and eligible")
  func rawWithEligibleRecordIsIncluded() {
    let primary = record("pair")
    let raw = record("pair", role: .alternatePhoto)
    let result = planned([primary, raw, record("a")], [facts("pair", alternatePhoto: true), facts("a")])
    #expect(result.map(\.id) == [primary.id, raw.id, record("a").id])
  }

  @Test("A RAW+JPEG asset is kept while its RAW is still pending")
  func rawPendingIsSkipped() {
    let result = plan(
      [record("pair"), record("pair", status: .pending, role: .alternatePhoto)],
      [facts("pair", alternatePhoto: true)]
    )
    #expect(result.isEmpty)
  }

  @Test("A RAW record edited since its upload keeps the whole asset")
  func rawEditedIsSkipped() {
    let result = plan(
      [record("pair", assetModifiedAt: uploadedAt.addingTimeInterval(120)), record("pair", role: .alternatePhoto)],
      [facts("pair", modified: uploadedAt.addingTimeInterval(120), alternatePhoto: true)]
    )
    #expect(result.isEmpty)
  }

  @Test("A RAW record alone, without its primary, plans nothing")
  func rawWithoutPrimaryIsSkipped() {
    #expect(plan([record("pair", role: .alternatePhoto)], [facts("pair", alternatePhoto: true)]).isEmpty)
  }

  @Test("The Live Photo rule applies to the primary, not to the RAW")
  func liveRuleIgnoresRaw() {
    let result = plan(
      [record("pair", pairedSHA1: "c2hhMQ=="), record("pair", role: .alternatePhoto)],
      [facts("pair", live: true, alternatePhoto: true)]
    )
    #expect(result == ["pair", "pair"])
  }

  @Test("An edited asset is kept until its original is uploaded and eligible")
  func editedAssetWaitsForOriginal() {
    #expect(plan([record("edit")], [facts("edit", needsOriginal: true)]).isEmpty)
    #expect(
      plan(
        [record("edit"), record("edit", status: .pending, role: .uneditedOriginal)],
        [facts("edit", needsOriginal: true)]
      ).isEmpty)
    let primary = record("edit")
    let original = record("edit", role: .uneditedOriginal)
    #expect(planned([primary, original], [facts("edit", needsOriginal: true)]).map(\.id) == [primary.id, original.id])
    // With originals off, the edit alone is enough.
    #expect(plan([record("edit")], [facts("edit")]) == ["edit"])
  }

  @Test("A new edit does not make the uploaded original out of date")
  func originalSurvivesLaterEdit() {
    let later = uploadedAt.addingTimeInterval(120)
    let result = plan(
      [record("edit", assetModifiedAt: later), record("edit", role: .uneditedOriginal)],
      [facts("edit", modified: later, needsOriginal: true)]
    )
    #expect(result == ["edit", "edit"])
  }

  @Test("An edited Live Photo's original needs its motion too")
  func liveOriginalNeedsMotion() {
    let live = facts("edit", live: true, needsOriginal: true)
    #expect(plan([record("edit", pairedSHA1: "c2hhMQ=="), record("edit", role: .uneditedOriginal)], [live]).isEmpty)
    #expect(
      plan(
        [record("edit", pairedSHA1: "c2hhMQ=="), record("edit", pairedSHA1: "c2hhMg==", role: .uneditedOriginal)],
        [live]
      ) == ["edit", "edit"])
  }

  @Test("A burst goes when every frame is eligible")
  func wholeBurstIsIncluded() {
    let frames = ["f1", "f2", "f3"]
    let result = plan(
      frames.map { record($0) } + [record("a")],
      frames.map { facts($0, burst: "b") } + [facts("a")],
      bursts: ["b": Set(frames)]
    )
    #expect(result == ["f1", "f2", "f3", "a"])
  }

  @Test("A burst with a frame missing from the plan is kept whole")
  func burstMissingFrameIsSkipped() {
    let result = plan(
      [record("f1"), record("f2"), record("a")],
      [facts("f1", burst: "b"), facts("f2", burst: "b"), facts("a")],
      bursts: ["b": ["f1", "f2", "f3"]]
    )
    #expect(result == ["a"])
  }

  @Test("A burst with one ineligible frame is kept whole")
  func burstIneligibleFrameIsSkipped() {
    let result = plan(
      [record("f1"), record("f2"), record("f3"), record("a")],
      [facts("f1", burst: "b"), facts("f2", favorite: true, burst: "b"), facts("f3", burst: "b"), facts("a")],
      bursts: ["b": ["f1", "f2", "f3"]]
    )
    #expect(result == ["a"])
  }

  @Test("A burst whose frames are unknown is kept")
  func burstWithoutMembersIsSkipped() {
    #expect(plan([record("f1"), record("a")], [facts("f1", burst: "b"), facts("a")]) == ["a"])
  }

  @Test("A byte target never splits a burst")
  func bytesNeededKeepsBurstWhole() {
    let result = plan(
      [record("f1"), record("f2"), record("a")],
      [facts("f1", burst: "b"), facts("f2", burst: "b"), facts("a")],
      bursts: ["b": ["f1", "f2"]],
      bytesNeeded: 50
    )
    #expect(result == ["f1", "f2"])
  }

  @Test("A record written before resource roles decodes as the primary")
  func resourceRoleDefaultsToPrimary() throws {
    let encoded = try JSONEncoder().encode(record("a", role: .alternatePhoto))
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["resourceRole"] as? String == "alternatePhoto")
    object.removeValue(forKey: "resourceRole")
    let legacy = try JSONDecoder().decode(TransferRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.resourceRole == .primary)
    #expect(legacy.assetLocalIdentifier == "a")

    let roundTripped = try JSONDecoder().decode(TransferRecord.self, from: encoded)
    #expect(roundTripped == record("a", role: .alternatePhoto))
  }

  @Test("A record written before the RAW lookup decodes as unchecked")
  func resourcesCheckedDefaultsToFalse() throws {
    var checked = record("a")
    checked.resourcesChecked = true
    let encoded = try JSONEncoder().encode(checked)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["resourcesChecked"] as? Bool == true)
    object.removeValue(forKey: "resourcesChecked")
    let legacy = try JSONDecoder().decode(TransferRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!legacy.resourcesChecked)
    #expect(try JSONDecoder().decode(TransferRecord.self, from: encoded) == checked)
  }

  @Test("An asset the library will not delete is not planned")
  func undeletableAssetIsSkipped() {
    #expect(plan([record("synced"), record("a")], [facts("synced", canDelete: false), facts("a")]) == ["a"])
  }

  @Test("Input order is preserved")
  func orderIsPreserved() {
    let ids = ["c", "a", "b"]
    #expect(plan(ids.map { record($0) }, ids.map { facts($0) }) == ids)
  }

  @Test("A byte target stops the plan once it is reached")
  func bytesNeededStopsEarly() {
    let records = [record("a", bytes: 100), record("b", bytes: 100), record("c", bytes: 100)]
    let library = records.compactMap(\.assetLocalIdentifier).map { facts($0) }
    #expect(plan(records, library, bytesNeeded: 150) == ["a", "b"])
    #expect(plan(records, library, bytesNeeded: 100) == ["a"])
    #expect(plan(records, library, bytesNeeded: 0).isEmpty)
    #expect(plan(records, library, bytesNeeded: nil) == ["a", "b", "c"])
  }

  @Test("Skipped assets do not count toward the byte target")
  func skippedAssetsDoNotCount() {
    let records = [record("fav", bytes: 500), record("a", bytes: 100), record("b", bytes: 100)]
    let library = [facts("fav", favorite: true), facts("a"), facts("b")]
    #expect(plan(records, library, bytesNeeded: 150) == ["a", "b"])
  }

  @Test("New protection settings decode with safe defaults")
  func protectionSettingsDefaults() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(settings.protectedAlbumIDs.isEmpty)
    #expect(settings.protectsFavorites)

    var changed = AppSettings()
    changed.protectedAlbumIDs = ["album-1"]
    changed.protectsFavorites = false
    let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
    #expect(roundTripped == changed)
  }
}
