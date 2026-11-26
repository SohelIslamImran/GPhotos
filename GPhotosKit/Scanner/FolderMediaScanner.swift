import Foundation

/// A photo or video found in a backed-up folder, with the attributes its identity uses.
public struct LocalMediaFile: Sendable, Hashable {
  public var url: URL
  public var size: Int64
  public var created: Date
  public var modified: Date

  public init(url: URL, size: Int64, created: Date, modified: Date) {
    self.url = url
    self.size = size
    self.created = created
    self.modified = modified
  }
}

/// What one folder scan found.
public struct MediaScan: Sendable {
  public var files: [LocalMediaFile]
  /// Set when a file was skipped because it is still being written.
  public var deferredRecentWrites: Bool
  /// Directories holding a file left for later (still being written, or an iCloud
  /// placeholder), which a scan of only the changed directories must read again.
  public var unsettledDirectories: Set<String>

  public init(files: [LocalMediaFile] = [], deferredRecentWrites: Bool = false, unsettledDirectories: Set<String> = []) {
    self.files = files
    self.deferredRecentWrites = deferredRecentWrites
    self.unsettledDirectories = unsettledDirectories
  }
}

/// Folder scanning and queue planning shared by the Mac's watched folders and the
/// iPhone's backed-up Files folders. Pure and platform-neutral: callers hold any
/// security scope the reads need.
public enum FolderMediaScanner {
  /// A file whose attributes changed more recently than this is assumed to still be
  /// written (a camera import, an export, a copy in progress) and is picked up later.
  public static let writeSettleInterval: TimeInterval = 10

  /// What a scan should queue and the records to create first.
  public struct QueuePlan: Sendable {
    public var items: [UploadQueueItem]
    public var newRecords: [TransferRecord]

    public init(items: [UploadQueueItem], newRecords: [TransferRecord]) {
      self.items = items
      self.newRecords = newRecords
    }
  }

