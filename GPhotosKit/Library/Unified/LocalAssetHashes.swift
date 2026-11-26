import CryptoKit
import Darwin
import Foundation
import Photos

/// Resolves timestamp mismatches from bytes already on this device, for display only.
enum LocalAssetHashes {
  static let maximumBytes: Int64 = 128 * 1024 * 1024
  static let passBudget: Int64 = 256 * 1024 * 1024

  struct Evidence: Sendable {
    var devices: [String: (version: PhotoBackupEvidence.Version, digest: Data)] = [:]
    var files: [String: (size: Int64, modified: Date?, digest: Data)] = [:]

    func current(device: [DeviceItemInfo], folder: [FolderItemInfo]) -> [String: Set<Data>] {
      var hashes: [String: Set<Data>] = [:]
      for item in device where !item.isHidden {
        if let saved = devices[item.localIdentifier], Self.sameContent(item.version, saved.version) {
          hashes[item.localIdentifier] = [saved.digest]
        }
      }
      for item in folder {
        if let saved = files[item.id], saved.size == item.size, saved.modified == item.modifiedAt {
          hashes[item.id] = [saved.digest]
        }
      }
      return hashes
    }

    func matches(_ other: Self) -> Bool {
      devices.count == other.devices.count && files.count == other.files.count
        && devices.allSatisfy { entry in other.devices[entry.key].map { $0 == entry.value } ?? false }
        && files.allSatisfy { entry in other.files[entry.key].map { $0 == entry.value } ?? false }
    }

    static func sameContent(_ a: PhotoBackupEvidence.Version, _ b: PhotoBackupEvidence.Version) -> Bool {
      a == b
        || (a.hasAdjustments != nil && b.hasAdjustments != nil
          && !a.assetVersion.contentChanged(since: b.assetVersion) && !b.assetVersion.contentChanged(since: a.assetVersion))
    }
  }

  struct Plan: Sendable {
    var known = Evidence()
    fileprivate var candidates: [Candidate] = []
    fileprivate var keys: [Signature: [String]] = [:]
    fileprivate var pendingSignatures = Set<Signature>()
    fileprivate var remainingBytes = passBudget

    var pendingKeys: Set<String> { Set(pendingSignatures.flatMap { keys[$0] ?? [] }) }

    fileprivate mutating func add(_ candidate: Candidate, matches: [Signature]) {
      guard candidate.size <= remainingBytes else { return }
      remainingBytes -= candidate.size
      candidates.append(candidate)
      pendingSignatures.formUnion(matches)
    }
  }

  // A size mismatch rules out probes across launches, but is checked against the
  // current mirror so a later upload can still become a candidate.
  struct ResourceSize: Sendable {
    let version: String
    let bytes: Int64
  }

  static func resourceVersion(_ item: DeviceItemInfo) -> String {
    "\(item.version.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)|"
  }

  private static func exactSizeSignatures(_ item: DeviceItemInfo, size: Int64) -> [Signature] {
    guard size > 0, size <= maximumBytes else { return [] }
    let video = item.isVideo
    let short = min(item.width, item.height)
    let long = max(item.width, item.height)
    return [
      .assetBytes(short, long, size, video: video), .assetBytes(short, long, 0, video: video),
      .unknownDimensionsBytes(size, video: video), .unknownDimensionsBytes(0, video: video),
    ]
  }

  fileprivate struct Candidate: Sendable {
    let source: Source
    let fingerprint: String
    let size: Int64

    enum Source: @unchecked Sendable {
      case asset(DeviceItemInfo, PHAssetResource)
      case file(FolderItemInfo)
    }
  }

  fileprivate enum Signature: Hashable {
    case dimensions(Int, Int, video: Bool)
    case unknownDimensions(video: Bool)
    case assetBytes(Int, Int, Int64, video: Bool)
    case unknownDimensionsBytes(Int64, video: Bool)
    case bytes(Int64, video: Bool)
    case filename(String, video: Bool)

    static func asset(width: Int, height: Int, video: Bool) -> Self {
      .dimensions(min(width, height), max(width, height), video: video)
    }
  }

  private static func signatures(_ item: RemoteItemSummary) -> [Signature] {
    let video = item.kind == .video
    var result: [Signature] = []
    if let w = item.width, let h = item.height, w > 0, h > 0 {
      result.append(.asset(width: w, height: h, video: video))
      result.append(.assetBytes(min(w, h), max(w, h), max(0, item.sizeBytes), video: video))
    } else {
      result.append(.unknownDimensions(video: video))
      result.append(.unknownDimensionsBytes(max(0, item.sizeBytes), video: video))
    }
    if item.sizeBytes > 0 {
      result.append(.bytes(max(0, item.sizeBytes), video: video))
    }
    if item.sizeBytes <= 0, !item.fileName.isEmpty { result.append(.filename(item.fileName.lowercased(), video: video)) }
    return result
  }

