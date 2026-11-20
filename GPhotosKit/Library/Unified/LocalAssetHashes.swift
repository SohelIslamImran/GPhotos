import CryptoKit
import Foundation
import Photos

/// Resolves timestamp mismatches using small resources already on this device. This
/// supplies display evidence only; it never changes upload or deletion records.
enum LocalAssetHashes {
  static let maximumBytes: Int64 = 32 * 1024 * 1024

  nonisolated static func read(
    ids: [String], cloud: [RemoteItemSummary], store: LibraryIndexStore
  ) async -> [String: Set<Data>] {
    var candidates = Set<Signature>()
    for item in cloud where item.kind != .video && item.sha1?.count == 20 {
      candidates.insert(Signature(name: item.fileName, width: item.width ?? 0, height: item.height ?? 0))
    }
    guard !candidates.isEmpty else { return [:] }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var hashes: [String: Set<Data>] = [:]
    for index in 0..<assets.count {
      guard !Task.isCancelled else { break }
      let asset = assets.object(at: index)
      guard asset.mediaType == .image, !asset.isHidden else { continue }
      let resources = PHAssetResource.assetResources(for: asset)
      guard let resource = AssetExportService.primaryResource(for: asset, in: resources),
        let name = AssetExportService.primaryUploadFilename(for: asset, in: resources),
        let size = resource.dataSize.map(Int64.init),
        size > 0, size <= maximumBytes,
        candidates.contains(Signature(name: name, width: asset.pixelWidth, height: asset.pixelHeight))
      else { continue }
      let modified = asset.modificationDate
      let fingerprint = "\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(resource.type.rawValue)|\(size)|\(name)"
      let cached = try? await store.resourceHash(id: asset.localIdentifier, fingerprint: fingerprint)
      if cached?.checked == true {
        if let digest = cached?.digest { hashes[asset.localIdentifier] = [digest] }
        continue
      }
      let digest = try? await LocalResourceDigest.read(resource)
      guard !Task.isCancelled else { break }
      // An edit during the read must not cache old bytes under the new asset state.
      guard PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject?.modificationDate == modified
      else { continue }
      try? await store.saveResourceHash(id: asset.localIdentifier, fingerprint: fingerprint, digest: digest)
      if let digest { hashes[asset.localIdentifier] = [digest] }
      await Task.yield()
    }
    return hashes
  }

  private struct Signature: Hashable {
    let name: String
    let shortSide: Int
    let longSide: Int

    init(name: String, width: Int, height: Int) {
      self.name = name.lowercased()
      shortSide = min(width, height)
      longSide = max(width, height)
    }
  }
}

/// PhotoKit streams chunks directly into SHA-1; no exported file or full-size Data copy.
private final class LocalResourceDigest: @unchecked Sendable {
  private let lock = NSLock()
  private var hasher = Insecure.SHA1()
  private var continuation: CheckedContinuation<Data, Error>?
  private var requestID: PHAssetResourceDataRequestID?
  private var finished = false

  static func read(_ resource: PHAssetResource) async throws -> Data {
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
          request.lock.withLock {
            if !request.finished { request.hasher.update(data: data) }
          }
        } completionHandler: { error in
          request.finish(error)
        }
        let cancel = request.lock.withLock {
          request.requestID = id
          return request.finished
        }
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
      }
    } onCancel: {
      request.finish(CancellationError())
      let id = request.lock.withLock { request.requestID }
      if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
  }

  private func finish(_ error: Error?) {
    let completion: (CheckedContinuation<Data, Error>, Result<Data, Error>)? = lock.withLock {
      guard !finished else { return nil }
      finished = true
      guard let continuation else { return nil }
      self.continuation = nil
      return (continuation, error.map { .failure($0) } ?? .success(Data(hasher.finalize())))
    }
    if let completion { completion.0.resume(with: completion.1) }
  }
}
