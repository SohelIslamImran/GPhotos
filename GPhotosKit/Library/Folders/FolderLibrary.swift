import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os

/// A backed-up folder, as the Library reads it: the bookmark that reaches it (none for a
/// folder the app can read directly) and where it was when it was chosen.
public struct LibraryFolder: Sendable, Hashable {
  public let id: String
  public let path: String
  public let bookmarkData: Data?
  /// What the backup leaves out of it, left out of the Library too.
  public let exclusions: FolderExclusions

  public init(id: String, path: String, bookmarkData: Data?, exclusions: FolderExclusions = .none) {
    self.id = id
    self.path = path
    self.bookmarkData = bookmarkData
    self.exclusions = exclusions
  }
}

/// A photo or video in a backed-up folder. A Live Photo is its still; the motion file
/// beside it isn't shown on its own.
public struct FolderItemInfo: Sendable, Hashable {
  public static let idPrefix = "f:"

  public let path: String
  /// When it was taken, as far as the file says: a date in its name, else the earlier of
  /// its creation and modification dates (a copy keeps the original's modification date).
  public let date: Date
  public let size: Int64
  public let isVideo: Bool
  public let isLivePhoto: Bool
  var modifiedAt: Date?
  var motion: FileVersion?

  struct FileVersion: Codable, Hashable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Date
  }

  /// A video's length, for its cell.
  public var duration: TimeInterval?

  public init(
    path: String, date: Date, size: Int64, isVideo: Bool, isLivePhoto: Bool = false, duration: TimeInterval? = nil
  ) {
    self.path = path
    self.date = date
    self.size = size
    self.isVideo = isVideo
    self.isLivePhoto = isLivePhoto
    self.duration = duration
  }

  /// The id grids and the thumbnail cache know the file by.
  public var id: String { Self.idPrefix + path }
  var thumbnailIdentity: ThumbnailIdentity {
    var hasher = Hasher()
    hasher.combine(modifiedAt)
    hasher.combine(size)
    return ThumbnailIdentity(id: id, version: Int64(hasher.finalize()))
  }

  public var url: URL { URL(fileURLWithPath: path) }
  public var fileName: String { (path as NSString).lastPathComponent }
  public var folderName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }

  static func path(fromID id: String) -> String? {
    id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : nil
  }
}

/// Reads the backed-up folders for the Library. Each folder's access is taken once when
/// it's added and given back when it's removed, so thumbnails, the viewer and sharing can
/// read its files at any time in between.
public final class FolderLibrary: Sendable {
  public static let shared = FolderLibrary()

  private struct Access: Sendable {
    let folder: LibraryFolder
    /// Where the folder is now; nil when its bookmark no longer resolves.
    let url: URL?
    let started: Bool
  }

  private let accesses = OSAllocatedUnfairLock<[String: Access]>(initialState: [:])

  /// Takes access to folders that are new and gives it back for ones no longer listed.
  public func setFolders(_ folders: [LibraryFolder]) {
    let wanted = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let (removed, added) = accesses.withLock { current -> ([Access], [LibraryFolder]) in
      let removed = current.values.filter { wanted[$0.folder.id] != $0.folder }
      for access in removed { current[access.folder.id] = nil }
      return (removed, wanted.values.filter { current[$0.id] == nil })
    }
    for access in removed where access.started { access.url?.stopAccessingSecurityScopedResource() }
    let opened = added.map(Self.open)
    let extra = accesses.withLock { current -> [Access] in
      var extra: [Access] = []
      for access in opened {
        // Another call took this folder meanwhile: keep that one, give this one back.
        if current[access.folder.id] != nil { extra.append(access) } else { current[access.folder.id] = access }
      }
      return extra
    }
    for access in extra where access.started { access.url?.stopAccessingSecurityScopedResource() }
  }

  private static func open(_ folder: LibraryFolder) -> Access {
    guard let bookmark = folder.bookmarkData else {
      return Access(folder: folder, url: URL(fileURLWithPath: folder.path), started: false)
    }
    var isStale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
    else { return Access(folder: folder, url: nil, started: false) }
    return Access(folder: folder, url: url, started: url.startAccessingSecurityScopedResource())
  }

  func resolvedPaths(excluding disabledIDs: Set<String>) -> [String] {
    accesses.withLock { current in
      current.values.compactMap { access in
        guard !disabledIDs.contains(access.folder.id), let url = access.url else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
      }
    }
  }

