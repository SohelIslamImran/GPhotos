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
    #expect(average < .milliseconds(30))
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
    #expect(elapsed < .seconds(1))
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
    #expect(elapsed < .milliseconds(250))
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
