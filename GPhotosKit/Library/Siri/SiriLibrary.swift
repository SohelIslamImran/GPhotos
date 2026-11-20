import AppIntents
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers
import os

/// The Library as Siri sees it. Entity lookups and search read the index database, so they
/// work while Siri runs the app without its window; opening something asks the app's window
/// to show it, and the app's root view carries the request out.
@MainActor
@Observable
public final class SiriLibrary {
  public static let shared = SiriLibrary()
  /// The activity the viewer advertises for the photo on screen.
  public nonisolated static let viewingActivityType = "org.gphotosapp.gphotos.viewing"

  /// The on-device index shared by the app's indexer, Spotlight and Siri: one connection
  /// to the database.
  public nonisolated let store = LibraryIndexStore()
  public nonisolated let spotlight: SiriSpotlightIndexer

  /// Where Siri asked to go.
  public enum Destination: Equatable, Sendable {
    /// An item by its index id, in the viewer.
    case item(String)
    case search(String)
    case person(Int64)
    case album(AlbumEntity.Reference)
  }

  /// The latest request, with a counter so asking for the same place twice still shows it.
  public private(set) var destination: (value: Destination, token: Int)?
  private var destinationToken = 0

  /// The browsed Google Photos account's library, set by the app.
  @ObservationIgnored public weak var cloud: CloudLibrary?
  /// Set by the app: reads the saved accounts, when Siri runs the app without its window
  /// and nothing has read them yet.
  @ObservationIgnored public var loadAccounts: (@MainActor () async -> Void)?
  /// Set by the app: the backed-up folders, for sharing their files when the Library
  /// hasn't opened them.
  @ObservationIgnored public var backedUpFolders: (@MainActor () -> [LibraryFolder])?
  @ObservationIgnored private var vocabulary: [String] = []
  @ObservationIgnored private var vocabularyLoadedAt = ContinuousClock.now

  private init() {
    spotlight = SiriSpotlightIndexer(store: store)
  }

  /// The browsed account's library, reading the saved accounts first when nothing has yet.
  public func browsedCloud() async -> CloudLibrary? {
    if cloud == nil, let loadAccounts { await loadAccounts() }
    return cloud
  }

  public func open(_ destination: Destination) {
    destinationToken &+= 1
    self.destination = (destination, destinationToken)
  }

  /// Clears a request the app has carried out.
  public func finish(token: Int) {
    if destination?.token == token { destination = nil }
  }

  // MARK: Search

  /// Index ids matching a spoken or typed request, best first: the index's matches for its
  /// words, narrowed to the period, kind and favorites it names. When no item has every
  /// word, items with the most of them come first.
  public func search(_ text: String, limit: Int = 200) async -> [String] {
    let query = SiriSearchQuery(text)
    guard !query.isEmpty else { return [] }
    // Indexing adds labels as it goes.
    if vocabulary.isEmpty || ContinuousClock.now - vocabularyLoadedAt > .seconds(60) {
      vocabulary = (try? await store.allLabels()) ?? []
      vocabularyLoadedAt = .now
    }
    let store = store
    let vocabulary = vocabulary
    var ids: [String]
    if query.terms.isEmpty {
      ids = []
    } else {
      // Spoken words are whole: no completing the last one as when typing.
      let people = ((try? await store.people(minimumFaces: 1)) ?? []).filter { $0.name != nil }
      ids = await LibraryIndexer.search(
        query.terms.joined(separator: " "), in: store, vocabulary: vocabulary, people: people, completingLastWord: false)
      if ids.isEmpty, query.terms.count > 1 {
        var perTerm: [[String]] = []
        for term in query.terms {
          perTerm.append(
            await LibraryIndexer.search(
              term, in: store, vocabulary: vocabulary, people: people, completingLastWord: false))
        }
        ids = Self.rankedByMatches(perTerm)
      }
    }
    return await Self.filter(ids, by: query, in: store, limit: limit)
  }

