import Foundation
import Observation

/// One account's Google Photos library on this device: the synced mirror, its thumbnails
/// and the actions on it. Owned by the app model for the account being browsed.
///
/// Remote actions follow the library rules in AGENTS.md: only this account is touched,
/// dedup keys come from the server, destructive changes stop at Trash (restorable for 60
/// days) and nothing is deleted forever.
@MainActor
@Observable
public final class CloudLibrary {
  public enum Status: Equatable, Sendable {
    case idle
    case syncing(RemoteLibrarySync.Progress)
    case failed(String)
  }

  var localAssetIDs: [String: String] { localFirstThumbnails.localCopies.assets }
  var localFiles: [String: FolderItemInfo] { localFirstThumbnails.localCopies.files }
  public private(set) var localCopyRevision = 0

  func registerLocalCopies(assets: [String: String], files: [String: FolderItemInfo] = [:]) {
    if localFirstThumbnails.register(assets: assets, files: files) { localCopyRevision &+= 1 }
  }

  public let accountEmail: String
  public private(set) var status: Status = .idle
  public private(set) var syncState = RemoteSyncState()
  public private(set) var stats = RemoteLibraryStats()
  /// Bumped after every committed page or local change; grids reload on it.
  public private(set) var revision = 0
  @ObservationIgnored public let thumbnails: any ThumbnailSource
  @ObservationIgnored let localFirstThumbnails: LocalFirstThumbnailSource
  @ObservationIgnored let store: RemoteLibraryStore
  @ObservationIgnored private let sync: RemoteLibrarySync
  /// Nil only in the DEBUG preview library, where actions fail.
  @ObservationIgnored private let actionClient: GooglePhotosMobileClient?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var uploadRefresh: Task<Void, Never>?
  /// The saved sync state, read once at creation; `refresh` waits for it so a launch sees
  /// when the last sync ran instead of syncing (and showing "Syncing") every time.
  @ObservationIgnored private var stateLoad: Task<Void, Never>?
  @ObservationIgnored private var revisionBump: Task<Void, Never>?
  @ObservationIgnored private var lastPageRefresh = Date.distantPast
  @ObservationIgnored private var latestProgress = RemoteLibrarySync.Progress()
  static let pageRefreshInterval: TimeInterval = 2

  /// Each refresh reloads and re-merges the whole mirror, so a large library being synced
  /// for the first time grows in steps further apart: 2 s up to 20,000 items, 10 s at
  /// 100,000.
  static func pageRefreshInterval(items: Int) -> TimeInterval {
    min(10, max(pageRefreshInterval, Double(items) / 10_000))
  }

  /// Delta syncs run at most this often unless the user asks, or a backup just uploaded.
  static let refreshInterval: TimeInterval = 10 * 60
  /// After a backup, the delta that brings its items in runs this long after the last
  /// sync at the soonest, so batch after batch doesn't sync after each.
  static let uploadRefreshGap: TimeInterval = 60
  /// Google empties its Trash after 60 days.
  nonisolated public static let trashRetention: TimeInterval = 60 * 24 * 60 * 60

  public convenience init(accountEmail: String, client: GooglePhotosMobileClient) {
    self.init(
      accountEmail: accountEmail, store: RemoteLibraryStore(accountEmail: accountEmail), fetcher: client,
      thumbnails: GoogleThumbnailSource(client: client, accountEmail: accountEmail), actionClient: client)
  }

  init(
    accountEmail: String, store: RemoteLibraryStore, fetcher: any RemoteLibraryFetching,
    thumbnails: any ThumbnailSource, actionClient: GooglePhotosMobileClient?
  ) {
    self.accountEmail = accountEmail
    self.actionClient = actionClient
    self.store = store
    sync = RemoteLibrarySync(store: store, fetcher: fetcher)
    self.thumbnails = thumbnails
    localFirstThumbnails = LocalFirstThumbnailSource(remote: thumbnails)
    // Grids load the mirror once on their own; a revision bump here would load it twice.
    stateLoad = Task { await loadState(bumpsRevision: false) }
    _ = Self.sweepDownloads
  }

