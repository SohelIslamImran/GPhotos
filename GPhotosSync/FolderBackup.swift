import Darwin
import Foundation
import GPhotosKit

/// A folder chosen in the Files app whose photos and videos are backed up. The bookmark
/// keeps access across launches; `path` is where the folder was when it was chosen.
public struct BackedUpFolder: Identifiable, Codable, Hashable, Sendable {
  /// The standardized path the folder was added from.
  public let id: String
  public var title: String
  public var path: String
  public var bookmarkData: Data
  public var isEnabled: Bool

  public init(url: URL, title: String, bookmarkData: Data, isEnabled: Bool = true) {
    let path = url.standardizedFileURL.path
    self.id = path
    self.title = title
    self.path = path
    self.bookmarkData = bookmarkData
    self.isEnabled = isEnabled
  }
}

/// What a backed-up folder is doing, as its row shows it.
public enum BackedUpFolderStatus: Sendable, Equatable {
  case backingUp
  case paused
  case needsAccess
  case waitingForSignIn

  public var title: String {
    switch self {
    case .backingUp: String(localized: "Backing up")
    case .paused: String(localized: "Paused")
    case .needsAccess: String(localized: "Needs Access")
    case .waitingForSignIn: String(localized: "Waiting for sign-in")
    }
  }
}

/// One folder's bookmark resolved and its security scope taken. Every access with
/// `started` set must be balanced through `FolderBackup.endAccess(_:)`.
struct FolderAccess: Sendable {
  let folderID: String
  /// Nil when the bookmark no longer resolves.
  let url: URL?
  let started: Bool
  let isReadable: Bool
  /// The bookmark the resolution started from, so a refresh is applied only while the
  /// folder still holds it.
  let previousBookmark: Data
  /// A recreated bookmark, only when the old one was stale and the new one differs.
  let refreshedBookmark: Data?

  /// The folder's root, when it can actually be read.
  var readableURL: URL? { isReadable ? url : nil }
}

/// A file in a backed-up folder that cleanup may remove, with everything checked
/// except the manifest claim.
struct FolderCleanupItem: Sendable {
  let record: TransferRecord
  let fileURL: URL
  let pairedFileURL: URL?
  let root: URL
  let volume: URL?

  var bytes: Int64 {
    var total = record.sourceFileSize ?? record.byteCount ?? 0
    if pairedFileURL != nil { total += record.pairedSourceFileSize ?? 0 }
    return max(0, total)
  }
}

enum FolderAdditionError: Error, Sendable {
  case duplicate
  case insideApp
  case unavailable

  var message: String {
    switch self {
    case .duplicate: String(localized: "This folder is already backed up.")
    case .insideApp: String(localized: "Folders inside \(ProductCopy.name) can't be backed up.")
    case .unavailable: String(localized: "This folder can't be accessed. Try choosing it again.")
    }
  }
}

/// Persistence, bookmark handling and the pure scanning and cleanup steps for the
/// iPhone's backed-up folders. Everything here may run off the main actor.
enum FolderBackup {
  private static let defaultsKey = "backedUpFolders"

