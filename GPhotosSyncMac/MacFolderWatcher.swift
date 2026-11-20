import CoreServices
import Foundation
import GPhotosKit

public struct MacWatchedFolder: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var url: URL
  public var title: String
  public var isEnabled: Bool
  public var bookmarkData: Data?

  public init(url: URL, title: String? = nil, isEnabled: Bool = true, bookmarkData: Data? = nil) {
    self.id = url.standardizedFileURL.path
    self.url = url
    self.title = title ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    self.isEnabled = isEnabled
    self.bookmarkData = bookmarkData
  }

  /// Resolves the security-scoped bookmark. `nil` when there is no bookmark or it no
  /// longer resolves.
  public func resolveBookmark() -> (url: URL, isStale: Bool)? {
    guard let bookmarkData else { return nil }
    var isStale = false
    guard
      let resolved = try? URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else { return nil }
    return (resolved, isStale)
  }

  /// Resolves the bookmark once and holds access until `endAccess(_:)`. A stale
  /// bookmark is recreated while access is held and returned as `refreshedBookmark`
  /// for the caller to persist; it cannot be recreated once access has lapsed.
  public func beginAccess() -> (url: URL, started: Bool, isResolved: Bool, refreshedBookmark: Data?) {
    guard bookmarkData != nil else { return (url, false, true, nil) }
    guard let resolved = resolveBookmark() else { return (url, false, false, nil) }
    let started = resolved.url.startAccessingSecurityScopedResource()
    let refreshed =
      resolved.isStale && started
      ? try? resolved.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      : nil
    return (resolved.url, started, true, refreshed)
  }

  public func endAccess(_ target: URL) {
    target.stopAccessingSecurityScopedResource()
  }

  /// Whether `url` is this watched folder or lives inside it. Used to pick the folder
  /// whose security scope must be held to reach a particular file.
  public func contains(_ url: URL) -> Bool {
    let root = (resolvedURL ?? self.url).standardizedFileURL
    return WatchedFolderPaths.isPath(url.standardizedFileURL.path, inside: root.path)
  }

  public var resolvedURL: URL? {
    guard bookmarkData != nil else { return url }
    return resolveBookmark()?.url
  }

  public var hasValidBookmark: Bool {
    bookmarkData == nil || resolveBookmark() != nil
  }
}

public final class MacFolderWatcher: @unchecked Sendable {
  private let folderURL: URL
  /// FSEvents reports canonical paths, so filtering compares against the real path.
  private let rootPath: String
  private let onRootChanged: @Sendable () -> Void
  private let onChange: @Sendable (FolderChanges) -> Void
  private let queue = DispatchQueue(label: "org.gphotosapp.gphotos.folder-events", qos: .utility)
  private let stateLock = NSLock()
  private var stream: FSEventStreamRef?
  private var debounceTask: Task<Void, Never>?
  private var generation = 0
  /// Changes seen since the last hand-off, gathered across the debounce.
  private var pendingChanges = FolderChanges()
  private let isSecurityScoped: Bool
  private var didStartAccess = false
  private var isRunning = false
  private var didFailToStart = false

