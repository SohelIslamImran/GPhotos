import Foundation

/// Item records for Siri, beside the analysis they come from. The table isn't part of the
/// analysis schema: it's rebuilt from the Library on the next pass whenever it's missing.
extension LibraryIndexStore {
  static func createSiriTables(in database: SQLiteDatabase) throws {
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS siri_items (id TEXT PRIMARY KEY, digest INTEGER NOT NULL, source TEXT NOT NULL,
        file_name TEXT NOT NULL, date REAL, video INTEGER NOT NULL, favorite INTEGER NOT NULL, lat REAL, lon REAL,
        place TEXT NOT NULL, caption TEXT NOT NULL, labels TEXT NOT NULL, content TEXT NOT NULL, people TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS siri_items_date ON siri_items (date);
      """)
  }

  /// The digest of every stored record, by id.
  func siriDigests() throws -> [String: Int64] {
    var digests: [String: Int64] = [:]
    try db().query("SELECT id, digest FROM siri_items") { row in
      if let id = row.text(0) { digests[id] = row.int(1) }
    }
    return digests
  }

  /// Stores records with the key that says when each needs indexing again.
  @discardableResult
  func saveSiri(_ records: [(record: SiriItemRecord, key: Int64)], cloud: CloudLibrary? = nil) throws -> [String] {
    guard cloud?.isIndexingCurrent != false else { return [] }
    let locked = Self.lockedIDs(among: records.lazy.map { $0.record.id })
    let records = records.filter { !locked.contains($0.record.id) }
    guard !records.isEmpty else { return [] }
    let database = try db()
    try database.transaction {
      for (record, key) in records {
        try database.run(
          """
          INSERT OR REPLACE INTO siri_items (id, digest, source, file_name, date, video, favorite, lat, lon, place, caption,
            labels, content, people) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(record.id), .int(key), .text(record.source.rawValue), .text(record.fileName),
            .optional(record.date), .bool(record.isVideo), .bool(record.isFavorite), .optional(record.latitude),
            .optional(record.longitude), .text(record.place), .text(record.caption),
            .text(record.labels.joined(separator: "\n")), .text(record.text), .text(record.people.joined(separator: "\n")),
          ])
      }
    }
    return records.map { $0.record.id }
  }

  func deleteSiri(_ ids: [String]) throws {
    guard !ids.isEmpty else { return }
    try db().run("DELETE FROM siri_items WHERE id IN (SELECT value FROM json_each(?))", [try .list(ids)])
  }

  /// Stored records for these ids, in the order given; unknown ids are skipped.
  public func siriRecords(ids: [String]) throws -> [SiriItemRecord] {
    guard !ids.isEmpty else { return [] }
    var found: [String: SiriItemRecord] = [:]
    let database = try db()
    for start in stride(from: 0, to: ids.count, by: 500) {
      let chunk = ids[start..<min(start + 500, ids.count)]
      try database.query(
        Self.siriSelect + " WHERE id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
        chunk.map { .text($0) }
      ) { row in
        if let record = Self.siriRecord(row) { found[record.id] = record }
      }
    }
    return ids.compactMap { found[$0] }
  }

  /// The newest items, or the newest favorites, for Siri's suggestions.
  public func recentSiriRecords(limit: Int, favoritesOnly: Bool = false) throws -> [SiriItemRecord] {
    var records: [SiriItemRecord] = []
    try db().query(
      Self.siriSelect + (favoritesOnly ? " WHERE favorite = 1" : "") + " ORDER BY date DESC LIMIT ?",
      [.int(Int64(limit))]
    ) { row in
      if let record = Self.siriRecord(row) { records.append(record) }
    }
    return records
  }

  /// Ids of items taken in a date range, newest first.
  public func siriIDs(takenIn range: Range<Date>, limit: Int) throws -> [String] {
    try siriIDs(period: range, limit: limit)
  }

  /// Ids of the newest items in a period (any time when nil), only videos or favorites
  /// when asked. The limit applies after the filters.
  func siriIDs(
    period: Range<Date>?, videosOnly: Bool = false, favoritesOnly: Bool = false, limit: Int
  ) throws
    -> [String]
  {
    var conditions: [String] = []
    var values: [SQLiteDatabase.Value] = []
    if let period {
      conditions.append("date >= ? AND date < ?")
      values += [.double(period.lowerBound.timeIntervalSince1970), .double(period.upperBound.timeIntervalSince1970)]
    }
    if videosOnly { conditions.append("video = 1") }
    if favoritesOnly { conditions.append("favorite = 1") }
    let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    var ids: [String] = []
    try db().query("SELECT id FROM siri_items\(filter) ORDER BY date DESC LIMIT ?", values + [.int(Int64(limit))]) {
      if let id = $0.text(0) { ids.append(id) }
    }
    return ids
  }

  func allSiriIDs() throws -> [String] {
    var ids: [String] = []
    try db().query("SELECT id FROM siri_items ORDER BY date DESC") { if let id = $0.text(0) { ids.append(id) } }
    return ids
  }

  public func siriRecordCount() throws -> Int {
    var count = 0
    try db().query("SELECT COUNT(*) FROM siri_items") { count = Int($0.int(0)) }
    return count
  }

  /// Labels, text and people for the given ids. Labels below the confidence search uses
  /// are left out.
  func siriFacts(for ids: Set<String>, minimumConfidence: Double = 0.5) throws -> [String: SiriItemFacts] {
    guard !ids.isEmpty else { return [:] }
    var facts: [String: SiriItemFacts] = [:]
    for (id, labels) in try siriLabels(for: Array(ids), minimumConfidence: minimumConfidence) {
      facts[id, default: SiriItemFacts()].labels = labels
    }
    for (id, text) in try siriTexts(for: ids) { facts[id, default: SiriItemFacts()].text = text }
    for (id, names) in try personNamesByItem() where ids.contains(id) {
      facts[id, default: SiriItemFacts()].people = Array(Set(names)).sorted()
    }
    return facts
  }

  /// Each item's confident labels, most confident first, looked up by id.
  func siriLabels(for ids: [String], minimumConfidence: Double = 0.5) throws -> [String: [String]] {
    var labels: [String: [String]] = [:]
    let database = try db()
    for start in stride(from: 0, to: ids.count, by: 500) {
      let chunk = ids[start..<min(start + 500, ids.count)]
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      try database.query(
        "SELECT id, label FROM labels WHERE confidence >= ? AND id IN (\(placeholders)) ORDER BY confidence DESC",
        [.double(minimumConfidence)] + chunk.map { .text($0) }
      ) { row in
        guard let id = row.text(0), let label = row.text(1) else { return }
        labels[id, default: []].append(label.replacingOccurrences(of: "_", with: " "))
      }
    }
    return labels
  }

  /// The text found in each of these items, cut to what Spotlight keeps. `search.id` can't
  /// be looked up (FTS5 seeks by rowid only), so a pass reads the text index once rather
  /// than once per batch.
  func siriTexts(for ids: Set<String>) throws -> [String: String] {
    guard !ids.isEmpty else { return [:] }
    var texts: [String: String] = [:]
    try db().query("SELECT id, content FROM search WHERE content != ''") { row in
      guard let id = row.text(0), ids.contains(id), let text = row.text(1) else { return }
      texts[id] = String(text.prefix(SiriItemRecord.maximumTextLength))
    }
    return texts
  }

  /// When each item was last analyzed, so a pass looks up facts only for items that changed.
  func analyzedStamps() throws -> [String: Double] {
    var stamps: [String: Double] = [:]
    try db().query("SELECT id, analyzed_at FROM analyzed") { row in
      if let id = row.text(0) { stamps[id] = row.double(1) }
    }
    return stamps
  }

  private static let siriSelect =
    "SELECT id, source, file_name, date, video, favorite, lat, lon, place, caption, labels, content, people FROM siri_items"

  private static func siriRecord(_ row: SQLiteDatabase.Row) -> SiriItemRecord? {
    guard let id = row.text(0), let source = SiriItemRecord.Source(rawValue: row.text(1) ?? "") else { return nil }
    func lines(_ column: Int32) -> [String] {
      (row.text(column) ?? "").split(separator: "\n").map(String.init)
    }
    return SiriItemRecord(
      id: id, source: source, fileName: row.text(2) ?? "", date: row.optionalDouble(3).map(Date.init(timeIntervalSince1970:)),
      isVideo: row.int(4) != 0, isFavorite: row.int(5) != 0, latitude: row.optionalDouble(6),
      longitude: row.optionalDouble(7), place: row.text(8) ?? "", caption: row.text(9) ?? "", labels: lines(10),
      text: row.text(11) ?? "", people: lines(12))
  }
}
