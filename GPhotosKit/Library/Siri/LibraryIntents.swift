import AppIntents
import Foundation
import Photos

/// "Search GPhotos for beach sunsets": the Search tab with Siri's words.
@AppIntent(schema: .system.searchInApp)
public struct SearchLibraryIntent: ShowInAppSearchResultsIntent {
  public static let searchScopes: [StringSearchScope] = [.general]
  public var criteria: StringSearchCriteria

  public init() {}

  public init(term: String) {
    criteria = StringSearchCriteria(term: term)
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
    SiriLibrary.shared.open(.search(criteria.term))
    return .result()
  }
}

/// Opens a photo or video in the viewer; Spotlight and Siri run it when a result is tapped.
@AppIntent(schema: .system.open)
public struct OpenPhotoIntent: OpenIntent {
  public var target: PhotoEntity

  public init() {}

  public init(target: PhotoEntity) {
    self.target = target
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
    SiriLibrary.shared.open(.item(target.id))
    return .result()
  }
}

/// Opens a person's photos.
@AppIntent(schema: .system.open)
public struct OpenPersonIntent: OpenIntent {
  public var target: PersonEntity

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult {
    guard let person = target.personID else { throw SiriLibraryError.notFound }
    SiriLibrary.shared.open(.person(person))
    return .result()
  }
}

/// Opens an album on this device or in Google Photos.
@AppIntent(schema: .photos.openAlbum)
public struct OpenAlbumIntent: OpenIntent {
  public var target: AlbumEntity

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult {
    guard let reference = target.reference else { throw SiriLibraryError.notFound }
    SiriLibrary.shared.open(.album(reference))
    return .result()
  }
}

/// "Find photos of the dog at the beach": the matching items, newest first, for Siri to
/// show, share or hand to another action. Runs without opening the app.
public struct FindPhotosIntent: AppIntent {
  public static let title: LocalizedStringResource = "Find Photos"
  public static let description = IntentDescription(
    "Finds photos and videos by what's in them, the text in them, people, places and dates, on this device and in Google Photos.",
    categoryName: "Library")
  public static let supportedModes: IntentModes = .background

  @Parameter(title: "Search For", requestValueDialog: "What should I look for?")
  public var query: String

  @Parameter(title: "Limit", default: 24, inclusiveRange: (1, 200))
  public var limit: Int

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Find photos of \(\.$query)") {
      \.$limit
    }
  }

  @MainActor
  public func perform() async throws -> some IntentResult & ReturnsValue<[PhotoEntity]> & ProvidesDialog {
    let ids = await SiriLibrary.shared.search(query, limit: limit)
    let entities = try await PhotoEntityQuery().entities(for: ids)
    let dialog: IntentDialog =
      entities.isEmpty
      ? "No photos match “\(query)”." : "Found ^[\(entities.count) item](inflect: true) for “\(query)”."
    return .result(value: entities, dialog: dialog)
  }
}

/// "Add these to my Trip album": device photos go into a device album, Google Photos items
/// into an album in the browsed account. Nothing is removed or moved.
@AppIntent(schema: .photos.addAssetsToAlbum)
public struct AddPhotosToAlbumIntent: AppIntent {
  public var assets: [PhotoEntity]
  public var album: AlbumEntity

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let reference = album.reference else { throw SiriLibraryError.notFound }
    let added: Int
    switch reference {
    case .device(let localIdentifier, _):
      let ids = assets.map(\.id).filter { !$0.hasPrefix("g:") && !$0.hasPrefix(FolderItemInfo.idPrefix) }
      var found: [PHAsset] = []
      PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in found.append(asset) }
      if !found.isEmpty { try await LibraryActions.add(found, toAlbum: localIdentifier) }
      added = found.count
    case .google(let mediaKey, _):
      guard let cloud = await SiriLibrary.shared.browsedCloud(),
        !cloud.isRetired,
        let target = await cloud.albums().first(where: { $0.mediaKey == mediaKey })
      else { throw SiriLibraryError.signedOut }
      var items: [RemoteItemSummary] = []
      for id in assets.map(\.id) where id.hasPrefix("g:") {
        let key = String(id.dropFirst(2))
        guard let item = await cloud.summary(mediaKey: key) else { continue }
        items.append(item)
      }
      if !items.isEmpty {
        // A change in the Google Photos account: asked first, with the count.
        try await requestConfirmation(
          actionName: .add,
          dialog: "Add ^[\(items.count) item](inflect: true) to \(album.name) in Google Photos (\(cloud.accountEmail))?")
        // The browsed account may have changed while Siri asked.
        guard SiriLibrary.shared.cloud === cloud else { throw SiriLibraryError.signedOut }
        try await cloud.add(items, toAlbum: target)
      }
      added = items.count
    }
    let skipped = assets.count - added
    let dialog: IntentDialog =
      skipped == 0
      ? "Added ^[\(added) item](inflect: true) to \(album.name)."
      : "Added ^[\(added) item](inflect: true) to \(album.name). ^[\(skipped) item](inflect: true) can't go in this album."
    return .result(dialog: dialog)
  }
}

public enum SiriLibraryError: Error, CustomLocalizedStringResourceConvertible {
  case notFound
  case signedOut

  public var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notFound: "That item isn't in your Library anymore."
    case .signedOut: "Open GPhotos and sign in to Google Photos to use this."
    }
  }
}

/// Registers this framework's entities and intents with each app.
public struct GPhotosKitIntents: AppIntentsPackage {}
