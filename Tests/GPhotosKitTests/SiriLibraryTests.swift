import Foundation
import Testing

@testable import GPhotosKit

@Suite("Siri and Spotlight")
struct SiriLibraryTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func makeStore() -> LibraryIndexStore {
    LibraryIndexStore(directory: TestTemporaryDirectory.root.appending(path: "Siri-\(UUID().uuidString)"))
  }

  // MARK: Queries

  @Test("Words that say what to show are dropped; what's in the photo is kept")
  func queryTerms() {
    let query = SiriSearchQuery("Show me photos of my dog at the beach", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms == ["dog", "beach"])
    #expect(query.period == nil)
    #expect(!query.videosOnly)
    #expect(!query.favoritesOnly)
  }

  @Test("A month and year narrow to that month")
  func queryMonthAndYear() {
    let query = SiriSearchQuery("videos from July 2024", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms.isEmpty)
    #expect(query.videosOnly)
    #expect(query.period == date(2024, 7, 1)..<date(2024, 8, 1))
  }

  @Test("A year alone is the whole year; favorites are a filter")
  func queryYear() {
    let query = SiriSearchQuery("favorite sunsets 2019", now: date(2026, 11, 8), calendar: calendar)
    #expect(query.terms == ["sunsets"])
    #expect(query.favoritesOnly)
    #expect(query.period == date(2019, 1, 1)..<date(2020, 1, 1))
  }

  @Test("A month alone is its latest occurrence")
  func queryMonthOnly() {
    let december = SiriSearchQuery("snow in december", now: date(2026, 11, 8), calendar: calendar)
    #expect(december.period == date(2025, 12, 1)..<date(2026, 1, 1))
    let march = SiriSearchQuery("march", now: date(2026, 11, 8), calendar: calendar)
    #expect(march.period == date(2026, 3, 1)..<date(2026, 4, 1))
  }

  @Test("Relative periods: today, yesterday, last month, this year")
  func queryRelative() {
    let now = date(2026, 11, 8).addingTimeInterval(15 * 3600)
    #expect(SiriSearchQuery("today", now: now, calendar: calendar).period == date(2026, 11, 8)..<date(2026, 11, 9))
    #expect(SiriSearchQuery("yesterday", now: now, calendar: calendar).period == date(2026, 11, 7)..<date(2026, 11, 8))
    let lastMonth = SiriSearchQuery("receipts from last month", now: now, calendar: calendar)
    #expect(lastMonth.terms == ["receipts"])
    #expect(lastMonth.period == date(2026, 10, 1)..<date(2026, 11, 1))
    #expect(
      SiriSearchQuery("this year", now: now, calendar: calendar).period == date(2026, 1, 1)..<date(2027, 1, 1))
  }

  @Test("Only filler words leave nothing to search")
  func queryEmpty() {
    #expect(SiriSearchQuery("show me my photos", now: date(2026, 11, 8), calendar: calendar).isEmpty)
    #expect(!SiriSearchQuery("google", now: date(2026, 11, 8), calendar: calendar).isEmpty)
  }

  @Test("Results found by more of the words come first, ties in the order found")
  func ranking() {
    let ranked = SiriLibrary.rankedByMatches([["a", "b", "c"], ["c", "d"], ["c", "b", "b"]])
    #expect(ranked == ["c", "b", "a", "d"])
    #expect(SiriLibrary.rankedByMatches([]).isEmpty)
  }

  // MARK: Records

  @Test("The digest changes with what Spotlight shows and is stable otherwise")
  func digest() {
    let record = SiriItemRecord(
      id: "a", source: .device, date: date(2024, 5, 1), isVideo: false, isFavorite: false, labels: ["dog"])
    #expect(record.digest() == record.digest())
    var favorite = record
    favorite.isFavorite = true
    #expect(favorite.digest() != record.digest())
    var labeled = record
    labeled.labels = ["dog", "beach"]
    #expect(labeled.digest() != record.digest())
    // Fields are delimited: moving text between fields changes the digest.
    let split = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false, labels: ["do", "g"])
    let joined = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false, labels: ["dog"])
    #expect(split.digest() != joined.digest())
    #expect(record.digest(including: ["1"]) != record.digest(including: ["2"]))
  }

  @Test("Records follow the timeline: device items, Google items, and folder files as their Google copy")
  func recordsFromSnapshot() {
    let device = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: true,
      latitude: 51.5, longitude: -0.1)
    let cloud = RemoteItemSummary(
      mediaKey: "M1", dedupKey: "M1", sha1: nil, kind: .video, takenAt: date(2025, 2, 3), contentVersion: 0,
      durationMs: 1_000, isFavorite: false, trashedAt: nil, width: nil, height: nil, fileName: "clip.mov")
    let backedUpFile = RemoteItemSummary(
      mediaKey: "M2", dedupKey: "M2", sha1: nil, kind: .photo, takenAt: date(2025, 3, 4), contentVersion: 0,
      durationMs: nil, isFavorite: false, trashedAt: nil, width: nil, height: nil, fileName: "scan.jpg")
    let file = FolderItemInfo(path: "/f/notes.png", date: date(2025, 4, 5), size: 1, isVideo: false)
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.device(0, cloud: nil), .cloud(0), .folder(1, cloud: 1), .folder(0, cloud: nil)], device: [device],
      cloud: [cloud, backedUpFile], folder: [file, file], cloudLibrary: nil)

    let records = SiriItemRecord.records(
      from: snapshot, facts: ["D1": SiriItemFacts(labels: ["dog"], text: "Hello", people: ["Sam"])],
      googleDetails: ["M1": RemoteSiriDetails(place: "Paris", caption: "Eiffel")])

    #expect(records.map(\.id) == ["D1", "g:M1", "g:M2", file.id])
    #expect(records.map(\.source) == [.device, .google, .google, .folder])
    #expect(records[0].labels == ["dog"])
    #expect(records[0].people == ["Sam"])
    #expect(records[0].isFavorite)
    #expect(records[0].latitude == 51.5)
    #expect(records[1].isVideo)
    #expect(records[1].place == "Paris")
    #expect(records[1].title.hasPrefix("Paris, "))
    #expect(records[3].fileName == "notes.png")
  }

  @Test("Spotlight gets the whole Library while the grid shows a filter")
  func unfilteredSnapshot() {
    let favorite = DeviceItemInfo(
      localIdentifier: "D1", date: date(2025, 1, 2), width: 4, height: 3, isVideo: false, isFavorite: true)
    let other = DeviceItemInfo(
      localIdentifier: "D2", date: date(2025, 1, 3), width: 4, height: 3, isVideo: false, isFavorite: false)
    let device = [favorite, other]
    let filtered = TimelineMerge.merge(device: device, cloud: [], uploadedMediaKeys: [:], filter: .favorites)
    #expect(filtered.count == 1)
    var inputs = UnifiedLibraryModel.MergeInputs()
    inputs.isFiltered = true
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: filtered, device: device, cloud: [], folder: [], cloudLibrary: nil, inputs: inputs)
    let all = snapshot.unfiltered()
    #expect(!all.inputs.isFiltered)
    #expect(Set(SiriItemRecord.records(from: all, facts: [:], googleDetails: [:]).map(\.id)) == ["D1", "D2"])
    // Unfiltered entries are used as they are.
    let plain = UnifiedLibraryModel.IndexSnapshot(entries: filtered, device: device, cloud: [], folder: [], cloudLibrary: nil)
    #expect(plain.unfiltered().entries == filtered)
  }

  @Test("A pass re-indexes changed items and removes those that left")
  func plan() {
    let plan = SiriSpotlightIndexer.Plan(
      current: [("a", 1), ("b", 2), ("c", 3), ("a", 1)], stored: ["a": 1, "b": 9, "gone": 4])
    #expect(plan.changed == ["b", "c"])
    #expect(plan.removed == ["gone"])
  }

  @Test("The change key follows analysis and people, not only metadata")
  func changeKey() {
    let base = SiriItemRecord(id: "a", source: .device, date: nil, isVideo: false, isFavorite: false)
    let key = SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: ["Sam"])
    #expect(key == SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: ["Sam"]))
    #expect(key != SiriSpotlightIndexer.changeKey(base, analyzedAt: 11, people: ["Sam"]))
    #expect(key != SiriSpotlightIndexer.changeKey(base, analyzedAt: 10, people: []))
  }

  // MARK: Store

  @Test("Records round-trip through the index database and are found by date")
  func storeRoundTrip() async throws {
    let store = makeStore()
    let older = SiriItemRecord(
      id: "a", source: .device, date: date(2024, 1, 1), isVideo: false, isFavorite: true, latitude: 1, longitude: 2,
      labels: ["dog", "beach"], text: "Hi", people: ["Sam", "Alex"])
    let newer = SiriItemRecord(
      id: "g:b", source: .google, fileName: "b.mov", date: date(2025, 1, 1), isVideo: true, isFavorite: false,
      place: "Rome", caption: "Trip")
    try await store.saveSiri([(older, 1), (newer, 2)])

    #expect(try await store.siriRecords(ids: ["g:b", "missing", "a"]) == [newer, older])
    #expect(try await store.siriDigests() == ["a": 1, "g:b": 2])
    #expect(try await store.recentSiriRecords(limit: 10).map(\.id) == ["g:b", "a"])
    #expect(try await store.recentSiriRecords(limit: 10, favoritesOnly: true).map(\.id) == ["a"])
    #expect(try await store.siriIDs(takenIn: date(2023, 6, 1)..<date(2024, 6, 1), limit: 10) == ["a"])
    #expect(try await store.allSiriIDs() == ["g:b", "a"])

    try await store.deleteSiri(["a"])
    #expect(try await store.siriRecordCount() == 1)
  }

  @Test("Periods, videos and favorites filter before the limit, so older matches aren't lost")
  func storeFilteredIDs() async throws {
    let store = makeStore()
    // The newest items are photos; the one video is the oldest.
    var records: [(SiriItemRecord, Int64)] = (1...20).map { day in
      (SiriItemRecord(id: "p\(day)", source: .device, date: date(2024, 3, day), isVideo: false, isFavorite: day == 1), 0)
    }
    records.append((SiriItemRecord(id: "v", source: .device, date: date(2023, 1, 1), isVideo: true, isFavorite: true), 0))
    try await store.saveSiri(records)

    #expect(try await store.siriIDs(period: nil, videosOnly: true, limit: 1) == ["v"])
    #expect(try await store.siriIDs(period: nil, favoritesOnly: true, limit: 5) == ["p1", "v"])
    #expect(try await store.siriIDs(period: date(2024, 3, 1)..<date(2024, 3, 3), limit: 10) == ["p2", "p1"])
    #expect(try await store.siriIDs(period: date(2024, 1, 1)..<date(2025, 1, 1), videosOnly: true, limit: 10).isEmpty)
  }

  @Test("Facts come from the analysis: confident labels, text and named people")
  func facts() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("sea_ocean", 0.9), ("blurry", 0.2)]
    analysis.text = "Welcome to Brighton"
    try await store.save(ItemMetadata(id: "a", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "b", date: Date(), words: []), analysis: ItemAnalysis())

    let facts = try await store.siriFacts(for: ["a", "b"])
    #expect(facts["a"]?.labels == ["sea ocean"])
    #expect(facts["a"]?.text == "Welcome to Brighton")
    #expect(facts["b"] == nil)
    #expect(try await store.analyzedStamps().keys.sorted() == ["a", "b"])
  }
}
