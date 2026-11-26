import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import Vision

@testable import GPhotosKit

@Suite("Library intelligence")
struct LibraryIntelligenceTests {
  private func makeStore() -> LibraryIndexStore {
    LibraryIndexStore(directory: TestTemporaryDirectory.root.appending(path: "Index-\(UUID().uuidString)"))
  }

  @Test("Search completes labels and metadata, matches whole OCR words, requires every word")
  func search() async throws {
    let store = makeStore()
    var beach = ItemAnalysis()
    beach.labels = [("sea_ocean", 0.9), ("beach", 0.8)]
    beach.text = "Welcome to Brighton"
    try await store.save(ItemMetadata(id: "a", date: Date(), words: ["photo", "October", "2025"]), analysis: beach)
    var dog = ItemAnalysis()
    dog.labels = [("dog", 0.95)]
    try await store.save(ItemMetadata(id: "b", date: Date(), words: ["video", "July", "2024"]), analysis: dog)
    try await store.save(ItemMetadata(id: "g:x", date: Date(), words: ["Paris", "google"]), analysis: nil)

    #expect(try await store.search([["ocean"]]) == ["a"])
    #expect(try await store.search([["brigh"]]).isEmpty)
    #expect(try await store.search([["dog"], ["2024"]]) == ["b"])
    #expect(try await store.search([["dog"], ["2025"]]).isEmpty)
    #expect(try await store.search([["puppy", "dog"]]) == ["b"])
    #expect(try await store.search([["paris"]]) == ["g:x"])
    #expect(try await store.analyzedIDs() == ["a", "b", "g:x"])
    #expect(try await store.pixelAnalyzedIDs() == ["a", "b"])
    try await store.save(ItemMetadata(id: "local", date: Date(), words: []), analysis: nil)
    // A device item without pixels waits before being tried again; Google items don't.
    #expect(try await store.settledIDs() == ["a", "b", "g:x", "local"])
    #expect(try await store.settledIDs(now: Date().addingTimeInterval(4 * 86_400)) == ["a", "b"])
    #expect(try await store.categories(minimumCount: 1).count == 3)
    #expect(try await store.ids(withLabel: "dog") == ["b"])

    // Saving again replaces the item's labels and text.
    try await store.save(ItemMetadata(id: "a", date: Date(), words: []), analysis: ItemAnalysis())
    #expect(try await store.search([["ocean"]]).isEmpty)
  }