  static func load() -> [BackedUpFolder] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
    return (try? JSONDecoder().decode([BackedUpFolder].self, from: data)) ?? []
  }

  static func save(_ folders: [BackedUpFolder]) {
    guard let data = try? JSONEncoder().encode(folders) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }

  // MARK: Adding

  /// The entry for a folder picked with `.fileImporter`. iOS bookmarks carry the
  /// picker's grant without a security-scope option, but only while access is held.
  static func makeFolder(from url: URL) -> Result<BackedUpFolder, FolderAdditionError> {
    let started = url.startAccessingSecurityScopedResource()
    defer {
      if started { url.stopAccessingSecurityScopedResource() }
    }
    let standardized = url.standardizedFileURL
    guard !isInsideAppContainer(standardized) else { return .failure(.insideApp) }
    guard let bookmark = try? url.bookmarkData() else { return .failure(.unavailable) }
    let displayName = FileManager.default.displayName(atPath: standardized.path)
    let title =
      displayName.isEmpty ? (standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent) : displayName
    return .success(BackedUpFolder(url: standardized, title: title, bookmarkData: bookmark))
  }

  /// A protected folder's entry, with a bookmark so it keeps protecting the folder
  /// after a move.
  static func makeIgnoredFolder(from url: URL) -> IgnoredFolderLocation {
    let started = url.startAccessingSecurityScopedResource()
    defer {
      if started { url.stopAccessingSecurityScopedResource() }
    }
    let standardized = url.standardizedFileURL
    let displayName = FileManager.default.displayName(atPath: standardized.path)
    return IgnoredFolderLocation(url: standardized, displayName: displayName, bookmarkData: try? url.bookmarkData())
  }

  /// The app's own container and the App Group hold the manifest, staged copies and
  /// shared items. Backing them up would upload, and then delete, the app's own state.
  private static func isInsideAppContainer(_ url: URL) -> Bool {
    var containers = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
    if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.identifier) {
      containers.append(group)
    }
    containers.append(AppGroupConstants.storageDirectory())
    return containers.contains { isPath(url.path, inside: $0) }
  }

  // MARK: Access

  /// Resolves each folder's bookmark and takes its security scope. A stale bookmark is
  /// recreated while access is held, since it cannot be once access has lapsed.
  static func beginAccess(_ folders: [BackedUpFolder]) -> [FolderAccess] {
    folders.map(beginAccess)
  }

  static func beginAccess(_ folder: BackedUpFolder) -> FolderAccess {
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: folder.bookmarkData,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else {
      return FolderAccess(
        folderID: folder.id, url: nil, started: false, isReadable: false,
        previousBookmark: folder.bookmarkData, refreshedBookmark: nil)
    }
    let started = url.startAccessingSecurityScopedResource()
    var refreshed: Data?
    if isStale, started, let data = try? url.bookmarkData(), data != folder.bookmarkData {
      refreshed = data
    }
    return FolderAccess(
      folderID: folder.id, url: url, started: started, isReadable: isReadableDirectory(url),
      previousBookmark: folder.bookmarkData, refreshedBookmark: refreshed)
  }

  static func endAccess(_ accesses: [FolderAccess]) {
    for access in accesses where access.started {
      access.url?.stopAccessingSecurityScopedResource()
    }
  }

  /// A folder that resolves can still refuse a listing; `opendir` answers that without
  /// paying for one.
  private static func isReadableDirectory(_ url: URL) -> Bool {
    guard let handle = opendir(url.standardizedFileURL.path) else { return false }
    closedir(handle)
    return true
  }

  // MARK: Scanning

  /// Every settled photo and video in the readable folders, each file once even when
  /// folders overlap, less what the user's rules leave out. Callers hold `accesses` for
  /// the duration.
  static func collectMedia(
    in accesses: [FolderAccess], excluding exclusions: FolderExclusions = .none,
    using foregroundRead: FolderMediaScanner.ForegroundRead? = nil
  ) async -> MediaScan {
    var merged = MediaScan()
    var seen = Set<String>()
    for access in accesses {
      guard !Task.isCancelled, let root = access.readableURL else { continue }
      let scan =
        if let foregroundRead { await foregroundRead.scan(root, excluding: exclusions) } else {
          FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true, excluding: exclusions)
        }
      merged.deferredRecentWrites = merged.deferredRecentWrites || scan.deferredRecentWrites
      // The scan follows no links below the root, so resolving the root once and
      // re-basing each file on it gives every file its resolved path without a stat.
      let rootPath = root.standardizedFileURL.path
      let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
      for file in scan.files {
        let path = file.url.standardizedFileURL.path
        let resolved = path.hasPrefix(rootPath + "/") ? resolvedRoot + String(path.dropFirst(rootPath.count)) : path
        guard seen.insert(comparisonKey(resolved)).inserted else { continue }
        merged.files.append(file)
      }
    }
    return merged
  }

  /// One spelling for paths that name the same file: `/private` for `/var`, precomposed
  /// and case-folded. Pure string work; resolve links before calling where that matters.
  static func comparisonKey(_ path: String) -> String {
    FolderMediaScanner.comparablePath(WatchedFolderPaths.privatePrefixed(path))
  }

  /// Whether `candidate` is already backed up under another entry, comparing resolved,
  /// normalized locations, so a folder reached through a link or spelled differently is
  /// still caught. `existing` pairs each other folder with where it last resolved.
  static func isDuplicate(_ candidate: URL, of existing: [(folder: BackedUpFolder, resolved: URL?)]) -> Bool {
    func keys(_ url: URL) -> Set<String> {
      [comparisonKey(url.standardizedFileURL.path), comparisonKey(url.resolvingSymlinksInPath().standardizedFileURL.path)]
    }
    let candidateKeys = keys(candidate)
    return existing.contains { entry in
      var entryKeys = keys(URL(fileURLWithPath: entry.folder.path, isDirectory: true))
      if let resolved = entry.resolved { entryKeys.formUnion(keys(resolved)) }
      return !entryKeys.isDisjoint(with: candidateKeys)
    }
  }

  // MARK: Paths

  /// Whether `path` is `root` or lies inside it, comparing both as given and with
  /// symbolic links resolved (`/var` is `/private/var` on iOS).
  static func isPath(_ path: String, inside root: URL) -> Bool {
    let candidate = URL(fileURLWithPath: path)
    let candidates = [candidate.standardizedFileURL.path, candidate.resolvingSymlinksInPath().path]
    let roots = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
    return candidates.contains { candidate in
      roots.contains { WatchedFolderPaths.isPath(candidate, inside: $0) }
    }
  }

  /// The paths `roots` may be known by, as given and, with `resolvesSymlinks`, with
  /// symbolic links resolved, worked out once for `isPath(_:insideAny:)`. Resolving
  /// touches the file system; without it this is pure string work.
  static func rootPaths(_ roots: [URL], resolvesSymlinks: Bool = true) -> [String] {
    var paths: [String] = []
    for root in roots {
      var spellings = [root.standardizedFileURL.path]
      if resolvesSymlinks { spellings.append(root.resolvingSymlinksInPath().path) }
      for path in spellings.map(normalized) where !paths.contains(path) {
        paths.append(path)
      }
    }
    return paths
  }

  /// Whether `path` lies inside one of `rootPaths` without touching the file system,
  /// so it can run on the main actor for every record.
  static func isPath(_ path: String, insideAny rootPaths: [String]) -> Bool {
    let candidate = normalized(URL(fileURLWithPath: path).standardizedFileURL.path)
    return rootPaths.contains { WatchedFolderPaths.isPath(candidate, inside: $0) }
  }

  /// `/var` is a symbolic link to `/private/var` on iOS, and both spellings appear in
  /// paths handed out by the system; names may arrive precomposed or not. Case is left
  /// to `WatchedFolderPaths.isPath`.
  private static func normalized(_ path: String) -> String {
    WatchedFolderPaths.privatePrefixed(path).precomposedStringWithCanonicalMapping
  }

  // MARK: Cleanup

  /// What may be removed from `records`, in order: the file must sit inside a readable
  /// backed-up folder and outside every protected folder, neither it nor its folder may
  /// be a shared iCloud item, a Live Photo's video must still match its record, and
  /// with `smartDelete` only as much goes as each folder's own volume needs to get back
  /// above the low-space threshold. `protectedPaths` comes from
  /// `IgnoredFolderLocation.protectedPaths(_:)`. Callers hold `accesses`;
  /// `deleteSourceFiles` re-verifies content before anything is removed.
  static func planCleanup(
    records: [TransferRecord],
    accesses: [FolderAccess],
    protectedPaths: [String],
    smartDelete: Bool
  ) -> [FolderCleanupItem] {
    let roots = accesses.compactMap(\.readableURL)
    guard !roots.isEmpty else { return [] }
    var volumeByRoot: [String: URL] = [:]
    var bytesNeededByVolume: [URL: Int64] = [:]
    var sharedRoots: [String: Bool] = [:]
    var items: [FolderCleanupItem] = []
    for record in records {
      if Task.isCancelled { break }
      guard record.sharedEntryID == nil,
        let sourcePath = record.sourcePath,
        let fileURL = SyncEngine.validatedSourceFileURL(atPath: sourcePath, roots: roots),
        let root = roots.first(where: { isPath(fileURL.path, inside: $0) }),
        !IgnoredFolderLocation.isProtected(fileURL, protectedPaths: protectedPaths),
        !FolderMediaScanner.isSharedCloudItem(fileURL)
      else { continue }
      let rootIsShared = sharedRoots[root.path] ?? FolderMediaScanner.isSharedCloudItem(root)
      sharedRoots[root.path] = rootIsShared
      guard !rootIsShared else { continue }

      var pairedFileURL: URL?
      if record.mediaType == "Live Photo" {
        guard let paired = SyncEngine.validatedExistingPairedFileURL(for: record, roots: roots),
          !IgnoredFolderLocation.isProtected(paired, protectedPaths: protectedPaths),
          !FolderMediaScanner.isSharedCloudItem(paired)
        else { continue }
        pairedFileURL = paired
      } else if record.pairedSourcePath != nil {
        continue
      }

      let volume =
        volumeByRoot[root.path]
        ?? (try? root.resourceValues(forKeys: [.volumeURLKey]))?.volume
        ?? root
      volumeByRoot[root.path] = volume
      let item = FolderCleanupItem(
        record: record, fileURL: fileURL, pairedFileURL: pairedFileURL, root: root, volume: volume)
      if smartDelete {
        if bytesNeededByVolume[volume] == nil {
          bytesNeededByVolume[volume] = TransferManifestStore.bytesNeededToRecover(onVolumeOf: root)
        }
        guard let needed = bytesNeededByVolume[volume], needed > 0 else { continue }
        bytesNeededByVolume[volume] = needed - item.bytes
      }
      items.append(item)
    }
    return items
  }

  /// The volume holding the app's home directory, which library and staged cleanup
  /// measure free space on.
  static func homeVolume() -> URL? {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    return (try? home.resourceValues(forKeys: [.volumeURLKey]))?.volume
  }

  // MARK: Display

  /// A readable location for a folder path: iCloud Drive and On My iPhone by name,
  /// external drives by volume name, otherwise the last few folders.
  static func displayPath(_ path: String) -> String {
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
    func joined(_ head: String, _ tail: ArraySlice<String>) -> String {
      ([head] + tail).joined(separator: " › ")
    }
    if let index = components.firstIndex(of: "com~apple~CloudDocs") {
      return joined(String(localized: "iCloud Drive"), components[(index + 1)...])
    }
    if let index = components.firstIndex(of: "File Provider Storage") {
      return joined(String(localized: "On My iPhone"), components[(index + 1)...])
    }
    // External drives mount under LiveFiles/<provider>/<volume>/.
    if let index = components.firstIndex(of: "LiveFiles"), components.count > index + 2 {
      return joined(components[index + 2], components[(index + 3)...])
    }
    return components.suffix(3).joined(separator: " › ")
  }
}
