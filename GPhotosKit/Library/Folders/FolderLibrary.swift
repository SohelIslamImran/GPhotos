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
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
    else { return Access(folder: folder, url: nil, started: false) }
    return Access(folder: folder, url: url, started: url.startAccessingSecurityScopedResource())
  }

  /// Every photo and video in the folders, newest first. Files still being written and
  /// iCloud placeholders wait for a later read, as the backup does. Only file attributes
  /// are read, so it's quick; video lengths come separately from `durations(of:)`.
  public func scan() -> [FolderItemInfo] {
    let roots = accesses.withLock { $0.values.compactMap { access in access.url.map { ($0, access.folder.exclusions) } } }
    var seen = Set<String>()
    var files: [LocalMediaFile] = []
    for (root, exclusions) in roots {
      for file in FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true, excluding: exclusions).files
      where seen.insert(file.url.standardizedFileURL.path).inserted {
        files.append(file)
      }
    }
    return Self.items(from: files)
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

  /// A still and a video sharing a name in one folder are a Live Photo: the still stands
  /// for both.
  static func items(from files: [LocalMediaFile]) -> [FolderItemInfo] {
    var stills = Set<String>()
    for file in files where !SupportedMediaFormats.isVideo(filename: file.url.lastPathComponent) {
      stills.insert(file.url.deletingPathExtension().standardizedFileURL.path.lowercased())
    }
    var motions = Set<String>()
    var items: [FolderItemInfo] = []
    items.reserveCapacity(files.count)
    for file in files {
      let url = file.url.standardizedFileURL
      let stem = url.deletingPathExtension().path.lowercased()
      let isVideo = SupportedMediaFormats.isVideo(filename: url.lastPathComponent)
      if isVideo, url.pathExtension.lowercased() == "mov", stills.contains(stem) {
        motions.insert(stem)
        continue
      }
      let date =
        FilenameDateParser.parseDate(from: url.lastPathComponent) ?? min(file.created, file.modified)
      items.append(FolderItemInfo(path: url.path, date: date, size: file.size, isVideo: isVideo))
    }
    if !motions.isEmpty {
      items = items.map { item in
        guard !item.isVideo, motions.contains((item.path as NSString).deletingPathExtension.lowercased()) else { return item }
        return FolderItemInfo(path: item.path, date: item.date, size: item.size, isVideo: false, isLivePhoto: true)
      }
    }
    items.sort { $0.date > $1.date }
    return items
  }

  public let thumbnails = FolderThumbnailSource()

  // MARK: Last read

  /// The last read of these folders, as it was saved: the Library draws it at launch
  /// while the folders are read again (a large folder in iCloud Drive takes seconds).
  /// Nil when there's none, or it was of other folders.
  public static func cachedItems(for folders: [LibraryFolder]) -> [FolderItemInfo]? {
    guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
      cache.folders == cacheKey(folders)
    else { return nil }
    return cache.items.map {
      FolderItemInfo(
        path: $0.path, date: $0.date, size: $0.size, isVideo: $0.isVideo, isLivePhoto: $0.isLivePhoto,
        duration: $0.duration)
    }
  }

  /// Keeps this read of the folders for the next launch.
  public static func saveCache(_ items: [FolderItemInfo], for folders: [LibraryFolder]) {
    let cache = Cache(
      folders: cacheKey(folders),
      items: items.map {
        Cache.Item(
          path: $0.path, date: $0.date, size: $0.size, isVideo: $0.isVideo, isLivePhoto: $0.isLivePhoto,
          duration: $0.duration)
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
    }
    let folders: [String]
    let items: [Item]
  }

  private static func cacheKey(_ folders: [LibraryFolder]) -> [String] {
    folders.map { $0.id + "|" + $0.path + "|" + $0.exclusions.key }.sorted()
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

  public func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    requestImage(id: id, pixelSize: pixelSize, quality: quality, onUnavailable: nil, deliver: deliver)
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, onUnavailable: (@Sendable () -> Void)?,
    deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let path = FolderItemInfo.path(fromID: id) else {
      onUnavailable?()
      return .none
    }
    let side = max(pixelSize.width, pixelSize.height, 64)
    let task = Task.detached(priority: .userInitiated) { [limiter] in
      guard await limiter.acquire() else { return }
      defer { limiter.release() }
      // A cell scrolled away while waiting for a slot.
      guard !Task.isCancelled else { return }
      let url = URL(fileURLWithPath: path)
      let image =
        SupportedMediaFormats.isVideo(filename: url.lastPathComponent)
        ? await Self.videoFrame(url, side: side) : Self.image(url, side: side)
      guard !Task.isCancelled else { return }
      if let image { deliver(image, true) } else { onUnavailable?() }
    }
    return ImageRequestToken { task.cancel() }
  }

  static func image(_ url: URL, side: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    func thumbnail(fromFullImage: Bool) -> CGImage? {
      let options: [CFString: Any] = [
        fromFullImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent:
          true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(side.rounded(.up)),
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    // A preview stored in the file (most camera photos and RAWs have one) saves decoding
    // the whole image, when it's big enough.
    if let preview = thumbnail(fromFullImage: false), CGFloat(max(preview.width, preview.height)) >= side * 0.9 {
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