  /// Originals downloaded for sharing, saving or playback (a video can be gigabytes) and
  /// stream playlists are left from earlier runs; once a day old they're no longer in use.
  private static let sweepDownloads: Void = {
    DispatchQueue.global(qos: .background).async {
      let manager = FileManager.default
      let temporary = manager.temporaryDirectory
      let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
      let candidates =
        ((try? manager.contentsOfDirectory(at: temporary.appending(path: "Downloads"), includingPropertiesForKeys: nil))
          ?? [])
        + ((try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "m3u8" }
      for url in candidates {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? manager.removeItem(at: url) }
      }
    }
  }()

  private func client() throws -> GooglePhotosMobileClient {
    guard let actionClient else { throw GPhotosError.httpError(status: -1, body: "Not available in the preview") }
    return actionClient
  }

  public var isSyncing: Bool {
    if case .syncing = status { return true }
    return false
  }

  private func loadState(bumpsRevision: Bool = true) async {
    syncState = (try? await store.syncState()) ?? RemoteSyncState()
    stats = (try? await store.stats()) ?? RemoteLibraryStats()
    if bumpsRevision { revision &+= 1 }
  }

  /// Syncs if the last sync is older than the refresh interval, or always with `force`.
  public func refresh(force: Bool = false) {
    guard syncTask == nil else { return }
    syncTask = Task {
      defer { syncTask = nil }
      await stateLoad?.value
      if !force, let last = syncState.lastSyncedAt, syncState.initialSyncDone,
        Date().timeIntervalSince(last) < Self.refreshInterval
      {
        return
      }
      status = .syncing(RemoteLibrarySync.Progress())
      do {
        _ = try await sync.sync { progress in
          Task { @MainActor in self.pageCommitted(progress) }
        }
        status = .idle
        await pruneKeptThumbnails()
      } catch is CancellationError {
        status = .idle
      } catch {
        status = .failed(Self.message(for: error))
      }
      await loadState()
    }
  }

  public func cancelSync() {
    uploadRefresh?.cancel()
    syncTask?.cancel()
  }

  /// A backup to this account finished: what it uploaded shows up in a minute or so,
  /// rather than at the next 10-minute delta. Batches close together share one sync.
  public func refreshAfterUpload() {
    guard uploadRefresh == nil else { return }
    uploadRefresh = Task {
      defer { uploadRefresh = nil }
      let sinceLast = Date().timeIntervalSince(syncState.lastSyncedAt ?? .distantPast)
      // A few seconds at least, so the last items' commits have settled.
      try? await Task.sleep(for: .seconds(max(5, Self.uploadRefreshGap - sinceLast)))
      // A sync already running may have started before the uploads finished.
      await syncTask?.value
      guard !Task.isCancelled else { return }
      refresh(force: true)
    }
  }

  public func summaries(_ scope: RemoteScope) async -> [RemoteItemSummary] {
    (try? await store.summaries(scope)) ?? []
  }

  /// Items stored more than once in Google Photos (same SHA-1).
  public func duplicateGroups() async -> [[RemoteItemSummary]] {
    (try? await store.duplicateGroups()) ?? []
  }

  public func searchWords(mediaKeys: [String]) async -> [String: String] {
    (try? await store.searchWords(mediaKeys: mediaKeys)) ?? [:]
  }

  public func siriDetails(mediaKeys: [String]) async -> [String: RemoteSiriDetails] {
    (try? await store.siriDetails(mediaKeys: mediaKeys)) ?? [:]
  }

  public func albums() async -> [RemoteAlbum] {
    (try? await store.albums()) ?? []
  }

  /// Creates a Google Photos album holding these items.
  public func createAlbum(titled title: String, with items: [RemoteItemSummary]) async throws {
    _ = try await client().createAlbum(albumName: title, mediaKeys: items.map(\.mediaKey))
    refresh(force: true)
  }

  /// Adds items to an existing Google Photos album.
  public func add(_ items: [RemoteItemSummary], toAlbum album: RemoteAlbum) async throws {
    try await client().addMediaToAlbum(albumMediaKey: album.mediaKey, mediaKeys: items.map(\.mediaKey))
    refresh(force: true)
  }

  public func summary(mediaKey: String) async -> RemoteItemSummary? {
    try? await store.summary(mediaKey: mediaKey)
  }

