import Foundation
import Photos

/// Bridges one PhotoKit data request to a continuation. The data and completion
/// callbacks are not ordered against each other or against task cancellation, so the
/// gate resumes exactly once, serialises chunk writes with closing the file, and hands
/// the request id to whichever side needs to cancel it.
final class ResourceRequestGate: @unchecked Sendable {
  private let lock = NSLock()
  private let fileHandle: FileHandle
  private var continuation: CheckedContinuation<Void, Error>?
  private var pendingResult: Result<Void, Error>?
  private var isFinished = false
  private var isCancelled = false
  private var requestID: PHAssetResourceDataRequestID?
  private var bytesSinceSpaceCheck = 0
  private var lastDataAt = ContinuousClock.now

  init(fileHandle: FileHandle) {
    self.fileHandle = fileHandle
  }

  func install(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if let pendingResult {
      self.pendingResult = nil
      lock.unlock()
      continuation.resume(with: pendingResult)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  /// Returns false when cancellation already arrived, so the caller cancels the request.
  func setRequestID(_ id: PHAssetResourceDataRequestID) -> Bool {
    lock.withLock {
      requestID = id
      return !isCancelled
    }
  }

  func cancel() -> PHAssetResourceDataRequestID? {
    lock.lock()
    isCancelled = true
    let id = requestID
    finishLocked(.failure(CancellationError()))
    return id
  }

  func write(_ chunk: Data) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    do {
      if bytesSinceSpaceCheck >= 16 * 1024 * 1024 {
        try UploadWorkerPool.requireFreeSpace(for: Int64(chunk.count))
        bytesSinceSpaceCheck = 0
      }
      try fileHandle.write(contentsOf: chunk)
      bytesSinceSpaceCheck += chunk.count
      lastDataAt = .now
      lock.unlock()
    } catch {
      // A disk failure must also stop PhotoKit's iCloud download, including when the
      // first callback arrived before requestData returned its request ID.
      isCancelled = true
      let id = requestID
      finishLocked(.failure(AssetExportService.exportError(error)))
      if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
  }

  func resume(_ result: Result<Void, Error>) {
    lock.lock()
    finishLocked(result)
  }

  /// A silent PhotoKit request would otherwise hold a worker until the user stops it.
  func timeOutIfIdle(for duration: Duration, now: ContinuousClock.Instant = .now) -> Bool {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return true
    }
    guard now - lastDataAt >= duration else {
      lock.unlock()
      return false
    }
    isCancelled = true
    let id = requestID
    finishLocked(.failure(GPhotosError.assetExportFailed(underlying: "Photos stopped responding. Tap Retry.")))
    if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    return true
  }

  private func finishLocked(_ result: Result<Void, Error>) {
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    try? fileHandle.close()
    if let continuation {
      self.continuation = nil
      lock.unlock()
      continuation.resume(with: result)
    } else {
      pendingResult = result
      lock.unlock()
    }
  }
}

public enum AssetExportService {
  public static func version(of asset: PHAsset) -> TransferRecord.AssetVersion {
    .init(
      modifiedAt: asset.modificationDate, hasAdjustments: asset.hasAdjustments, adjustmentTimestamp: asset.adjustmentTimestamp)
  }

  /// Fetch options for every library-wide or by-identifier fetch: without
  /// `includeAllBurstAssets` PhotoKit returns only a burst's representative frame, so the
  /// other frames would be neither uploaded nor found again at cleanup.
  public static func allFramesFetchOptions() -> PHFetchOptions {
    let options = PHFetchOptions()
    options.includeAllBurstAssets = true
    return options
  }

  /// The RAW half of a RAW+JPEG pair, which the primary export never sends.
  public static func alternatePhotoResource(in resources: [PHAssetResource]) -> PHAssetResource? {
    resources.first { $0.type == .alternatePhoto }
  }

  /// An edited asset's unedited original: the file the camera wrote, which an edit never
  /// changes. Deleting the asset from the library deletes it too.
  public static func uneditedOriginalResource(
    mediaType: PHAssetMediaType, in resources: [PHAssetResource]
  ) -> PHAssetResource? {
    resources.first { $0.type == uneditedOriginalType(mediaType: mediaType) }
  }

  public static func uneditedOriginalType(mediaType: PHAssetMediaType) -> PHAssetResourceType {
    mediaType == .video ? .video : .photo
  }

  /// The resource types to upload for an asset, best first: the file the Google Photos app
  /// would upload itself, since it counts a photo on the device as backed up only when the
  /// account holds those exact bytes. That is the rendered edit for an edited asset and the
  /// original otherwise. The list follows the media type because an edited video also
  /// carries a rendered still (`.fullSizePhoto`), which must never stand in for the video.
  public static func primaryResourceTypes(mediaType: PHAssetMediaType, edited: Bool) -> [PHAssetResourceType] {
    let photo: [PHAssetResourceType] = edited ? [.fullSizePhoto, .photo] : [.photo, .fullSizePhoto]
    let video: [PHAssetResourceType] = edited ? [.fullSizeVideo, .video] : [.video, .fullSizeVideo]
    switch mediaType {
    case .image: return photo
    case .video: return video
    default: return photo + video
    }
  }

  /// A Live Photo's motion, best first: the rendered edit's video for an edited asset, as
  /// the Google Photos app attaches it.
  public static func pairedVideoResourceTypes(edited: Bool) -> [PHAssetResourceType] {
    edited ? [.fullSizePairedVideo, .pairedVideo] : [.pairedVideo, .fullSizePairedVideo]
  }

  /// The first resource whose type appears in `preference`, in preference order.
  public static func firstResource<Resource>(
    in resources: [Resource],
    type: (Resource) -> PHAssetResourceType,
    preferring preference: [PHAssetResourceType]
  ) -> Resource? {
    for wanted in preference {
      if let match = resources.first(where: { type($0) == wanted }) { return match }
    }
    return nil
  }

