import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MapKit
import Photos
import UniformTypeIdentifiers
import WidgetKit
import os

/// Picks the photos the widgets show and keeps the Backup widget's status current. The
/// app calls it as the library and the backup change; it writes to the App Group and asks
/// WidgetKit to reload.
@MainActor
public final class WidgetPublisher {
  public static let shared = WidgetPublisher()

  /// Memories change by the day and People slowly; this keeps a running app from
  /// rendering the photos again on every library change.
  static let refreshInterval: TimeInterval = 30 * 60
  /// Big enough for the large widget on a Pro Max iPhone (about 1,100 pixels across) once
  /// the widget crops it to its shape, small enough for a widget's memory.
  nonisolated static let imageSide = 1_000
  /// Upper bound on waiting for one image request so offline/errored items don't stall a batch.
  nonisolated static let imageTimeout: Duration = .seconds(6)

  private let directory: URL
  private let reloadTimeline: @MainActor (String) -> Void
  private let allowsNetwork: @Sendable () -> Bool
  private var photoTask: Task<Void, Never>?
  private var photoRequestID: UUID?
  private var mutationTail: Task<Void, Never>?
  private var photoWriteGeneration = 0
  private var backupTask: Task<Void, Never>?
  private var pendingBackup: WidgetBackupSnapshot?
  private var writtenBackup: WidgetBackupSnapshot?
  private var hasLoadedBackup = false
  private var cachedPhotos: WidgetPhotoSnapshot?
  private var hasLoadedPhotos = false
  private var lastPhotoCheckAt: Date?
  private var lastCheckedAccountEmail: String?
  private var lastCheckedCloudRevision: Int?
  private let logger = Logger(subsystem: "org.gphotosapp.gphotos", category: "Widgets")

