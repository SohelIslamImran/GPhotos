import Foundation

/// Which part of the Google Photos library a view shows.
public enum RemoteScope: Hashable, Sendable {
  case library
  case favorites
  case videos
  case archive
  case trash
  case usesStorage
  case album(key: String, title: String)

  public var title: String {
    switch self {
    case .library: String(localized: "Google Photos")
    case .favorites: String(localized: "Favorites")
    case .videos: String(localized: "Videos")
    case .archive: String(localized: "Archive")
    case .trash: String(localized: "Trash")
    case .usesStorage: String(localized: "Uses Storage")
    case .album(_, let title): title
    }
  }

  public var symbol: String {
    switch self {
    case .library: "photo.on.rectangle.angled"
    case .favorites: "heart"
    case .videos: "video"
    case .archive: "archivebox"
    case .trash: "trash"
    case .usesStorage: "externaldrive.badge.icloud"
    case .album: "rectangle.stack"
    }
  }

  /// Locked Folder items are shown only on their own screen, behind device authentication
  /// (`RemoteLibraryStore.lockedSummaries`), never in a scope.
  var whereClause: String {
    // A shared album holds its own copy of each photo added to it (same hash, not
    // canonical); Google Photos lists only the original outside that album. Google marks
    // everything in Trash not canonical too, so Trash lists it all.
    switch self {
    case .library: "trashed_at IS NULL AND archived = 0 AND locked = 0 AND canonical = 1"
    case .favorites: "trashed_at IS NULL AND favorite = 1 AND locked = 0 AND canonical = 1"
    case .videos: "trashed_at IS NULL AND kind = 2 AND locked = 0 AND canonical = 1"
    case .archive: "trashed_at IS NULL AND archived = 1 AND locked = 0 AND canonical = 1"
    case .trash: "trashed_at IS NOT NULL AND locked = 0"
    case .usesStorage: "trashed_at IS NULL AND quota_charged > 0 AND locked = 0 AND canonical = 1"
    case .album: "trashed_at IS NULL AND locked = 0 AND collection_id = ?"
    }
  }

  var parameters: [SQLiteDatabase.Value] {
    if case .album(let key, _) = self { return [.text(key)] }
    return []
  }

  var orderClause: String { self == .trash ? "trashed_at DESC" : "taken_at DESC" }
}

/// The few columns a grid needs per item; 100k of them are a few megabytes.
public struct RemoteItemSummary: Sendable, Equatable, Identifiable {
  public let mediaKey: String
  public let dedupKey: String
  public let sha1: Data?
  public let kind: RemoteMediaItem.Kind
  public let takenAt: Date
  public let contentVersion: Int
  public let durationMs: Int?
  public let isFavorite: Bool
  public let trashedAt: Date?
  public let width: Int?
  public let height: Int?
  public var fileName: String = ""
  public var sizeBytes: Int64 = 0
  public var latitude: Double?
  public var longitude: Double?

  func hasSameMatchingMetadata(as other: Self) -> Bool {
    kind == other.kind && width == other.width && height == other.height
      && fileName == other.fileName && sha1 == other.sha1 && sizeBytes == other.sizeBytes
  }

  public var id: String { mediaKey }
}

public struct RemoteLibraryStats: Sendable, Equatable {
  public var items = 0
  public var photos = 0
  public var videos = 0
  public var bytes: Int64 = 0
  public var chargedItems = 0
  public var chargedBytes: Int64 = 0
  public var trashed = 0
  public var archived = 0
  /// Items in the Locked Folder, which no scope or count above includes.
  public var locked = 0
}

public struct RemoteSyncState: Sendable, Equatable {
  public var syncToken = ""
  public var resumeToken = ""
  var deltaToken: String?
  var deltaTriggersNextSync = false
  public var initialSyncDone = false
  public var lastSyncedAt: Date?
}