  public func item(mediaKey: String) async -> RemoteMediaItem? {
    try? await store.item(mediaKey: mediaKey)
  }

  // MARK: Actions

  /// Favorites all, or unfavorites all if they're all favorites. One request per item, as
  /// the API takes one item at a time.
  public func toggleFavorite(_ items: [RemoteItemSummary]) async throws {
    let favorite = !items.allSatisfy(\.isFavorite)
    var done: [String] = []
    defer { if !done.isEmpty { Task { await commitLocal(done, favorite: favorite) } } }
    for item in items where item.isFavorite != favorite {
      try await client().setFavorite(dedupKey: item.dedupKey, isFavorite: favorite)
      done.append(item.mediaKey)
    }
  }

  public func setArchived(_ items: [RemoteItemSummary], archived: Bool) async throws {
    guard !items.isEmpty else { return }
    try await client().setArchived(dedupKeys: items.map(\.dedupKey), isArchived: archived)
    try? await store.update(mediaKeys: items.map(\.mediaKey), archived: archived)
    await afterLocalChange()
  }

  /// Moves items to Google Photos' Trash; they can be restored for 60 days.
  public func trash(_ items: [RemoteItemSummary]) async throws {
    guard !items.isEmpty else { return }
    try await client().trash(dedupKeys: items.map(\.dedupKey))
    try? await store.update(mediaKeys: items.map(\.mediaKey), trashedAt: .some(Date()))
    await afterLocalChange()
  }

  /// Deletes items for good. Only items already in Trash are sent, so nothing outside
  /// it can be lost this way.
  public func deleteForever(_ items: [RemoteItemSummary]) async throws {
    let trashed = items.filter { $0.trashedAt != nil }
    guard !trashed.isEmpty else { return }
    try await client().deleteForever(dedupKeys: trashed.map(\.dedupKey))
    try? await store.remove(mediaKeys: trashed.map(\.mediaKey))
    await afterLocalChange()
  }

  public func restore(_ items: [RemoteItemSummary]) async throws {
    guard !items.isEmpty else { return }
    try await client().restoreFromTrash(dedupKeys: items.map(\.dedupKey))
    try? await store.update(mediaKeys: items.map(\.mediaKey), trashedAt: .some(nil))
    await afterLocalChange()
  }

  public func setCaption(_ item: RemoteItemSummary, caption: String) async throws {
    try await client().setCaption(dedupKey: item.dedupKey, caption: caption)
    refresh(force: true)
  }