  init(
    directory: URL = WidgetStore.directory,
    reloadTimeline: @escaping @MainActor (String) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0) },
    allowsNetwork: @escaping @Sendable () -> Bool = {
      LibraryIndexer.allowsCloudAnalysis() && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
  ) {
    self.directory = directory
    self.reloadTimeline = reloadTimeline
    self.allowsNetwork = allowsNetwork
  }

  private func mutate<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
    let previous = mutationTail
    let task = Task {
      await previous?.value
      return await operation()
    }
    mutationTail = Task { _ = await task.value }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  // MARK: Photos

  private func isPhotosFresh(now: Date = Date()) -> Bool {
    #if DEBUG
      // `-UIRefreshWidgets YES` picks again at launch, for reviewing the widgets.
      if UserDefaults.standard.bool(forKey: "UIRefreshWidgets") { return false }
    #endif
    guard let checkedAt = lastPhotoCheckAt, let cached = cachedPhotos, !cached.isEmpty else { return false }
    return Calendar.current.isDate(checkedAt, inSameDayAs: now)
      && now.timeIntervalSince(checkedAt) < Self.refreshInterval
  }

  /// The library changed: picks new photos when the last pick is from another day or a
  /// while ago. Always verifies any published cloud photos on account or mirror changes so
  /// newly locked, deleted or signed-out items leave the App Group immediately.
  public func libraryChanged(_ library: UnifiedLibraryModel) {
    let accountEmail = library.cloud?.library.accountEmail
    let cloudRevision = library.cloud?.library.revision
    let cloudLibrary = library.cloud?.library
    let accountSwitched = lastCheckedAccountEmail != nil && lastCheckedAccountEmail != accountEmail
    let cloudRetired = cloudLibrary?.isRetired == true
    guard library.isLoaded || accountSwitched || cloudRetired else { return }
    let libraryIsEmpty = library.isLoaded && library.hasMerged && library.filter == .all && library.itemCount == 0
    let stateChanged =
      lastCheckedAccountEmail != accountEmail || lastCheckedCloudRevision != cloudRevision || libraryIsEmpty
      || cloudRetired
    let needsSafetyCheck = !hasLoadedPhotos || stateChanged

    if !needsSafetyCheck {
      guard library.isLoaded, library.itemCount > 0, photoTask == nil else { return }
      if isPhotosFresh() { return }
    } else if photoTask != nil {
      guard stateChanged else { return }
      photoTask?.cancel()
      photoTask = nil
    }

    let requestID = UUID()
    photoRequestID = requestID
    photoTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if photoRequestID == requestID { photoTask = nil }
      }
      let purgedStale = await mutate { [self] in
        guard !Task.isCancelled else { return false }
        await loadCachedPhotosIfNeeded()
        let purged = await purgeStalePhotos(
          libraryIsEmpty: libraryIsEmpty, accountEmail: accountEmail, cloudLibrary: cloudLibrary)
        guard !Task.isCancelled else { return purged }
        lastCheckedAccountEmail = accountEmail
        lastCheckedCloudRevision = cloudRevision
        return purged
      }
      guard !Task.isCancelled else { return }

      guard library.isLoaded, library.itemCount > 0 else { return }
      if !purgedStale, self.isPhotosFresh() { return }
      let delay: Duration = purgedStale ? .seconds(1) : (self.cachedPhotos == nil ? .seconds(5) : .seconds(20))
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self.publishPhotos(from: library)
    }
  }

  private func purgeStalePhotos(libraryIsEmpty: Bool, accountEmail: String?, cloudLibrary: CloudLibrary?) async -> Bool {
    guard let cached = cachedPhotos else { return false }
    if libraryIsEmpty, !cached.isEmpty {
      return await applyPurge(removing: { _ in true }, extraFileIDs: [], updateAccountEmail: nil)
    }
    let cloudIDs = Self.cloudItemIDs(in: cached)
    guard !cloudIDs.isEmpty else { return false }
    guard let accountEmail, cached.accountEmail == accountEmail, let cloudLibrary, !cloudLibrary.isRetired else {
      return await applyPurge(
        removing: { $0.hasPrefix("g:") }, extraFileIDs: cloudIDs, updateAccountEmail: accountEmail)
    }
    let visible = try? await cloudLibrary.store.visibleMediaKeys(in: cloudIDs.map(Self.mediaKey))
    guard !Task.isCancelled else { return false }
    let invalid = cloudIDs.filter { visible?.contains(Self.mediaKey($0)) != true }
    guard !invalid.isEmpty else { return false }
    return await applyPurge(removing: invalid.contains, extraFileIDs: invalid, updateAccountEmail: accountEmail)
  }

  private nonisolated static func mediaKey(_ itemID: String) -> String { String(itemID.dropFirst(2)) }

  /// Removes any published widget entries and cached JPEGs for Google Photos `mediaKeys`
  /// (e.g. items moved into the Locked Folder) immediately, bypassing the refresh interval.
  public func purge(mediaKeys: Set<String>) async {
    guard !mediaKeys.isEmpty else { return }
    await purge(itemIDs: Set(mediaKeys.map(LibraryIndexer.searchID(cloudMediaKey:))))
  }

  /// Removes any published widget entries and cached JPEGs for `itemIDs` immediately,
  /// bypassing the refresh interval.
  public func purge(itemIDs: Set<String>) async {
    guard !itemIDs.isEmpty else { return }
    photoWriteGeneration &+= 1
    photoTask?.cancel()
    photoTask = nil
    await mutate { [self] in
      await loadCachedPhotosIfNeeded()
      _ = await applyPurge(
        removing: itemIDs.contains, extraFileIDs: itemIDs, updateAccountEmail: cachedPhotos?.accountEmail)
    }
  }

  /// Removes all Google Photos entries and cached JPEGs from the App Group widget store
  /// on sign-out (`unlessAccount == nil`) or when the stored snapshot belongs to another account.
  public func purgeCloudItems(unlessAccount accountEmail: String? = nil) async {
    photoWriteGeneration &+= 1
    photoTask?.cancel()
    photoTask = nil
    await mutate { [self] in
      await loadCachedPhotosIfNeeded()
      if let existing = cachedPhotos {
        if let accountEmail, existing.accountEmail == accountEmail { return }
        let cloudIDs = Self.cloudItemIDs(in: existing)
        _ = await applyPurge(
          removing: { $0.hasPrefix("g:") }, extraFileIDs: cloudIDs, updateAccountEmail: accountEmail)
      } else {
        guard accountEmail == nil else { return }
        let directory = directory
        let removedOrphans = await Task.detached(priority: .utility) { () -> Bool in
          let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
          guard names.contains(where: { $0.hasSuffix(".jpg") }) else { return false }
          WidgetStore.prune(keeping: [], in: directory)
          return true
        }.value
        lastPhotoCheckAt = nil
        if removedOrphans {
          reloadTimeline(WidgetStore.memoriesKind)
          reloadTimeline(WidgetStore.peopleKind)
        }
      }
      lastCheckedAccountEmail = accountEmail
      lastCheckedCloudRevision = nil
    }
  }

  private func loadCachedPhotosIfNeeded() async {
    guard !hasLoadedPhotos else { return }
    let directory = directory
    cachedPhotos = await Task.detached(priority: .utility) { WidgetStore.photos(in: directory) }.value
    lastPhotoCheckAt = cachedPhotos?.generatedAt
    hasLoadedPhotos = true
  }

  private nonisolated static func cloudItemIDs(in snapshot: WidgetPhotoSnapshot) -> Set<String> {
    Set((snapshot.memories + snapshot.people).flatMap(\.photos).map(\.itemID).filter { $0.hasPrefix("g:") })
  }

  private nonisolated static func filtering(
    _ sets: [WidgetPhotoSet], removing shouldRemove: (String) -> Bool
  ) -> [WidgetPhotoSet] {
    sets.compactMap { set in
      let kept = set.photos.filter { !shouldRemove($0.itemID) }
      guard !kept.isEmpty else { return nil }
      var copy = set
      copy.photos = kept
      return copy
    }
  }

  private func applyPurge(
    removing shouldRemove: @escaping @Sendable (String) -> Bool, extraFileIDs: Set<String>, updateAccountEmail: String?
  ) async -> Bool {
    let directory = directory
    let existing = cachedPhotos
    let result = await Task.detached(priority: .utility) {
      () -> (snapshot: WidgetPhotoSnapshot?, removedFile: Bool, error: Error?) in
      func purge(locked: Set<String>) throws -> WidgetPhotoSnapshot? {
        func removing(_ id: String) -> Bool {
          shouldRemove(id) || (id.hasPrefix("g:") && locked.contains(Self.mediaKey(id)))
        }
        let updated = existing.map {
          WidgetPhotoSnapshot(
            generatedAt: $0.generatedAt, accountEmail: updateAccountEmail,
            memories: Self.filtering($0.memories, removing: removing),
            people: Self.filtering($0.people, removing: removing))
        }
        if let updated, updated != existing {
          try WidgetStore.write(updated, in: directory)
        }
        return updated == existing ? nil : updated
      }

      do {
        let result: WidgetPhotoSnapshot?
        if let account = existing?.accountEmail {
          result = try LockedItems.withKeys(for: account) { try purge(locked: $0) }
        } else {
          result = try purge(locked: [])
        }
        if let updated = result {
          let kept = Set((updated.memories + updated.people).flatMap(\.photos).map(\.file))
          WidgetStore.prune(keeping: kept, in: directory)
          return (updated, false, nil)
        }
        var removedFile = false
        let kept = Set(((existing?.memories ?? []) + (existing?.people ?? [])).flatMap(\.photos).map(\.file))
        for name in Set(extraFileIDs.map(Self.fileName(for:))).subtracting(kept) {
          let url = directory.appendingPathComponent(name)
          if (try? FileManager.default.removeItem(at: url)) != nil { removedFile = true }
        }
        return (nil, removedFile, nil)
      } catch {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(WidgetStore.photosFileName))
        WidgetStore.prune(keeping: [], in: directory)
        return (nil, false, error)
      }
    }.value

    if let error = result.error {
      logger.error("Widgets: couldn't purge photos: \(error.localizedDescription)")
      cachedPhotos = nil
    } else if let updated = result.snapshot {
      cachedPhotos = updated
    }
    let memoriesChanged = cachedPhotos?.memories != existing?.memories
    let peopleChanged = cachedPhotos?.people != existing?.people
    let filesChanged = result.removedFile || result.error != nil
    if memoriesChanged || peopleChanged || filesChanged { lastPhotoCheckAt = nil }
    if memoriesChanged || filesChanged { reloadTimeline(WidgetStore.memoriesKind) }
    if peopleChanged || filesChanged { reloadTimeline(WidgetStore.peopleKind) }
    return memoriesChanged || peopleChanged || filesChanged
  }

  private enum TargetKind: Sendable {
    case device(assetID: String, date: Date)
    case cloud(mediaKey: String, thumbnailID: String, date: Date)

    var date: Date {
      switch self {
      case .device(_, let date), .cloud(_, _, let date): date
      }
    }
  }

  func publishPhotos(from library: UnifiedLibraryModel, store: LibraryIndexStore = SiriLibrary.shared.store) async {
    let directory = directory
    let generation = photoWriteGeneration
    let rawSnapshot = library.indexSnapshot()
    let thumbnailSource = library.thumbnailSource
    let cloudLibrary = library.cloud?.library
    let localAssets = cloudLibrary?.localAssetIDs ?? [:]
    let localFiles = cloudLibrary?.localFiles ?? [:]
    let accountEmail = cloudLibrary?.accountEmail
    let cloudRevision = cloudLibrary?.revision
    let allowsNetwork = allowsNetwork

    let cachedAccount = await mutate { [self] in
      await loadCachedPhotosIfNeeded()
      return cachedPhotos?.accountEmail
    }
    let staged = OSAllocatedUnfairLock(initialState: [String: Data]())

    let build = Task.detached(priority: .utility) {
      () -> (memories: [WidgetPhotoSet], people: [WidgetPhotoSet]) in
      let snapshot = rawSnapshot.unfiltered()
      // Build an index-ID lookup once off-main (from `.library`, so locked items are never included).
      var targets: [String: TargetKind] = [:]
      targets.reserveCapacity(snapshot.entries.count)
      for entry in snapshot.entries {
        switch entry {
        case .device(let index, _):
          guard snapshot.device.indices.contains(index) else { continue }
          let info = snapshot.device[index]
          targets[info.localIdentifier] = .device(assetID: info.localIdentifier, date: info.date)
        case .cloud(let index), .folder(_, cloud: .some(let index)):
          guard snapshot.cloud.indices.contains(index) else { continue }
          let item = snapshot.cloud[index]
          let id = LibraryIndexer.searchID(cloudMediaKey: item.mediaKey)
          targets[id] = .cloud(mediaKey: item.mediaKey, thumbnailID: item.thumbnailID, date: item.takenAt)
        case .folder(_, cloud: nil):
          break
        }
      }

      let existingNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      let existingFiles = Set(existingNames.filter { $0.hasSuffix(".jpg") })
      let context = ImageFetchContext(
        existingFiles: existingFiles, canReuseCloudImages: cachedAccount == accountEmail, staged: staged,
        targets: targets, thumbnailSource: thumbnailSource, localAssets: localAssets, localFiles: localFiles,
        accountEmail: accountEmail, allowsNetwork: allowsNetwork)

      let moments = snapshot.moments()
      let today = Date()
      let days = MemoryFinder.onThisDay(moments, today: today)
      let trips = MemoryFinder.trips(moments)
      let currentYear = Calendar.current.component(.year, from: today)
      var foundMemories: [Memory] = days.map { day in
        Memory(
          kind: .onThisDay(yearsAgo: currentYear - day.year),
          idList: ItemIDs(day.indices.compactMap(snapshot.indexID(at:))), date: moments[day.indices[0]].date)
      }
      for trip in trips.prefix(12) {
        let located = trip.filter { moments[$0].latitude != nil }
        guard !located.isEmpty else { continue }
        let middle = located[located.count / 2]
        foundMemories.append(
          Memory(
            kind: .trip(latitude: moments[middle].latitude ?? 0, longitude: moments[middle].longitude ?? 0),
            idList: ItemIDs(trip.reversed().compactMap(snapshot.indexID(at:))), date: moments[trip[0]].date))
      }

      var memories: [WidgetPhotoSet] = []
      for memory in foundMemories where memories.count < 6 {
        let picked = await Self.pick(memory.idList.values, count: 3, store: store, context: context)
        guard !picked.isEmpty else { continue }
        switch memory.kind {
        case .onThisDay:
          memories.append(
            WidgetPhotoSet(
              id: memory.id, kind: .onThisDay, title: String(localized: "On This Day"),
              subtitle: memory.date.formatted(.dateTime.day().month(.abbreviated).year()), photos: picked))
        case .trip(let latitude, let longitude):
          let place = await PlaceNameCache.shared.placeName(latitude: latitude, longitude: longitude)
          memories.append(
            WidgetPhotoSet(
              id: memory.id, kind: .trip, title: place ?? memory.title,
              subtitle: place == nil ? String(localized: "Trip") : memory.title, photos: picked))
        }
      }
      // Days without memories still get photos: the best ones, a different few each day.
      if memories.count < 3 {
        let featured = (try? await store.featuredIDs(limit: 400)) ?? []
        var generator = SeededGenerator(seed: UInt64(Calendar.current.ordinality(of: .day, in: .era, for: today) ?? 0))
        let picked = await Self.pick(
          featured.shuffled(using: &generator), count: 8, store: store, context: context, keepsOrder: true)
        if !picked.isEmpty {
          memories.append(
            WidgetPhotoSet(
              id: "featured", kind: .featured, title: String(localized: "Featured Photos"), subtitle: "",
              photos: picked))
        }
      }

      var people: [WidgetPhotoSet] = []
      for person in ((try? await store.people()) ?? []).prefix(8) {
        let ids = Array(((try? await store.ids(ofPerson: person.id)) ?? []).prefix(300))
        // Their best photos among the latest few hundred, so a widget feels current, cropped
        // around their face.
        let faces = (try? await store.faceCenters(person: person.id, ids: ids)) ?? [:]
        let picked = await Self.pick(ids, count: 5, store: store, context: context, focus: faces)
        guard !picked.isEmpty else { continue }
        people.append(
          WidgetPhotoSet(
            id: "person-\(person.id)", kind: .person, title: person.name ?? "",
            subtitle: ProductCopy.inflected("^[\(person.faceCount) photo](inflect: true)"), photos: picked,
            personID: person.id))
      }
      return (memories, people)
    }
    let built = await withTaskCancellationHandler {
      await build.value
    } onCancel: {
      build.cancel()
    }
    let proposed = WidgetPhotoSnapshot(accountEmail: accountEmail, memories: built.memories, people: built.people)
    let cloudIDs = Self.cloudItemIDs(in: proposed)

    await mutate { [self] in
      guard !Task.isCancelled, generation == photoWriteGeneration else { return }
      let visible: Set<String>
      if !cloudIDs.isEmpty, let cloudLibrary, !cloudLibrary.isRetired {
        visible = (try? await cloudLibrary.store.visibleMediaKeys(in: cloudIDs.map(Self.mediaKey))) ?? []
      } else {
        visible = []
      }
      guard !Task.isCancelled, generation == photoWriteGeneration, cloudLibrary?.isRetired != true,
        library.cloud?.library === cloudLibrary
      else { return }

      let previous = cachedPhotos
      let images = staged.withLock { $0 }
      let commit = await Task.detached(priority: .utility) {
        Self.commitPhotos(proposed, images: images, visible: visible, previous: previous, directory: directory)
      }.value
      if let error = commit.error {
        logger.error("Widgets: couldn't save photos: \(error.localizedDescription)")
        return
      }
      lastPhotoCheckAt = proposed.generatedAt
      lastCheckedAccountEmail = accountEmail
      lastCheckedCloudRevision = cloudRevision
      guard let snapshot = commit.snapshot else { return }
      cachedPhotos = snapshot
      if (previous?.memories ?? []) != snapshot.memories
        || snapshot.memories.contains(where: { $0.photos.contains(where: { commit.written.contains($0.file) }) })
      {
        reloadTimeline(WidgetStore.memoriesKind)
      }
      if (previous?.people ?? []) != snapshot.people
        || snapshot.people.contains(where: { $0.photos.contains(where: { commit.written.contains($0.file) }) })
      {
        reloadTimeline(WidgetStore.peopleKind)
      }
      logger.info("Widgets: \(snapshot.memories.count) memories, \(snapshot.people.count) people")
    }
  }

  nonisolated static func commitPhotos(
    _ proposed: WidgetPhotoSnapshot, images: [String: Data], visible: Set<String>,
    previous: WidgetPhotoSnapshot?, directory: URL,
    willPlace: (WidgetPhoto) -> Void = { _ in }
  ) -> (snapshot: WidgetPhotoSnapshot?, written: Set<String>, error: Error?) {
    let photos = (proposed.memories + proposed.people).flatMap(\.photos)
    let initialLocks = proposed.accountEmail.map { LockedItems.keys(accountEmail: $0) } ?? []
    let previousFiles = Set(((previous?.memories ?? []) + (previous?.people ?? [])).flatMap(\.photos).map(\.file))
    var availableFiles = Set<String>()
    var written = Set<String>()

    do {
      for photo in photos where !availableFiles.contains(photo.file) {
        if photo.itemID.hasPrefix("g:") {
          let key = mediaKey(photo.itemID)
          guard visible.contains(key), !initialLocks.contains(key) else { continue }
        }
        let url = directory.appendingPathComponent(photo.file)
        if let data = images[photo.file] {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          willPlace(photo)
          // Written under the lock, so one locked meanwhile isn't put back after its purge.
          let place = { (locked: Set<String>) throws -> Bool in
            guard !photo.itemID.hasPrefix("g:") || !locked.contains(mediaKey(photo.itemID)) else { return false }
            try data.write(to: url, options: .atomic)
            return true
          }
          let placed = try proposed.accountEmail.map { try LockedItems.withKeys(for: $0, place) } ?? place([])
          guard placed else { continue }
          written.insert(photo.file)
        } else if !FileManager.default.fileExists(atPath: url.path)
          || (photo.itemID.hasPrefix("g:") && previous?.accountEmail != proposed.accountEmail)
        {
          continue
        }
        availableFiles.insert(photo.file)
      }

      func publish(locked: Set<String>) throws -> WidgetPhotoSnapshot? {
        let unavailable = Set(
          photos.compactMap { photo -> String? in
            if !availableFiles.contains(photo.file) || (photo.itemID.hasPrefix("g:") && locked.contains(mediaKey(photo.itemID))) {
              return photo.itemID
            }
            return nil
          })
        let snapshot = WidgetPhotoSnapshot(
          generatedAt: proposed.generatedAt, accountEmail: proposed.accountEmail,
          memories: filtering(proposed.memories, removing: unavailable.contains),
          people: filtering(proposed.people, removing: unavailable.contains))
        guard
          !written.isEmpty || previous?.accountEmail != snapshot.accountEmail
            || (previous?.memories ?? []) != snapshot.memories || (previous?.people ?? []) != snapshot.people
        else { return nil }
        try WidgetStore.write(snapshot, in: directory)
        return snapshot
      }

      // A lock can arrive during JPEG writes. Only the snapshot commit needs the lock.
      let snapshot: WidgetPhotoSnapshot?
      if let account = proposed.accountEmail {
        snapshot = try LockedItems.withKeys(for: account) { try publish(locked: $0) }
      } else {
        snapshot = try publish(locked: [])
      }
      guard let snapshot else { return (nil, [], nil) }
      let kept = Set((snapshot.memories + snapshot.people).flatMap(\.photos).map(\.file))
      WidgetStore.prune(keeping: kept, in: directory)
      return (snapshot, written.intersection(kept), nil)
    } catch {
      WidgetStore.prune(keeping: previousFiles, in: directory)
      return (nil, [], error)
    }
  }

  private struct ImageFetchContext: Sendable {
    let existingFiles: Set<String>
    let canReuseCloudImages: Bool
    let staged: OSAllocatedUnfairLock<[String: Data]>
    let targets: [String: TargetKind]
    let thumbnailSource: any ThumbnailSource
    let localAssets: [String: String]
    let localFiles: [String: FolderItemInfo]
    let accountEmail: String?
    let allowsNetwork: @Sendable () -> Bool
  }

  /// The best `count` of `ids` that are in the library, with a saved image each. Items the
  /// index calls screenshots or documents are left out; folder files have no image source.
  private nonisolated static func pick(
    _ ids: [String], count: Int, store: LibraryIndexStore, context: ImageFetchContext, keepsOrder: Bool = false,
    focus: [String: CGPoint] = [:]
  ) async -> [WidgetPhoto] {
    let candidates = ids.filter { !$0.hasPrefix(FolderItemInfo.idPrefix) && context.targets[$0] != nil }
    guard !candidates.isEmpty else { return [] }
    let scores = (try? await store.photoScores(ids: candidates)) ?? [:]
    var ranked = candidates.filter { scores[$0]?.isUtility != true }
    if !keepsOrder {
      ranked.sort { (scores[$0]?.aesthetics ?? -1) > (scores[$1]?.aesthetics ?? -1) }
    }
    var photos: [WidgetPhoto] = []
    var cursor = 0
    while cursor < ranked.count, photos.count < count, !Task.isCancelled {
      let needed = count - photos.count
      let batchCount = min(max(needed, 4), ranked.count - cursor)
      let batch = Array(ranked[cursor..<(cursor + batchCount)])
      cursor += batchCount
      let results = await withTaskGroup(of: (Int, String?).self) { group in
        for (offset, id) in batch.enumerated() {
          group.addTask(priority: .utility) {
            (offset, await prepareImage(indexID: id, context: context))
          }
        }
        var collected: [(Int, String?)] = []
        collected.reserveCapacity(batch.count)
        for await result in group { collected.append(result) }
        return collected.sorted { $0.0 < $1.0 }
      }
      for (offset, file) in results where photos.count < count {
        guard let file else { continue }
        let id = batch[offset]
        let photoDate = scores[id]?.date ?? context.targets[id]?.date ?? .distantPast
        photos.append(WidgetPhoto(itemID: id, file: file, date: photoDate, focus: focus[id]))
      }
    }
    return photos
  }

  /// Holds encoded pixels in memory until publication can verify the item is still visible.
  private nonisolated static func prepareImage(indexID: String, context: ImageFetchContext) async -> String? {
    let name = fileName(for: indexID)
    if context.existingFiles.contains(name), !indexID.hasPrefix("g:") || context.canReuseCloudImages {
      return name
    }
    if context.staged.withLock({ $0[name] != nil }) { return name }
    guard let target = context.targets[indexID] else { return nil }
    guard let image = await fetchImage(for: target, context: context) else { return nil }
    guard !Task.isCancelled, let data = jpeg(image, maxPixel: imageSide) else { return nil }
    context.staged.withLock { $0[name] = data }
    return name
  }

  private nonisolated static func fetchImage(for target: TargetKind, context: ImageFetchContext) async -> CGImage? {
    let networkAllowed = context.allowsNetwork()
    switch target {
    case .device(let assetID, _):
      if !networkAllowed {
        guard let asset = PhotoKitImageSource.shared.asset(for: assetID) else { return nil }
        return await LibraryIndexer.localThumbnail(asset: asset, side: CGFloat(imageSide))
      }
      return await image(id: assetID, source: context.thumbnailSource, timeout: imageTimeout)
    case .cloud(let mediaKey, let thumbnailID, _):
      if let file = context.localFiles[mediaKey] {
        let local =
          file.isVideo
          ? await FolderThumbnailSource.videoFrame(file.url, side: CGFloat(imageSide))
          : LibraryIndexer.localFileImage(file.url, side: CGFloat(imageSide))
        if let local { return local }
      }
      if let assetID = context.localAssets[mediaKey], let asset = PhotoKitImageSource.shared.asset(for: assetID) {
        if let local = await LibraryIndexer.localThumbnail(asset: asset, side: CGFloat(imageSide)) { return local }
      }
      if !networkAllowed {
        if let email = context.accountEmail,
          let kept = KeptThumbnails.data(mediaKey: mediaKey, accountEmail: email),
          let decoded = GoogleThumbnailSource.decode(kept, maxPixel: imageSide)
        {
          return decoded
        }
        return nil
      }
      return await image(id: thumbnailID, source: context.thumbnailSource, timeout: imageTimeout)
    }
  }

  nonisolated static func fileName(for indexID: String) -> String {
    SHA256.hash(data: Data(indexID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
  }

  /// The source's final image at viewer size, or the best it had before the timeout.
  nonisolated static func image(
    id: String, source: any ThumbnailSource, timeout: Duration = imageTimeout
  ) async -> CGImage? {
    let request = ImageWait()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        request.begin(continuation)
        if Task.isCancelled {
          request.finish(useBest: false)
          return
        }
        let token = source.requestImage(
          id: id, pixelSize: CGSize(width: imageSide, height: imageSide), quality: .display,
          onUnavailable: { request.finish(useBest: true) }
        ) { image, isFinal in
          request.offer(image, isFinal: isFinal)
        }
        request.attach(token: token)
        let timer = Task {
          try? await Task.sleep(for: timeout)
          request.finish(useBest: true)
        }
        request.attach(timer: timer)
      }
    } onCancel: {
      request.finish(useBest: false)
    }
  }

  nonisolated static func jpeg(_ image: CGImage, maxPixel: Int) -> Data? {
    var image = image
    let longest = max(image.width, image.height)
    if longest > maxPixel {
      let scale = Double(maxPixel) / Double(longest)
      let width = Int((Double(image.width) * scale).rounded())
      let height = Int((Double(image.height) * scale).rounded())
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let scaled = context.makeImage() else { return nil }
      image = scaled
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  // MARK: Backup

  /// The backup status changed. Scans come and go all the time and aren't shown; a new
  /// kind of status is written within moments, progress within the minute.
  public func backupChanged(_ status: BackupStatus, backedUpCount: Int) {
    if case .scanning = status { return }
    let snapshot = WidgetBackupSnapshot(
      title: status.title, subtitle: status.subtitle, symbol: status.symbol, tone: status.tone.rawValue,
      isSignedIn: status != .signedOut, isHealthy: status.tone == .green, backedUpCount: backedUpCount)
    let base = pendingBackup ?? writtenBackup
    if let base, base.sameContent(as: snapshot) { return }
    let isNewKind = base?.symbol != snapshot.symbol || base?.title.prefix(8) != snapshot.title.prefix(8)
    pendingBackup = snapshot
    if isNewKind { backupTask?.cancel() } else if backupTask != nil { return }
    backupTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(isNewKind ? 2 : 60))
      guard !Task.isCancelled, let self, let pending = self.pendingBackup else { return }
      self.pendingBackup = nil
      self.backupTask = nil
      await self.mutate { await self.writeBackup(pending) }
    }
  }

  private func writeBackup(_ snapshot: WidgetBackupSnapshot) async {
    let directory = directory
    if !hasLoadedBackup {
      writtenBackup = await Task.detached(priority: .utility) { WidgetStore.backup(in: directory) }.value
      hasLoadedBackup = true
    }
    guard writtenBackup.map({ !$0.sameContent(as: snapshot) }) ?? true else { return }
    let error = await Task.detached(priority: .utility) { () -> Error? in
      do {
        try WidgetStore.write(snapshot, in: directory)
        return nil
      } catch {
        return error
      }
    }.value
    if let error {
      logger.error("Widgets: couldn't save the backup status: \(error.localizedDescription)")
    } else {
      writtenBackup = snapshot
      reloadTimeline(WidgetStore.backupKind)
    }
  }
}