  public static func primaryResource(for asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
    firstResource(
      in: resources, type: \.type,
      preferring: primaryResourceTypes(mediaType: asset.mediaType, edited: asset.hasAdjustments))
  }

  /// A rendered edit is named `FullSizeRender.heic`; it goes up under the original's name
  /// with the rendition's file type, so Google Photos shows the name the camera gave it.
  public static func uploadFilename(original: String?, rendition: String) -> String {
    guard let original, !original.isEmpty else { return rendition }
    let originalType = (original as NSString).pathExtension
    let renditionType = (rendition as NSString).pathExtension
    guard !renditionType.isEmpty, renditionType.lowercased() != originalType.lowercased() else { return original }
    let type = originalType == originalType.uppercased() ? renditionType.uppercased() : renditionType.lowercased()
    return (original as NSString).deletingPathExtension + "." + type
  }

  /// The camera's name for an asset: its original photo or video resource's filename.
  public static func originalFilename(in resources: [PHAssetResource], mediaType: PHAssetMediaType) -> String? {
    let types: [PHAssetResourceType] = mediaType == .video ? [.video, .photo] : [.photo, .video]
    return firstResource(in: resources, type: \.type, preferring: types)?.filenameOrEmpty
  }

  /// The name an asset's primary upload is committed under.
  public static func primaryUploadFilename(for asset: PHAsset, in resources: [PHAssetResource]) -> String? {
    guard let primary = primaryResource(for: asset, in: resources) else { return nil }
    return uploadFilename(
      original: originalFilename(in: resources, mediaType: asset.mediaType), rendition: primary.filenameOrEmpty)
  }

  /// Copies one of the asset's resources to `destinationURL`: for `.primary` the file the
  /// Google Photos app would upload, for `.alternatePhoto` the RAW of a RAW+JPEG pair, for
  /// `.uneditedOriginal` the camera's file of an edited asset.
  public static func exportResource(
    asset: PHAsset,
    role: AssetResourceRole,
    to destinationURL: URL,
    allowsNetworkAccess: Bool = true
  ) async throws -> (URL, Int64) {
    let resources = PHAssetResource.assetResources(for: asset)
    let resource: PHAssetResource?
    switch role {
    case .primary:
      resource = primaryResource(for: asset, in: resources)
    case .alternatePhoto:
      resource = alternatePhotoResource(in: resources)
    case .uneditedOriginal:
      resource = uneditedOriginalResource(mediaType: asset.mediaType, in: resources)
    }
    guard let resource else {
      throw GPhotosError.assetExportFailed(underlying: "No exportable resource for asset")
    }
    return try await write(resource: resource, to: destinationURL, allowsNetworkAccess: allowsNetworkAccess)
  }

  /// Streams one resource to `destinationURL`, cancelling the PhotoKit request (and its
  /// iCloud download) when the calling task is cancelled. Without network access a resource
  /// that is only in iCloud fails with `iCloudDownloadDeferred`.
  static func write(
    resource: PHAssetResource, to destinationURL: URL, allowsNetworkAccess: Bool = true
  ) async throws -> (URL, Int64) {
    try Task.checkCancellation()
    let manager = PHAssetResourceManager.default()
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = allowsNetworkAccess

    try UploadWorkerPool.requireFreeSpace(
      for: Int64(max(0, resource.dataSize ?? 0)), at: destinationURL.deletingLastPathComponent())

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    var completed = false
    defer {
      if !completed { try? FileManager.default.removeItem(at: destinationURL) }
    }
    let gate: ResourceRequestGate
    do {
      try Data().write(to: destinationURL)
      gate = ResourceRequestGate(fileHandle: try FileHandle(forWritingTo: destinationURL))
    } catch {
      throw exportError(error)
    }
    let watchdog = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, !gate.timeOutIfIdle(for: .seconds(120)) else { return }
      }
    }
    defer { watchdog.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        gate.install(continuation)
        let id = manager.requestData(
          for: resource, options: options,
          dataReceivedHandler: { gate.write($0) },
          completionHandler: { error in
            if let error {
              let nsError = error as NSError
              let needsDownload =
                nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.networkAccessRequired.rawValue
              gate.resume(
                .failure(
                  !allowsNetworkAccess && needsDownload
                    ? GPhotosError.iCloudDownloadDeferred
                    : Self.exportError(error)))
            } else {
              gate.resume(.success(()))
            }
          })
        if !gate.setRequestID(id) {
          manager.cancelDataRequest(id)
        }
      }
    } onCancel: {
      if let id = gate.cancel() {
        manager.cancelDataRequest(id)
      }
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
    completed = true
    return (destinationURL, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
  }

  static func exportError(_ error: Error) -> GPhotosError {
    if let error = error as? GPhotosError { return error }
    var underlying: NSError? = error as NSError
    for _ in 0..<4 {
      guard let cause = underlying else { break }
      if (cause.domain == NSCocoaErrorDomain && cause.code == NSFileWriteOutOfSpaceError)
        || (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC))
        || (cause.domain == PHPhotosErrorDomain && cause.code == PHPhotosError.notEnoughSpace.rawValue)
      {
        return .notEnoughSpace(needed: 0)
      }
      if cause.domain == PHPhotosErrorDomain && cause.code == PHPhotosError.networkError.rawValue {
        return .networkUnavailable
      }
      underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return .assetExportFailed(underlying: error.localizedDescription)
  }
}

extension PHAssetResource {
  /// The resource's file name, or "" when it has none, as `originalFilename` gave before iOS 27.
  public var filenameOrEmpty: String { filename ?? "" }
}
