import CoreGraphics
import Dispatch
import os

/// Keeps routing off the main actor while the library discovers local copies.
final class LocalFirstThumbnailSource: ThumbnailSource {
  struct LocalCopies: Sendable {
    var assets: [String: String] = [:]
    var files: [String: FolderItemInfo] = [:]
  }

  private let copies = OSAllocatedUnfairLock(initialState: LocalCopies())
  private let remote: any ThumbnailSource

  init(remote: any ThumbnailSource) { self.remote = remote }

  var localCopies: LocalCopies { copies.withLock { $0 } }

  func register(assets: [String: String], files: [String: FolderItemInfo]) -> Bool {
    copies.withLock { copies in
      var changed = false
      for (key, id) in assets where copies.assets[key] != id {
        copies.assets[key] = id
        changed = true
      }
      for (key, file) in files where copies.files[key] != file {
        copies.files[key] = file
        changed = true
      }
      return changed
    }
  }

  func requestImage(
    id: String, pixelSize: CGSize, quality: ImageRequestQuality, deliver: @escaping @Sendable (CGImage, Bool) -> Void
  ) -> ImageRequestToken {
    guard let key = RemoteThumbnailID(id)?.mediaKey else { return .none }
    let (assetID, fileID) = copies.withLock { ($0.assets[key], $0.files[key]?.id) }
    guard assetID != nil || fileID != nil else {
      return remote.requestImage(id: id, pixelSize: pixelSize, quality: quality, deliver: deliver)
    }

    // Manifest matches can outlive a deleted asset or an unavailable folder.
    let requests = OSAllocatedUnfairLock<[ImageRequestToken]?>(initialState: [])
    let add: @Sendable (ImageRequestToken) -> Void = { token in
      let cancelled = requests.withLock { tokens in
        tokens?.append(token)
        return tokens == nil
      }
      if cancelled { token.cancel() }
    }
    let requestRemote: @Sendable () -> Void = { [remote] in
      guard requests.withLock({ $0 != nil }) else { return }
      add(remote.requestImage(id: id, pixelSize: pixelSize, quality: quality, deliver: deliver))
    }
    let requestFile: @Sendable () -> Void = {
      guard requests.withLock({ $0 != nil }) else { return }
      guard let fileID else { return requestRemote() }
      add(
        FolderLibrary.shared.thumbnails.requestImage(
          id: fileID, pixelSize: pixelSize, quality: quality, onUnavailable: requestRemote, deliver: deliver))
    }
    if let assetID {
      DispatchQueue.global(qos: .userInitiated).async {
        guard requests.withLock({ $0 != nil }) else { return }
        add(
          PhotoKitImageSource.shared.requestImage(
            id: assetID, pixelSize: pixelSize, quality: quality, onUnavailable: requestFile, deliver: deliver))
      }
    } else {
      requestFile()
    }
    return ImageRequestToken {
      let tokens = requests.withLock { tokens in
        defer { tokens = nil }
        return tokens ?? []
      }
      for token in tokens { token.cancel() }
    }
  }

  func startCaching(ids: [String], pixelSize: CGSize) {
    for (source, ids) in groups(for: ids) where !ids.isEmpty {
      source.startCaching(ids: ids, pixelSize: pixelSize)
    }
  }

  func stopCaching(ids: [String], pixelSize: CGSize) {
    for (source, ids) in groups(for: ids) where !ids.isEmpty {
      source.stopCaching(ids: ids, pixelSize: pixelSize)
    }
  }

  private func groups(for ids: [String]) -> [(any ThumbnailSource, [String])] {
    let copies = localCopies
    var assetIDs: [String] = []
    var fileIDs: [String] = []
    var remoteIDs: [String] = []
    for id in ids {
      guard let key = RemoteThumbnailID(id)?.mediaKey else { continue }
      if let asset = copies.assets[key] {
        assetIDs.append(asset)
      } else if let file = copies.files[key] {
        fileIDs.append(file.id)
      } else {
        remoteIDs.append(id)
      }
    }
    return [(PhotoKitImageSource.shared, assetIDs), (FolderLibrary.shared.thumbnails, fileIDs), (remote, remoteIDs)]
  }
}
