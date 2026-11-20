import LocalAuthentication
import Photos
import SwiftUI

/// Where Collections navigates.
public enum CollectionRoute: Hashable {
  case scope(LibraryScope, LibraryFilter)
  case albums
  case places
  case place(ids: ItemIDs, latitude: Double, longitude: Double)
  case cloud(RemoteScope)
  case cloudAlbums
}

/// Collections, as in Photos: pinned collections, albums, media types and utilities.
/// Put it in a `NavigationStack`.
public struct CollectionsView: View {
  let records: [TransferRecord]
  let recordsRevision: Int?
  let cloud: CloudLibrary?
  @State private var collections: PhotoCollectionsModel
  @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

  /// `collections` lets a host that lists albums elsewhere (the Mac's sidebar) share one
  /// model with this screen.
  public init(
    records: [TransferRecord], recordsRevision: Int?, cloud: CloudLibrary? = nil,
    collections: PhotoCollectionsModel? = nil
  ) {
    self.records = records
    self.recordsRevision = recordsRevision
    self.cloud = cloud
    _collections = State(initialValue: collections ?? PhotoCollectionsModel())
  }

  public var body: some View {
    Group {
      if hasPhotoAccess || showsGalleryWithoutAccess {
        #if os(macOS)
          gallery
        #else
          list
        #endif
      } else {
        ContentUnavailableView {
          Label("Allow Photo Access", systemImage: "photo.badge.exclamationmark")
        } description: {
          Text("Allow access to see your albums here.")
        } actions: {
          Button("Allow Access") {
            Task {
              status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
              await collections.load()
            }
          }
          .buttonStyle(.glassProminent)
        }
      }
    }
    .navigationTitle("Collections")
    .collectionDestinations(records: records, recordsRevision: recordsRevision, cloud: cloud, collections: collections)
    .task {
      cloud?.refresh()
      await collections.load()
    }
  }

  private var hasPhotoAccess: Bool { status == .authorized || status == .limited }

  /// On the Mac, Google Photos still shows without access to this Mac's library.
  private var showsGalleryWithoutAccess: Bool {
    #if os(macOS)
      cloud != nil
    #else
      false
    #endif
  }

