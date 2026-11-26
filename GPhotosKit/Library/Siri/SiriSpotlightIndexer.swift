import AppIntents
import CoreSpotlight
import Foundation

/// Keeps the Spotlight semantic index, which Siri searches, in step with the Library: every
/// item as a `PhotoEntity` with what on-device analysis found in it. A pass re-indexes only
/// items whose metadata, analysis or people changed and removes items that left the Library
/// (including a removed account's Google Photos items).
public actor SiriSpotlightIndexer {
  static let indexName = "Library"
  private static let batchSize = 500
  private let store: LibraryIndexStore
  private let backend: Backend
  private let defaults: UserDefaults
  private let onAccountChanged: (@Sendable (String?) async -> Void)?
  /// The named people indexed last, so an unchanged list isn't indexed again.
  private var indexedPeople: [String: String]?
  private var indexedPeopleVersion: Int64?
  private var lastSyncedFingerprint: SyncFingerprint?
  private var cachedDetails: (cloud: ObjectIdentifier, revision: Int, values: [String: RemoteSiriDetails])?

  struct Backend: Sendable {
    var indexPhotos: @Sendable ([PhotoEntity]) async throws -> Void
    var deletePhotos: @Sendable ([String]) async throws -> Void
    var indexPeople: @Sendable ([PersonEntity]) async throws -> Void
    var deleteAllPeople: @Sendable () async throws -> Void

    static let spotlight = Backend(
      indexPhotos: { try await CSSearchableIndex(name: indexName).indexAppEntities($0, priority: 0) },
      deletePhotos: {
        try await CSSearchableIndex(name: indexName).deleteAppEntities(identifiedBy: $0, ofType: PhotoEntity.self)
      },
      indexPeople: { try await CSSearchableIndex(name: indexName).indexAppEntities($0, priority: 0) },
      deleteAllPeople: { try await CSSearchableIndex(name: indexName).deleteAppEntities(ofType: PersonEntity.self) })
  }

  /// Library tokens that detect device-side metadata edits (`deviceBadgeToken`), timeline
  /// changes, and mirror updates so unchanged passes skip whole-library planning.
  struct SyncContext: Equatable, Sendable {
    var libraryReloadToken: Int
    var deviceReloadToken: Int
    var deviceBadgeToken: Int
    var cloudRevision: Int
  }

  private struct SyncFingerprint: Equatable, Sendable {
    var cloud: ObjectIdentifier?
    var context: SyncContext
    var analysisVersion: Int64
    var peopleVersion: Int64
  }

  init(
    store: LibraryIndexStore, backend: Backend = .spotlight,
    defaultsSuite: String? = nil, onAccountChanged: (@Sendable (String?) async -> Void)? = nil
  ) {
    self.store = store
    self.backend = backend
    defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.onAccountChanged = onAccountChanged
  }

  /// What one pass will change, from each item's key and the keys stored last time.
  struct Plan: Equatable {
    var changed: [String]
    var removed: [String]

    init(current: [(id: String, key: Int64)], stored: [String: Int64]) {
      var seen = Set<String>()
      changed = []
      for item in current where seen.insert(item.id).inserted && stored[item.id] != item.key {
        changed.append(item.id)
      }
      removed = stored.keys.filter { !seen.contains($0) }.sorted()
    }
  }

  /// The key that says an item needs indexing again: its metadata, when it was last
  /// analyzed and the names of the people in it.
  static func changeKey(_ base: SiriItemRecord, analyzedAt: Double?, people: [String]) -> Int64 {
    base.digest(including: [analyzedAt.map { String($0) } ?? ""] + people.sorted())
  }

  /// Brings the index up to date with `snapshot`, all of the Library whatever its filter.
  /// A snapshot taken before the Library loaded (at launch, or just after switching
  /// accounts), or for another account than the one browsed now, is skipped: it would
  /// remove items that are only not read yet, or bring back a removed account's.
  public func sync(_ snapshot: UnifiedLibraryModel.IndexSnapshot) async {
    await sync(snapshot, context: nil)
  }

  /// Returns whether a full Spotlight planning pass ran (false when skipped or deferred).
  @discardableResult
  func sync(_ snapshot: UnifiedLibraryModel.IndexSnapshot, context: SyncContext?) async -> Bool {
    let generation = self.generation
    await accountEviction?.value
    await syncPeople()
    guard snapshot.inputs.isComplete, generation == self.generation, isBrowsed(snapshot.cloudLibrary?.accountEmail)
    else { return false }
    let cloudInfo: (revision: Int, deferringInitialSync: Bool, isRetired: Bool)?
    if let cloud = snapshot.cloudLibrary {
      cloudInfo = await MainActor.run {
        (cloud.revision, cloud.isSyncing && !cloud.syncState.initialSyncDone, cloud.isRetired)
      }
    } else {
      cloudInfo = nil
    }
    // Wait until the first Google Photos sync finishes rather than replanning on every page;
    // a retired library must never be indexed or cached.
    if cloudInfo?.deferringInitialSync == true || cloudInfo?.isRetired == true { return false }

    let analysisVersion = await store.analysisWriteVersion()
    let peopleVersion = (try? await store.peopleDirtyVersion()) ?? -1
    let fingerprint = context.map {
      SyncFingerprint(
        cloud: snapshot.cloudLibrary.map(ObjectIdentifier.init), context: $0, analysisVersion: analysisVersion, peopleVersion: peopleVersion
      )
    }
    if let fingerprint, fingerprint == lastSyncedFingerprint { return false }

    let snapshot = snapshot.unfiltered()
    guard let stamps = try? await store.analyzedStamps(), let people = try? await store.personNamesByItem(),
      let stored = try? await store.siriDigests()
    else { return false }
    // Places and captions are part of what changes an item; reuse them until the snapshot's mirror revision moves.
    let details: [String: RemoteSiriDetails]
    if let cloud = snapshot.cloudLibrary, let cloudInfo, !snapshot.cloud.isEmpty {
      let detailsRevision = context?.cloudRevision ?? cloudInfo.revision
      let identity = ObjectIdentifier(cloud)
      if let cached = cachedDetails, cached.cloud == identity, cached.revision == detailsRevision {
        details = cached.values
      } else {
        guard let fetched = try? await cloud.store.siriDetails() else { return false }
        let stillActive = await MainActor.run { !cloud.isRetired }
        if !Task.isCancelled, stillActive, generation == self.generation {
          cachedDetails = (identity, detailsRevision, fetched)
        }
        details = fetched
      }
    } else {
      details = [:]
    }
    // Stream over entries once instead of keeping 100k full `SiriItemRecord`s and dictionaries alive.
    var seen = Set<String>(minimumCapacity: snapshot.entries.count)
    var changed: [(id: String, position: Int, key: Int64)] = []
    for position in snapshot.entries.indices {
      guard let base = SiriItemRecord.baseRecord(at: position, in: snapshot, googleDetails: details) else { continue }
      guard seen.insert(base.id).inserted else { continue }
      let key = Self.changeKey(base, analyzedAt: stamps[base.id], people: people[base.id] ?? [])
      if stored[base.id] != key { changed.append((base.id, position, key)) }
    }
    let removed = stored.keys.filter { !seen.contains($0) }.sorted()

    var succeeded = true
    for start in stride(from: 0, to: removed.count, by: Self.batchSize) {
      guard !Task.isCancelled, generation == self.generation else { return true }
      let chunk = Array(removed[start..<min(start + Self.batchSize, removed.count)])
      do {
        try await enqueue { indexer in
          guard generation == indexer.generation else { return }
          try await indexer.deletePhotos(chunk)
        }.value
      } catch {
        succeeded = false
        break
      }
    }
    if changed.isEmpty {
      if succeeded, !Task.isCancelled, generation == self.generation { lastSyncedFingerprint = fingerprint }
      return true
    }

    // The text index can't be read by id, so it's read once for the whole pass.
    let texts = (try? await store.siriTexts(for: Set(changed.map(\.id)))) ?? [:]
    for start in stride(from: 0, to: changed.count, by: Self.batchSize) {
      while LibraryIndexer.pauseReason() != nil {
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled { return true }
      }
      guard !Task.isCancelled, generation == self.generation else { return true }
      let slice = changed[start..<min(start + Self.batchSize, changed.count)]
      let ids = slice.map(\.id)
      let labels = (try? await store.siriLabels(for: ids)) ?? [:]
      var records: [(record: SiriItemRecord, key: Int64)] = []
      records.reserveCapacity(slice.count)
      for item in slice {
        guard var record = SiriItemRecord.baseRecord(at: item.position, in: snapshot, googleDetails: details) else {
          continue
        }
        record.labels = labels[item.id] ?? []
        record.text = texts[item.id] ?? ""
        record.people = people[item.id].map { Array(Set($0)).sorted() } ?? []
        records.append((record, item.key))
      }
      // The account may have changed while the facts were read.
      guard generation == self.generation else { return true }
      do {
        // Indexed first: a failed batch keeps its old key and is tried on the next pass.
        let cloud = snapshot.cloudLibrary
        try await enqueue { [records] indexer in
          guard cloud?.isIndexingCurrent != false else { return }
          guard generation == indexer.generation else { return }
          let locked = LibraryIndexStore.lockedIDs(among: records.lazy.map { $0.record.id })
          let visible = records.filter { !locked.contains($0.record.id) }
          guard !visible.isEmpty else { return }
          let cloudIDs = visible.lazy.map { $0.record.id }.filter { $0.hasPrefix("g:") }
          indexer.unrecordedCloudIDs.formUnion(cloudIDs)
          try await indexer.backend.indexPhotos(visible.map { PhotoEntity($0.record) })
          guard generation == indexer.generation else { return }
          let saved = try await indexer.store.saveSiri(visible, cloud: cloud)
          indexer.unrecordedCloudIDs.subtract(saved)
        }.value
      } catch {
        return true
      }
    }
    if succeeded, !Task.isCancelled, generation == self.generation { lastSyncedFingerprint = fingerprint }
    return true
  }

  // MARK: Locked Folder

  private(set) var lastWork: Task<Void, Never>?

  /// Photos sent to Spotlight without a committed Siri record still need account eviction.
  private var unrecordedCloudIDs = Set<String>()

  /// Enqueue before suspending so eviction is ordered with every publication already waiting.
  private func enqueue(
    _ work: @escaping @Sendable (isolated SiriSpotlightIndexer) async throws -> Void
  ) -> Task<Void, Error> {
    let previous = lastWork
    let task = Task {
      await previous?.value
      try await work(self)
    }
    lastWork = Task { _ = await task.result }
    return task
  }

  private func deletePhotos(_ ids: [String]) async throws {
    try await backend.deletePhotos(ids)
    try await store.deleteSiri(ids)
    unrecordedCloudIDs.subtract(ids)
  }

  /// Items moved to the Locked Folder leave the on-device index, Siri and Spotlight now, not
  /// on a later pass. False when something couldn't be removed and is to be tried again.
  func purge(lockedKeys keys: Set<String>) async -> Bool {
    let ids = keys.map(LibraryIndexer.searchID(cloudMediaKey:)).sorted()
    lastSyncedFingerprint = nil
    for key in keys { cachedDetails?.values[key] = nil }
    FaceCropCache.removeAll()
    var succeeded = true
    // Clear local metadata first, even when a Spotlight request is still in flight.
    for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
      let chunk = Array(ids[start..<min(start + Self.batchSize, ids.count)])
      do { try await store.purge(ids: chunk) } catch { succeeded = false }
    }
    NotificationCenter.default.post(name: LibraryIndexStore.didPurgeCloudIndex, object: store)
    for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
      let chunk = Array(ids[start..<min(start + Self.batchSize, ids.count)])
      do {
        try await enqueue { indexer in try await indexer.deletePhotos(chunk) }.value
      } catch {
        succeeded = false
      }
    }
    await syncPeople()
    return succeeded
  }

  // MARK: Accounts

  private static let accountKey = "SiriIndexedAccount"
  /// Bumped when the browsed account changes, so a pass under way stops.
  private var generation = 0
  private var accountEviction: Task<Void, Never>?
  private var browsedAccount: String?

  /// Whether `email` is the account the index holds Google Photos items for (stored as ""
  /// when signed out). Before the app has said, any is.
  private func isBrowsed(_ email: String?) -> Bool {
    guard let indexed = browsedAccount ?? defaults.string(forKey: Self.accountKey) else { return true }
    return indexed == (email ?? "")
  }

  /// Another account is browsed, or none: the previous account's Google Photos items
  /// leave Siri and Spotlight now, not on a later pass, and a pass under way stops. Call
  /// it only when the accounts were read; a keychain that can't be read isn't a sign-out.
  public func browsedAccountChanged(to email: String?, waitForEviction: Bool = true) async {
    let account = email ?? ""
    let previous = browsedAccount ?? defaults.string(forKey: Self.accountKey)
    let signedOutAtStartup = browsedAccount == nil && email == nil
    browsedAccount = account
    guard signedOutAtStartup || previous != account else { return }
    generation &+= 1
    let generation = self.generation
    lastSyncedFingerprint = nil
    cachedDetails = nil
    indexedPeople = nil
    indexedPeopleVersion = nil
    let eviction = enqueue { indexer in
      if try await indexer.store.prune(keeping: [], device: false, folder: false, cloud: true) > 0 {
        NotificationCenter.default.post(name: LibraryIndexStore.didPurgeCloudIndex, object: indexer.store)
      }
      // The old account's analysis is gone: a Spotlight error below mustn't make the next
      // launch prune the new account's. Its leftover entries go with the next pass.
      if !account.isEmpty, indexer.generation == generation { indexer.defaults.set(account, forKey: Self.accountKey) }
      let stored = try await indexer.store.allSiriIDs().filter { $0.hasPrefix("g:") }
      let ids = indexer.unrecordedCloudIDs.union(stored).sorted()
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        // A failure leaves the IDs for the next pass.
        try await indexer.deletePhotos(Array(ids[start..<min(start + Self.batchSize, ids.count)]))
      }
      // A sign-out is kept pending until Spotlight's entries are gone too.
      if indexer.generation == generation { indexer.defaults.set(account, forKey: Self.accountKey) }
    }
    let completion = lastWork
    accountEviction = completion
    let finish = Task {
      await onAccountChanged?(email)
      _ = await eviction.result
      if accountEviction == completion {
        accountEviction = nil
        await syncPeople()
      }
    }
    if waitForEviction { await finish.value }
  }

  func waitForAccountEviction() async {
    await accountEviction?.value
  }

  // MARK: People

  /// Named people, so Siri knows who "Mum" is in "photos of Mum at the beach".
  private func syncPeople() async {
    let generation = self.generation
    guard let version = try? await store.peopleDirtyVersion() else { return }
    if indexedPeopleVersion == version { return }
    guard let people = try? await store.namedPeople() else { return }
    let entities = people.map(PersonEntity.init)
    let current = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, "\($0.name) \($0.photoCount)") })
    if current == indexedPeople {
      indexedPeopleVersion = version
      return
    }
    try? await enqueue { indexer in
      guard generation == indexer.generation, indexer.indexedPeopleVersion != version,
        try await indexer.store.peopleDirtyVersion() == version, generation == indexer.generation
      else { return }
      do {
        try await indexer.backend.deleteAllPeople()
        guard generation == indexer.generation else { return }
        if !entities.isEmpty { try await indexer.backend.indexPeople(entities) }
        indexer.indexedPeople = current
        indexer.indexedPeopleVersion = version
      } catch {
        indexer.indexedPeople = nil
        indexer.indexedPeopleVersion = nil
      }
    }.value
  }

  /// Indexes the named people again, when Spotlight asks (its index was lost or rebuilt).
  func reindexPeople() async {
    indexedPeople = nil
    indexedPeopleVersion = nil
    await syncPeople()
  }

  /// Indexes stored records again, when Spotlight asks (its index was lost or rebuilt).
  func reindex(ids: [String]?) async throws {
    let generation = self.generation
    try await enqueue { indexer in
      guard generation == indexer.generation else { return }
      let all: [String]
      if let ids { all = ids } else { all = try await indexer.store.allSiriIDs() }
      for start in stride(from: 0, to: all.count, by: Self.batchSize) {
        let records = try await indexer.store.siriRecords(ids: Array(all[start..<min(start + Self.batchSize, all.count)]))
        let browsed = await SiriLibrary.shared.excludingLocked(records)
        guard generation == indexer.generation else { return }
        let locked = LibraryIndexStore.lockedIDs(among: browsed.lazy.map(\.id))
        let visible = browsed.filter { !locked.contains($0.id) }
        if !visible.isEmpty { try await indexer.backend.indexPhotos(visible.map(PhotoEntity.init)) }
      }
    }.value
  }
}
