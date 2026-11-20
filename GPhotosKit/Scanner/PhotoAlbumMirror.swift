import Foundation

// PhotoKit's album model is only consulted by the iOS app; macOS derives album names
// from folders instead. Guarded so the macOS framework does not carry dead code.
#if os(iOS)
  import Photos

  /// Which albums in the photo library to mirror into Google Photos.
  ///
  /// Only user-created collections are mirrored. PhotoKit's smart albums (Recents,
  /// Favorites, Panoramas, Slomo, Screenshots, and so on) describe properties of an
  /// asset rather than a decision the user made about grouping, every asset falls into
  /// several of them, and Google Photos already builds its own equivalents — mirroring
  /// them would scatter the library into albums nobody asked for.
  public enum PhotoAlbumMirror {

    /// Resolves a Google Photos album name for every asset identifier in the library.
    ///
    /// The result is built once per scan rather than per asset, because walking album
    /// membership asset-by-asset is quadratic on a large library.
    ///
    /// Names that differ only by case or surrounding whitespace are treated as one
    /// album: "Travel" and "travel" are the same intent to a person, and splitting them
    /// would leave two near-identical albums in the cloud.
    public struct Mapping: Sendable {
      /// Asset local identifier to the album names it belongs to, deduplicated.
      private let albumsByAsset: [String: [String]]

      public init(albumsByAsset: [String: [String]]) {
        self.albumsByAsset = albumsByAsset
      }

      public func albumNames(forAssetIdentifier identifier: String) -> [String] {
        albumsByAsset[identifier] ?? []
      }

      public var isEmpty: Bool { albumsByAsset.isEmpty }
    }

    public static func buildMapping() -> Mapping {
      let collections = PHAssetCollection.fetchAssetCollections(
        with: .album,
        subtype: .any,
        options: PHFetchOptions()
      )

      var canonicalNames: [String: String] = [:]
      var albumsByAsset: [String: [String]] = [:]

      collections.enumerateObjects { collection, _, stop in
        guard !Task.isCancelled else {
          stop.pointee = true
          return
        }
        // Shared Albums and the photo stream are system-created under the album type but
        // are not groupings anybody made, so they are not mirrored.
        guard
          collection.assetCollectionSubtype == .albumRegular
            || collection.assetCollectionSubtype == .albumImported
        else { return }
        guard collection.canContainAssets, collection.estimatedAssetCount > 0 else { return }
        let trimmed = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        // First album to claim a given name wins, so a library holding both "Travel"
        // and "travel" mirrors to whichever the system listed first.
        let key = trimmed.lowercased()
        let canonical: String
        if let existing = canonicalNames[key] {
          canonical = existing
        } else {
          canonicalNames[key] = trimmed
          canonical = trimmed
        }

        // `PHAssetCollection` has no fetch of its own; membership comes from the asset
        // side of the relation.
        let members = PHAsset.fetchAssets(in: collection, options: nil)
        guard members.count > 0 else { return }
        members.enumerateObjects { asset, _, stop in
          guard !Task.isCancelled else {
            stop.pointee = true
            return
          }
          albumsByAsset[asset.localIdentifier, default: []].append(canonical)
        }
      }

      return Mapping(albumsByAsset: albumsByAsset)
    }
  }
#endif