  /// Ids found by several searches, those found most often first, then in the order found.
  nonisolated static func rankedByMatches(_ results: [[String]]) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for ids in results {
      var seen = Set<String>()
      for id in ids where seen.insert(id).inserted {
        if counts[id] == nil { order.append(id) }
        counts[id, default: 0] += 1
      }
    }
    let first = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return order.sorted { (counts[$0] ?? 0, -(first[$0] ?? 0)) > (counts[$1] ?? 0, -(first[$1] ?? 0)) }
  }

  private nonisolated static func filter(
    _ ids: [String], by query: SiriSearchQuery, in store: LibraryIndexStore, limit: Int
  ) async -> [String] {
    // Only a period, a kind or favorites: the newest that match, filtered in the query.
    if query.terms.isEmpty {
      return
        (try? await store.siriIDs(
          period: query.period, videosOnly: query.videosOnly, favoritesOnly: query.favoritesOnly, limit: limit)) ?? []
    }
    guard query.period != nil || query.videosOnly || query.favoritesOnly else { return Array(ids.prefix(limit)) }
    // Matches keep their order; each is checked against its record until enough are kept.
    var kept: [String] = []
    for start in stride(from: 0, to: ids.count, by: 500) where kept.count < limit {
      let chunk = Array(ids[start..<min(start + 500, ids.count)])
      let records = (try? await store.siriRecords(ids: chunk)) ?? []
      kept += records.filter { record in
        (!query.videosOnly || record.isVideo) && (!query.favoritesOnly || record.isFavorite)
          && query.period.map { period in record.date.map(period.contains) ?? false } ?? true
      }.map(\.id)
    }
    return Array(kept.prefix(limit))
  }

  /// Tells Siri about a search the user made in the app.
  public static func donateSearch(_ text: String) {
    let intent = SearchLibraryIntent(term: text)
    Task.detached(priority: .utility) { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
  }

  // MARK: Files and images

  /// The item's file, for sharing it through Siri: the device's current version, a Google
  /// Photos download, or the folder file itself.
  public func exportFile(id: String) async throws -> URL {
    if id.hasPrefix(FolderItemInfo.idPrefix) {
      let url = URL(fileURLWithPath: String(id.dropFirst(FolderItemInfo.idPrefix.count)))
      // Without the Library open, nothing holds the folders' access yet: take it as the
      // Library does (it's given back when the folder is no longer backed up).
      if !FileManager.default.isReadableFile(atPath: url.path), let folders = backedUpFolders?() {
        FolderLibrary.shared.setFolders(folders)
      }
      guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
      return url
    }
    if id.hasPrefix("g:") {
      guard let cloud = await browsedCloud(), let item = await cloud.summary(mediaKey: String(id.dropFirst(2))) else {
        throw CocoaError(.fileNoSuchFile)
      }
      return try await cloud.download(item)
    }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try await SharedAsset(asset).export()
  }

  /// A small JPEG of the item for Siri's results: from the device's local thumbnails or the
  /// Google Photos thumbnail cache, never a download of the original.
  public func thumbnailData(id: String, side: CGFloat = 240) async -> Data? {
    let image: CGImage?
    if id.hasPrefix("g:") {
      guard let cloud = await browsedCloud(), let item = await cloud.summary(mediaKey: String(id.dropFirst(2))) else {
        return nil
      }
      image = await Self.image(from: cloud.thumbnails, id: item.thumbnailID, side: side)
    } else if id.hasPrefix(FolderItemInfo.idPrefix) {
      image = nil
    } else {
      guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
      image = await LibraryIndexer.thumbnail(asset: asset)
    }
    guard let image else { return nil }
    return await Task.detached(priority: .utility) { Self.jpeg(image, side: side) }.value
  }

  private nonisolated static func image(from source: any ThumbnailSource, id: String, side: CGFloat) async -> CGImage? {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { continuation in
      _ = source.requestImage(id: id, pixelSize: CGSize(width: side, height: side), quality: .thumbnail) { image, isFinal in
        guard isFinal,
          resumed.withLock({ state in
            defer { state = true }
            return !state
          })
        else { return }
        continuation.resume(returning: image)
      }
    }
  }

  nonisolated static func jpeg(_ image: CGImage, side: CGFloat) -> Data? {
    let scale = min(1, side / CGFloat(max(image.width, image.height)))
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}