  /// Shares a walk between the Library and backup during one foreground activation.
  /// Each caller keeps its folder access while awaiting the same read.
  public actor ForegroundRead {
    private struct Key: Hashable {
      let root: URL
      let exclusions: FolderExclusions
    }

    private var scans: [Key: Task<(media: MediaScan, completedAt: ContinuousClock.Instant), Never>] = [:]

    public init() {}

    public func scan(_ root: URL, excluding exclusions: FolderExclusions) async -> MediaScan {
      let key = Key(root: root.standardizedFileURL, exclusions: exclusions)
      while let existing = scans[key] {
        let (media, completedAt) = await existing.value
        if ContinuousClock.now - completedAt < .seconds(5) { return media }
        // Only the first caller finding an expired result replaces the walk.
        if scans[key] == existing { scans[key] = nil }
      }
      let read = Task.detached(priority: .userInitiated) {
        let media = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true, excluding: exclusions)
        return (media: media, completedAt: ContinuousClock.now)
      }
      scans[key] = read
      return await read.value.media
    }
  }

  /// Every supported, regular, non-hidden file under `directory`, skipping package
  /// contents and symbolic links. With `skipsUnsettledFiles`, iCloud placeholders and
  /// files still being written are left for a later scan, together with any file that
  /// shares their name stem, so a Live Photo's still never goes up without its motion.
  /// Without `recursive`, only the directory's own files are read. Folders and files the
  /// user's rules leave out are passed over, a folder with everything in it.
  public static func collectMedia(
    in directory: URL, skipsUnsettledFiles: Bool, recursive: Bool = true, excluding exclusions: FolderExclusions = .none
  ) -> MediaScan {
    var scan = MediaScan()
    // Everything read below is prefetched with each directory entry, so no file costs
    // an extra stat.
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
      .attributeModificationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]
    let keySet = Set(keys)
    var deferredStems = Set<String>()
    let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: keys,
      options: recursive
        ? [.skipsHiddenFiles, .skipsPackageDescendants]
        : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
    )
    while let fileURL = enumerator?.nextObject() as? URL {
      if Task.isCancelled { break }
      if !exclusions.isEmpty,
        exclusions.excludes(name: fileURL.lastPathComponent) || exclusions.excludes(path: fileURL.path)
      {
        if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          enumerator?.skipDescendants()
        }
        continue
      }
      guard SupportedMediaFormats.isSupported(filename: fileURL.lastPathComponent) else { continue }
      let values = try? fileURL.resourceValues(forKeys: keySet)
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
      if skipsUnsettledFiles {
        // An iCloud placeholder would be downloaded just to be hashed and uploaded.
        if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
          scan.unsettledDirectories.insert(fileURL.deletingLastPathComponent().standardizedFileURL.path)
          continue
        }
        // The attribute date (ctime) moves on every write, unlike the content date,
        // which a copy preserves from the original. A date in the future (clock skew on
        // a network volume) would otherwise defer the file forever.
        if let changed = values?.attributeModificationDate {
          let age = Date().timeIntervalSince(changed)
          if age >= 0, age < writeSettleInterval {
            scan.deferredRecentWrites = true
            scan.unsettledDirectories.insert(fileURL.deletingLastPathComponent().standardizedFileURL.path)
            deferredStems.insert(fileURL.deletingPathExtension().path.lowercased())
            continue
          }
        }
      }
      guard SupportedMediaFormats.isSupported(fileURL: fileURL) else { continue }
      scan.files.append(metadata(for: fileURL, values: values))
    }
    // A camera import writes the still before the video. Queued alone, the still uploads
    // without its motion, and the pair's record then matches it and skips the video.
    if !deferredStems.isEmpty {
      scan.files.removeAll { deferredStems.contains($0.url.deletingPathExtension().path.lowercased()) }
    }
    return scan
  }

  public static func metadata(for url: URL) -> LocalMediaFile {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
    return metadata(for: url, values: values)
  }

  public static func metadata(for url: URL, values: URLResourceValues?) -> LocalMediaFile {
    let created = values?.creationDate ?? Date()
    return LocalMediaFile(
      url: url,
      size: Int64(values?.fileSize ?? 0),
      created: created,
      modified: values?.contentModificationDate ?? created
    )
  }

  /// Whether `fileURL` is the folder at path `ignored` or lies inside it. Compared
  /// case-insensitively and in one Unicode normalization form (a name typed as "é" and
  /// one stored decomposed are the same folder), and only on whole path components, so
  /// "/a/b" does not cover "/a/bc".
  public static func isInsideProtectedFolder(_ fileURL: URL, ignored: String) -> Bool {
    let path = comparablePath(fileURL.path)
    var root = comparablePath(ignored)
    if root.count > 1, root.hasSuffix("/") { root.removeLast() }
    return path == root || path.hasPrefix(root == "/" ? root : root + "/")
  }

  /// The form paths are compared in: precomposed, then case-folded.
  public static func comparablePath(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// Whether `url` is an iCloud item shared with, or by, other people. Removing a local
  /// copy of one deletes it for every participant, so silent cleanup never touches it.
  /// Fails closed: an item whose attributes can't be read counts as shared.
  public static func isSharedCloudItem(_ url: URL) -> Bool {
    // A URL keeps the values it read before; sharing may have changed since.
    var url = url
    url.removeAllCachedResourceValues()
    guard (try? url.checkResourceIsReachable()) == true,
      let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsSharedKey, .ubiquitousSharedItemCurrentUserRoleKey])
    else { return true }
    return values.ubiquitousItemIsShared == true || values.ubiquitousSharedItemCurrentUserRole != nil
  }

  /// A failed read is not proof of absence. Call while holding the source folder's scope.
  public static func fileIsConfirmedMissing(
    _ url: URL, in root: URL, includesCloudPlaceholder: Bool = false
  ) -> Bool {
    guard WatchedFolderPaths.isPath(url.standardizedFileURL.path, inside: root.standardizedFileURL.path),
      (try? root.checkResourceIsReachable()) == true,
      let names = try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    else { return false }
    guard names.contains(where: { $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) else {
      return true
    }
    guard includesCloudPlaceholder else { return false }
    let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
      .ubiquitousItemDownloadingStatus
    return status != nil && status != .current
  }

  /// Matches scanned files against the manifest and returns what still needs to go up.
  /// A file is the same version as a record only when its path, size and modification
  /// date all match; sent, deleted and in-flight versions are skipped.
  public static func planQueue(
    files: [LocalMediaFile],
    records currentRecords: [TransferRecord],
    accountEmail: String,
    pairLivePhotos: Bool,
    createAlbumsFromFolders: Bool,
    retriesFailedNow: Bool = false
  ) -> QueuePlan {
    var recordsByPath: [String: [TransferRecord]] = [:]
    for record in currentRecords {
      // A copy for another account carries the same source fields; matched here, its
      // record would be queued under this account's upload.
      guard let path = record.sourcePath,
        TransferRecord.accountEmail(fromScopedID: record.id).map({ $0 == accountEmail }) ?? true
      else { continue }
      // Standardized as lookups are: on iOS that drops the `/private` of a recorded path.
      recordsByPath[URL(fileURLWithPath: path).standardizedFileURL.path, default: []].append(record)
    }

    /// A file is the same version only when size *and* modification date match.
    /// Matching on size alone would silently skip an edited file that happens to
    /// keep its byte count, so a changed mtime always produces a new version. A Live
    /// Photo only reuses a pair record: a still uploaded alone never stands in for the
    /// still and its motion.
    func existingRecord(for url: URL, size: Int64, modified: Date, pair: LivePhotoExport? = nil) -> TransferRecord? {
      let path = url.standardizedFileURL.path
      let matching =
        recordsByPath[path]?.filter { record in
          if record.isTerminalSuccess && !record.sentAccountEmails.contains(accountEmail) { return false }
          guard (record.sourceFileSize ?? record.byteCount) == size,
            let recorded = record.sourceModifiedAt, abs(recorded.timeIntervalSince(modified)) < 1
          else { return false }
          guard let pair else { return true }
          guard let motionPath = record.pairedSourcePath,
            URL(fileURLWithPath: motionPath).standardizedFileURL == pair.videoURL.standardizedFileURL,
            record.pairedSourceFileSize == pair.videoSize, let motionDate = record.pairedSourceModifiedAt
          else { return false }
          return abs(motionDate.timeIntervalSince(pair.videoModificationDate)) < 1
        } ?? []
      return matching.first { $0.isTerminalSuccess || $0.status == .sending } ?? matching.first
    }

    var meta: [URL: LocalMediaFile] = [:]
    meta.reserveCapacity(files.count)
    for file in files {
      meta[file.url] = file
    }

    var settledPairFiles = Set<URL>()
    if pairLivePhotos {
      let byPath = Dictionary(files.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
      for record in currentRecords where record.isTerminalSuccess && record.sentAccountEmails.contains(accountEmail) {
        guard let photoPath = record.sourcePath, let motionPath = record.pairedSourcePath,
          let photo = byPath[URL(fileURLWithPath: photoPath).standardizedFileURL.path],
          let motion = byPath[URL(fileURLWithPath: motionPath).standardizedFileURL.path],
          (record.sourceFileSize ?? record.byteCount) == photo.size, record.pairedSourceFileSize == motion.size,
          let photoDate = record.sourceModifiedAt, abs(photoDate.timeIntervalSince(photo.modified)) < 1,
          let motionDate = record.pairedSourceModifiedAt, abs(motionDate.timeIntervalSince(motion.modified)) < 1
        else { continue }
        settledPairFiles.formUnion([photo.url, motion.url])
      }
    }
    let urls = files.map(\.url).filter { !settledPairFiles.contains($0) }
    let pairs: [LivePhotoExport]
    let singles: [URL]
    if pairLivePhotos {
      (pairs, singles) = LivePhotoManager.findLivePhotoPairs(in: urls, metadata: meta)
    } else {
      pairs = []
      singles = urls
    }
    var queueItems: [UploadQueueItem] = []
    var newRecords: [TransferRecord] = []

    func shouldSkip(_ record: TransferRecord?) -> Bool {
      guard let record else { return false }
      if !retriesFailedNow, !record.isDueForAutomaticRetry() { return true }
      return record.status == .sending || (record.isTerminalSuccess && record.sentAccountEmails.contains(accountEmail))
    }

    for pair in pairs {
      let existing = existingRecord(for: pair.photoURL, size: pair.photoSize, modified: pair.modificationDate, pair: pair)
      let version =
        "\(pair.photoSize)-\(pair.videoSize)-\(Int64(pair.modificationDate.timeIntervalSince1970 * 1000))-\(Int64(pair.videoModificationDate.timeIntervalSince1970 * 1000))"
      let id = existing?.id ?? TransferRecord.accountScopedID("\(pair.photoURL.path)|\(version)", accountEmail: accountEmail)
      if shouldSkip(existing) { continue }
      if existing == nil {
        newRecords.append(
          TransferRecord(
            id: id,
            filename: pair.photoFilename,
            mediaType: "Live Photo",
            creationDate: pair.creationDate,
            status: .pending,
            byteCount: pair.photoSize + pair.videoSize,
            sourcePath: pair.photoURL.path,
            pairedSourcePath: pair.videoURL.path,
            sourceFileSize: pair.photoSize,
            sourceModifiedAt: pair.modificationDate,
            pairedSourceFileSize: pair.videoSize,
            pairedSourceModifiedAt: pair.videoModificationDate
          ))
      }
      queueItems.append(
        UploadQueueItem(
          id: id,
          fileURL: pair.photoURL,
          filename: pair.photoFilename,
          livePhotoExport: pair,
          creationDate: pair.creationDate,
          albumNames: albumNames(for: pair.photoURL, createAlbumsFromFolders: createAlbumsFromFolders),
          precomputedSHA1: existing?.sourceSHA1 ?? existing?.sha1,
          precomputedSourceModifiedAt: pair.modificationDate,
          pairLivePhotos: pairLivePhotos,
          removeSourceOnSuccess: false
        ))
    }

    for fileURL in singles {
      let info = meta[fileURL]
      let size = info?.size ?? 0
      let modified = info?.modified ?? info?.created ?? Date()
      // A copied file has a new creation date but its original modification date.
      let creation = min(info?.created ?? modified, modified)
      let existing = existingRecord(for: fileURL, size: size, modified: modified)
      let version = "\(size)-\(Int64(modified.timeIntervalSince1970 * 1000))"
      let id = existing?.id ?? TransferRecord.accountScopedID("\(fileURL.path)|\(version)", accountEmail: accountEmail)
      if shouldSkip(existing) { continue }
      if existing == nil {
        newRecords.append(
          TransferRecord(
            id: id,
            filename: fileURL.lastPathComponent,
            mediaType: SupportedMediaFormats.isVideo(filename: fileURL.lastPathComponent) ? "Video" : "Photo",
            creationDate: creation,
            status: .pending,
            byteCount: size,
            sourcePath: fileURL.path,
            sourceFileSize: size,
            sourceModifiedAt: modified
          ))
      }
      queueItems.append(
        UploadQueueItem(
          id: id,
          fileURL: fileURL,
          filename: fileURL.lastPathComponent,
          fileSize: size,
          creationDate: creation,
          albumNames: albumNames(for: fileURL, createAlbumsFromFolders: createAlbumsFromFolders),
          precomputedSHA1: existing?.sourceSHA1 ?? existing?.sha1,
          precomputedSourceModifiedAt: modified,
          pairLivePhotos: pairLivePhotos,
          removeSourceOnSuccess: false
        ))
    }
    return QueuePlan(items: queueItems, newRecords: newRecords)
  }

  /// At most one album, named after the file's own folder.
  public static func albumNames(for fileURL: URL, createAlbumsFromFolders: Bool) -> [String] {
    guard createAlbumsFromFolders else { return [] }
    let name = fileURL.deletingLastPathComponent().lastPathComponent
    return name.isEmpty ? [] : [name]
  }
}