  private static func signatures(_ file: FolderItemInfo) -> [Signature] {
    [.bytes(file.size, video: file.isVideo), .filename(file.fileName.lowercased(), video: file.isVideo)]
  }

  private static func signatures(_ item: DeviceItemInfo) -> [Signature] {
    [.asset(width: item.width, height: item.height, video: item.isVideo), .unknownDimensions(video: item.isVideo)]
  }

  private static func fileFingerprint(_ file: FolderItemInfo) -> String? {
    let url = URL(fileURLWithPath: file.path)
    var info = stat()
    guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
    guard
      let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      ]), let date = values.contentModificationDate, values.fileSize.map(Int64.init) == file.size,
      file.modifiedAt == nil || file.modifiedAt == date,
      values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
    else { return nil }
    return "\(date.timeIntervalSinceReferenceDate)|\(file.size)"
  }

  nonisolated static func prepare(
    device: [DeviceItemInfo], folder: [FolderItemInfo], cloud: [RemoteItemSummary], store: LibraryIndexStore,
    previous: Evidence, receipts: [String: Set<Data>], allowsProbes: Bool = true,
    onKnown: (@Sendable (Evidence) async -> Void)? = nil
  ) async -> Plan {
    let cache = (try? await store.recentResourceHashChecks()) ?? [:]
    let retained = previous.current(device: device, folder: folder)
    var plan = Plan()
    for item in cloud where item.sha1?.count == 20 {
      for signature in signatures(item) { plan.keys[signature, default: []].append(item.mediaKey) }
    }
    for file in folder {
      guard !Task.isCancelled else { return plan }
      let saved = cache[file.id]
      let matches = signatures(file).filter { plan.keys[$0] != nil }
      if let modified = file.modifiedAt,
        let digest = retained[file.id]?.first
          ?? (saved?.fingerprint == "\(modified.timeIntervalSinceReferenceDate)|\(file.size)" ? saved?.digest : nil)
      {
        plan.known.files[file.id] = (file.size, modified, digest)
        continue
      }
      guard saved?.digest != nil || retained[file.id] != nil || (allowsProbes && !matches.isEmpty),
        let fingerprint = fileFingerprint(file)
      else { continue }
      if let digest = retained[file.id]?.first ?? (saved?.fingerprint == fingerprint ? saved?.digest : nil) {
        plan.known.files[file.id] = (file.size, file.modifiedAt, digest)
      } else if allowsProbes, receipts[file.id] == nil, saved?.fingerprint != fingerprint,
        !matches.isEmpty, file.size > 0, file.size <= maximumBytes
      {
        plan.add(Candidate(source: .file(file), fingerprint: fingerprint, size: file.size), matches: matches)
      }
    }
    var candidates: [String: DeviceItemInfo] = [:]
    for item in device where item.isMedia && !item.isHidden {
      let id = item.localIdentifier
      let version = resourceVersion(item)
      if let digest = retained[id]?.first ?? (cache[id]?.fingerprint.hasPrefix(version) == true ? cache[id]?.digest : nil) {
        plan.known.devices[id] = (item.version, digest)
      } else if allowsProbes, cache[id]?.fingerprint.hasPrefix(version) != true, receipts[id] == nil,
        signatures(item).contains(where: { plan.keys[$0] != nil })
      {
        candidates[id] = item
      }
    }
    guard !candidates.isEmpty, !Task.isCancelled else { return plan }
    await onKnown?(plan.known)
    let sizes = (try? await store.resourceSizes()) ?? [:]
    candidates = candidates.filter { id, item in
      guard let size = sizes[id], size.version == resourceVersion(item) else { return true }
      return exactSizeSignatures(item, size: size.bytes).contains { plan.keys[$0] != nil }
    }
    guard !candidates.isEmpty, !Task.isCancelled else { return plan }
    let options = AssetExportService.allFramesFetchOptions()
    options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidates.keys), options: options)
    var checkedSizes: [String: ResourceSize] = [:]
    for index in 0..<assets.count {
      guard !Task.isCancelled else { break }
      let asset = assets.object(at: index)
      guard let item = candidates[asset.localIdentifier], !asset.isHidden,
        asset.modificationDate == item.version.modifiedAt
      else { continue }
      let resources = PHAssetResource.assetResources(for: asset)
      let resource = AssetExportService.primaryResource(for: asset, in: resources)
      let version = resourceVersion(item)
      guard let resource else {
        checkedSizes[item.localIdentifier] = ResourceSize(version: version, bytes: 0)
        continue
      }
      guard let size = resource.dataSize.map(Int64.init), size > 0 else { continue }
      checkedSizes[item.localIdentifier] = ResourceSize(version: version, bytes: size)
      let matches = exactSizeSignatures(item, size: size).filter { plan.keys[$0] != nil }
      guard !matches.isEmpty else { continue }
      let name = AssetExportService.primaryUploadFilename(for: asset, in: resources) ?? resource.filenameOrEmpty
      let fingerprint = "\(version)\(resource.type.rawValue)|\(size)|\(name)"
      plan.add(Candidate(source: .asset(item, resource), fingerprint: fingerprint, size: size), matches: matches)
    }
    try? await store.saveResourceSizes(checkedSizes)
    return plan
  }

  nonisolated static func read(
    _ plan: Plan, store: LibraryIndexStore, canRead: @Sendable () async -> Bool = { true }
  ) async -> (evidence: Evidence, complete: Bool) {
    var verified = plan.known
    for candidate in plan.candidates {
      guard !Task.isCancelled, await canRead() else { return (verified, false) }
      switch candidate.source {
      case .asset(let item, let resource):
        let digest = try? await LocalResourceDigest.read(resource, size: candidate.size)
        let canRecordMiss = digest == nil && !Task.isCancelled ? await canRead() : false
        if let asset = LocalFirstThumbnailSource.visibleAsset(item.localIdentifier),
          asset.modificationDate == item.version.modifiedAt, digest != nil || canRecordMiss
        {
          try? await store.saveResourceHash(id: item.localIdentifier, fingerprint: candidate.fingerprint, digest: digest)
          if let digest { verified.devices[item.localIdentifier] = (item.version, digest) }
        }
      case .file(let file):
        guard let digest = readLocalFile(file, fingerprint: candidate.fingerprint) else { continue }
        try? await store.saveResourceHash(id: file.id, fingerprint: candidate.fingerprint, digest: digest)
        verified.files[file.id] = (file.size, file.modifiedAt, digest)
      }
    }
    let allowed = await canRead()
    return (verified, allowed && !Task.isCancelled)
  }

  static func readLocalFile(_ file: FolderItemInfo, fingerprint: String) -> Data? {
    let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    let scope = IOPOL_SCOPE_THREAD
    let previous = getiopolicy_np(policy, scope)
    guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
    // The kernel must refuse hydration even if eviction races the metadata check.
    defer { _ = setiopolicy_np(policy, scope, previous) }
    guard fileFingerprint(file) == fingerprint else { return nil }
    let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size == file.size
    else { return nil }

    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
    defer { buffer.deallocate() }
    var hasher = Insecure.SHA1()
    var remaining = file.size
    while remaining > 0 {
      guard !Task.isCancelled, LibraryIndexer.pauseReason() == nil else { return nil }
      let count = Darwin.read(descriptor, buffer.baseAddress, Int(min(remaining, Int64(buffer.count))))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return nil }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
      remaining -= Int64(count)
    }
    guard fileFingerprint(file) == fingerprint else { return nil }
    return Data(hasher.finalize())
  }

}

