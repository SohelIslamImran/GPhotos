import Foundation

/// What analysis found in one item.
public struct ItemAnalysis: Sendable, Equatable {
  public var labels: [(name: String, confidence: Float)] = []
  public var text = ""
  public var featurePrint: Data?
  public var faces: [DetectedFace] = []
  public var aesthetics: Float?
  /// A screenshot, receipt, document or similar.
  public var isUtility = false
  /// Faces too small in the thumbnail waited for a larger image that wasn't available
  /// (not on the device yet, or skipped while paused): the item is analyzed again later.
  public var facesIncomplete = false

  public init() {}

  public static func == (lhs: ItemAnalysis, rhs: ItemAnalysis) -> Bool {
    lhs.labels.map(\.name) == rhs.labels.map(\.name) && lhs.text == rhs.text && lhs.featurePrint == rhs.featurePrint
      && lhs.faces == rhs.faces && lhs.aesthetics == rhs.aesthetics && lhs.isUtility == rhs.isUtility
      && lhs.facesIncomplete == rhs.facesIncomplete
  }
}

public struct DetectedFace: Sendable, Equatable {
  /// Normalized, origin at the top left.
  public var rect: CGRect
  public var featurePrint: Data
  public var quality: Double = 1
}

/// Searchable facts that come from metadata rather than pixels.
public struct ItemMetadata: Sendable, Equatable {
  public var id: String
  public var date: Date?
  public var words: [String]

  public init(id: String, date: Date?, words: [String]) {
    self.id = id
    self.date = date
    self.words = words
  }
}

public struct IndexedFace: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let itemID: String
  public let rect: CGRect
  public let featurePrint: Data
  public var person: Int64?
  public var quality: Double = 1
}

public struct Person: Sendable, Equatable, Identifiable {
  public let id: Int64
  public var name: String?
  public var faceCount: Int
  public var cover: IndexedFace?
}

