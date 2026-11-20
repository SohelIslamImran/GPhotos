import CoreTransferable
import Foundation
import Photos
import UniformTypeIdentifiers

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Changes to the photo library that the user asks for from the browser. Deletion goes
/// through one `deleteAssets` call after the browser's own confirmation, and the system
/// shows its prompt too.
public enum LibraryActions {
  /// Favorites all of them, or unfavorites all of them if they're all favorites already.
  public static func toggleFavorite(_ assets: [PHAsset]) async throws {
    guard !assets.isEmpty else { return }
    let favorite = !assets.allSatisfy(\.isFavorite)
    try await PHPhotoLibrary.shared().performChanges {
      for asset in assets where asset.canPerform(.properties) {
        PHAssetChangeRequest(for: asset).isFavorite = favorite
      }
    }
  }

  public static func setHidden(_ assets: [PHAsset], hidden: Bool) async throws {
    guard !assets.isEmpty else { return }
    try await PHPhotoLibrary.shared().performChanges {
      for asset in assets where asset.canPerform(.properties) {
        PHAssetChangeRequest(for: asset).isHidden = hidden
      }
    }
  }

  public static func delete(_ assets: [PHAsset]) async throws {
    let deletable = assets.filter { $0.canPerform(.delete) }
    guard !deletable.isEmpty else { return }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.deleteAssets(deletable as NSArray)
    }
  }

  public static func add(_ assets: [PHAsset], toAlbum id: String) async throws {
    guard
      !assets.isEmpty,
      let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    else { return }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
    }
  }

  public static func remove(_ assets: [PHAsset], fromAlbum id: String) async throws {
    guard
      !assets.isEmpty,
      let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    else { return }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
    }
  }

  /// Puts a photo on the pasteboard, as Copy in Photos does (current version, from
  /// iCloud if needed).
  public static func copy(_ asset: PHAsset) async throws {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current
    let (data, type) = await withCheckedContinuation { continuation in
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, _, _ in
        continuation.resume(returning: (data, type))
      }
    }
    guard let data, let type else { throw CocoaError(.fileReadNoSuchFile) }
    await MainActor.run {
      #if os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: type)
      #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type))
      #endif
    }
  }

  public static func createAlbum(titled title: String, with assets: [PHAsset]) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
      if !assets.isEmpty { request.addAssets(assets as NSArray) }
    }
  }
}

/// An asset for the share sheet and drag and drop. The file (the edited version when there
/// is one) is only written when a destination asks for it.
public struct SharedAsset: Transferable, Sendable {
  public let asset: PHAsset

  public init(_ asset: PHAsset) {
    self.asset = asset
  }

  public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .movie) { item in SentTransferredFile(try await item.export()) }
      .exportingCondition { $0.asset.mediaType == .video }
    FileRepresentation(exportedContentType: .image) { item in SentTransferredFile(try await item.export()) }
      .exportingCondition { $0.asset.mediaType != .video }
  }

  /// Writes the current version of the asset to a new temporary folder.
  public func export() async throws -> URL {
    let resources = PHAssetResource.assetResources(for: asset)
    let preferred: [PHAssetResourceType] =
      asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
    guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first
    else { throw CocoaError(.fileNoSuchFile) }
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "Shared", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: Self.filename(of: resource))
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    return url
  }

  static func filename(of resource: PHAssetResource) -> String {
    let name = resource.filenameOrEmpty
    return name.isEmpty ? "Photo" : name
  }
}