/// One image request's result: the final image, or the best delivered before the timeout.
private final class ImageWait: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage?, Never>?
  private var best: CGImage?
  private var token: ImageRequestToken?
  private var timer: Task<Void, Never>?
  private var isDone = false

  func begin(_ continuation: CheckedContinuation<CGImage?, Never>) {
    let accepted = lock.withLock {
      guard !isDone else { return false }
      self.continuation = continuation
      return true
    }
    if !accepted { continuation.resume(returning: nil) }
  }

  func attach(token: ImageRequestToken) {
    let cancelNow = lock.withLock { () -> Bool in
      self.token = token
      return isDone
    }
    if cancelNow { token.cancel() }
  }

  func attach(timer: Task<Void, Never>) {
    let cancelNow = lock.withLock { () -> Bool in
      self.timer = timer
      return isDone
    }
    if cancelNow { timer.cancel() }
  }

  func offer(_ image: CGImage, isFinal: Bool) {
    lock.withLock { best = image }
    if isFinal { finish(useBest: true) }
  }

  func finish(useBest: Bool) {
    let (continuation, image, token, timer) = lock.withLock {
      () -> (CheckedContinuation<CGImage?, Never>?, CGImage?, ImageRequestToken?, Task<Void, Never>?) in
      guard !isDone else { return (nil, nil, nil, nil) }
      isDone = true
      defer {
        self.continuation = nil
        self.token = nil
        self.timer = nil
      }
      return (self.continuation, useBest ? best : nil, self.token, self.timer)
    }
    timer?.cancel()
    token?.cancel()
    continuation?.resume(returning: image)
  }
}

/// A repeatable shuffle, so the featured photos change once a day, not on every pick.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