  /// Every photo and video in the folders, newest first. Files still being written and
  /// iCloud placeholders wait for a later read, as the backup does.
  public func scan(
    using foregroundRead: FolderMediaScanner.ForegroundRead? = nil,
    pairLivePhotos: Bool = AppSettingsStore.load().pairLivePhotos,
    records: [String: [TransferRecord]] = [:], accountEmail: String? = nil
  ) async -> [FolderItemInfo] {
    let roots = accesses.withLock { $0.values.compactMap { access in access.url.map { ($0, access.folder.exclusions) } } }
    var seen = Set<String>()
    var items: [FolderItemInfo] = []
    for (root, exclusions) in roots {
      guard !Task.isCancelled else { break }
      let scan =
        if let foregroundRead { await foregroundRead.scan(root, excluding: exclusions) } else {
          FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true, excluding: exclusions)
        }
      let files = scan.files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
      items.append(contentsOf: Self.items(from: files, pairLivePhotos: pairLivePhotos, records: records, accountEmail: accountEmail))
    }
    return items.sorted(by: Self.newerFirst)
  }

  /// Each video's length, read from its file's header, by path.
  public static func durations(of videos: [FolderItemInfo]) async -> [String: TimeInterval] {
    var durations: [String: TimeInterval] = [:]
    for video in videos where video.isVideo {
      if Task.isCancelled { break }
      let seconds = try? await AVURLAsset(url: video.url).load(.duration).seconds
      if let seconds, seconds.isFinite { durations[video.path] = seconds }
    }
    return durations
  }

  static func items(
    from files: [LocalMediaFile], pairLivePhotos: Bool = true,
    records: [String: [TransferRecord]] = [:], accountEmail: String? = nil
  ) -> [FolderItemInfo] {
    let metadata = Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    let byPath = Dictionary(
      files.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
    var motions: [URL: FolderItemInfo.FileVersion] = [:]
    var consumed = Set<URL>()
    if pairLivePhotos {
      if let accountEmail {
        // The backup scanner also reserves unchanged pairs it already sent.
        for file in files {
          let path = file.url.standardizedFileURL.path
          for record in records[path] ?? [] where record.isTerminalSuccess && record.sentAccountEmails.contains(accountEmail) {
            guard let motionPath = record.pairedSourcePath.map(TransferManifestStore.standardizedPath),
              let motion = byPath[motionPath], !consumed.contains(motion.url), motions[file.url] == nil
            else { continue }
            let version = FolderItemInfo.FileVersion(path: motionPath, size: motion.size, modifiedAt: motion.modified)
            guard UnifiedLibraryModel.matchesFile(record, size: file.size, modified: file.modified, motion: version, isLivePhoto: true)
            else { continue }
            motions[file.url] = version
            consumed.insert(motion.url)
          }
        }
      }
      let urls = files.map(\.url).filter { motions[$0] == nil && !consumed.contains($0) }
      for pair in LivePhotoManager.findLivePhotoPairs(in: urls, metadata: metadata).pairs {
        motions[pair.photoURL] = .init(
          path: pair.videoURL.standardizedFileURL.path, size: pair.videoSize, modifiedAt: pair.videoModificationDate)
        consumed.insert(pair.videoURL)
      }
    }
    return files.filter { !consumed.contains($0.url) }.map { file in
      let url = file.url.standardizedFileURL
      let motion = motions[file.url]
      let date = FilenameDateParser.parseDate(from: url.lastPathComponent) ?? min(file.created, file.modified)
      var item = FolderItemInfo(
        path: url.path, date: date, size: file.size,
        isVideo: SupportedMediaFormats.isVideo(filename: url.lastPathComponent), isLivePhoto: motion != nil)
      item.modifiedAt = file.modified
      item.motion = motion
      return item
    }.sorted(by: newerFirst)
  }

  private static func newerFirst(_ lhs: FolderItemInfo, _ rhs: FolderItemInfo) -> Bool {
    lhs.date == rhs.date ? lhs.path < rhs.path : lhs.date > rhs.date
  }

  public let thumbnails = FolderThumbnailSource()

  // MARK: Last read

  /// The last read of these folders, as it was saved: the Library draws it at launch
  /// while the folders are read again (a large folder in iCloud Drive takes seconds).
  /// Nil when there's none, or it was of other folders.
  public static func cachedItems(for folders: [LibraryFolder], pairLivePhotos: Bool = true) -> [FolderItemInfo]? {
    guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
      cache.folders == cacheKey(folders, pairLivePhotos: pairLivePhotos)
    else { return nil }
    return cache.items.map {
      var item = FolderItemInfo(
        path: $0.path, date: $0.date, size: $0.size, isVideo: $0.isVideo, isLivePhoto: $0.isLivePhoto,
        duration: $0.duration)
      item.modifiedAt = $0.modifiedAt
      item.motion = $0.motion
      return item
    }.sorted(by: newerFirst)
  }

  /// Keeps this read of the folders for the next launch.
  public static func saveCache(_ items: [FolderItemInfo], for folders: [LibraryFolder], pairLivePhotos: Bool = true) {
    let cache = Cache(
      folders: cacheKey(folders, pairLivePhotos: pairLivePhotos),
      items: items.map {
        Cache.Item(
          path: $0.path, date: $0.date, size: $0.size, isVideo: $0.isVideo, isLivePhoto: $0.isLivePhoto,
          duration: $0.duration, modifiedAt: $0.modifiedAt, motion: $0.motion)
      })
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }

  private struct Cache: Codable {
    struct Item: Codable {
      let path: String
      let date: Date
      let size: Int64
      let isVideo: Bool
      let isLivePhoto: Bool
      let duration: TimeInterval?
      let modifiedAt: Date?
      let motion: FolderItemInfo.FileVersion?
    }
    let folders: [String]
    let items: [Item]
  }

  private static func cacheKey(_ folders: [LibraryFolder], pairLivePhotos: Bool) -> [String] {
    [pairLivePhotos ? "paired-by-identifier" : "singles"]
      + folders.map { $0.id + "|" + $0.path + "|" + $0.exclusions.key }.sorted()
  }

  private static var cacheURL: URL {
    var name = "FolderLibrary"
    #if DEBUG
      // Each review hook shows its own library.
      if let screen = UserDefaults.standard.string(forKey: "UIScreen") { name += "-" + screen }
    #endif
    return URL.cachesDirectory.appending(path: name).appending(path: "items.json")
  }
}