/// The local mirror of one account's Google Photos library, the source of truth for what
/// is in Google Photos. Each page of a sync is committed together with its tokens, so an
/// interrupted sync resumes where it stopped. The database can always be rebuilt from the
/// server, so a schema change just starts it over.
public actor RemoteLibraryStore {
  /// What a committed page changed. Pages that repeat what the mirror already has change
  /// nothing, so views don't reload for them.
  public struct Changes: Sendable, Equatable {
    /// Items added, changed or deleted.
    public var items = 0
    /// Albums added, changed or deleted.
    public var albums = 0
    /// Items that left the library: deleted, or moved to the Locked Folder.
    public var removals = 0
    /// Items moved to the Locked Folder while the library listed them.
    public var hidden = 0

    public var isEmpty: Bool { items == 0 && albums == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
      Changes(
        items: lhs.items + rhs.items, albums: lhs.albums + rhs.albums, removals: lhs.removals + rhs.removals,
        hidden: lhs.hidden + rhs.hidden)
    }
  }

  /// A closed store belongs to a library that was switched away from or removed; it never
  /// opens its database again, so a sync still finishing can't write to it.
  public struct ClosedError: Error {}

  public let accountEmail: String
  private let url: URL
  private var database: SQLiteDatabase?
  private var isClosed = false
  private static let schemaVersion = 5

  public init(accountEmail: String, directory: URL? = nil) {
    self.accountEmail = accountEmail
    let base = directory ?? Self.defaultDirectory
    url = base.appending(path: Self.fileName(for: accountEmail))
  }

  public static var defaultDirectory: URL {
    URL.applicationSupportDirectory.appending(path: "RemoteLibrary", directoryHint: .isDirectory)
  }

  static func fileName(for email: String) -> String {
    let safe = email.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
    return String(safe) + ".sqlite"
  }

  private func db() throws -> SQLiteDatabase {
    if let database { return database }
    guard !isClosed else { throw ClosedError() }
    if try Self.hasOlderSchema(url) { removeFiles() }
    let database = try SQLiteDatabase(url: url)
    // What's deleted or blanked is overwritten too, not only unlinked.
    try database.query("PRAGMA secure_delete = ON") { _ in }
    var version = 0
    try database.query("PRAGMA user_version") { version = Int($0.int(0)) }
    if version != Self.schemaVersion {
      try database.execute(
        """
        CREATE TABLE items (
          media_key TEXT PRIMARY KEY, dedup_key TEXT NOT NULL, sha1 BLOB, file_name TEXT NOT NULL, caption TEXT,
          kind INTEGER NOT NULL, size_bytes INTEGER NOT NULL, quota_charged INTEGER NOT NULL,
          original_quality INTEGER NOT NULL, taken_at REAL NOT NULL, tz_offset INTEGER, uploaded_at REAL,
          content_version INTEGER NOT NULL, trashed_at REAL, archived INTEGER NOT NULL, favorite INTEGER NOT NULL,
          locked INTEGER NOT NULL, canonical INTEGER NOT NULL, edited INTEGER NOT NULL, origin INTEGER NOT NULL,
          width INTEGER, height INTEGER, latitude REAL, longitude REAL, location_name TEXT, camera_make TEXT,
          camera_model TEXT, aperture REAL, shutter_speed REAL, iso INTEGER, focal_length REAL, duration_ms INTEGER,
          collection_id TEXT
        );
        CREATE INDEX items_taken ON items (taken_at DESC);
        CREATE INDEX items_sha1 ON items (sha1);
        CREATE INDEX items_collection ON items (collection_id);
        CREATE INDEX items_library ON items (taken_at DESC)
          WHERE trashed_at IS NULL AND archived = 0 AND locked = 0 AND canonical = 1;
        CREATE INDEX items_locked ON items (taken_at DESC) WHERE locked = 1 AND trashed_at IS NULL;
        CREATE TABLE albums (
          media_key TEXT PRIMARY KEY, title TEXT NOT NULL, item_count INTEGER NOT NULL, cover_media_key TEXT,
          start_date REAL, end_date REAL, last_activity REAL
        );
        CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT);
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }
    try database.execute("CREATE TABLE IF NOT EXISTS locked_purges (media_key TEXT PRIMARY KEY)")
    // A quit between a lock and its checkpoint left the old page in the file.
    try? database.checkpoint()
    self.database = database
    return database
  }

  private static func hasOlderSchema(_ url: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    var version = 0
    try SQLiteDatabase(url: url).query("PRAGMA user_version") { version = Int($0.int(0)) }
    return version != schemaVersion
  }

  // MARK: Sync state

  public func syncState() throws -> RemoteSyncState {
    var state = RemoteSyncState()
    try db().query("SELECT key, value FROM state") { row in
      let value = row.text(1) ?? ""
      switch row.text(0) {
      case "sync_token": state.syncToken = value
      case "resume_token": state.resumeToken = value
      case "delta_token": state.deltaToken = value
      case "delta_next": state.deltaTriggersNextSync = value == "1"
      case "initial_done": state.initialSyncDone = value == "1"
      case "synced_at": state.lastSyncedAt = Double(value).map(Date.init(timeIntervalSince1970:))
      default: break
      }
    }
    return state
  }

  private func setState(_ key: String, _ value: String, in database: SQLiteDatabase) throws {
    try database.run("INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)", [.text(key), .text(value)])
  }

  /// The next token belongs to a cycle whose pages haven't all been applied.
  func restartDelta(from token: String) throws {
    let database = try db()
    try database.transaction {
      try setState("sync_token", token, in: database)
      try database.run("DELETE FROM state WHERE key IN ('resume_token', 'delta_token', 'delta_next')")
    }
  }

  /// Applies one page and its tokens in a single transaction. `syncToken` nil keeps the
  /// stored one (pages after the first don't carry it). A delta's first page also records
  /// the request token until its last page commits. `willLock` is given the items this page moves to the Locked Folder just before it's committed, to delete what's kept of
  /// them: an app that quits in between applies the page again.
  @discardableResult
  public func apply(
    _ update: RemoteLibraryUpdate, syncToken: String?, now: Date = Date(), deltaToken: String? = nil,
    willLock: @Sendable (Set<String>) -> Void = { _ in }
  ) throws -> Changes {
    let database = try db()
    var locksItems = false
    let applied = try database.transaction {
      var changes = Changes()
      var locking = Set<String>()
      for item in update.items {
        let wasLocked = try isLocked(item.mediaKey, in: database)
        guard try upsert(item, in: database) else { continue }
        if wasLocked == true, !item.isLocked { changes.albums += 1 }
        changes.items += 1
        if item.isLocked {
          changes.removals += 1
          if wasLocked == false { changes.hidden += 1 }
          // A row that's new here may have been listed before the mirror was rebuilt.
          if wasLocked != true { locking.insert(item.mediaKey) }
        }
      }
      for key in update.deletedMediaKeys {
        try database.run("DELETE FROM items WHERE media_key = ?", [.text(key)])
        if database.changes > 0 {
          changes.items += 1
          changes.removals += 1
        }
      }
      for album in update.albums {
        try database.run(
          Self.albumUpsert,
          [
            .text(album.mediaKey), .text(album.title), .int(Int64(album.itemCount)), .optional(album.coverMediaKey),
            .optional(album.startDate), .optional(album.endDate), .optional(album.lastActivity),
          ])
        changes.albums += database.changes
      }
      for key in update.deletedAlbumKeys {
        try database.run("DELETE FROM albums WHERE media_key = ?", [.text(key)])
        changes.albums += database.changes
      }
      if let syncToken, !syncToken.isEmpty { try setState("sync_token", syncToken, in: database) }
      try setState("resume_token", update.resumeToken, in: database)
      if update.resumeToken.isEmpty {
        try database.run("DELETE FROM state WHERE key IN ('delta_token', 'delta_next')")
      } else if let deltaToken {
        try setState("delta_token", deltaToken, in: database)
        try setState("delta_next", update.triggersNextSync ? "1" : "0", in: database)
      }
      try setState("synced_at", String(now.timeIntervalSince1970), in: database)
      if !locking.isEmpty {
        try enqueueLockedPurges(locking, in: database)
        willLock(locking)
        locksItems = true
      }
      return changes
    }
    // Until then the file still holds what these rows were; a busy one is retried at open.
    if locksItems { try? database.checkpoint() }
    return applied
  }

  /// Applies a confirmed web move without changing the mobile sync cursor.
  func markLocked(_ keys: Set<String>, willLock: @Sendable (Set<String>) -> Void) throws {
    let database = try db()
    try database.transaction {
      for key in keys {
        if let item = try item(mediaKey: key) { _ = try upsertLocked(item, in: database) }
      }
      try enqueueLockedPurges(keys, in: database)
      willLock(keys)
    }
    try? database.checkpoint()
  }

  private func enqueueLockedPurges(_ keys: Set<String>, in database: SQLiteDatabase) throws {
    try database.run("INSERT OR IGNORE INTO locked_purges (media_key) SELECT value FROM json_each(?)", [try .list(keys)])
  }

  /// Even a key with no local Siri row may still have an older Spotlight entry.
  func enqueueExistingLockedKeys() throws {
    let database = try db()
    var seeded = false
    try database.query("SELECT 1 FROM state WHERE key = 'locked_index_reconciliation'") { _ in seeded = true }
    guard !seeded else { return }
    try database.transaction {
      try database.run("INSERT OR IGNORE INTO locked_purges SELECT media_key FROM items WHERE locked = 1")
      try setState("locked_index_reconciliation", "1", in: database)
    }
  }

  /// Items moved to the Locked Folder that the on-device index may still hold, kept from
  /// the transaction that locks them until `finishLockedPurges`. One unlocked since stays.
  func pendingLockedPurges() throws -> Set<String> {
    let database = try db()
    try database.run("DELETE FROM locked_purges WHERE media_key IN (SELECT media_key FROM items WHERE locked = 0)")
    var keys = Set<String>()
    try database.query("SELECT media_key FROM locked_purges") { if let key = $0.text(0) { keys.insert(key) } }
    return keys
  }

  func finishLockedPurges(_ keys: Set<String>) throws {
    try db().run("DELETE FROM locked_purges WHERE media_key IN (SELECT value FROM json_each(?))", [try .list(keys)])
  }

  /// Nil when the item isn't in the mirror.
  private func isLocked(_ mediaKey: String, in database: SQLiteDatabase) throws -> Bool? {
    var locked: Bool?
    try database.query("SELECT locked FROM items WHERE media_key = ?", [.text(mediaKey)]) { locked = $0.int(0) == 1 }
    return locked
  }

  public func markInitialSyncDone() throws {
    try setState("initial_done", "1", in: try db())
  }

  /// Forgets everything; the next sync starts from scratch.
  public func reset() throws {
    database = nil
    removeFiles()
  }

  /// Stops using the database for good; it stays on disk for the next library object.
  public func close() {
    isClosed = true
    database = nil
  }

  /// Closes the store and deletes the mirror, for sign-out and removed accounts.
  public func closeAndRemove() {
    close()
    removeFiles()
  }

  private func removeFiles() {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
    }
  }

  private static let itemColumns = [
    "media_key", "dedup_key", "sha1", "file_name", "caption", "kind", "size_bytes", "quota_charged", "original_quality",
    "taken_at", "tz_offset", "uploaded_at", "content_version", "trashed_at", "archived", "favorite", "locked", "canonical",
    "edited", "origin", "width", "height", "latitude", "longitude", "location_name", "camera_make", "camera_model",
    "aperture", "shutter_speed", "iso", "focal_length", "duration_ms", "collection_id",
  ]

  /// Writes a row only when something in it differs, so `changes` tells a real change from
  /// a page repeating what's stored.
  private static func upsertSQL(table: String, columns: [String]) -> String {
    let updated = columns.dropFirst()
    return """
      INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
      ON CONFLICT(\(columns[0])) DO UPDATE SET \(updated.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
      WHERE \(updated.map { "\(table).\($0) IS NOT excluded.\($0)" }.joined(separator: " OR "))
      """
  }

  private static let itemUpsert = upsertSQL(table: "items", columns: itemColumns)
  private static let albumUpsert = upsertSQL(
    table: "albums",
    columns: ["media_key", "title", "item_count", "cover_media_key", "start_date", "end_date", "last_activity"])

  /// True when the row was added or changed.
  private func upsert(_ item: RemoteMediaItem, in database: SQLiteDatabase) throws -> Bool {
    if item.isLocked { return try upsertLocked(item, in: database) }
    try database.run(
      Self.itemUpsert,
      [
        .text(item.mediaKey), .text(item.dedupKey), .optional(item.sha1), .text(item.fileName), .optional(item.caption),
        .int(Int64(item.kind.rawValue)), .int(item.sizeBytes), .int(item.quotaChargedBytes),
        .bool(item.isOriginalQuality), .double(item.takenAt.timeIntervalSince1970), .optional(item.timezoneOffsetMinutes),
        .optional(item.uploadedAt), .int(Int64(item.contentVersion)), .optional(item.trashedAt), .bool(item.isArchived),
        .bool(item.isFavorite), .bool(item.isLocked), .bool(item.isCanonical), .bool(item.isEdited),
        .int(Int64(item.origin)), .optional(item.width), .optional(item.height), .optional(item.latitude),
        .optional(item.longitude), .optional(item.locationName), .optional(item.cameraMake), .optional(item.cameraModel),
        .optional(item.aperture), .optional(item.shutterSpeed), .optional(item.iso), .optional(item.focalLength),
        .optional(item.durationMs), .optional(item.collectionID),
      ])
    return database.changes > 0
  }

  /// A Locked Folder item keeps only what marks it and lists it (its date, kind and shape):
  /// no name, caption, hash, place or camera reaches disk, and those stored before it was
  /// locked go.
  private func upsertLocked(_ item: RemoteMediaItem, in database: SQLiteDatabase) throws -> Bool {
    let listed: [String: SQLiteDatabase.Value] = [
      "media_key": .text(item.mediaKey), "dedup_key": .text(""), "file_name": .text(""), "kind": .int(Int64(item.kind.rawValue)),
      "size_bytes": .int(0), "quota_charged": .int(0), "original_quality": .bool(false),
      "taken_at": .double(item.takenAt.timeIntervalSince1970), "content_version": .int(Int64(item.contentVersion)),
      "trashed_at": .optional(item.trashedAt), "archived": .bool(item.isArchived), "favorite": .bool(false),
      "locked": .bool(true), "canonical": .bool(item.isCanonical), "edited": .bool(false), "origin": .int(0),
      "width": .optional(item.width), "height": .optional(item.height), "duration_ms": .optional(item.durationMs),
    ]
    try database.run(Self.itemUpsert, Self.itemColumns.map { listed[$0] ?? .null })
    return database.changes > 0
  }

  // MARK: Reading

  private static let summaryColumns = """
    media_key, dedup_key, sha1, kind, taken_at, content_version, duration_ms, favorite, trashed_at, width, height,
      file_name, size_bytes, latitude, longitude
    """

  private static func summary(_ row: SQLiteDatabase.Row) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: row.text(0) ?? "", dedupKey: row.text(1) ?? "", sha1: row.blob(2),
      kind: RemoteMediaItem.Kind(rawValue: Int(row.int(3))) ?? .photo,
      takenAt: Date(timeIntervalSince1970: row.double(4)), contentVersion: Int(row.int(5)),
      durationMs: row.optionalInt(6).map(Int.init), isFavorite: row.int(7) == 1,
      trashedAt: row.optionalDouble(8).map(Date.init(timeIntervalSince1970:)),
      width: row.optionalInt(9).map(Int.init), height: row.optionalInt(10).map(Int.init),
      fileName: row.text(11) ?? "", sizeBytes: row.int(12), latitude: row.optionalDouble(13), longitude: row.optionalDouble(14))
  }

  public func summaries(_ scope: RemoteScope) throws -> [RemoteItemSummary] {
    var result: [RemoteItemSummary] = []
    try db().query(
      "SELECT \(Self.summaryColumns) FROM items WHERE \(scope.whereClause) ORDER BY \(scope.orderClause)",
      scope.parameters
    ) { result.append(Self.summary($0)) }
    return result
  }

  /// The Locked Folder, newest first. Only its own screen reads it, once unlocked.
  public func lockedSummaries() throws -> [RemoteItemSummary] {
    var result: [RemoteItemSummary] = []
    try db().query(
      "SELECT \(Self.summaryColumns) FROM items WHERE locked = 1 AND trashed_at IS NULL ORDER BY taken_at DESC"
    ) { result.append(Self.summary($0)) }
    return result
  }

  /// Everything locked, in Trash too, for `LockedItems`.
  func lockedKeys() throws -> Set<String> {
    var keys = Set<String>()
    try db().query("SELECT media_key FROM items WHERE locked = 1") { if let key = $0.text(0) { keys.insert(key) } }
    return keys
  }

  /// Lookups by key (Siri, the info panel) never return a Locked Folder item.
  public func summary(mediaKey: String) throws -> RemoteItemSummary? {
    var result: RemoteItemSummary?
    try db().query("SELECT \(Self.summaryColumns) FROM items WHERE media_key = ? AND locked = 0", [.text(mediaKey)]) {
      result = Self.summary($0)
    }
    return result
  }

  public func item(mediaKey: String) throws -> RemoteMediaItem? {
    var item: RemoteMediaItem?
    try db().query("SELECT * FROM items WHERE media_key = ? AND locked = 0", [.text(mediaKey)]) { row in
      item = RemoteMediaItem(
        mediaKey: row.text(0) ?? "", dedupKey: row.text(1) ?? "", sha1: row.blob(2), fileName: row.text(3) ?? "",
        caption: row.text(4), kind: RemoteMediaItem.Kind(rawValue: Int(row.int(5))) ?? .photo, sizeBytes: row.int(6),
        quotaChargedBytes: row.int(7), isOriginalQuality: row.int(8) == 1,
        takenAt: Date(timeIntervalSince1970: row.double(9)), timezoneOffsetMinutes: row.optionalInt(10).map(Int.init),
        uploadedAt: row.optionalDouble(11).map(Date.init(timeIntervalSince1970:)), contentVersion: Int(row.int(12)),
        trashedAt: row.optionalDouble(13).map(Date.init(timeIntervalSince1970:)), isArchived: row.int(14) == 1,
        isFavorite: row.int(15) == 1, isLocked: row.int(16) == 1, isCanonical: row.int(17) == 1,
        isEdited: row.int(18) == 1, origin: Int(row.int(19)), width: row.optionalInt(20).map(Int.init),
        height: row.optionalInt(21).map(Int.init), latitude: row.optionalDouble(22), longitude: row.optionalDouble(23),
        locationName: row.text(24), cameraMake: row.text(25), cameraModel: row.text(26), aperture: row.optionalDouble(27),
        shutterSpeed: row.optionalDouble(28), iso: row.optionalInt(29).map(Int.init), focalLength: row.optionalDouble(30),
        durationMs: row.optionalInt(31).map(Int.init), collectionID: row.text(32))
    }
    return item
  }

  /// Place, camera and caption words for search, only for the items being indexed.
  public func searchWords(mediaKeys: [String]) throws -> [String: String] {
    var words: [String: String] = [:]
    let database = try db()
    for start in stride(from: 0, to: mediaKeys.count, by: 500) {
      let chunk = mediaKeys[start..<min(start + 500, mediaKeys.count)]
      try database.query(
        """
        SELECT media_key, COALESCE(location_name, '') || ' ' || COALESCE(camera_make, '') || ' '
          || COALESCE(camera_model, '') || ' ' || COALESCE(caption, '')
        FROM items WHERE locked = 0
          AND media_key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))
        """, chunk.map { .text($0) }
      ) { row in
        if let key = row.text(0) { words[key] = row.text(1) }
      }
    }
    return words
  }

  /// Place names and captions for every non-locked item, in one table scan.
  public func siriDetails() throws -> [String: RemoteSiriDetails] {
    var details: [String: RemoteSiriDetails] = [:]
    try db().query(
      """
      SELECT media_key, COALESCE(location_name, ''), COALESCE(caption, '')
      FROM items WHERE locked = 0 AND (location_name IS NOT NULL OR caption IS NOT NULL)
      """
    ) { row in
      if let key = row.text(0) { details[key] = RemoteSiriDetails(place: row.text(1) ?? "", caption: row.text(2) ?? "") }
    }
    return details
  }

  /// Place names and captions, for Siri and Spotlight.
  public func siriDetails(mediaKeys: [String]) throws -> [String: RemoteSiriDetails] {
    var details: [String: RemoteSiriDetails] = [:]
    let database = try db()
    for start in stride(from: 0, to: mediaKeys.count, by: 500) {
      let chunk = mediaKeys[start..<min(start + 500, mediaKeys.count)]
      try database.query(
        """
        SELECT media_key, COALESCE(location_name, ''), COALESCE(caption, '')
        FROM items WHERE locked = 0
          AND media_key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))
          AND (location_name IS NOT NULL OR caption IS NOT NULL)
        """, chunk.map { .text($0) }
      ) { row in
        if let key = row.text(0) { details[key] = RemoteSiriDetails(place: row.text(1) ?? "", caption: row.text(2) ?? "") }
      }
    }
    return details
  }

  /// Media keys among `mediaKeys` that exist in the mirror and are not in the Locked Folder.
  public func visibleMediaKeys(in mediaKeys: [String]) throws -> Set<String> {
    guard !mediaKeys.isEmpty else { return [] }
    var visible = Set<String>()
    let database = try db()
    for start in stride(from: 0, to: mediaKeys.count, by: 500) {
      let chunk = mediaKeys[start..<min(start + 500, mediaKeys.count)]
      try database.query(
        """
        SELECT media_key FROM items WHERE locked = 0
          AND media_key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))
        """, chunk.map { .text($0) }
      ) { row in
        if let key = row.text(0) { visible.insert(key) }
      }
    }
    return visible
  }

  /// Kept thumbnails of these stay; a Locked Folder item's go.
  public func allMediaKeys() throws -> Set<String> {
    var keys = Set<String>()
    try db().query("SELECT media_key FROM items WHERE locked = 0") { if let key = $0.text(0) { keys.insert(key) } }
    return keys
  }

  /// Items stored more than once (the same SHA-1), newest first in each group.
  public func duplicateGroups() throws -> [[RemoteItemSummary]] {
    var groups: [Data: [RemoteItemSummary]] = [:]
    var order: [Data] = []
    let library = RemoteScope.library.whereClause
    try db().query(
      """
      SELECT \(Self.summaryColumns) FROM items WHERE \(library) AND sha1 IN (
        SELECT sha1 FROM items WHERE sha1 IS NOT NULL AND \(library) GROUP BY sha1 HAVING COUNT(*) > 1)
      ORDER BY taken_at DESC
      """
    ) { row in
      let item = Self.summary(row)
      guard let sha1 = item.sha1 else { return }
      if groups[sha1] == nil { order.append(sha1) }
      groups[sha1, default: []].append(item)
    }
    return order.compactMap { groups[$0] }
  }

  /// Albums, most recently active first. A cover moved to the Locked Folder isn't shown.
  public func albums() throws -> [RemoteAlbum] {
    var albums: [RemoteAlbum] = []
    try db().query(
      """
      SELECT a.media_key, a.title, a.item_count,
        CASE WHEN EXISTS (SELECT 1 FROM items WHERE media_key = a.cover_media_key AND locked = 1) THEN NULL
          ELSE a.cover_media_key END,
        a.start_date, a.end_date, a.last_activity
      FROM albums a ORDER BY COALESCE(a.last_activity, a.end_date, 0) DESC, a.title
      """
    ) { row in
      albums.append(
        RemoteAlbum(
          mediaKey: row.text(0) ?? "", title: row.text(1) ?? "", itemCount: Int(row.int(2)), coverMediaKey: row.text(3),
          startDate: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)),
          endDate: row.optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
          lastActivity: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:))))
    }
    return albums
  }

  public func stats() throws -> RemoteLibraryStats {
    var stats = RemoteLibraryStats()
    try db().query(
      """
      SELECT
        SUM(trashed_at IS NULL), SUM(trashed_at IS NULL AND kind != 2), SUM(trashed_at IS NULL AND kind = 2),
        TOTAL(CASE WHEN trashed_at IS NULL THEN size_bytes END),
        SUM(trashed_at IS NULL AND quota_charged > 0), TOTAL(CASE WHEN trashed_at IS NULL THEN quota_charged END),
        SUM(trashed_at IS NOT NULL), SUM(trashed_at IS NULL AND archived = 1),
        (SELECT COUNT(*) FROM items WHERE locked = 1 AND trashed_at IS NULL)
      FROM items WHERE locked = 0 AND (canonical = 1 OR trashed_at IS NOT NULL)
      """
    ) { row in
      stats = RemoteLibraryStats(
        items: Int(row.int(0)), photos: Int(row.int(1)), videos: Int(row.int(2)), bytes: Int64(row.double(3)),
        chargedItems: Int(row.int(4)), chargedBytes: Int64(row.double(5)), trashed: Int(row.int(6)),
        archived: Int(row.int(7)), locked: Int(row.int(8)))
    }
    return stats
  }

  /// Updates an item locally right after a remote action succeeds, so the UI doesn't wait
  /// for the next sync (which then confirms it).
  /// Drops items deleted for good; the next delta sync would remove them too.
  public func remove(mediaKeys: [String]) throws {
    let database = try db()
    try database.transaction {
      for key in mediaKeys { try database.run("DELETE FROM items WHERE media_key = ?", [.text(key)]) }
    }
  }

  public func update(mediaKeys: [String], favorite: Bool? = nil, archived: Bool? = nil, trashedAt: Date?? = nil) throws {
    let database = try db()
    try database.transaction {
      for key in mediaKeys {
        if let favorite { try database.run("UPDATE items SET favorite = ? WHERE media_key = ?", [.bool(favorite), .text(key)]) }
        if let archived { try database.run("UPDATE items SET archived = ? WHERE media_key = ?", [.bool(archived), .text(key)]) }
        if let trashedAt {
          try database.run("UPDATE items SET trashed_at = ? WHERE media_key = ?", [.optional(trashedAt), .text(key)])
        }
      }
    }
  }
}

extension RemoteMediaItem {
  init(
    mediaKey: String, dedupKey: String, sha1: Data?, fileName: String, caption: String?, kind: Kind, sizeBytes: Int64,
    quotaChargedBytes: Int64, isOriginalQuality: Bool, takenAt: Date, timezoneOffsetMinutes: Int?, uploadedAt: Date?,
    contentVersion: Int, trashedAt: Date?, isArchived: Bool, isFavorite: Bool, isLocked: Bool, isCanonical: Bool,
    isEdited: Bool, origin: Int, width: Int?, height: Int?, latitude: Double?, longitude: Double?, locationName: String?,
    cameraMake: String?, cameraModel: String?, aperture: Double?, shutterSpeed: Double?, iso: Int?, focalLength: Double?,
    durationMs: Int?, collectionID: String? = nil
  ) {
    self.mediaKey = mediaKey
    self.dedupKey = dedupKey
    self.sha1 = sha1
    self.fileName = fileName
    self.caption = caption
    self.kind = kind
    self.sizeBytes = sizeBytes
    self.quotaChargedBytes = quotaChargedBytes
    self.isOriginalQuality = isOriginalQuality
    self.takenAt = takenAt
    self.timezoneOffsetMinutes = timezoneOffsetMinutes
    self.uploadedAt = uploadedAt
    self.contentVersion = contentVersion
    self.trashedAt = trashedAt
    self.isArchived = isArchived
    self.isFavorite = isFavorite
    self.isLocked = isLocked
    self.isCanonical = isCanonical
    self.isEdited = isEdited
    self.origin = origin
    self.width = width
    self.height = height
    self.latitude = latitude
    self.longitude = longitude
    self.locationName = locationName
    self.cameraMake = cameraMake
    self.cameraModel = cameraModel
    self.aperture = aperture
    self.shutterSpeed = shutterSpeed
    self.iso = iso
    self.focalLength = focalLength
    self.durationMs = durationMs
    self.collectionID = collectionID
  }
}