  @Test("Items gone from the library leave the index, each kind only when its list loaded")
  func prune() async throws {
    let store = makeStore()
    var dog = ItemAnalysis()
    dog.labels = [("dog", 0.95)]
    for id in ["kept", "gone", "f:gone", "g:kept", "g:gone"] {
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: dog)
    }
    #expect(try await store.prune(keeping: ["kept", "g:kept"], device: true, folder: false, cloud: true) == 2)
    #expect(try await store.analyzedIDs() == ["kept", "f:gone", "g:kept"])
    #expect(Set(try await store.search([["dog"]])) == ["kept", "f:gone", "g:kept"])
    #expect(try await store.ids(withLabel: "dog").count == 3)
  }

  @Test("Exact confident labels rank above OCR and prefixes; recency breaks ties")
  func searchRanking() async throws {
    let store = makeStore()
    for (id, confidence, timestamp) in [("strong-old", Float(0.95), 1.0), ("strong-new", 0.95, 2.0), ("weak", 0.6, 3.0)] {
      var analysis = ItemAnalysis()
      analysis.labels = [("cat", confidence)]
      try await store.save(ItemMetadata(id: id, date: Date(timeIntervalSince1970: timestamp), words: []), analysis: analysis)
    }
    var ocr = ItemAnalysis()
    ocr.text = "cat category catalog"
    try await store.save(ItemMetadata(id: "ocr", date: Date(), words: []), analysis: ocr)
    try await store.save(ItemMetadata(id: "prefix", date: Date(), words: ["catalog"]), analysis: nil)
    let matches = try await store.search([["cat"]])
    #expect(Array(matches.prefix(3)) == ["strong-new", "strong-old", "weak"])
    #expect(matches.contains("ocr"))
    #expect(try await store.search([["kitten", "cat"]]).contains("ocr") == false)
    #expect(matches.contains("prefix"))
    #expect(try await store.search([["cat"]], completingLastWord: false).contains("prefix") == false)
    #expect(try await store.search([["cata"]]).contains("ocr") == false)
    #expect(try await store.search([["cat"], ["category"]]) == ["ocr"])
    #expect(try await store.search([["cata"], ["cat"]]).isEmpty)
    #expect(try await store.search([["cat OR catalog"]]).isEmpty)
    #expect(try await store.search([["cat"]], limit: 0).isEmpty)
  }

  @Test("Categories omit generic and uncertain labels, merge synonyms and choose quality covers")
  func categories() async throws {
    let store = makeStore()
    for (id, label, score) in [("a", "dog", Float(0.9)), ("z", "canine", 0.2), ("b", "dog", 0.5)] {
      var analysis = ItemAnalysis()
      analysis.labels = [(label, 0.95), ("dog", 0.7), ("structure", 0.99), ("material", 0.99), ("animal", 0.9), ("beach", 0.1)]
      analysis.aesthetics = score
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis)
    }
    let categories = try await store.categories()
    #expect(categories.count == 1)
    #expect(categories.first?.label == "dog")
    #expect(categories.first?.displayName == "Dogs")
    #expect(categories.first?.count == 3)
    #expect(categories.first?.sampleID == "a")
    #expect(try await store.search([["structure"]]).isEmpty)
    #expect(try await store.search([["beach"]]).isEmpty)
    #expect(try await store.search([["animal"]]).count == 3)
    #expect(try await store.ids(withLabel: "canine").count == 3)
    #expect(SearchVocabulary.displayName("sea_ocean") == "Sea & Ocean")
  }

  @Test("Suggestions use typed document counts and stay fresh after replacement")
  func suggestions() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("dog", 0.95)]
    analysis.text = "receipt receipt"
    try await store.save(ItemMetadata(id: "a", date: nil, words: ["Paris", "Paris"]), analysis: analysis)
    try await store.save(ItemMetadata(id: "b", date: nil, words: ["Paris"]), analysis: nil)
    #expect(try await store.suggestions(for: "do").first?.kind == .category)
    #expect(try await store.suggestions(for: "pa").first?.count == 2)
    #expect(try await store.suggestions(for: "re").first?.kind == .text)
    #expect(try await store.suggestions(for: "re").first?.count == 1)
    #expect(try await store.suggestions(for: "p").isEmpty)
    #expect(try await store.suggestions(for: "pa", limit: 0).isEmpty)
    try await store.save(ItemMetadata(id: "a", date: nil, words: []), analysis: nil)
    #expect(try await store.suggestions(for: "do").isEmpty)
    #expect(try await store.suggestions(for: "pa").first?.count == 1)
  }

  @Test("Common completions come before rarer ones that sort first, and kinds share the list")
  func suggestionRanking() async throws {
    let store = makeStore()
    var items: [(metadata: ItemMetadata, analysis: ItemAnalysis?)] = []
    for index in 0..<30 {
      var analysis = ItemAnalysis()
      // "cab", "cac", ... each in one photo; "cat" in twenty.
      let rare = "ca" + String(UnicodeScalar(UInt8(98 + index % 20)))
      analysis.labels = [(index < 20 ? "cat" : rare, 0.9)]
      analysis.text = index == 0 ? "cafe" : ""
      items.append((ItemMetadata(id: "\(index)", date: nil, words: index == 0 ? ["Cairo"] : []), analysis))
    }
    for index in 0..<15 {
      var analysis = ItemAnalysis()
      analysis.labels = [("ca" + String(UnicodeScalar(UInt8(97 + index))) + "x", 0.9)]
      items.append((ItemMetadata(id: "r\(index)", date: nil, words: []), analysis))
    }
    try await store.saveAll(items)
    let found = try await store.suggestions(for: "ca", limit: 6)
    #expect(found.first?.query == "cat")
    #expect(found.first?.count == 20)
    #expect(found.contains { $0.kind == .metadata && $0.query == "cairo" })
    #expect(found.contains { $0.kind == .text && $0.query == "cafe" })
    #expect(found.count == 6)
  }

  @MainActor
  @Test("Indexer suggests visible names by word prefix with distinct photo counts")
  func personSuggestions() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [
      DetectedFace(rect: CGRect(x: 0, y: 0, width: 0.3, height: 0.3), featurePrint: Data([1])),
      DetectedFace(rect: CGRect(x: 0.5, y: 0, width: 0.3, height: 0.3), featurePrint: Data([2])),
    ]
    try await store.save(ItemMetadata(id: "portrait", date: nil, words: []), analysis: analysis)
    let faces = try await store.faces()
    try await store.assignFaces(Dictionary(uniqueKeysWithValues: faces.map { ($0.id, Int64(1)) }))
    try await store.name(person: 1, "Ada Lovelace")
    let indexer = LibraryIndexer(store: store)
    let suggestions = await indexer.suggestions(for: "ada lov")
    #expect(suggestions.first?.kind == .person)
    #expect(suggestions.first?.query == "Ada Lovelace")
    #expect(suggestions.first?.count == 1)
    #expect(await indexer.search("lov") == ["portrait"])
    #expect(await indexer.search("ovel").isEmpty)
    try await store.hide(person: 1)
    indexer.peopleDidChange()
    #expect(await indexer.suggestions(for: "ada").isEmpty)
  }

  @Test("Semantic expansion rejects loose neighbors and never expands known subjects")
  func expansion() {
    #expect(LibraryIndexer.semanticAlternatives([("cat", 0.5), ("dog", 0.34), ("bird", 0.2)], labels: ["cat", "dog", "bird"]) == ["dog"])
    #expect(!LibraryIndexer.matchesName("Catherine", query: "cat" + "alog"))
    #expect(!LibraryIndexer.matchesName("Catherine", query: "ther"))
    #expect(LibraryIndexer.matchesName("Ada Lovelace", query: "ada lov"))
    #expect(LibraryIndexer.expand(["dog"], vocabulary: ["dog", "cat"]) == [["dog", "dogs"]])
    #expect(LibraryIndexer.expand(["puppy"], vocabulary: ["dog"]) == [["puppy", "puppies", "dog"]])
    #expect(LibraryIndexer.expand(["puppies"], vocabulary: ["dog"]) == [["puppies", "puppy", "dog"]])
    #expect(LibraryIndexer.expand(["canine"], vocabulary: ["dog"]) == [["canine", "canines", "dog"]])
  }

  @Test("Everyday words find the narrower labels Vision gives")
  func relatedLabels() async throws {
    let store = makeStore()
    for (id, label, confidence) in [("range", "hill", 0.7), ("peak", "mountain", 0.9), ("palm", "palm_tree", 0.8), ("pet", "dog", 0.9)] {
      var analysis = ItemAnalysis()
      analysis.labels = [(label, Float(confidence))]
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis)
    }
    let vocabulary = try await store.allLabels()
    for query in ["mountain", "mountains"] {
      let found = await LibraryIndexer.search(query, in: store, vocabulary: vocabulary, people: [], completingLastWord: false)
      // The label itself comes before the related one.
      #expect(found == ["peak", "range"])
    }
    let trees = await LibraryIndexer.search("trees", in: store, vocabulary: vocabulary, people: [], completingLastWord: false)
    #expect(trees == ["palm"])
    let dogs = await LibraryIndexer.search("dogs", in: store, vocabulary: vocabulary, people: [], completingLastWord: false)
    #expect(dogs == ["pet"])
  }

  @Test("Google items stay unsettled until their pixels are tried")
  func pendingPixels() async throws {
    let store = makeStore()
    try await store.saveAll([(ItemMetadata(id: "g:x", date: Date(), words: ["Paris"]), nil)], pixelsPending: true)
    #expect(try await store.search([["paris"]]) == ["g:x"])
    #expect(try await store.settledIDs().isEmpty)
    #expect(try await store.analyzedIDs() == ["g:x"])
    try await store.saveAll([(ItemMetadata(id: "g:x", date: Date(), words: ["Paris"]), ItemAnalysis())])
    #expect(try await store.settledIDs() == ["g:x"])
  }

  @Test("Vocabulary suggestions seek efficiently across 100,000 items")
  func suggestionPerformance() async throws {
    let store = makeStore()
    try await store.saveAll(
      (0..<100_000).map { index in
        (ItemMetadata(id: "g:\(index)", date: nil, words: ["Paris", "photo", "place\(index)"]), nil)
      })
    let clock = ContinuousClock()
    // Include the first lookup: no warm vocabulary cache is needed.
    let start = clock.now
    for _ in 0..<10 {
      let suggestions = try await store.suggestions(for: "pa")
      #expect(suggestions.first?.count == 100_000)
    }
    let average = start.duration(to: clock.now) / 10
    print("SEARCH suggestions 100k average: \(average)")
    #if !GPHOTOS_HOSTED_IOS_TESTS
      #expect(average < .milliseconds(30))
    #endif
  }

  @Test("Short words, unspaced scripts and accents match the way they're indexed")
  func scriptAwareSearch() async throws {
    let store = makeStore()
    var dog = ItemAnalysis()
    dog.labels = [("dog", 0.95)]
    dog.text = "東京都旅行 Café"
    try await store.save(ItemMetadata(id: "a", date: nil, words: ["Paris", "東京都", "কলকাতা"]), analysis: dog)

    #expect(try await store.search([["pa"]]) == ["a"])
    #expect(try await store.search([["do"]]) == ["a"])
    #expect(try await store.search([["p"]]).isEmpty)
    #expect(try await store.search([["東京"]]) == ["a"])
    #expect(try await store.search([["東京都"]], completingLastWord: false) == ["a"])
    #expect(try await store.search([["cafe"]]) == ["a"])
    #expect(try await store.search([["café"]]) == ["a"])
    #expect(try await store.search([["কলকাতা"]]) == ["a"])

    #expect(try await store.suggestions(for: "東").first?.query == "東京都")
    #expect(try await store.suggestions(for: "café").first?.query == "cafe")
    #expect(try await store.suggestions(for: "cafe\u{301}").first?.query == "cafe")
    #expect(try await store.suggestions(for: "কল").first?.query == "কলকাতা")
    #expect(try await store.suggestions(for: "dog pa").first?.query == "dog paris")

    #expect(LibraryIndexer.matchesName("山田太郎", query: "太郎"))
    #expect(LibraryIndexer.matchesName("张小明", query: "小明"))
    #expect(!LibraryIndexer.matchesName("张小明", query: "大明"))
    #expect(SearchVocabulary.folded("Ñandú") == "nandu")
    #expect(SearchVocabulary.folded("কলকাতা") == "কলকাতা")
  }

  @Test("A broad search ranks 100,000 matches quickly")
  func broadSearchPerformance() async throws {
    let store = makeStore()
    try await store.saveAll(
      (0..<100_000).map { index in
        var analysis = ItemAnalysis()
        analysis.labels = [("dog", 0.9), ("grass", 0.6), ("outdoor", 0.8)]
        return (
          ItemMetadata(id: "\(index)", date: Date(timeIntervalSince1970: Double(index)), words: ["photo"]), analysis
        )
      })
    _ = try await store.search([["dog"]])
    let clock = ContinuousClock()
    var ids: [String] = []
    var elapsed = Duration.seconds(Int64.max)
    // The fastest of three: tests running alongside can slow any one search to several
    // times its 0.3 to 0.4 s alone, while a slower query (a label subquery per match took
    // about twice as long) slows all three.
    for _ in 0..<3 {
      let start = clock.now
      ids = try await store.search([["dog"]])
      elapsed = min(elapsed, start.duration(to: clock.now))
    }
    print("SEARCH broad 100k: \(elapsed)")
    #expect(ids.count == 5_000)
    #expect(ids.first == "99999")
    #if !GPHOTOS_HOSTED_IOS_TESTS
      #expect(elapsed < .seconds(1))
    #endif
  }

  @Test("Faces are assigned to people, named and searchable by name")
  func people() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [
      DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([1])),
      DetectedFace(rect: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([2])),
    ]
    try await store.save(ItemMetadata(id: "p1", date: Date(), words: []), analysis: analysis)
    let faces = try await store.faces()
    #expect(faces.count == 2)
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2])
    #expect(try await store.maxPersonID() == 2)
    #expect(try await store.people(minimumFaces: 1).count == 2)
    try await store.name(person: 1, "Ada")
    #expect(try await store.search(personNamed: "ad") == ["p1"])
    try await store.hide(person: 2)
    #expect(try await store.people(minimumFaces: 1).map(\.name) == ["Ada"])
  }

  @Test("Similar photos group only close neighbours in time")
  func similarity() {
    let dates = [0.0, 5, 10, 500, 505].map { Date(timeIntervalSince1970: $0) }
    // Items 0-1-2 are a burst, 3-4 another; 2 and 3 look alike but are minutes apart.
    let values: [Set<Int>: Double] = [[0, 1]: 0.1, [1, 2]: 0.2, [0, 2]: 0.5, [3, 4]: 0.05, [2, 3]: 0.01]
    let groups = SimilarityGrouping.groups(count: 5, date: { dates[$0] }, distance: { values[[$0, $1]] ?? 1 })
    #expect(groups == [[0, 1, 2], [3, 4]])
  }

  private func faceVectors(_ values: [[Float]]) -> FeatureVectors {
    FeatureVectors(values.map { $0.withUnsafeBytes { Data($0) } })
  }

  @Test("People use average linkage and leave borderline and ambiguous faces unassigned")
  func clustering() {
    let vectors = faceVectors([[0], [0.1], [0.2], [1.5], [0.55]])
    // 4 is weighed while person 7 still has two photos, so 0.50 on average is borderline.
    let result = FaceClustering.assign(existing: [(7, [0, 1])], unassigned: [4, 2, 3], nextPersonID: 8) {
      vectors.distance($0, $1)
    }
    #expect(result.assignments == [2: 7, 3: 8])
    #expect(result.nextPersonID == 9)
    let ambiguous = faceVectors([[0], [0.6], [0.3]])
    let waiting = FaceClustering.assign(existing: [(1, [0]), (2, [1])], unassigned: [2], nextPersonID: 3) {
      ambiguous.distance($0, $1)
    }
    #expect(waiting.assignments.isEmpty)
  }

  @Test("Someone with three or more photos takes a less similar face than someone with two")
  func steadierPeopleMatchWider() {
    // The new face is 0.43–0.47 from each reference, 0.45 on average.
    let vectors = faceVectors([[0], [0.02], [0.04], [0.47]])
    let three = FaceClustering.assign(existing: [(1, [0, 1, 2])], unassigned: [3], nextPersonID: 2) {
      vectors.distance($0, $1)
    }
    #expect(three.assignments == [3: 1])
    let two = FaceClustering.assign(existing: [(1, [0, 1])], unassigned: [3], nextPersonID: 2) {
      vectors.distance($0, $1)
    }
    // Too far to join, too close to be someone new: it waits.
    #expect(two.assignments.isEmpty)
  }

  @Test("Duplicate people merge into the named person and distinct names never merge")
  func peopleMerging() {
    let vectors = faceVectors([[0], [0.05], [0.1], [0.15]])
    let result = FaceClustering.assign(
      existing: [(1, [0, 1]), (7, [2, 3])], unassigned: [], nextPersonID: 8, names: [7: "Ada"]
    ) { vectors.distance($0, $1) }
    #expect(result.merges == [1: 7])
    let named = FaceClustering.assign(
      existing: [(1, [0, 1]), (7, [2, 3])], unassigned: [], nextPersonID: 8, names: [1: "Grace", 7: "Ada"]
    ) { vectors.distance($0, $1) }
    #expect(named.merges.isEmpty)
  }

  @Test("Assignments never lean on a merge, and same-name people stay apart")
  func mergesStaySeparate() async throws {
    // A merge of 2 into 1 could be refused by the store, so a new face must be placed as
    // if the people were apart: 0.41 is nearest person 2.
    let vectors = faceVectors([[0], [0.3], [0.41]])
    let assigning = FaceClustering.assign(
      existing: [(1, [0]), (2, [1])], unassigned: [2], threshold: 0.4, nextPersonID: 3, allowsMerging: false
    ) { vectors.distance($0, $1) }
    #expect(assigning.merges.isEmpty)
    #expect(assigning.assignments[2] != 1)

    let close = faceVectors([[0], [0.05]])
    let sameName = FaceClustering.assign(
      existing: [(1, [0]), (2, [1])], unassigned: [], nextPersonID: 3, names: [1: "Alex", 2: "Alex"]
    ) { close.distance($0, $1) }
    #expect(sameName.merges.isEmpty)

    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([1]))]
    try await store.save(ItemMetadata(id: "one", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "two", date: Date(), words: []), analysis: analysis)
    let faces = try await store.faces()
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2])
    try await store.name(person: 1, "Alex")
    try await store.name(person: 2, "Alex")
    #expect(try await store.mergePeople([2: 1]) == false)
    #expect(try await store.ids(ofPerson: 2) == ["two"])
  }

  @Test("Merging people by hand combines them, whatever their names, and keeps the page shown")
  func manualMerge() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([1]))]
    for id in ["one", "two", "three"] { try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis) }
    let faces = try await store.faces().sorted { $0.itemID < $1.itemID }
    // one -> 1, three -> 2, two -> 3
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2, faces[2].id: 3])
    try await store.name(person: 1, "Alex")
    try await store.name(person: 2, "Alex")
    try await store.hide(person: 2)

    try await store.merge(person: 2, into: 1)
    #expect(Set(try await store.ids(ofPerson: 1)) == ["one", "three"])
    #expect(try await store.ids(ofPerson: 2).isEmpty)
    let shown = try await store.people(minimumFaces: 1)
    #expect(shown.first { $0.id == 1 }?.name == "Alex")
    #expect(shown.first { $0.id == 1 }?.faceCount == 2)

    // An unnamed person takes the name of the one merged into it.
    try await store.merge(person: 1, into: 3)
    #expect(try await store.people(minimumFaces: 1).map(\.name) == ["Alex"])
    #expect(Set(try await store.ids(ofPerson: 3)) == ["one", "two", "three"])
    try await store.merge(person: 3, into: 3)
    #expect(try await store.ids(ofPerson: 3).count == 3)

    // A page left open on a person indexing has since merged away moves nothing.
    #expect(try await store.merge(person: 3, into: 1) == false)
    #expect(try await store.ids(ofPerson: 3).count == 3)
    #expect(try await store.people(minimumFaces: 1).map(\.id) == [3])
  }

  @Test("A crowded face bucket keeps the candidate query small")
  func crowdedBucketQuery() async throws {
    let store = makeStore()
    let vector = (0..<64).map { Float($0 % 7) / 7 }.withUnsafeBytes { Data($0) }
    let face = DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: vector)
    var analysis = ItemAnalysis()
    analysis.faces = [face]
    try await store.saveAll((0..<20_000).map { (ItemMetadata(id: "p\($0)", date: nil, words: []), analysis) })
    let faces = try await store.faces()
    // Everyone is a different person in the same bucket, except one face still to place.
    try await store.assignFaces(Dictionary(uniqueKeysWithValues: faces.dropLast().map { ($0.id, $0.id) }))
    let clock = ContinuousClock()
    let start = clock.now
    let page = try await store.facesForClustering()
    let elapsed = start.duration(to: clock.now)
    print("PEOPLE crowded bucket: \(elapsed)")
    #expect(page.count <= 65)
    #if !GPHOTOS_HOSTED_IOS_TESTS
      #expect(elapsed < .milliseconds(250))
    #endif
  }

  @Test("Faces that waited for a larger image are analyzed again later")
  func incompleteFacesRetry() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("dog", 0.9)]
    analysis.facesIncomplete = true
    try await store.save(ItemMetadata(id: "small-faces", date: Date(), words: []), analysis: analysis)
    #expect(try await store.settledIDs().contains("small-faces"))
    let later = Date().addingTimeInterval(LibraryIndexStore.pixelRetryInterval + 60)
    #expect(try await store.settledIDs(now: later).contains("small-faces") == false)
    #expect(try await store.search([["dog"]]) == ["small-faces"])
  }

  @Test("Faces in the same photo cannot join or merge, and a close outlier cannot bridge people")
  func peopleCannotLink() {
    let vectors = faceVectors([[0], [0.02], [0.03], [0.9]])
    let result = FaceClustering.assign(
      existing: [(1, [0]), (2, [1])], unassigned: [2], nextPersonID: 3, itemID: { _ in "same-photo" },
      distance: { vectors.distance($0, $1) })
    #expect(result.merges.isEmpty)
    #expect(result.assignments[2] == 3)
    let outlier = FaceClustering.assign(existing: [(1, [0, 3])], unassigned: [2], nextPersonID: 2) {
      vectors.distance($0, $1)
    }
    #expect(outlier.assignments[2] != 1)
  }

  @Test("People require five distinct photos, retain named people and choose quality covers")
  func peopleCovers() async throws {
    let store = makeStore()
    for index in 0..<5 {
      var analysis = ItemAnalysis()
      analysis.faces = [
        DetectedFace(
          rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
          featurePrint: [Float(0.1)].withUnsafeBytes { Data($0) }, quality: Double(index) / 5)
      ]
      try await store.save(ItemMetadata(id: "photo-\(index)", date: Date(), words: []), analysis: analysis)
    }
    let faces = try await store.faces()
    try await store.assignFaces(Dictionary(uniqueKeysWithValues: faces.prefix(4).map { ($0.id, Int64(1)) }))
    #expect(try await store.people().isEmpty)
    try await store.name(person: 1, "Ada")
    #expect(try await store.people().count == 1)
    try await store.assignFaces([faces[4].id: 1])
    let people = try await store.people()
    #expect(people.first?.faceCount == 5)
    #expect(people.first?.cover?.itemID == "photo-4")
  }

  @Test("Persistent merge checks all photos and preserves hidden status")
  func persistentPeopleMerges() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    let face = DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([1]))
    analysis.faces = [face, face]
    try await store.save(ItemMetadata(id: "together", date: Date(), words: []), analysis: analysis)
    let faces = try await store.faces()
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2])
    try await store.mergePeople([2: 1])
    #expect(try await store.ids(ofPerson: 2) == ["together"])
    try await store.assignFaces([faces[1].id: 1])
    #expect(try await store.ids(ofPerson: 2) == ["together"])
    analysis.faces = [face]
    try await store.save(ItemMetadata(id: "alone", date: Date(), words: []), analysis: analysis)
    let extra = try #require(try await store.faces().first { $0.itemID == "alone" })
    try await store.assignFaces([extra.id: 3])
    try await store.name(person: 1, "Ada")
    try await store.hide(person: 3)
    try await store.mergePeople([3: 1])
    #expect(try await store.people(minimumFaces: 1).map(\.id) == [2])
    #expect(try await store.peopleNames()[1] == "Ada")
  }

  @Test("Face candidate hashes are deterministic and retain identical vectors")
  func faceCandidates() async throws {
    let data = (0..<768).map { sin(Float($0)) }.withUnsafeBytes { Data($0) }
    #expect(FaceClustering.buckets(data) == FaceClustering.buckets(data))
    #expect(FaceClustering.buckets(data).count == 4)
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [DetectedFace(rect: .zero, featurePrint: data)]
    for id in ["first", "second"] {
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis)
    }
    let faces = try await store.faces()
    try await store.assignFaces([faces[0].id: 7])
    #expect(try await store.facesForClustering().count == 2)
  }

  @Test("Periodic People merging still has references when there are no unassigned faces")
  func periodicPeopleMerging() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.faces = [DetectedFace(rect: .zero, featurePrint: [Float(0.1)].withUnsafeBytes { Data($0) })]
    for id in ["one", "two"] {
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis)
    }
    let faces = try await store.faces()
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2])
    #expect(try await store.facesForClustering().isEmpty)
    let page = try #require(try await store.peopleForMerging(after: 0))
    #expect(Set(page.faces.compactMap(\.person)) == [1, 2])
    #expect(page.next == 2)
    #expect(try await store.peopleForMerging(after: page.next) == nil)
  }

  @Test("Faces from another face model are dropped with their people, never mixed with new ones")
  func faceModelChangeClearsPeople() async throws {
    let directory = TestTemporaryDirectory.root.appending(path: "Index-\(UUID().uuidString)")
    let old = LibraryIndexStore(directory: directory)
    var analysis = ItemAnalysis()
    analysis.faces = [DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), featurePrint: Data([1]))]
    try await old.save(ItemMetadata(id: "one", date: Date(), words: []), analysis: analysis)
    try await old.assignFaces([try await old.faces()[0].id: 1])
    try await old.name(person: 1, "Ada")
    try await old.markFaceModel("an earlier model")

    let reopened = LibraryIndexStore(directory: directory)
    #expect(try await reopened.faces().isEmpty)
    #expect(try await reopened.peopleNames().isEmpty)
    // Opening again with the same model keeps what's there.
    try await reopened.save(ItemMetadata(id: "two", date: Date(), words: []), analysis: analysis)
    #expect(try await LibraryIndexStore(directory: directory).faces().count == 1)
  }

  @Test("Crowded candidate buckets keep comparison work bounded")
  func boundedPeopleClustering() {
    var comparisons = 0
    let existing = (0..<2_000).map { (person: Int64($0), faces: [$0]) }
    let result = FaceClustering.assign(
      existing: existing, unassigned: [2_000], nextPersonID: 2_001,
      buckets: { _ in [0, 0, 0, 0] },
      distance: { _, _ in
        comparisons += 1
        return 1
      })
    #expect(result.assignments[2_000] == 2_001)
    #expect(comparisons <= 8_192 + 128)
  }

  @Test("On This Day and trips")
  func memories() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    let home = (23.8, 90.4)
    var moments = (0..<20).map { MemoryFinder.Moment(date: day(2024, 1, 1 + $0), latitude: home.0, longitude: home.1) }
    moments += (0..<15).map { MemoryFinder.Moment(date: day(2025, 3, 10 + $0 / 5), latitude: 48.85, longitude: 2.35) }
    moments.append(MemoryFinder.Moment(date: day(2023, 10, 24), latitude: nil, longitude: nil))
    let today = day(2026, 10, 24)
    let onThisDay = MemoryFinder.onThisDay(moments, today: today, calendar: calendar)
    #expect(onThisDay.map(\.year) == [2023])
    let trips = MemoryFinder.trips(moments)
    #expect(trips.count == 1)
    #expect(trips.first?.count == 15)
    #expect(abs(MemoryFinder.kilometres(moments[0], moments[25]) - 7_900) < 200)
  }

  @Test("On This Day handles leap day and multi-year history without Calendar per item")
  func onThisDayLeapYear() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
      calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }
    let moments = [
      MemoryFinder.Moment(date: day(2016, 2, 29), latitude: nil, longitude: nil),
      MemoryFinder.Moment(date: day(2019, 3, 1), latitude: nil, longitude: nil),
      MemoryFinder.Moment(date: day(2020, 2, 29), latitude: nil, longitude: nil),
      MemoryFinder.Moment(date: day(2024, 2, 29), latitude: nil, longitude: nil),
    ]
    let found = MemoryFinder.onThisDay(moments, today: day(2024, 2, 29), calendar: calendar)
    #expect(found.map(\.year) == [2020, 2016])
    #expect(found.map(\.indices) == [[2], [0]])
  }

  @MainActor
  @Test("People-dirty counter tracks mutations, persists clean state and skips unchanged passes")
  func peopleDirtyCounter() async throws {
    let dir = TestTemporaryDirectory.root.appending(path: "PeopleDirty-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: dir)
    // Empty database starts clean.
    #expect(try await store.needsPeoplePass() == false)
    let v0 = try await store.peopleDirtyVersion()

    // Saving an item without faces does not dirty People.
    var dog = ItemAnalysis()
    dog.labels = [("dog", 0.9)]
    try await store.save(ItemMetadata(id: "no-face", date: Date(), words: []), analysis: dog)
    #expect(try await store.peopleDirtyVersion() == v0)
    #expect(try await store.needsPeoplePass() == false)

    // Saving a face dirties People.
    let vector = (0..<64).map { Float($0 % 5) / 5 }.withUnsafeBytes { Data($0) }
    var withFace = ItemAnalysis()
    withFace.faces = [DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), featurePrint: vector)]
    try await store.save(ItemMetadata(id: "f1", date: Date(), words: []), analysis: withFace)
    let v1 = try await store.peopleDirtyVersion()
    #expect(v1 > v0)
    #expect(try await store.needsPeoplePass() == true)

    // Stored k0..k3 buckets are loaded on IndexedFace without recomputing.
    let clustering = try await store.facesForClustering()
    #expect(clustering.count == 1)
    #expect(clustering[0].buckets == FaceClustering.buckets(vector))

    // Running updatePeople assigns the face and marks clean.
    let indexer = LibraryIndexer(store: store, spotlight: nil)
    #expect(await indexer.updatePeople() == true)
    #expect(try await store.needsPeoplePass() == false)

    // Second call skips immediately.
    #expect(await indexer.updatePeople() == false)

    // Reopening the database on cold launch keeps clean state.
    let reopened = LibraryIndexStore(directory: dir)
    #expect(try await reopened.needsPeoplePass() == false)

    // Naming or hiding a person bumps peopleDirtyVersion (for Spotlight) without triggering a full merge pass.
    let personID = try #require(try await reopened.faces().first?.person)
    let beforeNameDirty = try await reopened.peopleDirtyVersion()
    let beforeNameClustering = try await reopened.peopleClusteringVersion()
    try await reopened.name(person: personID, "Ada")
    #expect(try await reopened.peopleDirtyVersion() > beforeNameDirty)
    #expect(try await reopened.peopleClusteringVersion() == beforeNameClustering)
    #expect(try await reopened.needsPeoplePass() == false)
    let named = try await reopened.namedPeople()
    #expect(named.count == 1)
    #expect(named[0].name == "Ada")
    #expect(named[0].photoCount == 1)
    #expect(try await reopened.personName(id: personID) == "Ada")

    let beforeHideDirty = try await reopened.peopleDirtyVersion()
    try await reopened.hide(person: personID)
    #expect(try await reopened.peopleDirtyVersion() > beforeHideDirty)
    #expect(try await reopened.peopleClusteringVersion() == beforeNameClustering)
    #expect(try await reopened.needsPeoplePass() == false)

    // Refused merge does not bump the dirty counter.
    let beforeRefused = try await reopened.peopleDirtyVersion()
    #expect(try await reopened.mergePeople([personID: personID]) == false)
    #expect(try await reopened.peopleDirtyVersion() == beforeRefused)
  }

  @MainActor
  @Test("updatePeople settles merges cleanly so the next pass does not re-scan")
  func updatePeopleSettlesMergesCleanly() async throws {
    let store = makeStore()
    let vector = (0..<64).map { Float($0 % 5) / 5 }.withUnsafeBytes { Data($0) }
    var withFace = ItemAnalysis()
    withFace.faces = [DetectedFace(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), featurePrint: vector)]
    try await store.save(ItemMetadata(id: "p1", date: Date(), words: []), analysis: withFace)
    try await store.save(ItemMetadata(id: "p2", date: Date(), words: []), analysis: withFace)
    let faces = try await store.faces()
    // Assign identical faces to two distinct people so phase 2 must merge them.
    try await store.assignFaces([faces[0].id: 1, faces[1].id: 2])
    #expect(try await store.needsPeoplePass() == true)

    let indexer = LibraryIndexer(store: store, spotlight: nil)
    #expect(await indexer.updatePeople() == true)
    // After settling merges, needsPeoplePass must be false without needing another pass.
    #expect(try await store.needsPeoplePass() == false)
    #expect(await indexer.updatePeople() == false)
  }

  @MainActor
  @Test("rekeyDeleted moves confirmed-deleted device analysis to Google id so next pass needs zero Google analysis")
  func rekeyDeletedPreventsCloudReanalysis() async throws {
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("mountain", 0.92)]
    analysis.text = "Alps Summit"
    try await store.save(
      ItemMetadata(id: "DEV-CLEAN", date: Date(timeIntervalSince1970: 5_000), words: ["photo"]), analysis: analysis)

    let browsedPrimary = TransferRecord(
      id: "browsed@example.com|DEV-CLEAN", filename: "IMG_1.HEIC", mediaType: "Photo", status: .deleted,
      sentAccountEmails: ["browsed@example.com"],
      mediaKeysByAccount: ["browsed@example.com": "M_CLEAN", "other@example.com": "M_OTHER"],
      assetLocalIdentifier: "DEV-CLEAN", resourceRole: .primary)
    let rawCompanion = TransferRecord(
      id: "browsed@example.com|DEV-CLEAN|raw", filename: "IMG_1.DNG", mediaType: "Photo", status: .deleted,
      sentAccountEmails: ["browsed@example.com"],
      mediaKeysByAccount: ["browsed@example.com": "M_RAW"],
      assetLocalIdentifier: "DEV-CLEAN", resourceRole: .alternatePhoto)

    let pairs = LibraryIndexer.rekeyPairs(for: [browsedPrimary, rawCompanion], accountEmail: "browsed@example.com")
    #expect(pairs.count == 1)
    #expect(pairs[0].from == "DEV-CLEAN")
    #expect(pairs[0].to == LibraryIndexer.searchID(cloudMediaKey: "M_CLEAN"))

    let email = "browsed@example.com"
    let cloud = try await rekeyCloud(email: email, items: [rekeyItem("M_CLEAN")])
    LockedItems.load([], accountEmail: email)
    defer { LockedItems.forget(accountEmail: email) }
    let rekey = LibraryIndexer.scheduleRekeyDeleted([browsedPrimary, rawCompanion], cloud: cloud, store: store)
    await rekey?.value
    await cloud.retire()

    let cloudItem = RemoteItemSummary(
      mediaKey: "M_CLEAN", dedupKey: "D1", sha1: nil, kind: .photo, takenAt: Date(timeIntervalSince1970: 5_000),
      contentVersion: 1, durationMs: nil, isFavorite: false, trashedAt: nil, width: 100, height: 100,
      fileName: "IMG_1.HEIC")
    let postCleanupSnapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.cloud(0)], device: [], cloud: [cloudItem], folder: [], cloudLibrary: nil)
    let currentIDs = LibraryIndexer.indexIDs(postCleanupSnapshot)
    _ = try await store.prune(keeping: currentIDs, device: true, folder: false, cloud: true)

    let settled = try await store.settledIDs()
    let pending = LibraryIndexer.workItems(postCleanupSnapshot, settled: settled)
    #expect(pending.isEmpty)
    #expect(try await store.search([["mountain"]]) == ["g:M_CLEAN"])
    #expect(try await store.search([["summit"]]) == ["g:M_CLEAN"])
  }

  @MainActor
  @Test("Rekey needs a visible mirror target and rechecks the lock and Library at the write")
  func rekeySkipsLockedMissingAndRetiredTargets() async throws {
    let email = "rekey-\(UUID().uuidString)@example.com"
    let cloud = try await rekeyCloud(email: email, items: [rekeyItem("locked", locked: true), rekeyItem("open"), rekeyItem("second")])
    LockedItems.load([], accountEmail: email)
    defer { LockedItems.forget(accountEmail: email) }
    let store = makeStore()
    for id in ["locked", "missing", "open", "retired"] {
      var analysis = ItemAnalysis()
      analysis.labels = [("mountain", 0.9)]
      try await store.save(ItemMetadata(id: id, date: Date(), words: []), analysis: analysis)
    }
    func deleted(_ key: String) -> TransferRecord {
      TransferRecord(
        id: "\(email)|\(key)", filename: "\(key).jpg", mediaType: "Photo", status: .deleted,
        sentAccountEmails: [email], mediaKeysByAccount: [email: key], assetLocalIdentifier: key, resourceRole: .primary)
    }

    let rekey = LibraryIndexer.scheduleRekeyDeleted([deleted("locked"), deleted("missing")], cloud: cloud, store: store)
    await rekey?.value
    #expect(Set(try await store.search([["mountain"]])) == ["locked", "missing", "open", "retired"])

    // The mirror's lookup may already have returned an open key when a new page locks it.
    LockedItems.insert(["open"], accountEmail: email)
    try await store.rekeyKnownUnlocked([(from: "open", to: "g:open")], cloud: cloud)
    #expect(Set(try await store.search([["mountain"]])).contains("open"))

    LockedItems.release(["open"], accountEmail: email)
    cloud.cancelSync()
    try await store.rekeyKnownUnlocked([(from: "retired", to: "g:second")], cloud: cloud)
    #expect(Set(try await store.search([["mountain"]])).contains("retired"))
    await cloud.retire()
  }

  @MainActor
  @Test("Scheduling post-delete rekey returns before the queued work can run")
  func postDeleteRekeyIsBestEffort() async throws {
    let email = "rekey-\(UUID().uuidString)@example.com"
    let cloud = try await rekeyCloud(email: email, items: [rekeyItem("open")])
    LockedItems.load([], accountEmail: email)
    defer { LockedItems.forget(accountEmail: email) }
    let store = makeStore()
    var analysis = ItemAnalysis()
    analysis.labels = [("mountain", 0.9)]
    try await store.save(ItemMetadata(id: "device", date: Date(), words: []), analysis: analysis)
    let record = TransferRecord(
      id: "\(email)|device", filename: "device.jpg", mediaType: "Photo", status: .deleted,
      sentAccountEmails: [email], mediaKeysByAccount: [email: "open"], assetLocalIdentifier: "device", resourceRole: .primary)
    let rekey = try #require(LibraryIndexer.scheduleRekeyDeleted([record], cloud: cloud, store: store))
    // Same actor turn as scheduling. Cleanup can return and the account can retire before rekey starts.
    cloud.cancelSync()
    await rekey.value
    #expect(try await store.search([["mountain"]]) == ["device"])
    await cloud.retire()
  }

  @MainActor
  private func rekeyCloud(email: String, items: [RemoteMediaItem]) async throws -> CloudLibrary {
    let remote = RemoteLibraryStore(accountEmail: email, directory: TestTemporaryDirectory.root.appending(path: UUID().uuidString))
    try await remote.apply(
      RemoteLibraryUpdate(
        syncToken: "t", resumeToken: "", items: items, deletedMediaKeys: [], triggersNextSync: false, albums: [],
        deletedAlbumKeys: []),
      syncToken: "t")
    let client = GooglePhotosMobileClient(authService: GoogleAuthService())
    return CloudLibrary(
      accountEmail: email, store: remote, fetcher: client,
      thumbnails: GoogleThumbnailSource(client: client, accountEmail: email), actionClient: nil)
  }

  private func rekeyItem(_ key: String, locked: Bool = false) -> RemoteMediaItem {
    RemoteMediaItem(
      mediaKey: key, dedupKey: "d-\(key)", sha1: nil, fileName: "\(key).jpg", caption: nil, kind: .photo,
      sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: Date(), timezoneOffsetMinutes: nil,
      uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false, isFavorite: false, isLocked: locked,
      isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100, latitude: nil, longitude: nil,
      locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil, shutterSpeed: nil, iso: nil,
      focalLength: nil, durationMs: nil)
  }

  @MainActor
  @Test("LibraryIndexer.search fails closed for locked or signed-out Google items")
  func indexerSearchFailsClosedForLockedItems() async throws {
    let dir = TestTemporaryDirectory.root.appending(path: "SearchLocked-\(UUID().uuidString)")
    let store = LibraryIndexStore(directory: dir.appending(path: "index"))
    let remoteStore = RemoteLibraryStore(accountEmail: "search@example.com", directory: dir.appending(path: "remote"))

    var analysis = ItemAnalysis()
    analysis.labels = [("sunset", 0.95)]
    try await store.save(ItemMetadata(id: "g:LOCKED_S", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "g:OPEN_S", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "DEV_S", date: Date(), words: []), analysis: analysis)

    let lockedItem = RemoteMediaItem(
      mediaKey: "LOCKED_S", dedupKey: "DL", sha1: nil, fileName: "secret.jpg", caption: nil, kind: .photo,
      sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: Date(), timezoneOffsetMinutes: nil,
      uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false, isFavorite: false, isLocked: true,
      isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100, latitude: nil, longitude: nil,
      locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil, shutterSpeed: nil, iso: nil,
      focalLength: nil, durationMs: nil)
    let openItem = RemoteMediaItem(
      mediaKey: "OPEN_S", dedupKey: "DO", sha1: nil, fileName: "open.jpg", caption: nil, kind: .photo,
      sizeBytes: 10, quotaChargedBytes: 0, isOriginalQuality: true, takenAt: Date(), timezoneOffsetMinutes: nil,
      uploadedAt: nil, contentVersion: 1, trashedAt: nil, isArchived: false, isFavorite: false, isLocked: false,
      isCanonical: true, isEdited: false, origin: 0, width: 100, height: 100, latitude: nil, longitude: nil,
      locationName: nil, cameraMake: nil, cameraModel: nil, aperture: nil, shutterSpeed: nil, iso: nil,
      focalLength: nil, durationMs: nil)
    try await remoteStore.apply(
      RemoteLibraryUpdate(
        syncToken: "t", resumeToken: "", items: [lockedItem, openItem], deletedMediaKeys: [],
        triggersNextSync: false, albums: [], deletedAlbumKeys: []),
      syncToken: "t")

    struct StubFetcher: RemoteLibraryFetching {
      private static var empty: RemoteLibraryUpdate {
        RemoteLibraryUpdate(
          syncToken: "", resumeToken: "", items: [], deletedMediaKeys: [], triggersNextSync: false, albums: [],
          deletedAlbumKeys: [])
      }
      func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
      func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate { Self.empty }
    }
    final class EmptyThumbSource: ThumbnailSource, @unchecked Sendable {
      func requestImage(
        id: String, pixelSize: CGSize, quality: ImageRequestQuality,
        onUnavailable: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CGImage, Bool) -> Void
      ) -> ImageRequestToken { .none }
    }
    let cloud = CloudLibrary(
      accountEmail: "search@example.com", store: remoteStore, fetcher: StubFetcher(), thumbnails: EmptyThumbSource(),
      actionClient: nil)
    let previousCloud = SiriLibrary.shared.cloud
    let previousLoad = SiriLibrary.shared.loadAccounts
    SiriLibrary.shared.loadAccounts = nil
    SiriLibrary.shared.cloud = cloud
    defer {
      SiriLibrary.shared.cloud = previousCloud
      SiriLibrary.shared.loadAccounts = previousLoad
    }

    let indexer = LibraryIndexer(store: store, spotlight: nil)
    let found = await indexer.search("sunset")
    #expect(Set(found) == ["g:OPEN_S", "DEV_S"])

    // Signed out / unavailable cloud fails closed for all g: items.
    SiriLibrary.shared.cloud = nil
    let signedOut = await indexer.search("sunset")
    #expect(signedOut == ["DEV_S"])
  }

  @Test("Rekey moves analysis from device id to Google id, handles collisions and drops prints")
  func rekeyMovesAnalysis() async throws {
    let store = makeStore()
    let vector = (0..<64).map { Float($0) / 64 }.withUnsafeBytes { Data($0) }
    var analysis = ItemAnalysis()
    analysis.labels = [("beach", 0.9), ("sunset", 0.8)]
    analysis.text = "Boardwalk Cafe"
    analysis.aesthetics = 0.85
    analysis.isUtility = true
    analysis.featurePrint = vector
    analysis.faces = [DetectedFace(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), featurePrint: vector)]
    try await store.save(
      ItemMetadata(id: "DEV-1", date: Date(timeIntervalSince1970: 10_000), words: ["July"]), analysis: analysis)
    let faceID = try #require(try await store.faces().first?.id)
    try await store.assignFaces([faceID: 42])
    try await store.name(person: 42, "Sam")

    // Target already exists as metadata-only (has_pixels = 0) with Google place/caption metadata.
    try await store.saveAll(
      [(ItemMetadata(id: "g:M1", date: Date(timeIntervalSince1970: 10_000), words: ["Paris", "google"]), nil)],
      pixelsPending: true)

    // Second pair whose target already has pixel analysis must be skipped.
    var existingCloud = ItemAnalysis()
    existingCloud.labels = [("cat", 0.95)]
    try await store.save(ItemMetadata(id: "DEV-2", date: Date(), words: []), analysis: analysis)
    try await store.save(ItemMetadata(id: "g:M2", date: Date(), words: []), analysis: existingCloud)

    let moved = try await store.rekey([(from: "DEV-1", to: "g:M1"), (from: "DEV-2", to: "g:M2")])
    #expect(moved == 1)

    // Device id is gone; Google id is settled with pixels, labels, OCR, merged Google metadata and face.
    let settled = try await store.settledIDs()
    #expect(!settled.contains("DEV-1"))
    #expect(settled.contains("g:M1"))
    #expect(try await store.pixelAnalyzedIDs().contains("g:M1"))
    #expect(try await store.search([["beach"]]) == ["DEV-2", "g:M1"])
    #expect(try await store.search([["boardwalk"]]) == ["DEV-2", "g:M1"])
    #expect(try await store.search([["paris"]]) == ["g:M1"])
    #expect(try await store.ids(ofPerson: 42) == ["g:M1"])
    #expect(try await store.utilityCount() == 2)

    // Feature print was dropped for the rekeyed Google item (device DEV-2 still keeps its print).
    var printedIDs: [String] = []
    try await store.forEachPrintByTime { id, _, _, _ in printedIDs.append(id) }
    #expect(!printedIDs.contains("DEV-1"))
    #expect(!printedIDs.contains("g:M1"))
    #expect(printedIDs.contains("DEV-2"))

    // Target with existing pixel analysis kept its own analysis.
    #expect(try await store.search([["cat"]]) == ["g:M2"])
  }

  @Test("Unaligned Data slices compute face buckets and streaming similarity safely")
  func unalignedFloatBuffers() {
    let raw = (0..<64).map { sin(Float($0)) }.withUnsafeBytes { Data($0) }
    var padded = Data([0xFF])
    padded.append(raw)
    let unalignedSlice = padded.dropFirst()
    #expect(FaceClustering.buckets(unalignedSlice) == FaceClustering.buckets(raw))

    var sim = StreamingSimilarity()
    sim.add(id: "a", date: Date(timeIntervalSince1970: 100), print: unalignedSlice, score: 0.5)
    sim.add(id: "b", date: Date(timeIntervalSince1970: 105), print: unalignedSlice, score: 0.8)
    #expect(sim.groups() == [[0, 1]])
  }

  @MainActor
  @Test("Backed-up folder files analyze local pixels under their Google id with zero Google requests")
  func folderAnalysisUsesLocalPixels() async throws {
    let dir = TestTemporaryDirectory.root.appending(path: "FolderIndex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appending(path: "IMG_1001.png")

    // Create a local PNG with clear text so Vision analyzes it locally on both platforms.
    let context = try #require(
      CGContext(
        data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    let cgImage = try #require(context.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, cgImage, nil)
    #expect(CGImageDestinationFinalize(dest))

    let folderItem = FolderItemInfo(path: fileURL.path, date: Date(timeIntervalSince1970: 2_000), size: 1024, isVideo: false)
    let missingItem = FolderItemInfo(
      path: dir.appending(path: "missing.png").path, date: Date(timeIntervalSince1970: 3_000), size: 1024, isVideo: false)
    let cloudItem = RemoteItemSummary(
      mediaKey: "M_LOCAL", dedupKey: "D1", sha1: nil, kind: .photo, takenAt: Date(timeIntervalSince1970: 2_000),
      contentVersion: 1, durationMs: nil, isFavorite: false, trashedAt: nil, width: 256, height: 256,
      fileName: "IMG_1001.png")
    let missingCloud = RemoteItemSummary(
      mediaKey: "M_MISSING", dedupKey: "D2", sha1: nil, kind: .photo, takenAt: Date(timeIntervalSince1970: 3_000),
      contentVersion: 1, durationMs: nil, isFavorite: false, trashedAt: nil, width: 256, height: 256,
      fileName: "missing.png")
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: [.folder(0, cloud: 0), .folder(1, cloud: 1)], device: [], cloud: [cloudItem, missingCloud],
      folder: [folderItem, missingItem], cloudLibrary: nil)

    let work = LibraryIndexer.workItems(snapshot, settled: [])
    #expect(work.count == 2)
    #expect(work[0].id == "g:M_LOCAL")
    #expect(work[0].file?.path == fileURL.path)
    #expect(work[0].cloud?.mediaKey == "M_LOCAL")

    let store = makeStore()
    let indexer = LibraryIndexer(store: store, spotlight: nil)
    // `cloudLibrary` is nil (no GoogleThumbnailSource exists at all): local analysis must succeed
    // for the readable file and return only the missing file for cloud fallback.
    let fallback = await indexer.analyzeLocalFiles(work, in: snapshot) { _ in }
    #expect(fallback.map(\.id) == ["g:M_MISSING"])
    #expect(try await store.analyzedIDs().contains("g:M_LOCAL"))
    #expect(try await store.settledIDs().contains("g:M_LOCAL"))
  }

  @Test("Places extracts newest-first points from the unfiltered timeline")
  func placesNewestFirstAndUnfiltered() {
    let older = DeviceItemInfo(
      localIdentifier: "OLD", date: Date(timeIntervalSince1970: 1_000), width: 10, height: 10, isVideo: false,
      isFavorite: false, latitude: 48.85, longitude: 2.35)
    let newer = DeviceItemInfo(
      localIdentifier: "NEW", date: Date(timeIntervalSince1970: 2_000), width: 10, height: 10, isVideo: false,
      isFavorite: true, latitude: 48.85, longitude: 2.35)
    // TimelineMerge expects inputs newest first and outputs oldest first.
    let device = [newer, older]
    let filtered = TimelineMerge.merge(device: device, cloud: [], uploadedMediaKeys: [:], filter: .favorites)
    var inputs = UnifiedLibraryModel.MergeInputs()
    inputs.isFiltered = true
    let snapshot = UnifiedLibraryModel.IndexSnapshot(
      entries: filtered, device: device, cloud: [], folder: [], cloudLibrary: nil, inputs: inputs)
    let points = PlacesView.points(snapshot.unfiltered())
    #expect(points.map(\.id) == ["NEW", "OLD"])
  }

  @Test("Low Data Mode turning off posts didChangeConstrained without firing didReconnect")
  func constrainedChangeNotification() {
    let monitor = NetworkStatusMonitor(watches: false)
    let constrainedCount = LockedCounter()
    let reconnectCount = LockedCounter()
    let cToken = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didChangeConstrained, object: monitor, queue: nil
    ) { _ in constrainedCount.increment() }
    let rToken = NotificationCenter.default.addObserver(
      forName: NetworkStatusMonitor.didReconnect, object: monitor, queue: nil
    ) { _ in reconnectCount.increment() }
    defer {
      NotificationCenter.default.removeObserver(cToken)
      NotificationCenter.default.removeObserver(rToken)
    }

    monitor.update(isConnected: true, isExpensive: false, isConstrained: true)
    let beforeFlipConstrained = constrainedCount.value
    let beforeFlipReconnect = reconnectCount.value
    monitor.update(isConnected: true, isExpensive: false, isConstrained: false)
    #expect(constrainedCount.value == beforeFlipConstrained + 1)
    #expect(reconnectCount.value == beforeFlipReconnect)
  }

  #if os(macOS)
    private func picture(_ name: String) -> CGImage? {
      let url = URL(filePath: "/System/Library/Desktop Pictures/.thumbnails/\(name).heic")
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @Test("OCR language correction cost on a local text thumbnail")
    func ocrCost() async throws {
      let context = try #require(
        CGContext(
          data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
      let text = NSAttributedString(
        string: "Welcome to Brighton",
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
      context.textPosition = CGPoint(x: 25, y: 250)
      CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
      let image = try #require(context.makeImage())
      try await Task.detached(priority: .utility) {
        for (level, correction) in [(RecognizeTextRequest.RecognitionLevel.fast, false), (.fast, true)] {
          var request = RecognizeTextRequest()
          request.recognitionLevel = level
          request.usesLanguageCorrection = correction
          _ = try await request.perform(on: image)
          let start = ContinuousClock.now
          for _ in 0..<3 {
            let results = try await request.perform(on: image)
            #expect(results.map(\.transcript).joined(separator: " ").contains("Brighton"))
          }
          print("SEARCH OCR \(level) correction=\(correction): \(start.duration(to: .now) / 3)")
        }
      }.value
    }

    @Test("Vision finds labels, a feature print and a quality score in a real photo")
    func analyzer() async throws {
      guard let image = picture("Big Sur Coastline") else { return }
      let analysis = try await ItemAnalyzer.analyze(image)
      #expect(!analysis.labels.isEmpty)
      #expect(analysis.featurePrint?.count == 768 * 4)
    }

    @Test("Comparing raw prints with vDSP gives Vision's own distance")
    func printDistance() throws {
      guard let first = picture("Big Sur Coastline"), let second = picture("Big Sur Aerial") else { return }
      func observation(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try #require(request.results?.first)
      }
      var expected: Float = 0
      try observation(first).computeDistance(&expected, to: observation(second))
      let vectors = FeatureVectors([ItemAnalyzer.rawFeaturePrint(first), ItemAnalyzer.rawFeaturePrint(second), nil])
      let distance = try #require(vectors.distance(0, 1))
      #expect(abs(distance - Double(expected)) < 0.0001)
      #expect(vectors.distance(0, 0) == 0)
      #expect(vectors.distance(0, 2) == nil)
    }
  #endif
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