  /// Downloads the original (or the edited version) to a temporary file named like it.
  public func download(_ item: RemoteItemSummary, edited: Bool = true) async throws -> URL {
    let links = try await client().downloadURLs(mediaKey: item.mediaKey)
    guard let link = (edited ? links.edited ?? links.original : links.original ?? links.edited) else {
      throw GPhotosError.httpError(status: 404, body: "No download link")
    }
    let file = try await client().download(link)
    let fallbackExtension = item.kind == .video ? "mp4" : "jpg"
    let fallback = "\(Self.safeFileName(item.mediaKey, fallback: "download")).\(fallbackExtension)"
    let name = Self.safeFileName((try? await store.item(mediaKey: item.mediaKey))?.fileName, fallback: fallback)
    let folder = FileManager.default.temporaryDirectory.appending(path: "Downloads/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appending(path: name)
    do {
      try FileManager.default.moveItem(at: file, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    return destination
  }

  nonisolated static func safeFileName(_ raw: String?, fallback: String) -> String {
    guard let raw, !raw.isEmpty else { return fallback }
    let component = (raw as NSString).lastPathComponent
    guard !component.isEmpty, component != "/", component != ".", component != "..", !component.contains("\0") else {
      return fallback
    }
    let sanitized =
      component
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else { return fallback }
    return sanitized
  }

  /// AVFoundation rejects a master playlist opened as a local file. Google's rendition
  /// URLs are remote playlists, so playback fetches only the segments it needs.
  public func streamingPlaylist(_ item: RemoteItemSummary) async throws -> (url: URL, headers: [String: String]) {
    let manifest = try await client().streamManifest(mediaKey: item.mediaKey, contentVersion: item.contentVersion)
    guard let url = Self.streamingRendition(in: manifest) else {
      throw GPhotosError.httpError(status: 404, body: "No playable video stream")
    }
    return (url, try await client().mediaHeaders())
  }

  nonisolated static func streamingRendition(in manifest: Data) -> URL? {
    guard let text = String(data: manifest, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
    var bandwidth: Int?
    var best: (url: URL, bandwidth: Int)?
    for line in text.components(separatedBy: .newlines) {
      let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-STREAM-INF:") {
        bandwidth = line.dropFirst("#EXT-X-STREAM-INF:".count).split(separator: ",")
          .first { $0.hasPrefix("BANDWIDTH=") }.flatMap { Int($0.dropFirst("BANDWIDTH=".count)) }
      } else if !line.isEmpty, !line.hasPrefix("#"), let rate = bandwidth {
        bandwidth = nil
        guard let url = URL(string: line), url.scheme == "https", url.host != nil else { continue }
        if rate > (best?.bandwidth ?? -1) { best = (url, rate) }
      }
    }
    return best?.url
  }

  /// An original/edited video URL that AVPlayer can progressively stream without
  /// staging the whole file in Downloads.
  public func videoURL(_ item: RemoteItemSummary) async throws -> (url: URL, headers: [String: String]) {
    let client = try client()
    let links = try await client.downloadURLs(mediaKey: item.mediaKey)
    guard let url = links.edited ?? links.original else {
      throw GPhotosError.httpError(status: 404, body: "No video link")
    }
    return (url, try await client.mediaHeaders())
  }

  private func commitLocal(_ keys: [String], favorite: Bool) async {
    try? await store.update(mediaKeys: keys, favorite: favorite)
    await afterLocalChange()
  }

  /// The next delta sync confirms local changes against the server.
  private func afterLocalChange() async {
    await loadState()
    refresh(force: true)
  }

  /// Views refresh (and the progress shown updates) while a sync streams pages, but at
  /// most every couple of seconds: a first sync is hundreds of pages, and each refresh
  /// reloads the whole mirror.
  private func pageCommitted(_ progress: RemoteLibrarySync.Progress) {
    latestProgress = progress
    guard revisionBump == nil else { return }
    let wait = max(0, Self.pageRefreshInterval(items: stats.items) - Date().timeIntervalSince(lastPageRefresh))
    revisionBump = Task {
      try? await Task.sleep(for: .seconds(wait))
      revisionBump = nil
      lastPageRefresh = Date()
      if isSyncing { status = .syncing(latestProgress) }
      // One aggregate query, so Collections' counts move with the grid during a long sync.
      if let latest = try? await store.stats() { stats = latest }
      revision &+= 1
    }
  }

  /// Kept thumbnails of items deleted from Google Photos go too.
  private func pruneKeptThumbnails() async {
    guard let keys = try? await store.allMediaKeys() else { return }
    let email = accountEmail
    await Task.detached(priority: .background) { KeptThumbnails.prune(keeping: keys, accountEmail: email) }.value
  }

  /// Removes the mirror and thumbnails, for sign-out and removed accounts.
  public func removeLocalData() async {
    syncTask?.cancel()
    try? await store.reset()
    (thumbnails as? GoogleThumbnailSource)?.removeCache()
    KeptThumbnails.removeAll(accountEmail: accountEmail)
    LibrarySnapshot.remove()
    syncState = RemoteSyncState()
    stats = RemoteLibraryStats()
    revision &+= 1
  }

  /// Removes an account's mirror and thumbnails without a library object.
  public static func removeLocalData(forAccountEmail email: String) async {
    try? await RemoteLibraryStore(accountEmail: email).reset()
    try? FileManager.default.removeItem(at: ThumbnailDiskCache.directory(for: email))
    KeptThumbnails.removeAll(accountEmail: email)
    LibrarySnapshot.remove()
  }

  static func message(for error: Error) -> String {
    switch error {
    case RemoteLibrarySyncError.cycleWithoutProgress:
      String(localized: "Google Photos kept asking to sync again. Try again later.")
    case let error as GPhotosError: error.localizedDescription
    default: error.localizedDescription
    }
  }
}
