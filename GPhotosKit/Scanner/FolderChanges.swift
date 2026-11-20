import Foundation

/// Where watched folders changed, so a pass reads only those directories instead of
/// every file under every folder. `isFull` asks for everything: events the system
/// dropped, a change it can't place, or more directories than are worth tracking.
public struct FolderChanges: Sendable, Equatable {
  /// Directories whose own entries changed, read one level deep.
  public private(set) var directories: Set<String> = []
  /// Directories that appeared whole (created, or moved or renamed in), read with
  /// everything below them.
  public private(set) var trees: Set<String> = []
  public private(set) var isFull = false

  /// Past this many directories, reading everything costs about the same.
  public static let maxDirectories = 256

  public static let full: FolderChanges = {
    var changes = FolderChanges()
    changes.markFull()
    return changes
  }()

  public init() {}

  public var isEmpty: Bool { !isFull && directories.isEmpty && trees.isEmpty }

  public mutating func insertDirectory(_ path: String) {
    guard !isFull else { return }
    directories.insert(path)
    collapseIfLarge()
  }

  public mutating func insertTree(_ path: String) {
    guard !isFull else { return }
    trees.insert(path)
    collapseIfLarge()
  }

  public mutating func formUnion(_ other: FolderChanges) {
    guard !isFull else { return }
    guard !other.isFull else {
      markFull()
      return
    }
    directories.formUnion(other.directories)
    trees.formUnion(other.trees)
    collapseIfLarge()
  }

  public mutating func markFull() {
    isFull = true
    directories = []
    trees = []
  }

  private mutating func collapseIfLarge() {
    if directories.count + trees.count > Self.maxDirectories { markFull() }
  }
}

extension FolderMediaScanner {
  /// What `collectMedia(in: root)` finds in the changed directories, and only there.
  /// Change paths may use the canonical spelling FSEvents reports (`/private/var` for
  /// `/var`); found files keep `root`'s own spelling, the one the manifest records.
  /// Paths outside `root` are ignored, and a directory a full scan would not enter
  /// (hidden, a package, a symbolic link) is skipped as it would be there.
  public static func collectMedia(
    in root: URL, changes: FolderChanges, skipsUnsettledFiles: Bool, excluding exclusions: FolderExclusions = .none
  ) -> MediaScan {
    if changes.isFull { return collectMedia(in: root, skipsUnsettledFiles: skipsUnsettledFiles, excluding: exclusions) }
    let rootPath = root.standardizedFileURL.path
    let resolvedPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let bases = [rootPath, resolvedPath, WatchedFolderPaths.privatePrefixed(resolvedPath)].map(pathComponents)

    func relativeComponents(_ path: String) -> [String]? {
      let components = pathComponents(path)
      for base in bases where hasPrefix(components, base, caseInsensitive: true) {
        return Array(components.dropFirst(base.count))
      }
      return nil
    }

    var trees: [[String]] = []
    for path in changes.trees {
      guard let relative = relativeComponents(path) else { continue }
      if relative.isEmpty { return collectMedia(in: root, skipsUnsettledFiles: skipsUnsettledFiles, excluding: exclusions) }
      trees.append(relative)
    }
    // A tree inside another is already read with it.
    var outerTrees: [[String]] = []
    for tree in trees.sorted(by: { $0.count < $1.count }) where !outerTrees.contains(where: { hasPrefix(tree, $0) }) {
      outerTrees.append(tree)
    }
    var directories: [[String]] = []
    var seenDirectories = Set<String>()
    for path in changes.directories {
      guard let relative = relativeComponents(path),
        !outerTrees.contains(where: { hasPrefix(relative, $0) }),
        seenDirectories.insert(relative.joined(separator: "/")).inserted
      else { continue }
      directories.append(relative)
    }

    var scan = MediaScan()
    var seenFiles = Set<String>()
    func add(_ part: MediaScan) {
      for file in part.files where seenFiles.insert(file.url.path).inserted {
        scan.files.append(file)
      }
      scan.deferredRecentWrites = scan.deferredRecentWrites || part.deferredRecentWrites
      scan.unsettledDirectories.formUnion(part.unsettledDirectories)
    }
    for (relative, recursive) in outerTrees.map({ ($0, true) }) + directories.map({ ($0, false) }) {
      if Task.isCancelled { break }
      guard let directory = scannableDirectory(relative, in: root),
        !exclusions.excludes(directory, below: root)
      else { continue }
      add(
        collectMedia(
          in: directory, skipsUnsettledFiles: skipsUnsettledFiles, recursive: recursive, excluding: exclusions))
    }
    return scan
  }

  /// The directory at `relative` below `root`, if a full scan of `root` would read it:
  /// every step down must be a real, visible directory and not a package.
  private static func scannableDirectory(_ relative: [String], in root: URL) -> URL? {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
    var url = root
    for name in relative {
      guard !name.hasPrefix(".") else { return nil }
      url = url.appendingPathComponent(name, isDirectory: true)
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        values.isPackage != true,
        values.isHidden != true
      else { return nil }
    }
    return url
  }

  private static func pathComponents(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }

  /// The folder is matched case-insensitively, as `WatchedFolderPaths.isPath` does.
  /// Below it names are compared exactly: on a case-sensitive volume `Raw` and `raw` are
  /// two directories, and reading one twice costs nothing but time.
  private static func hasPrefix(_ components: [String], _ prefix: [String], caseInsensitive: Bool = false) -> Bool {
    components.count >= prefix.count
      && zip(components, prefix).allSatisfy {
        caseInsensitive ? $0.caseInsensitiveCompare($1) == .orderedSame : $0 == $1
      }
  }
}