/// The on-device index behind search, duplicates, People and Memories: Vision labels, text
/// in photos and metadata words in an FTS5 table, plus feature prints, faces and quality
/// scores. One database for the device; Google Photos items are keyed by their thumbnail
/// id, so switching accounts keeps the device's analysis.
public actor LibraryIndexStore {
  private let url: URL
  private var database: SQLiteDatabase?
  /// Every distinct label, read once and dropped when items are written.
  private var labelCache: [String]?
  /// Bumped when analysis changes, so old results are redone.
  public static let analysisVersion = 9
  /// How the stored faces' prints were made. Prints made another way can't be compared
  /// with new ones, and People built from them would mix the two, so when it changes they
  /// go at once, with the people made of them; analysis then finds the faces again.
  static let faceModel = "vision-featureprint-224-1.25"
  private static let schemaVersion = 7
  /// Device items whose pixels couldn't be analyzed (no local thumbnail yet) are tried
  /// again after this long.
  static let pixelRetryInterval: TimeInterval = 3 * 24 * 60 * 60

  public init(directory: URL? = nil) {
    url = (directory ?? URL.applicationSupportDirectory.appending(path: "LibraryIndex", directoryHint: .isDirectory))
      .appending(path: "index.sqlite")
  }

  func db() throws -> SQLiteDatabase {
    if let database { return database }
    let database = try SQLiteDatabase(url: url)
    var version = 0
    try database.query("PRAGMA user_version") { version = Int($0.int(0)) }
    if version != Self.schemaVersion {
      try database.execute(
        """
        DROP TABLE IF EXISTS search_vocab; DROP TABLE IF EXISTS analyzed; DROP TABLE IF EXISTS labels; DROP TABLE IF EXISTS search;
        DROP TABLE IF EXISTS prints; DROP TABLE IF EXISTS faces; DROP TABLE IF EXISTS people;
        CREATE TABLE analyzed (id TEXT PRIMARY KEY, version INTEGER NOT NULL, taken_at REAL, aesthetics REAL,
          utility INTEGER NOT NULL DEFAULT 0, has_pixels INTEGER NOT NULL DEFAULT 0, analyzed_at REAL NOT NULL DEFAULT 0);
        CREATE INDEX analyzed_taken ON analyzed (taken_at);
        CREATE TABLE labels (id TEXT NOT NULL, label TEXT NOT NULL, confidence REAL NOT NULL);
        CREATE INDEX labels_label ON labels (label, confidence DESC, id);
        CREATE INDEX labels_id ON labels (id);
        -- Vowel signs (Mc, Mn) stay inside words, as Bengali and other Indic scripts need.
        CREATE VIRTUAL TABLE search USING fts5 (id UNINDEXED, labels, content, meta, tokenize = "unicode61 remove_diacritics 2 categories 'L* N* Co Mc Mn'");
        CREATE VIRTUAL TABLE search_vocab USING fts5vocab(search, 'col');
        CREATE TABLE prints (id TEXT PRIMARY KEY, data BLOB NOT NULL);
        CREATE TABLE faces (face INTEGER PRIMARY KEY, id TEXT NOT NULL, x REAL, y REAL, w REAL, h REAL, data BLOB NOT NULL,
          person INTEGER, quality REAL NOT NULL, k0 INTEGER, k1 INTEGER, k2 INTEGER, k3 INTEGER);
        CREATE INDEX faces_k0 ON faces(k0, person);
        CREATE INDEX faces_k1 ON faces(k1, person);
        CREATE INDEX faces_k2 ON faces(k2, person);
        CREATE INDEX faces_k3 ON faces(k3, person);
        CREATE INDEX faces_id ON faces (id);
        CREATE INDEX faces_person ON faces (person);
        CREATE TABLE people (person INTEGER PRIMARY KEY, name TEXT, hidden INTEGER NOT NULL DEFAULT 0);
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }
    try Self.createSiriTables(in: database)
    try database.execute(
      "CREATE TABLE IF NOT EXISTS resource_hashes (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, digest BLOB, checked_at REAL NOT NULL)")
    try database.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    var faceModel: String?
    try database.query("SELECT value FROM meta WHERE key = 'face_model'") { faceModel = $0.text(0) }
    if faceModel != Self.faceModel {
      try database.transaction {
        try database.run("DELETE FROM faces")
        try database.run("DELETE FROM people")
        try database.run(
          "INSERT OR REPLACE INTO meta (key, value) VALUES ('face_model', ?)", [.text(Self.faceModel)])
      }
    }
    self.database = database
    return database
  }

  #if DEBUG
    /// For tests: records another face model, as an older build would have.
    func markFaceModel(_ model: String) throws {
      try db().run("INSERT OR REPLACE INTO meta (key, value) VALUES ('face_model', ?)", [.text(model)])
    }
  #endif

  // MARK: Writing

  func resourceHash(id: String, fingerprint: String, now: Date = Date()) throws -> (digest: Data?, checked: Bool) {
    var result: (digest: Data?, checked: Bool) = (nil, false)
    try db().query("SELECT digest, checked_at FROM resource_hashes WHERE id = ? AND fingerprint = ?", [.text(id), .text(fingerprint)]) {
      row in
      let digest = row.blob(0) ?? Data()
      result = (digest.isEmpty ? nil : digest, !digest.isEmpty || now.timeIntervalSince1970 - row.double(1) < 86400)
    }
    return result
  }

  func saveResourceHash(id: String, fingerprint: String, digest: Data?, now: Date = Date()) throws {
    try db().run(
      "INSERT OR REPLACE INTO resource_hashes (id, fingerprint, digest, checked_at) VALUES (?, ?, ?, ?)",
      [.text(id), .text(fingerprint), digest.map { .blob($0) } ?? .null, .double(now.timeIntervalSince1970)])
  }

  /// Ids analyzed with the current analysis version.
  public func analyzedIDs() throws -> Set<String> {
    var ids = Set<String>()
    try db().query("SELECT id FROM analyzed WHERE version = ?", [.int(Int64(Self.analysisVersion))]) {
      if let id = $0.text(0) { ids.insert(id) }
    }
    return ids
  }

  /// Ids that don't need indexing again now: everything current, except items whose
  /// pixels weren't analyzed a while ago, or haven't been tried yet (Google Photos items
  /// are saved with their metadata first). Folder files never are, by design.
  public func settledIDs(now: Date = Date()) throws -> Set<String> {
    var ids = Set<String>()
    try db().query(
      """
      SELECT id FROM analyzed
      WHERE version = ? AND (has_pixels = 1 OR id LIKE 'f:%' OR analyzed_at > ?)
      """, [.int(Int64(Self.analysisVersion)), .double(now.timeIntervalSince1970 - Self.pixelRetryInterval)]
    ) { if let id = $0.text(0) { ids.insert(id) } }
    return ids
  }

  /// Removes items that have left the library (deleted, trashed, or now shown as their
  /// device copy), so suggestion counts, categories and People count only what's there.
  /// Each kind (device, folder `f:`, Google `g:`) is pruned only when its list was loaded.
  @discardableResult
  public func prune(keeping current: Set<String>, device: Bool, folder: Bool, cloud: Bool) throws -> Int {
    let database = try db()
    var stale: [(id: String, rowID: Int64)] = []
    try database.query("SELECT id, rowid FROM analyzed") { row in
      guard let id = row.text(0), !current.contains(id) else { return }
      let prunes = id.hasPrefix("g:") ? cloud : id.hasPrefix(FolderItemInfo.idPrefix) ? folder : device
      if prunes { stale.append((id, row.int(1))) }
    }
    guard !stale.isEmpty else { return 0 }
    labelCache = nil
    try database.transaction {
      for (id, rowID) in stale {
        let value = SQLiteDatabase.Value.text(id)
        try database.run("DELETE FROM labels WHERE id = ?", [value])
        try database.run("DELETE FROM search WHERE rowid = ?", [.int(rowID)])
        try database.run("DELETE FROM faces WHERE id = ?", [value])
        try database.run("DELETE FROM prints WHERE id = ?", [value])
        try database.run("DELETE FROM analyzed WHERE id = ?", [value])
      }
    }
    return stale.count
  }

  public struct PhotoScore: Sendable {
    /// Nil when the pixels weren't analyzed.
    public var aesthetics: Float?
    /// A screenshot, document or receipt.
    public var isUtility: Bool
    public var date: Date?
  }

  /// What picking widget photos needs to know about each item.
  public func photoScores(ids: [String]) throws -> [String: PhotoScore] {
    var scores: [String: PhotoScore] = [:]
    let database = try db()
    for start in stride(from: 0, to: ids.count, by: 500) {
      let chunk = Array(ids[start..<min(start + 500, ids.count)])
      try database.query(
        "SELECT id, aesthetics, utility, taken_at FROM analyzed WHERE id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
        chunk.map { .text($0) }
      ) { row in
        guard let id = row.text(0) else { return }
        scores[id] = PhotoScore(
          aesthetics: row.optionalDouble(1).map(Float.init), isUtility: row.int(2) != 0,
          date: row.optionalDouble(3).map(Date.init(timeIntervalSince1970:)))
      }
    }
    return scores
  }

  /// Where the person's best face is in each of their photos: its eye line, which a crop
  /// keeps in view, normalized with the origin at the top left.
  public func faceCenters(person: Int64, ids: [String]) throws -> [String: CGPoint] {
    var centers: [String: (point: CGPoint, quality: Double)] = [:]
    let database = try db()
    for start in stride(from: 0, to: ids.count, by: 500) {
      let chunk = Array(ids[start..<min(start + 500, ids.count)])
      try database.query(
        """
        SELECT id, x, y, w, h, quality FROM faces
        WHERE person = ? AND id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))
        """, [.int(person)] + chunk.map { .text($0) }
      ) { row in
        guard let id = row.text(0) else { return }
        let quality = row.double(5)
        guard quality > centers[id]?.quality ?? -1 else { return }
        centers[id] = (CGPoint(x: row.double(1) + row.double(3) / 2, y: row.double(2) + row.double(4) * 0.4), quality)
      }
    }
    return centers.mapValues(\.point)
  }

  /// The best-looking analyzed photos that aren't screenshots or documents, best first.
  public func featuredIDs(limit: Int) throws -> [String] {
    var ids: [String] = []
    try db().query(
      """
      SELECT id FROM analyzed
      WHERE has_pixels = 1 AND utility = 0 AND aesthetics IS NOT NULL AND id NOT LIKE 'f:%'
      ORDER BY aesthetics DESC LIMIT ?
      """, [.int(Int64(limit))]
    ) { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  /// Ids whose pixels were analyzed (metadata-only entries are excluded).
  public func pixelAnalyzedIDs() throws -> Set<String> {
    var ids = Set<String>()
    try db().query("SELECT id FROM analyzed WHERE version = ? AND has_pixels = 1", [.int(Int64(Self.analysisVersion))]) {
      if let id = $0.text(0) { ids.insert(id) }
    }
    return ids
  }

  /// Stores one item's metadata and, when its pixels were analyzed, what Vision found.
  public func save(_ metadata: ItemMetadata, analysis: ItemAnalysis?) throws {
    try saveAll([(metadata, analysis)])
  }

  /// Saves many items in one transaction: one commit for hundreds of metadata-only
  /// items instead of one each. With `pixelsPending` the items are searchable by their
  /// metadata now and stay unsettled until their pixels are tried.
  public func saveAll(_ items: [(metadata: ItemMetadata, analysis: ItemAnalysis?)], pixelsPending: Bool = false) throws {
    guard !items.isEmpty else { return }
    let database = try db()
    labelCache = nil
    try database.transaction {
      for (metadata, analysis) in items {
        try write(metadata, analysis: analysis, pixelsPending: pixelsPending, in: database)
      }
    }
  }

  private func write(
    _ metadata: ItemMetadata, analysis: ItemAnalysis?, pixelsPending: Bool, in database: SQLiteDatabase
  ) throws {
    let id = SQLiteDatabase.Value.text(metadata.id)
    do {
      var searchRowID: Int64?
      try database.query("SELECT rowid FROM analyzed WHERE id = ?", [id]) { searchRowID = $0.int(0) }
      if let searchRowID {
        try database.run("DELETE FROM labels WHERE id = ?", [id])
        try database.run("DELETE FROM search WHERE rowid = ?", [.int(searchRowID)])
        try database.run("DELETE FROM faces WHERE id = ?", [id])
        // A pass that produced no print must not leave the previous one for Similar Photos.
        try database.run("DELETE FROM prints WHERE id = ?", [id])
      }
      try database.run(
        """
        INSERT OR REPLACE INTO analyzed (id, version, taken_at, aesthetics, utility, has_pixels, analyzed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id, .int(Int64(Self.analysisVersion)), .optional(metadata.date), .optional(analysis?.aesthetics.map(Double.init)),
          .bool(analysis?.isUtility ?? false), .bool(analysis.map { !$0.facesIncomplete } ?? false),
          .double(pixelsPending ? 0 : Date().timeIntervalSince1970),
        ])
      var accepted: [String: Float] = [:]
      for label in analysis?.labels ?? [] where label.confidence >= ItemAnalyzer.minimumLabelConfidence {
        let name = SearchVocabulary.canonical(label.name)
        guard !SearchVocabulary.generic.contains(name) else { continue }
        accepted[name] = max(accepted[name] ?? 0, label.confidence)
      }
      for (name, confidence) in accepted {
        try database.run(
          "INSERT INTO labels (id, label, confidence) VALUES (?, ?, ?)",
          [id, .text(name), .double(Double(confidence))])
      }
      try database.run(
        "INSERT INTO search (rowid, id, labels, content, meta) VALUES ((SELECT rowid FROM analyzed WHERE id = ?), ?, ?, ?, ?)",
        [
          id, id, .text(Self.searchableLabels(Array(accepted.keys))), .text(analysis?.text ?? ""),
          .text(metadata.words.joined(separator: " ")),
        ])
      if let print = analysis?.featurePrint {
        try database.run("INSERT OR REPLACE INTO prints (id, data) VALUES (?, ?)", [id, .blob(print)])
      }
      for face in analysis?.faces ?? [] {
        let keys = FaceClustering.buckets(face.featurePrint)
        try database.run(
          "INSERT INTO faces (id, x, y, w, h, data, quality, k0, k1, k2, k3) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            id, .double(face.rect.minX), .double(face.rect.minY), .double(face.rect.width), .double(face.rect.height),
            .blob(face.featurePrint), .double(face.quality),
          ] + (0..<4).map { keys.indices.contains($0) ? .int(keys[$0]) : .null })
      }
    }
  }

  /// Vision's labels use underscores ("sea_ocean"); words make them searchable.
  static func searchableLabels(_ labels: [String]) -> String {
    labels.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " ")
  }

  public func removeAll() throws {
    database = nil
    labelCache = nil
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix)) }
  }

  // MARK: Search

  /// Every term is required: its first word is the one typed, the rest are alternatives
  /// (other forms of the word, or labels that mean nearly the same, which may be several
  /// words: "palm_tree"). Only the final typed word completes labels/metadata; OCR and
  /// alternatives always match whole words.
  public func search(_ terms: [[String]], limit: Int = 5_000, completingLastWord: Bool = true) throws -> [String] {
    guard limit > 0 else { return [] }
    // What a label earns when a query term names it: the typed word and its other forms
    // count twice as much as a related label.
    var wordWeights: [String: Int] = [:]
    var labelWeights: [String: Int] = [:]
    let clauses = terms.enumerated().compactMap { index, alternatives -> String? in
      guard let typed = alternatives.first, let original = Self.ftsWord(typed) else { return nil }
      let isLast = completingLastWord && index == terms.count - 1
      let prefix = SearchVocabulary.isUnspaced(original) || (isLast && original.count >= 2)
      var fields = ["{labels meta} : \"\(original)\"\(prefix ? "*" : "")"]
      wordWeights[original] = 4
      let forms = Set(SearchVocabulary.forms(original))
      for alternative in alternatives.dropFirst() {
        let words = SearchVocabulary.tokens(SearchVocabulary.folded(alternative))
        guard !words.isEmpty else { continue }
        fields.append("{labels meta} : \"\(words.joined(separator: " "))\"")
        if words.count == 1, forms.contains(words[0]) {
          wordWeights[words[0]] = 4
        } else {
          let label = words.joined(separator: "_")
          labelWeights[label] = max(labelWeights[label] ?? 0, 2)
        }
      }
      let content = "content : \"\(original)\"\(SearchVocabulary.isUnspaced(original) ? "*" : "")"
      return "(" + (fields + [content]).joined(separator: " OR ") + ")"
    }
    guard !clauses.isEmpty else { return [] }
    let boosts = try allLabels().compactMap { label -> (label: String, weight: Int)? in
      (label.split(separator: "_").compactMap { wordWeights[String($0)] } + [labelWeights[label] ?? 0]).max()
        .flatMap { $0 > 0 ? (label, $0) : nil }
    }
    // The label boost is worked out once per query from the labels index, then joined to
    // the text matches by rowid (each item's search row shares its `analyzed` rowid),
    // instead of a subquery for every matching item.
    let boost =
      boosts.isEmpty
      ? "SELECT NULL AS item, 0 AS value WHERE 0"
      : """
      SELECT a.rowid AS item, MAX(l.confidence * CASE l.label \(boosts.map { _ in "WHEN ? THEN ?" }.joined(separator: " ")) END)
        AS value
      FROM labels l JOIN analyzed a ON a.id = l.id
      WHERE l.label IN (\(boosts.map { _ in "?" }.joined(separator: ","))) GROUP BY l.id
      """
    let boostValues: [SQLiteDatabase.Value] =
      boosts.flatMap { [.text($0.label), .int(Int64($0.weight))] } + boosts.map { .text($0.label) }
    var ids: [String] = []
    try db().query(
      """
      WITH boost AS MATERIALIZED (\(boost))
      SELECT s.id FROM search s JOIN analyzed a ON a.rowid = s.rowid LEFT JOIN boost b ON b.item = s.rowid
      WHERE search MATCH ?
      ORDER BY COALESCE(b.value, 0) DESC, bm25(search, 0, 3, 1, 2), a.taken_at DESC, s.id LIMIT ?
      """,
      boostValues + [.text(clauses.joined(separator: " AND ")), .int(Int64(limit))]
    ) { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  static func ftsWord(_ word: String) -> String? {
    let tokens = SearchVocabulary.tokens(SearchVocabulary.folded(word))
    return tokens.count == 1 ? tokens[0] : nil
  }

  /// Specific, reliable subjects with at least three distinct photos by default.
  /// Covers combine confidence and aesthetics, prefer non-utility images, then recency. Synonyms are canonicalized on write.
  public func categories(limit: Int = 24, minimumCount: Int = 3, minimumConfidence: Double = 0.5) throws -> [SearchCategory] {
    guard limit > 0 else { return [] }
    let excluded = SearchVocabulary.categoryExcluded.sorted()
    let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ",")
    var result: [SearchCategory] = []
    try db().query(
      """
      WITH ranked AS (
        SELECT l.label, l.id, COUNT(*) OVER (PARTITION BY l.label) AS n,
          ROW_NUMBER() OVER (PARTITION BY l.label ORDER BY a.utility,
            (l.confidence * 0.8 + (COALESCE(a.aesthetics, 0) + 1) * 0.1) DESC,
            l.confidence DESC, a.taken_at DESC, l.id) AS rank
        FROM labels l JOIN analyzed a ON a.id = l.id WHERE l.confidence >= ? AND l.label NOT IN (\(placeholders))
      ) SELECT label, n, id FROM ranked WHERE rank = 1 AND n >= ? ORDER BY n DESC, label LIMIT ?
      """, [.double(minimumConfidence)] + excluded.map { .text($0) } + [.int(Int64(max(1, minimumCount))), .int(Int64(limit))]
    ) { row in
      guard let label = row.text(0), let sample = row.text(2) else { return }
      result.append(
        SearchCategory(label: label, displayName: SearchVocabulary.displayName(label), count: Int(row.int(1)), sampleID: sample))
    }
    return result
  }

  public func allLabels() throws -> [String] {
    if let labelCache { return labelCache }
    var labels: [String] = []
    try db().query("SELECT DISTINCT label FROM labels") { if let label = $0.text(0) { labels.append(label) } }
    labelCache = labels
    return labels
  }

  public func ids(withLabel label: String, minimumConfidence: Double = 0.5) throws -> [String] {
    var ids: [String] = []
    try db().query(
      """
      SELECT l.id FROM labels l JOIN analyzed a ON a.id = l.id
      WHERE l.label = ? AND l.confidence >= ? ORDER BY l.confidence DESC, a.taken_at DESC, l.id
      """, [.text(SearchVocabulary.canonical(label)), .double(minimumConfidence)]
    ) { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  /// Vocabulary range seeks avoid scanning the library while typing. Counts are distinct
  /// documents per field, not occurrence counts. Metadata includes places, dates and captions.
  public func suggestions(for prefix: String, limit: Int = 12) throws -> [SearchSuggestion] {
    // The last word is completed; words before it stay as typed.
    let typed = SearchVocabulary.tokens(prefix)
    guard limit > 0, let last = typed.last, let word = Self.ftsWord(last),
      word.count >= 2 || SearchVocabulary.isUnspaced(word)
    else { return [] }
    let lead = typed.dropLast().joined(separator: " ")
    var columns: [[SearchSuggestion]] = []
    for (column, kind) in [("labels", SearchSuggestion.Kind.category), ("meta", .metadata), ("content", .text)] {
      var found: [SearchSuggestion] = []
      // Terms come back in alphabetical order; a wider range is read so the most common
      // completions ("cat", "car") aren't cut off by rarer ones that sort first ("cab").
      try db().query(
        "SELECT term, doc FROM search_vocab WHERE term >= ? AND term < ? AND col = ? LIMIT 200",
        [.text(word), .text(word + "\u{10FFFF}"), .text(column)]
      ) { row in
        guard let term = row.text(0) else { return }
        let title = kind == .category ? SearchVocabulary.displayName(term) : term
        found.append(
          SearchSuggestion(
            kind: kind, title: lead.isEmpty ? title : lead + " " + title,
            query: lead.isEmpty ? term : lead + " " + term, count: Int(row.int(1))))
      }
      columns.append(found.sorted { $0.count == $1.count ? $0.query < $1.query : $0.count > $1.count })
    }
    // Taken in turns, so subjects can't crowd out places and text in photos.
    var result: [SearchSuggestion] = []
    for rank in 0..<limit {
      for column in columns where rank < column.count && result.count < limit { result.append(column[rank]) }
    }
    return result
  }

  public func utilityIDs() throws -> [String] {
    var ids: [String] = []
    try db().query("SELECT id FROM analyzed WHERE utility = 1 ORDER BY taken_at DESC") {
      if let id = $0.text(0) { ids.append(id) }
    }
    return ids
  }

  // MARK: Prints, quality and faces

  /// Feature prints with capture times, oldest first, for finding similar neighbours.
  /// Feature prints with capture times, oldest first, handed over one row at a time so
  /// the whole table never sits in memory.
  public func forEachPrintByTime(_ body: (_ id: String, _ date: Date, _ data: Data, _ aesthetics: Float?) -> Void) throws {
    try db().query(
      """
      SELECT p.id, a.taken_at, p.data, a.aesthetics FROM prints p JOIN analyzed a ON a.id = p.id
      WHERE a.taken_at IS NOT NULL ORDER BY a.taken_at
      """
    ) { row in
      guard let id = row.text(0), let data = row.blob(2) else { return }
      body(id, Date(timeIntervalSince1970: row.double(1)), data, row.optionalDouble(3).map(Float.init))
    }
  }

  /// Similar-photo groups among `existing` items (ones deleted since analysis drop out),
  /// newest group first, streamed so only a small window of prints is in memory.
  public func similarGroups(existing: Set<String>) throws -> [[(id: String, score: Float?)]] {
    var grouping = StreamingSimilarity()
    try forEachPrintByTime { id, date, data, score in
      guard existing.contains(id) else { return }
      grouping.add(id: id, date: date, print: data, score: score)
    }
    let ids = grouping.ids
    let scores = grouping.scores
    return grouping.groups().reversed().map { group in group.map { (ids[$0], scores[$0]) } }
  }

  public func unassignedFaceCount() throws -> Int {
    var count = 0
    try db().query("SELECT COUNT(*) FROM faces WHERE person IS NULL") { count = Int($0.int(0)) }
    return count
  }

  /// A page of faces and a bounded shortlist of nearby references, never all vectors.
  public func facesForClustering(after cursor: Int64 = 0, newFaces limit: Int = 128) throws -> [IndexedFace] {
    let database = try db()
    var seeds: [IndexedFace] = []
    try database.query(
      "SELECT face, id, x, y, w, h, data, person, quality FROM faces WHERE person IS NULL AND face > ? ORDER BY face LIMIT ?",
      [.int(cursor), .int(Int64(limit))]
    ) { if let face = Self.readFace($0) { seeds.append(face) } }
    return try clusteringCandidates(seeds)
  }

  public func peopleForMerging(after person: Int64) throws -> (faces: [IndexedFace], next: Int64)? {
    var seeds: [IndexedFace] = []
    try db().query(
      """
      SELECT face, id, x, y, w, h, data, person, quality FROM (
        SELECT face, id, x, y, w, h, data, person, quality,
          ROW_NUMBER() OVER (PARTITION BY person ORDER BY quality DESC, face) AS rank
        FROM faces WHERE person > ?
      ) WHERE rank = 1 ORDER BY person LIMIT 128
      """, [.int(person)]
    ) { if let face = Self.readFace($0) { seeds.append(face) } }
    guard let next = seeds.last?.person else { return nil }
    return (try clusteringCandidates(seeds), next)
  }

  private static func readFace(_ row: SQLiteDatabase.Row) -> IndexedFace? {
    guard let id = row.text(1), let data = row.blob(6) else { return nil }
    return IndexedFace(
      id: row.int(0), itemID: id,
      rect: CGRect(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5)),
      featurePrint: data, person: row.optionalInt(7), quality: row.double(8))
  }

  private func clusteringCandidates(_ seeds: [IndexedFace]) throws -> [IndexedFace] {
    let database = try db()
    var selected = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0) })
    for seed in seeds {
      let keys = FaceClustering.buckets(seed.featurePrint)
      guard keys.count == 4 else { continue }
      var clauses: [String] = []
      var bindings: [SQLiteDatabase.Value] = []
      for index in 0..<4 {
        let neighbors = [keys[index]] + (0..<10).map { keys[index] ^ (1 << $0) }
        // Each bucket is capped before anything is ranked or a print is read, so a crowded
        // bucket costs at most a few hundred index entries.
        clauses.append(
          "SELECT face FROM (SELECT face FROM faces WHERE k\(index) IN (\(Array(repeating: "?", count: 11).joined(separator: ","))) "
            + "AND person IS NOT NULL LIMIT 256)")
        bindings += neighbors.map { .int($0) }
      }
      try database.query(
        """
        WITH hits AS (\(clauses.joined(separator: " UNION "))),
        ranked AS (
          SELECT f.face, f.quality, ROW_NUMBER() OVER (PARTITION BY f.person ORDER BY f.quality DESC, f.face) AS rank
          FROM faces f WHERE f.face IN (SELECT face FROM hits)
        ),
        chosen AS (SELECT face FROM ranked WHERE rank <= 5 ORDER BY quality DESC, face LIMIT 64)
        SELECT face, id, x, y, w, h, data, person, quality FROM faces WHERE face IN (SELECT face FROM chosen)
        """,
        bindings
      ) { if let face = Self.readFace($0) { selected[face.id] = face } }
    }
    return selected.values.sorted { $0.quality == $1.quality ? $0.id < $1.id : $0.quality > $1.quality }
  }

  public func peopleNames() throws -> [Int64: String] {
    var names: [Int64: String] = [:]
    try db().query("SELECT person, name FROM people WHERE name IS NOT NULL") {
      if let name = $0.text(1) { names[$0.int(0)] = name }
    }
    return names
  }

  /// Re-check the complete membership, including faces outside the reference shortlist.
  /// Returns whether any merge was made.
  @discardableResult
  public func mergePeople(_ merges: [Int64: Int64]) throws -> Bool {
    guard !merges.isEmpty else { return false }
    var merged = false
    let database = try db()
    try database.transaction {
      for source in merges.keys.sorted() {
        var target = merges[source]!
        var visited: Set<Int64> = [source]
        while let next = merges[target], visited.insert(target).inserted { target = next }
        guard !visited.contains(target) else { continue }
        var conflicts = 0
        try database.query(
          "SELECT COUNT(*) FROM faces a JOIN faces b ON a.id = b.id WHERE a.person = ? AND b.person = ?",
          [.int(source), .int(target)]
        ) { conflicts = Int($0.int(0)) }
        guard conflicts == 0 else { continue }
        var names: [String] = []
        try database.query("SELECT name FROM people WHERE person IN (?, ?) AND name IS NOT NULL", [.int(source), .int(target)]) {
          if let name = $0.text(0) { names.append(name) }
        }
        // Two named people stay apart even with the same name: two friends can share one.
        guard names.count <= 1 else { continue }
        // Someone hidden stays hidden when a duplicate of them is found.
        try Self.move(source, into: target, keepingHidden: true, in: database)
        merged = true
      }
    }
    return merged
  }

  /// The user says two people are one: every face of `source` moves to `target`, which
  /// keeps its name (or takes the other's) and stays as shown or hidden as it was. False
  /// if either is gone, as when indexing merged it away while its page was open.
  @discardableResult
  public func merge(person source: Int64, into target: Int64) throws -> Bool {
    guard source != target else { return false }
    let database = try db()
    var merged = false
    try database.transaction {
      var found = 0
      try database.query("SELECT COUNT(*) FROM people WHERE person IN (?, ?)", [.int(source), .int(target)]) {
        found = Int($0.int(0))
      }
      guard found == 2 else { return }
      try Self.move(source, into: target, keepingHidden: false, in: database)
      merged = true
    }
    return merged
  }

  private static func move(_ source: Int64, into target: Int64, keepingHidden: Bool, in database: SQLiteDatabase) throws {
    try database.run(
      "UPDATE people SET name = COALESCE(name, (SELECT name FROM people WHERE person = ?)) WHERE person = ?",
      [.int(source), .int(target)])
    if keepingHidden {
      try database.run(
        "UPDATE people SET hidden = MAX(hidden, COALESCE((SELECT hidden FROM people WHERE person = ?), 0)) WHERE person = ?",
        [.int(source), .int(target)])
    }
    try database.run("UPDATE faces SET person = ? WHERE person = ?", [.int(target), .int(source)])
    try database.run("DELETE FROM people WHERE person = ?", [.int(source)])
  }

  public func faces() throws -> [IndexedFace] {
    var faces: [IndexedFace] = []
    try db().query("SELECT face, id, x, y, w, h, data, person FROM faces") { row in
      guard let id = row.text(1), let data = row.blob(6) else { return }
      faces.append(
        IndexedFace(
          id: row.int(0), itemID: id, rect: CGRect(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5)),
          featurePrint: data, person: row.optionalInt(7)))
    }
    return faces
  }

  /// Records which person each face belongs to; faces not mentioned keep theirs.
  public func assignFaces(_ assignments: [Int64: Int64]) throws {
    guard !assignments.isEmpty else { return }
    let database = try db()
    try database.transaction {
      for (face, person) in assignments {
        try database.run(
          "UPDATE faces SET person = ? WHERE face = ? AND NOT EXISTS (SELECT 1 FROM faces other WHERE other.person = ? AND other.id = faces.id AND other.face != faces.face)",
          [.int(person), .int(face), .int(person)])
      }
      try database.run("INSERT OR IGNORE INTO people (person) SELECT DISTINCT person FROM faces WHERE person IS NOT NULL")
    }
  }

  public func maxPersonID() throws -> Int64 {
    var value: Int64 = 0
    try db().query("SELECT COALESCE(MAX(person), 0) FROM people") { value = $0.int(0) }
    return value
  }

  /// People supported by distinct photos, with their best frontal capture as the cover.
  public func people(minimumFaces: Int = 5) throws -> [Person] {
    var people: [Person] = []
    try db().query(
      """
      WITH counts AS (
        SELECT person, COUNT(DISTINCT id) AS n FROM faces WHERE person IS NOT NULL GROUP BY person
      ), covers AS (
        SELECT face, id, x, y, w, h, person,
          ROW_NUMBER() OVER (PARTITION BY person ORDER BY quality DESC, w * h DESC, face) AS rank
        FROM faces WHERE person IN (SELECT person FROM counts)
      )
      SELECT p.person, p.name, c.n, v.face, v.id, v.x, v.y, v.w, v.h
      FROM people p JOIN counts c ON c.person = p.person JOIN covers v ON v.person = p.person AND v.rank = 1
      WHERE p.hidden = 0 AND (c.n >= ? OR p.name IS NOT NULL) ORDER BY c.n DESC, p.person
      """, [.int(Int64(minimumFaces))]
    ) { row in
      let person = row.int(0)
      let cover = row.text(4).map { itemID in
        IndexedFace(
          id: row.int(3), itemID: itemID,
          rect: CGRect(x: row.double(5), y: row.double(6), width: row.double(7), height: row.double(8)),
          featurePrint: Data(), person: person)
      }
      people.append(Person(id: person, name: row.text(1), faceCount: Int(row.int(2)), cover: cover))
    }
    return people
  }

  public func ids(ofPerson person: Int64) throws -> [String] {
    var ids: [String] = []
    try db().query(
      "SELECT DISTINCT f.id FROM faces f LEFT JOIN analyzed a ON a.id = f.id WHERE f.person = ? ORDER BY a.taken_at DESC",
      [.int(person)]
    ) { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  /// Names a person; their photos become searchable by that name.
  public func name(person: Int64, _ name: String?) throws {
    let database = try db()
    try database.transaction {
      try database.run("UPDATE people SET name = ? WHERE person = ?", [.optional(name), .int(person)])
    }
  }

  public func hide(person: Int64) throws {
    try db().run("UPDATE people SET hidden = 1 WHERE person = ?", [.int(person)])
  }

  /// People names as extra search words for each item.
  public func personNamesByItem() throws -> [String: [String]] {
    var names: [String: [String]] = [:]
    try db().query(
      "SELECT f.id, p.name FROM faces f JOIN people p ON p.person = f.person WHERE p.name IS NOT NULL AND p.hidden = 0"
    ) { row in
      guard let id = row.text(0), let name = row.text(1) else { return }
      names[id, default: []].append(name)
    }
    return names
  }

  public func search(personNamed query: String) throws -> [String] {
    var ids: [String] = []
    try db().query(
      """
      SELECT DISTINCT f.id FROM faces f JOIN people p ON p.person = f.person
      WHERE p.name LIKE ? AND p.hidden = 0
      """, [.text("%\(query)%")]
    ) { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  public func analyzedCount() throws -> (all: Int, pixels: Int) {
    var counts = (0, 0)
    try db().query("SELECT COUNT(*), SUM(has_pixels) FROM analyzed WHERE version = ?", [.int(Int64(Self.analysisVersion))]) {
      counts = (Int($0.int(0)), Int($0.int(1)))
    }
    return counts
  }
}