/// Thumbnails and screen-sized images of folder files, read from disk: the image's own
/// embedded preview or a decode at the size asked for, a video's frame near its start.
/// The grid's memory cache keeps them; nothing is written to disk.
public final class FolderThumbnailSource: ThumbnailSource, Sendable {
  private let limiter = DownloadLimiter(slots: 4)
  private let displayLimiter = DownloadLimiter(slots: 2)

  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    requestImage(id: id, pixelSize: pixelSize, quality: quality, alias: nil, onUnavailable: onUnavailable, deliver: deliver)
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, alias: FolderItemInfo?,
    onUnavailable: @escaping @Sendable () -> Void, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let path = FolderItemInfo.path(fromID: id) else {
      onUnavailable()
      return .none
    }
    let side = max(pixelSize.width, pixelSize.height, 64)
    let limiter = quality == .display ? displayLimiter : limiter
    let task = Task.detached(priority: .userInitiated) {
      guard await limiter.acquire() else { return }
      defer { limiter.release() }
      // A cell scrolled away while waiting for a slot.
      guard !Task.isCancelled else { return }
      if let alias, !LocalFirstThumbnailSource.fileAliasIsCurrent(alias) {
        onUnavailable()
        return
      }
      let url = URL(fileURLWithPath: path)
      let image =
        SupportedMediaFormats.isVideo(filename: url.lastPathComponent)
        ? await Self.videoFrame(url, side: side) : Self.image(url, side: side)
      guard !Task.isCancelled else { return }
      if let image { deliver(image, true) } else { onUnavailable() }
    }
    return ImageRequestToken { task.cancel() }
  }

  static func image(_ url: URL, side: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    func thumbnail(fromFullImage: Bool) -> CGImage? {
      var options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(side.rounded(.up)),
      ]
      if fromFullImage { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let longest = max(
      properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? side,
      properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? side)
    // A preview stored in the file (most camera photos and RAWs have one) saves decoding
    // the whole image, when it's big enough.
    if let preview = thumbnail(fromFullImage: false),
      CGFloat(max(preview.width, preview.height)) >= min(side, longest) * 0.9
    {
      return preview
    }
    return thumbnail(fromFullImage: true)
  }

  static func videoFrame(_ url: URL, side: CGFloat) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: side, height: side)
    return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
  }
}
