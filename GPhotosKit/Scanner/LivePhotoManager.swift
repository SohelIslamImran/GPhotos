import Foundation
#if canImport(Photos)
  import Photos
#endif

public struct LivePhotoExport: Sendable {
  public let photoURL: URL
  public let videoURL: URL
  public let photoFilename: String
  public let videoFilename: String
  public let photoSize: Int64
  public let videoSize: Int64
  public let creationDate: Date
  public let modificationDate: Date
  public let videoModificationDate: Date

  public init(
    photoURL: URL,
    videoURL: URL,
    photoFilename: String,
    videoFilename: String,
    photoSize: Int64,
    videoSize: Int64,
    creationDate: Date,
    modificationDate: Date,
    videoModificationDate: Date
  ) {
    self.photoURL = photoURL
    self.videoURL = videoURL
    self.photoFilename = photoFilename
    self.videoFilename = videoFilename
    self.photoSize = photoSize
    self.videoSize = videoSize
    self.creationDate = creationDate
    self.modificationDate = modificationDate
    self.videoModificationDate = videoModificationDate
  }
}

public enum LivePhotoManager {
  /// Every upload export lives under here, so a sweep can reclaim what a killed
  /// process left behind without touching other temporary files.
  static var exportRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("GPhotosTemp", isDirectory: true)
  }

  #if canImport(Photos)
    /// Checks if a PHAsset is a Live Photo
    public static func isLivePhoto(_ asset: PHAsset) -> Bool {
      asset.mediaSubtypes.contains(.photoLive)
    }

    /// Exports both the still photo and the paired motion video for a Live Photo asset: the
    /// current version, or with `unedited` the camera's files of an edited one. Into
    /// `directory` (created, and removed if the export fails) or a new temporary one.
    public static func exportLivePhoto(
      asset: PHAsset, unedited: Bool = false, allowsNetworkAccess: Bool = true, into directory: URL? = nil
    ) async throws -> LivePhotoExport {
      let resources = PHAssetResource.assetResources(for: asset)
      let edited = asset.hasAdjustments && !unedited
      guard
        let photoResource = AssetExportService.firstResource(
          in: resources, type: \.type,
          preferring: AssetExportService.primaryResourceTypes(mediaType: .image, edited: edited)),
        let videoResource = AssetExportService.firstResource(
          in: resources, type: \.type,
          preferring: AssetExportService.pairedVideoResourceTypes(edited: edited))
      else {
        throw GPhotosError.assetExportFailed(underlying: "Live Photo missing photo or paired video resource")
      }

      let tempDir = directory ?? exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      var exportCompleted = false
      defer {
        if !exportCompleted {
          try? FileManager.default.removeItem(at: tempDir)
        }
      }

      // An edited Live Photo's renders are named FullSizeRender; they go up under the
      // camera's names instead.
      let photoName = Self.filename(
        original: resources.first(where: { $0.type == .photo })?.filenameOrEmpty,
        rendition: photoResource.filenameOrEmpty, fallback: "photo.heic")
      let videoName = Self.filename(
        original: resources.first(where: { $0.type == .pairedVideo })?.filenameOrEmpty,
        rendition: videoResource.filenameOrEmpty, fallback: "video.mov")

      let photoDest = tempDir.appendingPathComponent(photoName)
      let videoDest = tempDir.appendingPathComponent(videoName)

      let (_, photoSize) = try await AssetExportService.write(
        resource: photoResource, to: photoDest, allowsNetworkAccess: allowsNetworkAccess)
      let (_, videoSize) = try await AssetExportService.write(
        resource: videoResource, to: videoDest, allowsNetworkAccess: allowsNetworkAccess)
      let videoAttrs = try FileManager.default.attributesOfItem(atPath: videoDest.path)
      let creation = asset.creationDate ?? Date()
      let modification = asset.modificationDate ?? creation
      let videoModification = (videoAttrs[.modificationDate] as? Date) ?? creation

      exportCompleted = true
      return LivePhotoExport(
        photoURL: photoDest,
        videoURL: videoDest,
        photoFilename: photoName,
        videoFilename: videoName,
        photoSize: photoSize,
        videoSize: videoSize,
        creationDate: creation,
        modificationDate: modification,
        videoModificationDate: videoModification
      )
    }

    static func filename(original: String?, rendition: String, fallback: String) -> String {
      let safeOriginal = CloudLibrary.safeFileName(original, fallback: "")
      let safeRendition = CloudLibrary.safeFileName(rendition, fallback: "")
      let name = AssetExportService.uploadFilename(
        original: safeOriginal.isEmpty ? nil : safeOriginal,
        rendition: safeRendition)
      return CloudLibrary.safeFileName(name, fallback: fallback)
    }
  #endif

  private struct MediaCandidate {
    let url: URL
    let stem: String
    let identifier: String?
  }

  /// Classifies a list of standalone files on disk into single files and Live Photo pairs.
  /// Called on every folder scan, so this stays cheap for folders without videos.
  /// Within the same directory:
  /// 1. Pairs still + video by matching Apple Live Photo content identifier first.
  /// 2. Falls back to filename-stem matching only when identifier is missing on either side.
  /// 3. Never pairs two files with different non-empty identifiers.
  /// `metadata` carries what a scan already read for each file, so neither the identifier
  /// cache nor a pair's export has to stat it again.
  public static func findLivePhotoPairs(
    in fileURLs: [URL],
    metadata: [URL: LocalMediaFile] = [:]
  ) -> (pairs: [LivePhotoExport], singles: [URL]) {
    var filesByDirectory: [String: [URL]] = [:]
    for url in fileURLs {
      let dirKey = url.deletingLastPathComponent().standardizedFileURL.path
      filesByDirectory[dirKey, default: []].append(url)
    }

    var allPairs: [LivePhotoExport] = []
    var allSingles: [URL] = []

    for (_, dirURLs) in filesByDirectory {
      var photoCandidates: [MediaCandidate] = []
      var videoCandidates: [MediaCandidate] = []
      var nonCandidates: [URL] = []

      // Metadata is only worth reading when the folder has a motion file to pair with.
      let hasVideos = dirURLs.contains { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
      for url in dirURLs {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()

        if SupportedMediaFormats.isPhoto(filename: url.lastPathComponent) {
          let id = hasVideos ? IdentifierCache.shared.identifier(for: url, isVideo: false, known: metadata[url]) : nil
          photoCandidates.append(MediaCandidate(url: url, stem: stem, identifier: id))
        } else if ext == "mov" || ext == "mp4" {
          let id = IdentifierCache.shared.identifier(for: url, isVideo: true, known: metadata[url])
          videoCandidates.append(MediaCandidate(url: url, stem: stem, identifier: id))
        } else if SupportedMediaFormats.isSupported(fileURL: url) {
          nonCandidates.append(url)
        }
      }

      // Step 1: Pair by matching non-empty content identifier first.
      var photosWithID: [String: [MediaCandidate]] = [:]
      var remainingPhotos: [MediaCandidate] = []
      for photo in photoCandidates {
        if let id = photo.identifier {
          photosWithID[id, default: []].append(photo)
        } else {
          remainingPhotos.append(photo)
        }
      }

      var videosWithID: [String: [MediaCandidate]] = [:]
      var remainingVideos: [MediaCandidate] = []
      for video in videoCandidates {
        if let id = video.identifier {
          videosWithID[id, default: []].append(video)
        } else {
          remainingVideos.append(video)
        }
      }

      for (id, photos) in photosWithID {
        var pList = photos
        var vList = videosWithID.removeValue(forKey: id) ?? []
        while !pList.isEmpty && !vList.isEmpty {
          let p = pList.removeFirst()
          let v = vList.removeFirst()
          allPairs.append(makeExport(photoURL: p.url, videoURL: v.url, metadata: metadata))
        }
        remainingPhotos.append(contentsOf: pList)
        remainingVideos.append(contentsOf: vList)
      }

      for (_, unMatchedVideos) in videosWithID {
        remainingVideos.append(contentsOf: unMatchedVideos)
      }

      // Step 2: Fall back to filename-stem matching for unconsumed items.
      var photosByStem: [String: [MediaCandidate]] = [:]
      for photo in remainingPhotos {
        photosByStem[photo.stem, default: []].append(photo)
      }

      var videosByStem: [String: [MediaCandidate]] = [:]
      for video in remainingVideos {
        videosByStem[video.stem, default: []].append(video)
      }

      for (stem, pList) in photosByStem {
        var stemPhotos = pList
        var stemVideos = videosByStem.removeValue(forKey: stem) ?? []
        var pIndex = 0

        while pIndex < stemPhotos.count {
          let photo = stemPhotos[pIndex]
          if let vIndex = stemVideos.firstIndex(where: { video in
            // Never pair two files with different non-empty identifiers.
            if let pID = photo.identifier, let vID = video.identifier, pID != vID {
              return false
            }
            return true
          }) {
            let video = stemVideos.remove(at: vIndex)
            stemPhotos.remove(at: pIndex)
            allPairs.append(makeExport(photoURL: photo.url, videoURL: video.url, metadata: metadata))
          } else {
            pIndex += 1
          }
        }

        allSingles.append(contentsOf: stemPhotos.map(\.url))
        allSingles.append(contentsOf: stemVideos.map(\.url))
      }

      for (_, unMatchedVideos) in videosByStem {
        allSingles.append(contentsOf: unMatchedVideos.map(\.url))
      }

      allSingles.append(contentsOf: nonCandidates)
    }

    return (allPairs, allSingles)
  }

  private static func makeExport(photoURL: URL, videoURL: URL, metadata: [URL: LocalMediaFile]) -> LivePhotoExport {
    if let photo = metadata[photoURL], let video = metadata[videoURL] {
      return LivePhotoExport(
        photoURL: photoURL,
        videoURL: videoURL,
        photoFilename: photoURL.lastPathComponent,
        videoFilename: videoURL.lastPathComponent,
        photoSize: photo.size,
        videoSize: video.size,
        creationDate: min(photo.created, photo.modified),
        modificationDate: photo.modified,
        videoModificationDate: video.modified
      )
    }
    let photoAttrs = (try? FileManager.default.attributesOfItem(atPath: photoURL.path)) ?? [:]
    let videoAttrs = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)) ?? [:]

    let photoSize = (photoAttrs[.size] as? NSNumber)?.int64Value ?? 0
    let videoSize = (videoAttrs[.size] as? NSNumber)?.int64Value ?? 0
    // A copied file has a new creation date but its original modification date.
    let creation =
      [photoAttrs[.creationDate] as? Date, photoAttrs[.modificationDate] as? Date].compactMap { $0 }.min() ?? Date()
    let mod = (photoAttrs[.modificationDate] as? Date) ?? creation
    let videoMod = (videoAttrs[.modificationDate] as? Date) ?? creation

    return LivePhotoExport(
      photoURL: photoURL,
      videoURL: videoURL,
      photoFilename: photoURL.lastPathComponent,
      videoFilename: videoURL.lastPathComponent,
      photoSize: photoSize,
      videoSize: videoSize,
      creationDate: creation,
      modificationDate: mod,
      videoModificationDate: videoMod
    )
  }
}

/// Content identifiers by file version. Watched folders are rescanned on every change,
/// and without this each pass would re-read the metadata of every unchanged file.
final class IdentifierCache: @unchecked Sendable {
  static let shared = IdentifierCache()
  private static let limit = 50_000

  private let lock = NSLock()
  /// "" records a file read once that has no identifier.
  private var entries: [String: String] = [:]

  func identifier(for url: URL, isVideo: Bool, known: LocalMediaFile? = nil) -> String? {
    let version: String
    if let known {
      version = "\(known.size)|\(known.modified.timeIntervalSince1970)"
    } else {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      version = "\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    let key = url.standardizedFileURL.path + "|" + version
    if let cached = lock.withLock({ entries[key] }) { return cached.isEmpty ? nil : cached }
    let id =
      isVideo
      ? LivePhotoMetadata.readVideoLivePhotoMetadata(from: url)?.contentIdentifier
      : LivePhotoMetadata.readPhotoContentIdentifier(from: url)
    lock.withLock {
      if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
      entries[key] = id ?? ""
    }
    return id
  }
}