/// PhotoKit streams chunks directly into SHA-1; no exported file or full-size Data copy.
private final class LocalResourceDigest: @unchecked Sendable {
  private let lock = NSLock()
  private var hasher = Insecure.SHA1()
  private var bytes: Int64 = 0
  private var continuation: CheckedContinuation<Data, Error>?
  private var requestID: PHAssetResourceDataRequestID?
  private var finished = false

  static func read(_ resource: PHAssetResource, size: Int64) async throws -> Data {
    let request = LocalResourceDigest()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let active = request.lock.withLock {
          guard !request.finished else { return false }
          request.continuation = continuation
          return true
        }
        guard active else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
          let oversized = request.lock.withLock {
            guard !request.finished else { return false }
            request.bytes += Int64(data.count)
            guard request.bytes <= size else { return true }
            request.hasher.update(data: data)
            return false
          }
          if oversized { request.cancel(CocoaError(.fileReadCorruptFile)) }
        } completionHandler: { error in
          request.finish(error, expectedSize: size)
        }
        let cancel = request.lock.withLock {
          request.requestID = id
          return request.finished
        }
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
      }
    } onCancel: {
      request.cancel(CancellationError())
    }
  }

  private func cancel(_ error: Error) {
    finish(error)
    let id = lock.withLock { requestID }
    if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
  }

  private func finish(_ error: Error?, expectedSize: Int64? = nil) {
    let completion: (CheckedContinuation<Data, Error>, Result<Data, Error>)? = lock.withLock {
      guard !finished else { return nil }
      finished = true
      guard let continuation else { return nil }
      self.continuation = nil
      if let error { return (continuation, .failure(error)) }
      guard bytes == expectedSize else { return (continuation, .failure(CocoaError(.fileReadCorruptFile))) }
      return (continuation, .success(Data(hasher.finalize())))
    }
    if let completion { completion.0.resume(with: completion.1) }
  }
}
