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
  /// The named people indexed last, so an unchanged list isn't indexed again.
  private var indexedPeople: [String: String]?

  init(store: LibraryIndexStore) {
    self.store = store
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
    await syncPeople()
    guard snapshot.inputs.isComplete, isBrowsed(snapshot.cloudLibrary?.accountEmail) else { return }
    let generation = self.generation
    let snapshot = snapshot.unfiltered()
    guard let stamps = try? await store.analyzedStamps(), let people = try? await store.personNamesByItem(),
      let stored = try? await store.siriDigests()
    else { return }
    // Places and captions are part of what changes an item, so they're read for all of them.
    let googleKeys = snapshot.cloud.map(\.mediaKey)
    let details = googleKeys.isEmpty ? [:] : await snapshot.cloudLibrary?.siriDetails(mediaKeys: googleKeys) ?? [:]
    let bases = SiriItemRecord.records(from: snapshot, facts: [:], googleDetails: details)
    var keys: [String: Int64] = [:]
    var basesByID: [String: SiriItemRecord] = [:]
    for base in bases {
      keys[base.id] = Self.changeKey(base, analyzedAt: stamps[base.id], people: people[base.id] ?? [])
      basesByID[base.id] = base
    }
    let plan = Plan(current: bases.map { ($0.id, keys[$0.id] ?? 0) }, stored: stored)

    for start in stride(from: 0, to: plan.removed.count, by: Self.batchSize) {
      guard generation == self.generation else { return }
      let chunk = Array(plan.removed[start..<min(start + Self.batchSize, plan.removed.count)])
      do {
        try await Self.delete(chunk)
        try await store.deleteSiri(chunk)
      } catch {
        break
      }
    }
    guard !plan.changed.isEmpty else { return }

    // The text index can't be read by id, so it's read once for the whole pass.
    let texts = (try? await store.siriTexts(for: Set(plan.changed))) ?? [:]
    for start in stride(from: 0, to: plan.changed.count, by: Self.batchSize) {
      while LibraryIndexer.pauseReason() != nil {
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled { return }
      }
      guard !Task.isCancelled, generation == self.generation else { return }
      let ids = Array(plan.changed[start..<min(start + Self.batchSize, plan.changed.count)])
      let labels = (try? await store.siriLabels(for: ids)) ?? [:]
      let records = ids.compactMap { id -> SiriItemRecord? in
        guard var record = basesByID[id] else { return nil }
        record.labels = labels[id] ?? []
        record.text = texts[id] ?? ""
        record.people = people[id].map { Array(Set($0)).sorted() } ?? []
        return record
      }
      // The account may have changed while the facts were read.
      guard generation == self.generation else { return }
      do {
        // Indexed first: a failed batch keeps its old key and is tried on the next pass.
        try await Self.index(records.map(PhotoEntity.init))
        try await store.saveSiri(records.map { ($0, keys[$0.id] ?? 0) })
      } catch {
        return
      }
    }
  }

  // MARK: Accounts

  private static let accountKey = "SiriIndexedAccount"
  /// Bumped when the browsed account changes, so a pass under way stops.
  private var generation = 0

  /// Whether `email` is the account the index holds Google Photos items for (stored as ""
  /// when signed out). Before the app has said, any is.
  private func isBrowsed(_ email: String?) -> Bool {
    guard let indexed = UserDefaults.standard.string(forKey: Self.accountKey) else { return true }
    return indexed == (email ?? "")
  }

  /// Another account is browsed, or none: the previous account's Google Photos items
  /// leave Siri and Spotlight now, not on a later pass, and a pass under way stops. Call
  /// it only when the accounts were read; a keychain that can't be read isn't a sign-out.
  public func browsedAccountChanged(to email: String?) async {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: Self.accountKey)
    guard previous != (email ?? "") else { return }
    generation &+= 1
    defaults.set(email ?? "", forKey: Self.accountKey)
    let ids = ((try? await store.allSiriIDs()) ?? []).filter { $0.hasPrefix("g:") }
    for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
      let chunk = Array(ids[start..<min(start + Self.batchSize, ids.count)])
      do {
        try await Self.delete(chunk)
        try await store.deleteSiri(chunk)
      } catch {
        // Left for the next pass, which removes what isn't in the Library.
        return
      }
    }
  }

  // MARK: People

  /// Named people, so Siri knows who "Mum" is in "photos of Mum at the beach".
  private func syncPeople() async {
    guard let people = try? await store.people().filter({ $0.name?.isEmpty == false }) else { return }
    let entities = people.map(PersonEntity.init)
    let current = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, "\($0.name) \($0.photoCount)") })
    guard current != indexedPeople else { return }
    do {
      try await Self.deleteAll(PersonEntity.self)
      if !entities.isEmpty { try await Self.index(entities) }
      indexedPeople = current
    } catch {
      indexedPeople = nil
    }
  }

  /// Indexes the named people again, when Spotlight asks (its index was lost or rebuilt).
  func reindexPeople() async {
    indexedPeople = nil
    await syncPeople()
  }

  /// Indexes stored records again, when Spotlight asks (its index was lost or rebuilt).
  func reindex(ids: [String]?) async throws {
    let all: [String]
    if let ids { all = ids } else { all = try await store.allSiriIDs() }
    for start in stride(from: 0, to: all.count, by: Self.batchSize) {
      let records = try await store.siriRecords(ids: Array(all[start..<min(start + Self.batchSize, all.count)]))
      try await Self.index(records.map(PhotoEntity.init))
    }
  }

  // The index isn't Sendable: each call makes its own handle, outside the actor.
  private nonisolated static func index(_ entities: [some IndexedEntity]) async throws {
    try await CSSearchableIndex(name: indexName).indexAppEntities(entities, priority: 0)
  }

  private nonisolated static func deleteAll<Entity: IndexedEntity>(_ type: Entity.Type) async throws {
    try await CSSearchableIndex(name: indexName).deleteAppEntities(ofType: type)
  }

  private nonisolated static func delete(_ ids: [String]) async throws {
    try await CSSearchableIndex(name: indexName).deleteAppEntities(identifiedBy: ids, ofType: PhotoEntity.self)
  }
}