  public var isActive: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isRunning && stream != nil
  }

  /// Set when the folder could be read but FSEvents refused to start, which leaves the
  /// folder readable yet never triggering another scan. Silent otherwise.
  public var failedToStart: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return didFailToStart
  }

  /// `onRootChanged` fires when the watched folder itself (or a parent) is moved,
  /// renamed or deleted, which leaves this stream watching a path that no longer
  /// holds the folder.
  public init(
    folderURL: URL,
    isSecurityScoped: Bool = false,
    onRootChanged: @escaping @Sendable () -> Void = {},
    onChange: @escaping @Sendable (FolderChanges) -> Void
  ) {
    self.folderURL = folderURL
    self.rootPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
    self.isSecurityScoped = isSecurityScoped
    self.onRootChanged = onRootChanged
    self.onChange = onChange
  }

  public func start() {
    stop()
    stateLock.lock()
    didFailToStart = false
    stateLock.unlock()
    if isSecurityScoped {
      let started = folderURL.startAccessingSecurityScopedResource()
      stateLock.lock()
      didStartAccess = started
      stateLock.unlock()
    }

    // FSEvents gives no ordering guarantee between a callback already in flight and
    // FSEventStreamInvalidate, so the context holds a strong reference for the
    // stream's lifetime. `stop()` breaks the cycle by invalidating the stream.
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: { pointer in
        pointer.map { UnsafeRawPointer(Unmanaged<MacFolderWatcher>.fromOpaque($0).retain().toOpaque()) }
      },
      release: { pointer in
        if let pointer { Unmanaged<MacFolderWatcher>.fromOpaque(pointer).release() }
      },
      copyDescription: nil
    )
    // Per-file events are needed to tell a new photo from noise such as hidden files,
    // package internals or the app's own tombstones. Without NoDefer and with a long
    // latency, bursts (a camera import, a library rebuild) arrive as one callback.
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
    let paths = [folderURL.path] as CFArray
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        gphotosFolderEventCallback,
        &context,
        paths,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        3.0,
        flags
      )
    else {
      markFailedToStart()
      return
    }

    FSEventStreamSetDispatchQueue(stream, queue)
    // A stream can be created for a path we cannot read and still fail to start, so the
    // return value decides whether this watcher counts as live.
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      markFailedToStart()
      return
    }

    stateLock.lock()
    isRunning = true
    self.stream = stream
    stateLock.unlock()
  }

  public func stop() {
    stateLock.lock()
    generation &+= 1
    isRunning = false
    debounceTask?.cancel()
    debounceTask = nil
    pendingChanges = FolderChanges()
    let currentStream = stream
    stream = nil
    stateLock.unlock()

    if let currentStream {
      FSEventStreamStop(currentStream)
      FSEventStreamInvalidate(currentStream)
      FSEventStreamRelease(currentStream)
    }
    endAccess()
  }

  private func markFailedToStart() {
    endAccess()
    stateLock.lock()
    isRunning = false
    didFailToStart = true
    stateLock.unlock()
  }

  fileprivate func eventsReceived(paths: [String], flags: [FSEventStreamEventFlags]) {
    let rootChangedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
    if flags.contains(where: { $0 & rootChangedFlag != 0 }), isActive {
      onRootChanged()
    }
    let rescanFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped
    )
    // Extended attributes alone (Preview's last-used date, Finder tags) never change what
    // a scan finds. An inode change can (a file unhidden or made readable, or given a new
    // modification date), and costs a read of only its directory.
    let contentFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemInodeMetaMod
    )
    let isFileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    let isDirectoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    var changes = FolderChanges()
    for (path, flag) in zip(paths, flags) {
      if flag & rescanFlags != 0 {
        changes.markFull()
        break
      }
      // A path that is gone (a removal, a rename away, cleanup moving a file to its
      // tombstone) holds nothing to upload, so it does not cost a rescan.
      guard flag & contentFlags != 0,
        WatchedFolderPaths.isRelevantChange(path: path, root: rootPath, isFile: flag & isFileFlag != 0),
        FileManager.default.fileExists(atPath: path)
      else { continue }
      if !WatchedFolderPaths.isPath(path, inside: rootPath),
        !WatchedFolderPaths.isPath(path, inside: WatchedFolderPaths.privatePrefixed(rootPath))
      {
        changes.markFull()
        break
      }
      // A directory created or moved in arrives as one event for the directory alone,
      // so everything below it is read; a file needs only its own directory, which
      // also holds its Live Photo partner.
      if flag & isDirectoryFlag != 0 {
        // The folder's own attributes say nothing about what lies below it.
        let isOnlyInodeChange = flag & contentFlags == FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod)
        if isOnlyInodeChange, WatchedFolderPaths.isPath(rootPath, inside: path) {
          changes.insertDirectory(path)
        } else {
          changes.insertTree(path)
        }
      } else {
        changes.insertDirectory((path as NSString).deletingLastPathComponent)
      }
    }
    guard !changes.isEmpty else { return }

    stateLock.lock()
    generation &+= 1
    let currentGeneration = generation
    pendingChanges.formUnion(changes)
    stateLock.unlock()

    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled,
        let self,
        let changes = self.takeChanges(ifGeneration: currentGeneration)
      else { return }
      self.onChange(changes)
    }
    stateLock.lock()
    debounceTask?.cancel()
    debounceTask = task
    stateLock.unlock()
  }

  private func takeChanges(ifGeneration value: Int) -> FolderChanges? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard isRunning, generation == value else { return nil }
    let changes = pendingChanges
    pendingChanges = FolderChanges()
    return changes
  }

  private func endAccess() {
    stateLock.lock()
    let shouldStop = didStartAccess
    didStartAccess = false
    stateLock.unlock()
    if shouldStop {
      folderURL.stopAccessingSecurityScopedResource()
    }
  }

  deinit {
    stop()
  }
}

private func gphotosFolderEventCallback(
  _: ConstFSEventStreamRef,
  info: UnsafeMutableRawPointer?,
  eventCount: Int,
  eventPaths: UnsafeMutableRawPointer,
  eventFlags: UnsafePointer<FSEventStreamEventFlags>,
  _: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watcher = Unmanaged<MacFolderWatcher>.fromOpaque(info).takeUnretainedValue()
  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
  let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
  watcher.eventsReceived(paths: paths, flags: flags)
}