  #if os(macOS)
    private var accessBanner: some View {
      HStack(spacing: 12) {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.title2)
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text("Allow Photo Access").font(.headline)
          Text("Allow access to see this Mac’s albums here.").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Allow Access") {
          Task {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await collections.load()
          }
        }
      }
      .padding(16)
      .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
    }

    /// The Mac's Collections: a page of tiles and rows, as in Photos and Music on the Mac,
    /// rather than the iPhone's grouped list.
    private var gallery: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 32) {
          if !hasPhotoAccess { accessBanner }
          if hasPhotoAccess { deviceSections }
          if let cloud { CloudCollectionsGallery(library: cloud) }
          if hasPhotoAccess { utilitySections }
        }
        .galleryPage()
      }
    }

    @ViewBuilder private var deviceSections: some View {
      GallerySection("Pinned") {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)], spacing: 14) {
          ForEach(pinned, id: \.title) { pin in
            PinnedTile(
              title: Text(pin.title), symbol: pin.symbol, keyAssetID: pin.keyAssetID, route: pin.route, side: nil)
          }
        }
      }

      GallerySection("Albums") {
        if collections.albums.count > Self.albumPreviewCount {
          NavigationLink("Show All", value: CollectionRoute.albums)
        }
      } content: {
        if collections.albums.isEmpty {
          Text(collections.isLoaded ? "No albums yet." : "Loading…")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
        } else {
          LazyVGrid(columns: galleryCoverColumns, spacing: 20) {
            ForEach(collections.albums.prefix(Self.albumPreviewCount)) { album in
              NavigationLink(value: CollectionRoute.scope(.album(id: album.id, title: album.title), .all)) {
                GalleryCover(title: album.title, count: album.count, thumbnailID: album.keyAssetID)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

    }

    @ViewBuilder private var utilitySections: some View {
      if !mediaKinds.isEmpty {
        GallerySection("Media Types") {
          LazyVGrid(columns: galleryRowColumns, spacing: 10) {
            ForEach(mediaKinds) { summary in
              NavigationLink(value: CollectionRoute.scope(.mediaKind(summary.kind), .all)) {
                GalleryRow(title: summary.kind.title, symbol: summary.kind.symbol, count: summary.count)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      GallerySection("Utilities") {
        LazyVGrid(columns: galleryRowColumns, spacing: 10) {
          NavigationLink(value: CollectionRoute.scope(.all, .notBackedUp)) {
            GalleryRow(title: String(localized: "Not Backed Up"), symbol: "icloud.slash", tint: .orange)
          }
          NavigationLink(value: CollectionRoute.scope(.all, .backedUp)) {
            GalleryRow(title: String(localized: "Backed Up"), symbol: "checkmark.icloud", tint: .green)
          }
          NavigationLink(value: CollectionRoute.scope(.recentlyAdded, .all)) {
            GalleryRow(title: String(localized: "Recently Added"), symbol: "clock")
          }
          NavigationLink(value: CollectionRoute.scope(.hidden, .all)) {
            GalleryRow(title: String(localized: "Hidden"), symbol: "eye.slash", tint: .secondary)
          }
        }
        .buttonStyle(.plain)
      }

      if collections.isLoaded {
        Text("\(collections.photoCount.formatted()) Photos, \(collections.videoCount.formatted()) Videos")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
    }

    private static let albumPreviewCount = 12

    private var pinned: [(title: String, symbol: String, keyAssetID: String?, route: CollectionRoute)] {
      [
        (
          String(localized: "Favorites"), "heart.fill", collections.summary(for: .favorites)?.keyAssetID,
          .scope(.mediaKind(.favorites), .all)
        ),
        (
          String(localized: "Recently Added"), "clock.fill", collections.recentlyAddedKeyID,
          .scope(.recentlyAdded, .all)
        ),
        (
          String(localized: "Videos"), "video.fill", collections.summary(for: .videos)?.keyAssetID,
          .scope(.mediaKind(.videos), .all)
        ),
        (String(localized: "Places"), "map.fill", nil, .places),
        (String(localized: "Not Backed Up"), "icloud.slash.fill", nil, .scope(.all, .notBackedUp)),
        (String(localized: "Hidden"), "eye.slash.fill", nil, .scope(.hidden, .all)),
      ]
    }
  #endif

  private var list: some View {
    List {
      // As in Photos: pinned collections as a row of square tiles.
      Section {
        ScrollView(.horizontal) {
          LazyHStack(spacing: 10) {
            PinnedTile(
              title: Text("Favorites"), symbol: "heart.fill",
              keyAssetID: collections.summary(for: .favorites)?.keyAssetID,
              route: .scope(.mediaKind(.favorites), .all))
            PinnedTile(
              title: Text("Recently Added"), symbol: "clock.fill", keyAssetID: collections.recentlyAddedKeyID,
              route: .scope(.recentlyAdded, .all))
            PinnedTile(
              title: Text("Videos"), symbol: "video.fill", keyAssetID: collections.summary(for: .videos)?.keyAssetID,
              route: .scope(.mediaKind(.videos), .all))
            PinnedTile(title: Text("Places"), symbol: "map.fill", keyAssetID: nil, route: .places)
            PinnedTile(
              title: Text("Not Backed Up"), symbol: "icloud.slash.fill", keyAssetID: nil, route: .scope(.all, .notBackedUp))
            PinnedTile(title: Text("Hidden"), symbol: "eye.slash.fill", keyAssetID: nil, route: .scope(.hidden, .all))
          }
          .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      } header: {
        Text("Pinned")
      }

      Section {
        if collections.albums.isEmpty {
          Text(collections.isLoaded ? "No albums yet." : "Loading…").foregroundStyle(.secondary)
        } else {
          ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
              ForEach(collections.albums.prefix(20)) { album in
                PinnedTile(
                  title: Text(album.title), keyAssetID: album.keyAssetID,
                  route: .scope(.album(id: album.id, title: album.title), .all))
              }
            }
            .scrollTargetLayout()
          }
          .scrollIndicators(.hidden)
          .scrollTargetBehavior(.viewAligned)
          .contentMargins(.horizontal, 20, for: .scrollContent)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      } header: {
        HStack {
          Text("Albums")
          Spacer()
          NavigationLink("See All", value: CollectionRoute.albums).font(.subheadline)
        }
      }

      if let cloud { CloudCollectionsSection(library: cloud) }

      if !mediaKinds.isEmpty {
        Section("Media Types") {
          ForEach(mediaKinds) { summary in
            NavigationLink(value: CollectionRoute.scope(.mediaKind(summary.kind), .all)) {
              CountRow(title: summary.kind.title, symbol: summary.kind.symbol, count: summary.count)
            }
          }
        }
      }

      Section("Utilities") {
        NavigationLink(value: CollectionRoute.scope(.all, .notBackedUp)) {
          Label("Not Backed Up", systemImage: "icloud.slash")
        }
        NavigationLink(value: CollectionRoute.scope(.all, .backedUp)) {
          Label("Backed Up", systemImage: "checkmark.icloud")
        }
        NavigationLink(value: CollectionRoute.scope(.recentlyAdded, .all)) {
          Label("Recently Added", systemImage: "clock")
        }
        NavigationLink(value: CollectionRoute.scope(.hidden, .all)) {
          Label("Hidden", systemImage: "eye.slash")
        }
      }

      if collections.isLoaded {
        Section {
        } footer: {
          Text("\(collections.photoCount.formatted()) Photos, \(collections.videoCount.formatted()) Videos")
            .frame(maxWidth: .infinity)
        }
      }
    }
    #if os(iOS)
      .listStyle(.insetGrouped)
      // Shelf titles, as in Photos.
      .headerProminence(.increased)
    #else
      .listStyle(.inset)
    #endif
  }

  /// Favorites and Videos are pinned, so they aren't repeated here.
  private var mediaKinds: [MediaKindSummary] {
    collections.mediaKinds.filter { $0.kind != .favorites && $0.kind != .videos }
  }
}

/// A square tile, as in Photos' Pinned row: the collection's photo (or a neutral fill)
/// with its name in the corner. With no `side` it fills its grid cell (Mac).
private struct PinnedTile: View {
  let title: Text
  var symbol: String?
  let keyAssetID: String?
  let route: CollectionRoute
  var side: CGFloat? = 127

  var body: some View {
    NavigationLink(value: route) {
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .frame(width: side, height: side)
        .overlay {
          ZStack(alignment: .bottomLeading) {
            if let keyAssetID {
              LibraryThumbnail(id: keyAssetID, bucket: .medium)
              LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            } else {
              // Color belongs to icons; a tile with no photo stays neutral.
              Rectangle().fill(.fill.tertiary)
            }
            if let symbol {
              Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(foreground)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            title
              .font(.subheadline.weight(.semibold))
              .lineLimit(2)
              .foregroundStyle(foreground)
              .padding(10)
          }
        }
        .clipShape(.rect(cornerRadius: side == nil ? 14 : 18, style: .continuous))
        .contentShape(.rect(cornerRadius: 18))
        #if os(macOS)
          .hoverLift()
        #endif
    }
    .buttonStyle(.plain)
    .navigationLinkIndicatorVisibility(.hidden)
  }

  private var foreground: AnyShapeStyle {
    keyAssetID == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)
  }
}

/// Where a collection route leads. Collections pushes these; the Mac's sidebar also opens
/// them directly.
public struct CollectionRouteView: View {
  let route: CollectionRoute
  let records: [TransferRecord]
  let recordsRevision: Int?
  let cloud: CloudLibrary?
  let collections: PhotoCollectionsModel

  public init(
    route: CollectionRoute, records: [TransferRecord], recordsRevision: Int?, cloud: CloudLibrary?,
    collections: PhotoCollectionsModel
  ) {
    self.route = route
    self.records = records
    self.recordsRevision = recordsRevision
    self.cloud = cloud
    self.collections = collections
  }

  public var body: some View {
    switch route {
    case .scope(let scope, let filter):
      LibraryCollectionScreen(scope: scope, filter: filter, records: records, recordsRevision: recordsRevision, cloud: cloud)
    case .albums:
      AlbumsGridView(collections: collections)
        .task { if !collections.isLoaded { await collections.load() } }
    case .places:
      PlacesView(cloud: cloud, records: records)
    case .place(let ids, let latitude, let longitude):
      PlaceLibraryScreen(ids: ids.values, latitude: latitude, longitude: longitude)
    case .cloud(let scope):
      if let cloud {
        CloudLibraryView(library: cloud, scope: scope, records: records, recordsRevision: recordsRevision)
      }
    case .cloudAlbums:
      if let cloud { GoogleAlbumsView(library: cloud) }
    }
  }
}

extension View {
  /// Pushes collection routes inside the enclosing `NavigationStack`.
  public func collectionDestinations(
    records: [TransferRecord], recordsRevision: Int?, cloud: CloudLibrary?, collections: PhotoCollectionsModel
  ) -> some View {
    navigationDestination(for: CollectionRoute.self) { route in
      CollectionRouteView(
        route: route, records: records, recordsRevision: recordsRevision, cloud: cloud, collections: collections
      )
      #if os(iOS)
        // Every screen under Collections titles itself as Collections does.
        .toolbarTitleDisplayMode(.inlineLarge)
      #endif
    }
  }
}

struct AlbumCard: View {
  let album: AlbumSummary
  let side: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LibraryThumbnail(id: album.keyAssetID, bucket: .medium)
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 12))
      Text(album.title).font(.subheadline).lineLimit(1)
      Text(album.count, format: .number).font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: side)
    .accessibilityElement(children: .combine)
  }
}

private struct CountRow: View {
  let title: String
  let symbol: String
  let count: Int

  var body: some View {
    LabeledContent {
      Text(count, format: .number)
    } label: {
      Label(title, systemImage: symbol)
    }
  }
}

/// Every album, with a button to make a new one.
struct AlbumsGridView: View {
  let collections: PhotoCollectionsModel
  @State private var isNaming = false
  @State private var newTitle = ""

  var body: some View {
    ScrollView {
      #if os(macOS)
        LazyVGrid(columns: galleryCoverColumns, spacing: 20) {
          ForEach(collections.albums) { album in
            NavigationLink(value: CollectionRoute.scope(.album(id: album.id, title: album.title), .all)) {
              GalleryCover(title: album.title, count: album.count, thumbnailID: album.keyAssetID)
            }
            .buttonStyle(.plain)
          }
        }
        .galleryPage()
      #else
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
          ForEach(collections.albums) { album in
            NavigationLink(value: CollectionRoute.scope(.album(id: album.id, title: album.title), .all)) {
              AlbumCard(album: album, side: 150)
            }
            .buttonStyle(.plain)
          }
        }
        .padding()
      #endif
    }
    .overlay {
      if collections.isLoaded, collections.albums.isEmpty {
        ContentUnavailableView("No Albums", systemImage: "rectangle.stack", description: Text("Albums you make appear here."))
      }
    }
    .navigationTitle("Albums")
    .toolbar {
      Button {
        newTitle = ""
        isNaming = true
      } label: {
        Label("New Album", systemImage: "plus")
      }
    }
    .alert("New Album", isPresented: $isNaming) {
      TextField("Title", text: $newTitle)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { try? await LibraryActions.createAlbum(titled: title, with: []) }
      }
    } message: {
      Text("Enter a name for this album.")
    }
  }
}

/// One collection as a full library grid. Hidden items need Face ID, Touch ID or the
/// device passcode first, as in Photos.
public struct LibraryCollectionScreen: View {
  let cloud: CloudLibrary?
  let records: [TransferRecord]
  let recordsRevision: Int?
  @State private var model: PhotoLibraryGridModel
  @State private var isUnlocked: Bool

  public init(
    scope: LibraryScope, filter: LibraryFilter = .all, records: [TransferRecord], recordsRevision: Int?, cloud: CloudLibrary? = nil
  ) {
    self.cloud = cloud
    self.records = records
    self.recordsRevision = recordsRevision
    _model = State(initialValue: PhotoLibraryGridModel(scope: scope, filter: filter))
    _isUnlocked = State(initialValue: scope != .hidden)
  }

  public var body: some View {
    if isUnlocked {
      LibraryView(
        model: model, records: records, recordsRevision: recordsRevision,
        title: model.filter == .all ? nil : model.filter.title, cloud: cloud)
    } else {
      ContentUnavailableView {
        Label("Hidden Is Locked", systemImage: "lock.fill")
      } description: {
        Text("Unlock to see your hidden photos and videos.")
      } actions: {
        Button("View Hidden") { Task { await unlock() } }
          .buttonStyle(.glassProminent)
      }
      .navigationTitle("Hidden")
      .task { await unlock() }
    }
  }

  private func unlock() async {
    let context = LAContext()
    let reason = String(localized: "Unlock to see your hidden photos and videos.")
    if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
      isUnlocked = true
    }
  }
}
