import CryptoKit
import Darwin
import Foundation

public struct SharedUploadEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let fileName: String
  public let relativePath: String
  public let bytesTotal: Int64
  /// Base64-encoded SHA-1 of the staged file, used as the Google Photos content hash.
  public let sha1Base64: String
  public let addedAt: Date

  public init(
    id: UUID = UUID(),
    fileName: String,
    relativePath: String,
    bytesTotal: Int64,
    sha1Base64: String,
    addedAt: Date = .now
  ) {
    self.id = id
    self.fileName = fileName
    self.relativePath = Self.sanitizeRelativePath(relativePath)
    self.bytesTotal = bytesTotal
    self.sha1Base64 = sha1Base64
    self.addedAt = addedAt
  }

  /// The synthesized decoder would otherwise bypass `sanitizeRelativePath`, so a
  /// hand-edited queue file could reintroduce a traversing path.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.fileName = try container.decode(String.self, forKey: .fileName)
    self.relativePath = Self.sanitizeRelativePath(try container.decode(String.self, forKey: .relativePath))
    self.bytesTotal = try container.decode(Int64.self, forKey: .bytesTotal)
    // Decoded leniently on purpose: the file is written by another App Group process
    // and this is the only record of a queued upload. A missing hash yields an empty
    // string, which `ingestSharedQueueItems` treats as "untrusted" and re-hashes, rather
    // than failing the decode and discarding every other entry in the queue.
    self.sha1Base64 = try container.decodeIfPresent(String.self, forKey: .sha1Base64) ?? ""
    self.addedAt = try container.decode(Date.self, forKey: .addedAt)
  }
  private static func sanitizeRelativePath(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let safeComponents = components.compactMap { component -> String? in
      guard !component.isEmpty, component != ".", component != ".." else { return nil }
      let sanitized = String(
        component.unicodeScalars.filter { scalar in
          !CharacterSet.controlCharacters.contains(scalar)
        })
      return sanitized.isEmpty ? nil : sanitized
    }
    let joined = safeComponents.joined(separator: "/")
    return joined.isEmpty ? "file" : joined
  }
}

public enum SharedQueueBridge {
  private static var containerURL: URL {
    AppGroupConstants.storageDirectory()
  }

  public static var incomingDirectory: URL {
    containerURL.appendingPathComponent(AppGroupConstants.incomingFolderName, isDirectory: true)
  }

  private static var queueURL: URL {
    containerURL.appendingPathComponent(AppGroupConstants.sharedQueueFileName)
  }

  public static func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
  }

  private static func withQueueLock<T>(_ body: () throws -> T) throws -> T {
    let lockURL = queueURL.appendingPathExtension("lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { close(descriptor) }

    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw CocoaError(.fileWriteUnknown)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  private static func loadEntriesUnlocked() throws -> [SharedUploadEntry] {
    try readQueue(at: queueURL)
  }

  /// A queue file that no longer decodes is moved aside as `.unreadable` and treated as
  /// empty; otherwise every later append would fail and sharing would stay broken. Read
  /// errors still throw, since they may be transient and the file may be fine.
  static func readQueue(at url: URL) throws -> [SharedUploadEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode([SharedUploadEntry].self, from: data)
    } catch is DecodingError {
      AppSettingsStore.quarantine(url)
      return []
    }
  }

  private static func saveEntriesUnlocked(_ entries: [SharedUploadEntry]) throws {
    let data = try JSONEncoder().encode(entries)
    try data.write(to: queueURL, options: .atomic)
  }

  public static func loadEntries() -> [SharedUploadEntry] {
    (try? withQueueLock { try loadEntriesUnlocked() }) ?? []
  }

  public static func saveEntries(_ entries: [SharedUploadEntry]) throws {
    try withQueueLock {
      try saveEntriesUnlocked(entries)
    }
  }

  public static func appendEntries(_ newEntries: [SharedUploadEntry]) throws {
    guard !newEntries.isEmpty else { return }
    try withQueueLock {
      var entries = try loadEntriesUnlocked()
      entries.append(contentsOf: newEntries)
      try saveEntriesUnlocked(entries)
    }
    postItemsAddedNotification()
  }

  public static func appendEntry(_ entry: SharedUploadEntry) throws {
    try appendEntries([entry])
  }

  public static func removeEntries(ids: Set<UUID>) throws {
    guard !ids.isEmpty else { return }
    try withQueueLock {
      var entries = try loadEntriesUnlocked()
      entries.removeAll { ids.contains($0.id) }
      try saveEntriesUnlocked(entries)
    }
  }

  public static func removeOrphanedIncomingFiles(
    olderThan cutoff: Date = .now.addingTimeInterval(-86_400),
    protectedPaths: Set<String> = []
  ) {
    try? withQueueLock {
      guard let entries = try? loadEntriesUnlocked() else { return }
      let referencedPaths = Set(entries.map(\.relativePath)).union(protectedPaths)
      let root = incomingDirectory.standardizedFileURL
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles]
        )
      else { return }
      let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
      for file in files {
        let path = file.standardizedFileURL.path
        let relativePath = String(path.dropFirst(rootPath.count))
        guard path.hasPrefix(rootPath),
          !referencedPaths.contains(relativePath),
          !protectedPaths.contains(path)
        else { continue }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let modified = values.contentModificationDate,
          modified < cutoff
        else { continue }
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  public static func fileURL(for entry: SharedUploadEntry) -> URL? {
    let path = entry.relativePath
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      return nil
    }

    let root = incomingDirectory.standardizedFileURL
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path.hasPrefix(rootPrefix) else { return nil }

    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }

    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
    guard resolvedCandidate.path.hasPrefix(resolvedRootPrefix) else { return nil }
    return candidate
  }

  public static func sha1Fingerprint(forFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while true {
      let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).base64EncodedString()
  }

  public static func postItemsAddedNotification() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(
      center,
      CFNotificationName(AppGroupConstants.shareItemsAddedNotification as CFString),
      nil,
      nil,
      true
    )
  }

  public static func observeItemsAdded(handler: @escaping @Sendable () -> Void) -> UnsafeMutableRawPointer {
    let token = ObserverToken(handler: handler)
    let pointer = Unmanaged.passRetained(token).toOpaque()
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(
      center,
      pointer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        let token = Unmanaged<ObserverToken>.fromOpaque(observer).takeUnretainedValue()
        token.handler()
      },
      AppGroupConstants.shareItemsAddedNotification as CFString,
      nil,
      .deliverImmediately
    )
    return pointer
  }

  public static func removeObserver(_ pointer: UnsafeMutableRawPointer) {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterRemoveObserver(center, pointer, nil, nil)
    Unmanaged<ObserverToken>.fromOpaque(pointer).release()
  }
}

private final class ObserverToken: @unchecked Sendable {
  let handler: @Sendable () -> Void
  init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
}
