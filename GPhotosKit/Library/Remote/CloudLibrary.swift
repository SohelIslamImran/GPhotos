import CoreGraphics
import Foundation
import Observation
import WebKit
import os

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

  func registerLocalCopies(assets: [String: String], versions: [String: PhotoBackupEvidence.Version]) {
    let previous = localFirstThumbnails.localCopies
    guard localFirstThumbnails.register(assets: assets, versions: versions) else { return }
    self.localCopiesChanged(from: previous, to: self.localFirstThumbnails.localCopies)
  }

  func replaceLocalCopies(_ copies: LocalFirstThumbnailSource.LocalCopies) {
    let previous = localFirstThumbnails.localCopies
    guard localFirstThumbnails.replace(with: copies) else { return }
    localCopiesChanged(from: previous, to: copies)
  }

  func clearLocalCopies() {
    let previous = localFirstThumbnails.localCopies
    localFirstThumbnails.clearProjection()
    if previous != .init() { localCopiesChanged(from: previous, to: .init()) }
  }

  private func localCopiesChanged(
    from previous: LocalFirstThumbnailSource.LocalCopies, to copies: LocalFirstThumbnailSource.LocalCopies
  ) {
    ThumbnailPipeline.shared.invalidateRemoteImages(
      where: { key in
        previous.assets[key] != copies.assets[key] || previous.files[key] != copies.files[key]
          || copies.assets[key].map { previous.assetVersions[$0] != copies.assetVersions[$0] } == true
      },
      retrying: { key in previous.route(for: key) != copies.route(for: key) })
    localCopyRevision &+= 1
  }

  public let accountEmail: String
  public private(set) var status: Status = .idle
  public private(set) var syncState = RemoteSyncState()
  public private(set) var stats = RemoteLibraryStats()
  /// Bumped when the mirror's items change (a sync page that changed something, or a local
  /// change); grids reload on it. A sync that brings nothing new leaves it alone.
  public private(set) var revision = 0
  /// Bumped when the albums change, which album lists follow without reloading grids.
  public private(set) var albumsRevision = 0
  /// The account's albums, most recently active first, kept here so album lists draw in
  /// full on every visit instead of starting empty.
  public private(set) var albumList: [RemoteAlbum] = []
  /// The saved sync state, counts and albums have been read.
  public private(set) var isStateLoaded = false
  /// Switched away from or removed: it never syncs, writes or sends a request again.
  public private(set) var isRetired = false
  @ObservationIgnored private var isRemoved = false
  @ObservationIgnored public let thumbnails: any ThumbnailSource
  @ObservationIgnored let localFirstThumbnails: LocalFirstThumbnailSource
  @ObservationIgnored let store: RemoteLibraryStore
  nonisolated let indexLifetime = OSAllocatedUnfairLock(initialState: true)
  nonisolated var isIndexingCurrent: Bool { indexLifetime.withLock { $0 } }
  @ObservationIgnored private let sync: RemoteLibrarySync
  @ObservationIgnored private let indexPurge: LockedIndexPurge
  @ObservationIgnored private let purgeLockedItems: @Sendable (Set<String>) -> Void
  @ObservationIgnored private var isMovingToLockedFolder = false
  /// A move reached Google, so the mirror needs a delta to catch up.
  @ObservationIgnored private var sentLockedFolderMove = false
  /// Nil only in the DEBUG preview library.
  @ObservationIgnored private let actionClient: GooglePhotosMobileClient?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var uploadRefresh: Task<Void, Never>?
  /// The saved sync state, read once at creation; `refresh` waits for it so a launch sees
  /// when the last sync ran instead of syncing (and showing "Syncing") every time.
  @ObservationIgnored private var stateLoad: Task<Void, Never>?
  @ObservationIgnored private var revisionBump: Task<Void, Never>?
  /// Restores here, finished and under way: a Delete Forever sends only while none is under
  /// way for its items and none finished since it was asked for.
  @ObservationIgnored private let restores = OSAllocatedUnfairLock(initialState: Restores())

  private struct Restores {
    var finished: [String: Int] = [:]
    var underway: [String: Int] = [:]

    func stamp(_ keys: [String]) -> [Int]? {
      keys.contains { underway[$0, default: 0] > 0 } ? nil : keys.map { finished[$0, default: 0] }
    }
  }
  @ObservationIgnored private var lastPageRefresh = Date.distantPast
  @ObservationIgnored private var latestProgress = RemoteLibrarySync.Progress()
  /// What this sync's pages changed that views have already been told about.
  @ObservationIgnored private var published = RemoteLibraryStore.Changes()
  @ObservationIgnored private var syncGeneration = 0
  /// What this library has out on the shared client, besides its sync and thumbnails.
  @ObservationIgnored private let requests = AccountRequests()
  /// The Locked Folder's own client, made when it's first opened: an ephemeral session,
  /// whose response cache stays in memory, unlike the shared client's on-disk one.
  @ObservationIgnored private var lockedClient: GooglePhotosMobileClient?
  @ObservationIgnored private let lockedLimiter = DownloadLimiter(slots: 6)
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
    let spotlight = SiriLibrary.shared.spotlight
    self.init(
      accountEmail: accountEmail, store: RemoteLibraryStore(accountEmail: accountEmail), fetcher: client,
      thumbnails: GoogleThumbnailSource(client: client, accountEmail: accountEmail), actionClient: client,
      purgeIndex: { await spotlight.purge(lockedKeys: $0) })
  }

  init(
    accountEmail: String, store: RemoteLibraryStore, fetcher: any RemoteLibraryFetching,
    thumbnails: any ThumbnailSource, actionClient: GooglePhotosMobileClient?,
    invalidateSnapshot: @escaping @Sendable () -> Void = { LibrarySnapshot.invalidate() },
    purgeIndex: @escaping @Sendable (Set<String>) async -> Bool = { _ in true }
  ) {
    self.accountEmail = accountEmail
    self.actionClient = actionClient
    self.store = store
    let indexPurge = LockedIndexPurge(store: store, purge: purgeIndex)
    self.indexPurge = indexPurge
    let purgeLockedItems: @Sendable (Set<String>) -> Void = { keys in
      LockedItems.insert(keys, accountEmail: accountEmail)
      Self.purge(keys, accountEmail: accountEmail)
      invalidateSnapshot()
      // Reads the mirror, so it waits for the transaction being committed here.
      Task { await indexPurge.start() }
      Task { @MainActor in
        ThumbnailPipeline.shared.purge(ids: keys)
        await WidgetPublisher.shared.purge(mediaKeys: keys)
      }
    }
    self.purgeLockedItems = purgeLockedItems
    sync = RemoteLibrarySync(
      store: store, fetcher: fetcher, willLock: purgeLockedItems,
      didRelease: { LockedItems.release($0, accountEmail: accountEmail) })
    self.thumbnails = thumbnails
    localFirstThumbnails = LocalFirstThumbnailSource(remote: thumbnails, accountEmail: accountEmail)
    localFirstThumbnails.observeRepairs { [weak self] previous, _ in
      Task { @MainActor in
        guard let self else { return }
        self.localCopiesChanged(from: previous, to: self.localFirstThumbnails.localCopies)
      }
    }
    // Grids load the mirror once on their own; a revision bump here would load it twice.
    stateLoad = Task { await loadState() }
    _ = Self.sweepDownloads
  }

  /// Deletes every copy of these items kept on disk: thumbnails, kept thumbnails and
  /// originals downloaded to share.
  nonisolated private static func purge(_ keys: Set<String>, accountEmail: String) {
    ThumbnailDiskCache.remove(keys, accountEmail: accountEmail)
    KeptThumbnails.remove(keys, accountEmail: accountEmail)
    WidgetStore.remove(Set(keys.map(LibraryIndexer.searchID(cloudMediaKey:))))
    let names = Set(keys.map(ThumbnailDiskCache.itemName))
    for folder in (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
    where names.contains(String(folder.prefix { $0 != "-" })) {
      try? FileManager.default.removeItem(at: downloads.appending(path: folder))
    }
  }

  nonisolated private static var downloads: URL { FileManager.default.temporaryDirectory.appending(path: "Downloads") }

  /// Originals downloaded for sharing, saving or playback (a video can be gigabytes) and
  /// stream playlists are left from earlier runs; once a day old they're no longer in use.
  private static let sweepDownloads: Void = {
    DispatchQueue.global(qos: .background).async {
      let manager = FileManager.default
      let temporary = manager.temporaryDirectory
      let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
      let candidates =
        ((try? manager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil))
          ?? [])
        + ((try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "m3u8" }
      for url in candidates {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? manager.removeItem(at: url) }
      }
    }
  }()

  /// The shared client holds the browsed account's credential, so a library switched away
  /// from sends nothing through it.
  private func client() throws -> GooglePhotosMobileClient {
    guard !isRetired else { throw CancellationError() }
    guard let actionClient else { throw GPhotosError.httpError(status: -1, body: "Not available in the preview") }
    return actionClient
  }

  /// Every request on the shared client goes out this way, so retiring can stop it.
  private func send<T: Sendable>(
    _ request: @escaping @Sendable (GooglePhotosMobileClient) async throws -> T
  ) async throws -> T {
    let client = try client()
    return try await requests.run { try await request(client) }
  }

  public var isSyncing: Bool {
    if case .syncing = status { return true }
    return false
  }

  private func loadState() async {
    await reloadSyncState()
    await reloadStats()
    await reloadAlbums()
    await loadLockedKeys()
    await indexPurge.start(reconcileExisting: true)
    if !isStateLoaded { isStateLoaded = true }
  }

  private func loadLockedKeys() async {
    let email = accountEmail
    guard !LockedItems.isKnown(accountEmail: email), let keys = try? await store.lockedKeys(), !isRetired else { return }
    LockedItems.load(keys, accountEmail: email)
    guard !keys.isEmpty else { return }
    // The thumbnail cache looks for these itself, when it's next trimmed.
    Task.detached(priority: .background) { KeptThumbnails.remove(keys, accountEmail: email) }
  }

  // Observation tells every reader of a property on each assignment, equal or not. A
  // mirror that can't be read leaves what was read before.
  private func reloadSyncState() async {
    if let state = try? await store.syncState(), state != syncState { syncState = state }
  }

  private func reloadStats() async {
    if let latest = try? await store.stats(), latest != stats { stats = latest }
  }

  private func reloadAlbums() async {
    guard let latest = try? await store.albums(), latest != albumList else { return }
    albumList = latest
    albumsRevision &+= 1
  }

  /// Syncs if the last sync is older than the refresh interval, or always with `force`.
  public func refresh(force: Bool = false) {
    guard syncTask == nil, !isRetired, !isMovingToLockedFolder else { return }
    syncTask = Task {
      defer { syncTask = nil }
      await stateLoad?.value
      await loadLockedKeys()
      guard !Task.isCancelled else { return }
      if !force, let last = syncState.lastSyncedAt, syncState.initialSyncDone,
        Date().timeIntervalSince(last) < Self.refreshInterval
      {
        return
      }
      syncGeneration &+= 1
      let generation = syncGeneration
      latestProgress = RemoteLibrarySync.Progress()
      published = RemoteLibraryStore.Changes()
      status = .syncing(RemoteLibrarySync.Progress())
      do {
        _ = try await sync.sync { progress in
          Task { @MainActor in self.pageCommitted(progress, generation: generation) }
        }
        status = .idle
      } catch {
        status = error is CancellationError || isRetired ? .idle : .failed(Self.message(for: error))
      }
      // A bump already past its wait finishes first, so changes are published once.
      if let bump = revisionBump {
        bump.cancel()
        await bump.value
        revisionBump = nil
      }
      guard !isRetired else { return }
      // Pages committed before a failure count too.
      let progress = await sync.progress
      latestProgress = progress
      await publish(progress.changes)
      await reloadSyncState()
      if progress.changes.removals > 0 { await pruneKeptThumbnails() }
    }
  }

  /// Stops this library for good: the browsed account changed, so the shared client is
  /// about to carry another account's credential. Nothing more is requested or written.
  public func cancelSync() {
    guard !isRetired else { return }
    indexLifetime.withLock { $0 = false }
    isRetired = true
    uploadRefresh?.cancel()
    uploadRefresh = nil
    revisionBump?.cancel()
    revisionBump = nil
    stateLoad?.cancel()
    syncTask?.cancel()
    requests.close()
    lockedClient = nil
    (thumbnails as? GoogleThumbnailSource)?.retire()
    let store = store
    let indexPurge = indexPurge
    let requests = requests
    Task {
      // A web move that was already sent may still need to scrub the account's mirror.
      await requests.drain()
      await indexPurge.close()
      await store.close()
    }
  }

  /// Returns when the sync running now (if any) has ended and published what it changed.
  func waitForSync() async {
    await syncTask?.value
  }

  /// `cancelSync`, then waits for the sync and everything else it has out to stop, so no
  /// request or write of this library follows. Await it before the credential changes to
  /// another account.
  public func retire() async {
    cancelSync()
    await syncTask?.value
    await stateLoad?.value
    await requests.drain()
    await (thumbnails as? GoogleThumbnailSource)?.drain()
    await store.close()
  }

  /// A backup to this account finished: what it uploaded shows up in a minute or so,
  /// rather than at the next 10-minute delta. Batches close together share one sync.
  public func refreshAfterUpload() {
    guard uploadRefresh == nil, !isRetired else { return }
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

  public func summaries(_ scope: RemoteScope) async throws -> [RemoteItemSummary] {
    // Removed with its account: nothing stays on screen either.
    if isRemoved { return [] }
    return try await store.summaries(scope)
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

  /// The albums, once the saved state is read (Siri can ask before any view did).
  public func albums() async -> [RemoteAlbum] {
    await stateLoad?.value
    return albumList
  }

  /// Whether the account has Locked Folder items, which get their own screen.
  public var hasLockedItems: Bool { stats.locked > 0 }

  /// The Locked Folder, newest first. Read only by its screen once unlocked, and never kept.
  func lockedItems() async throws -> [RemoteItemSummary] {
    try await store.lockedSummaries()
  }

  private func lockedFolderClient() throws -> GooglePhotosMobileClient {
    let shared = try client()
    if let lockedClient { return lockedClient }
    let client = GooglePhotosMobileClient(authService: shared.authService, isolatedSession: true)
    lockedClient = client
    return client
  }

  /// A Locked Folder photo, `side` pixels on its longest edge (a square crop with `crop`):
  /// the same thumbnail request as any item, but nothing is written to any cache on disk.
  func lockedImage(_ item: RemoteItemSummary, side: Int, crop: Bool) async throws -> CGImage {
    #if DEBUG
      if actionClient == nil, !isRetired { return try await Self.firstImage(from: thumbnails, id: item.thumbnailID, side: side) }
    #endif
    let client = try lockedFolderClient()
    guard await lockedLimiter.acquire() else { throw CancellationError() }
    defer { lockedLimiter.release() }
    let data = try await requests.run {
      try await client.thumbnail(
        mediaKey: item.mediaKey, width: side, height: side, contentVersion: item.contentVersion, crop: crop)
    }
    let image = try await Self.decodeLockedImage(data, side: side)
    guard !isRetired else { throw CancellationError() }
    return image
  }

  @concurrent static func decodeLockedImage(
    _ data: Data, side: Int, decode: @Sendable (Data, Int) -> CGImage? = GoogleThumbnailSource.decode
  ) async throws -> CGImage {
    try Task.checkCancellation()
    let image = decode(data, side)
    try Task.checkCancellation()
    guard let image else { throw GPhotosError.httpError(status: -1, body: "Unreadable image") }
    return image
  }

  /// A stream for a Locked Folder video, as the viewer plays any video: nothing is
  /// downloaded to a file.
  func lockedVideo(_ item: RemoteItemSummary) async throws -> (url: URL, headers: [String: String]) {
    let client = try lockedFolderClient()
    return try await requests.run {
      if let manifest = try? await client.streamManifest(mediaKey: item.mediaKey, contentVersion: item.contentVersion),
        let url = Self.streamingRendition(in: manifest)
      {
        return (url, try await client.mediaHeaders())
      }
      let links = try await client.downloadURLs(mediaKey: item.mediaKey)
      guard let url = links.edited ?? links.original else { throw GPhotosError.httpError(status: 404, body: "No video link") }
      return (url, try await client.mediaHeaders())
    }
  }

  #if DEBUG
    /// The preview library's drawn images, which always arrive.
    private static func firstImage(from source: any ThumbnailSource, id: String, side: Int) async throws -> CGImage {
      let delivered = OSAllocatedUnfairLock(initialState: false)
      return await withCheckedContinuation { continuation in
        _ = source.requestImage(id: id, pixelSize: CGSize(width: side, height: side), quality: .display) { image, isFinal in
          guard isFinal,
            delivered.withLock({ state in
              defer { state = true }
              return !state
            })
          else { return }
          continuation.resume(returning: image)
        }
      }
    }
  #endif

  /// Creates a Google Photos album holding these items.
  public func createAlbum(titled title: String, with items: [RemoteItemSummary]) async throws {
    _ = try await send { try await $0.createAlbum(albumName: title, mediaKeys: items.map(\.mediaKey)) }
    refresh(force: true)
  }

  /// Adds items to an existing Google Photos album.
  public func add(_ items: [RemoteItemSummary], toAlbum album: RemoteAlbum) async throws {
    try await send { try await $0.addMediaToAlbum(albumMediaKey: album.mediaKey, mediaKeys: items.map(\.mediaKey)) }
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
      try await send { try await $0.setFavorite(dedupKey: item.dedupKey, isFavorite: favorite) }
      done.append(item.mediaKey)
    }
  }

  public func setArchived(_ items: [RemoteItemSummary], archived: Bool) async throws {
    guard !items.isEmpty else { return }
    try await send { try await $0.setArchived(dedupKeys: items.map(\.dedupKey), isArchived: archived) }
    try? await store.update(mediaKeys: items.map(\.mediaKey), archived: archived)
    await afterLocalChange()
  }

  var supportsLockedFolderWeb: Bool { actionClient != nil && !isRetired }

  func saveLockedFolderSignIn(from dataStore: WKWebsiteDataStore, page: WebPage) async throws {
    try await requests.run {
      try await GooglePhotosWebSession(accountEmail: self.accountEmail).saveSignIn(from: dataStore, page: page)
    }
  }

  nonisolated static func lockableItems(_ items: [RemoteItemSummary], excluding locked: Set<String>) -> [RemoteItemSummary] {
    var seen = locked
    return items.filter { !$0.dedupKey.isEmpty && $0.trashedAt == nil && seen.insert($0.mediaKey).inserted }
  }

  func canMoveToLockedFolder(_ item: RemoteItemSummary) -> Bool {
    !isRetired && !item.dedupKey.isEmpty && item.trashedAt == nil
      && !LockedItems.contains(item.mediaKey, accountEmail: accountEmail)
  }

  public func moveToLockedFolder(_ items: [RemoteItemSummary]) async throws {
    guard !isMovingToLockedFolder else { throw GooglePhotosWebError.unavailable }
    guard !isRetired else { throw CancellationError() }
    let items = Self.lockableItems(items, excluding: LockedItems.keys(accountEmail: accountEmail))
    guard !items.isEmpty else { return }
    isMovingToLockedFolder = true
    sentLockedFolderMove = false
    defer {
      isMovingToLockedFolder = false
      if sentLockedFolderMove { refresh(force: true) }
    }
    // Finish the current sync so a page fetched before the move can't undo the local lock.
    await waitForSync()
    try await requests.run { try await self.moveLockedFolderBatches(items) }
  }

  private func moveLockedFolderBatches(_ items: [RemoteItemSummary]) async throws {
    // A resumed page can predate the move even if no sync is running now.
    guard try await store.syncState().resumeToken.isEmpty else {
      throw GooglePhotosWebError.syncPending
    }
    let session = GooglePhotosWebSession(accountEmail: accountEmail)
    let page: WebPage?
    #if DEBUG
      page = if actionClient == nil { nil } else { try await session.makeSignedInPage() }
    #else
      page = try await session.makeSignedInPage()
    #endif
    defer { page?.stopLoading() }
    for batch in LockedFolderWebRequest.batches(of: items) {
      try Task.checkCancellation()
      var fresh: [RemoteItemSummary] = []
      for item in batch {
        if let current = try await store.summary(mediaKey: item.mediaKey), current.dedupKey == item.dedupKey,
          canMoveToLockedFolder(current)
        {
          fresh.append(current)
        }
      }
      guard !fresh.isEmpty else { continue }
      if let actionClient, let page {
        // Someone is watching the progress, so a busy server ends the move instead of a long wait.
        guard await !actionClient.isRateLimited else { throw GooglePhotosWebError.busy }
        try Self.checkNoneLocked(fresh.map(\.mediaKey), accountEmail: accountEmail)
        sentLockedFolderMove = true
        do {
          try await session.moveToLockedFolder(dedupKeys: fresh.map(\.dedupKey), on: page)
          await actionClient.noteRequestSucceeded()
        } catch let limit as GooglePhotosWebSession.WebRateLimit {
          await actionClient.noteRateLimited(retryAfter: limit.retryAfter)
          throw GooglePhotosWebError.busy
        }
      }
      // Once Google accepted a batch, finish its purge even if an account change cancelled us.
      let keys = Set(fresh.map(\.mediaKey))
      do {
        try await store.markLocked(keys, willLock: purgeLockedItems)
      } catch {
        // Keep them off-screen and out of caches until a delta can repair the mirror.
        purgeLockedItems(keys)
        revision &+= 1
        throw error
      }
      await reloadStats()
      await reloadAlbums()
      revision &+= 1
    }
  }

  nonisolated private static func checkNoneLocked(_ keys: [String], accountEmail: String) throws {
    guard !keys.contains(where: { LockedItems.contains($0, accountEmail: accountEmail) }) else { throw CancellationError() }
  }

  /// Moves items to Google Photos' Trash; they can be restored for 60 days.
  public func trash(_ items: [RemoteItemSummary]) async throws {
    // The system's own prompt can stay up while a sync locks one of them.
    let email = accountEmail
    let items = items.filter { !LockedItems.contains($0.mediaKey, accountEmail: email) }
    guard !items.isEmpty else { return }
    let keys = items.map(\.mediaKey)
    try await send { client in
      try await client.trash(dedupKeys: items.map(\.dedupKey)) { try Self.checkNoneLocked(keys, accountEmail: email) }
    }
    try? await store.update(mediaKeys: items.map(\.mediaKey), trashedAt: .some(Date()))
    await afterLocalChange()
  }

  /// Deletes items for good. Only items already in Trash are sent, so nothing outside
  /// it can be lost this way.
  public func deleteForever(_ items: [RemoteItemSummary]) async throws {
    let trashed = items.filter { $0.trashedAt != nil && !LockedItems.contains($0.mediaKey, accountEmail: accountEmail) }
    guard !trashed.isEmpty else { return }
    let email = accountEmail
    let keys = trashed.map(\.mediaKey)
    // One restored since the dialog opened, or while this waits its turn, is in the library again.
    let restores = restores
    guard let restored = restores.withLock({ $0.stamp(keys) }) else { throw CancellationError() }
    for key in keys {
      guard try await store.summary(mediaKey: key)?.trashedAt != nil else { throw CancellationError() }
    }
    try await send { client in
      try await client.deleteForever(dedupKeys: trashed.map(\.dedupKey)) {
        try Self.checkNoneLocked(keys, accountEmail: email)
        guard restores.withLock({ $0.stamp(keys) }) == restored else { throw CancellationError() }
      }
    }
    try? await store.remove(mediaKeys: trashed.map(\.mediaKey))
    await afterLocalChange()
  }

  public func restore(_ items: [RemoteItemSummary]) async throws {
    guard !items.isEmpty else { return }
    let keys = items.map(\.mediaKey)
    let restores = restores
    restores.withLock { state in for key in keys { state.underway[key, default: 0] += 1 } }
    var settled = false
    // After the mirror is updated too, so a Delete Forever asked for meanwhile is called off.
    // A mirror that couldn't be updated still lists them in Trash: they stay blocked.
    defer {
      let settled = settled
      restores.withLock { state in
        for key in keys {
          state.finished[key, default: 0] += 1
          if settled { state.underway[key, default: 1] -= 1 }
        }
      }
      // Whether Google restored them is unknown until a sync says.
      if !settled { refresh(force: true) }
    }
    try await send { try await $0.restoreFromTrash(dedupKeys: items.map(\.dedupKey)) }
    do {
      try await store.update(mediaKeys: items.map(\.mediaKey), trashedAt: .some(nil))
      settled = true
    } catch {}
    await afterLocalChange()
  }

  public func setCaption(_ item: RemoteItemSummary, caption: String) async throws {
    try await send { try await $0.setCaption(dedupKey: item.dedupKey, caption: caption) }
    refresh(force: true)
  }

  nonisolated func checkUnlocked(_ mediaKey: String) throws {
    try Task.checkCancellation()
    guard isIndexingCurrent, !LockedItems.contains(mediaKey, accountEmail: accountEmail) else {
      throw CancellationError()
    }
  }

  /// Downloads the original (or the edited version) to a temporary file named like it.
  public func download(_ item: RemoteItemSummary, edited: Bool = true) async throws -> URL {
    let key = item.mediaKey
    try checkUnlocked(key)
    let links = try await send { client in
      try self.checkUnlocked(key)
      return try await client.downloadURLs(mediaKey: key)
    }
    guard let link = (edited ? links.edited ?? links.original : links.original ?? links.edited) else {
      throw GPhotosError.httpError(status: 404, body: "No download link")
    }
    let file = try await send { client in
      try self.checkUnlocked(key)
      return try await client.download(link)
    }
    defer { try? FileManager.default.removeItem(at: file) }
    try checkUnlocked(key)
    let fallbackExtension = item.kind == .video ? "mp4" : "jpg"
    let fallback = "\(Self.safeFileName(key, fallback: "download")).\(fallbackExtension)"
    let name = Self.safeFileName((try? await store.item(mediaKey: key))?.fileName, fallback: fallback)
    return try publishDownload(file, mediaKey: key, name: name)
  }

  func publishDownload(_ file: URL, mediaKey: String, name: String) throws -> URL {
    defer { try? FileManager.default.removeItem(at: file) }
    try checkUnlocked(mediaKey)
    let folder = Self.downloads.appending(path: "\(ThumbnailDiskCache.itemName(for: mediaKey))-\(UUID().uuidString)")
    let destination = folder.appending(path: name)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try LockedItems.withKeys(for: accountEmail) { locked in
        guard !locked.contains(mediaKey) else { throw CancellationError() }
        try FileManager.default.moveItem(at: file, to: destination)
      }
      try checkUnlocked(mediaKey)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
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
    try checkUnlocked(item.mediaKey)
    let stream = try await send { client in
      try self.checkUnlocked(item.mediaKey)
      let manifest = try await client.streamManifest(mediaKey: item.mediaKey, contentVersion: item.contentVersion)
      guard let url = Self.streamingRendition(in: manifest) else {
        throw GPhotosError.httpError(status: 404, body: "No playable video stream")
      }
      try self.checkUnlocked(item.mediaKey)
      return (url, try await client.mediaHeaders())
    }
    try checkUnlocked(item.mediaKey)
    return stream
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
    try checkUnlocked(item.mediaKey)
    let stream = try await send { client in
      try self.checkUnlocked(item.mediaKey)
      let links = try await client.downloadURLs(mediaKey: item.mediaKey)
      guard let url = links.edited ?? links.original else {
        throw GPhotosError.httpError(status: 404, body: "No video link")
      }
      try self.checkUnlocked(item.mediaKey)
      return (url, try await client.mediaHeaders())
    }
    try checkUnlocked(item.mediaKey)
    return stream
  }

  private func commitLocal(_ keys: [String], favorite: Bool) async {
    try? await store.update(mediaKeys: keys, favorite: favorite)
    await afterLocalChange()
  }

  /// The next delta sync confirms local changes against the server.
  private func afterLocalChange() async {
    guard !isRetired else { return }
    await reloadSyncState()
    await reloadStats()
    revision &+= 1
    refresh(force: true)
  }

  /// Views refresh (and the progress shown updates) while a sync streams pages, but at
  /// most every couple of seconds: a first sync is hundreds of pages, and each refresh
  /// reloads the whole mirror. Items that moved to the Locked Folder leave the screen now.
  private func pageCommitted(_ progress: RemoteLibrarySync.Progress, generation: Int) {
    guard generation == syncGeneration, syncTask != nil, !isRetired else { return }
    latestProgress = progress
    let hides = progress.changes.hidden > published.hidden
    guard revisionBump == nil || hides else { return }
    revisionBump?.cancel()
    let wait =
      hides ? 0 : max(0, Self.pageRefreshInterval(items: stats.items) - Date().timeIntervalSince(lastPageRefresh))
    revisionBump = Task {
      try? await Task.sleep(for: .seconds(wait))
      guard !Task.isCancelled else { return }
      revisionBump = nil
      lastPageRefresh = Date()
      if isSyncing { status = .syncing(latestProgress) }
      await publish(latestProgress.changes)
    }
  }

  /// Tells views about what the sync changed since they were last told: grids only for
  /// items, album lists only for albums. Pages that changed nothing reload nothing.
  private func publish(_ changes: RemoteLibraryStore.Changes) async {
    let items = changes.items > published.items
    // An item moved to the Locked Folder can be an album's cover.
    let albums = changes.albums > published.albums || changes.removals > published.removals
    published = changes
    if items {
      // One aggregate query, so Collections' counts move with the grid during a long sync.
      await reloadStats()
      revision &+= 1
    }
    if albums { await reloadAlbums() }
  }

  /// Kept thumbnails of items deleted from Google Photos go too.
  private func pruneKeptThumbnails() async {
    guard let keys = try? await store.allMediaKeys() else { return }
    let email = accountEmail
    await Task.detached(priority: .background) { KeptThumbnails.prune(keeping: keys, accountEmail: email) }.value
  }

  /// Removes the mirror and thumbnails, for sign-out and removed accounts. The library is
  /// retired first, so no sync still running or scheduled can write the mirror back.
  public func removeLocalData() async {
    isRemoved = true
    await retire()
    await store.closeAndRemove()
    await GooglePhotosWebSession.deleteWebData(forAccountEmail: accountEmail)
    (thumbnails as? GoogleThumbnailSource)?.removeCache()
    KeptThumbnails.removeAll(accountEmail: accountEmail)
    LibrarySnapshot.remove()
    syncState = RemoteSyncState()
    stats = RemoteLibraryStats()
    albumList = []
    revision &+= 1
    albumsRevision &+= 1
  }

  /// Removes an account's mirror and thumbnails without a library object.
  public static func removeLocalData(forAccountEmail email: String) async {
    await RemoteLibraryStore(accountEmail: email).closeAndRemove()
    await GooglePhotosWebSession.deleteWebData(forAccountEmail: email)
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
