import LocalAuthentication
import Photos
import SwiftUI

/// Where Collections navigates.
public enum CollectionRoute: Hashable, Sendable {
  case scope(LibraryScope, LibraryFilter)
  case libraryFilter(LibraryFilter)
  case albums
  case places
  case place(ids: ItemIDs, latitude: Double, longitude: Double)
  case cloud(RemoteScope)
  case cloudAlbums
  /// The Google Photos Locked Folder, listed only when the account has items in it.
  case cloudLocked

  public var mergedLibraryFilter: LibraryFilter? {
    guard case .libraryFilter(let filter) = self else { return nil }
    return filter
  }

  static let backupUtilities: [Self] = [.libraryFilter(.notBackedUp), .libraryFilter(.backedUp), .libraryFilter(.notIncludedInBackup)]
}

extension EnvironmentValues {
  @Entry public var showLibraryFilter: ShowLibraryFilterAction?
}

public struct ShowLibraryFilterAction {
  private let action: @MainActor (LibraryFilter) -> Void

  public init(_ action: @escaping @MainActor (LibraryFilter) -> Void) {
    self.action = action
  }

  @MainActor public func callAsFunction(_ filter: LibraryFilter) {
    action(filter)
  }
}

/// Collections, as in Photos: pinned collections, albums, media types and utilities.
/// Put it in a `NavigationStack`.
public struct CollectionsView: View {
  let records: [TransferRecord]
  let recordsRevision: Int?
  let cloud: CloudLibrary?
  let accountsLoaded: Bool
  @State private var collections: PhotoCollectionsModel
  @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  @State private var canShowSections = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `collections` lets a host that lists albums elsewhere (the Mac's sidebar) share one
  /// model with this screen; otherwise it's `PhotoCollectionsModel.shared`, which the app
  /// loads at launch so the screen's first frame is already complete.
  public init(
    records: [TransferRecord], recordsRevision: Int?, cloud: CloudLibrary? = nil,
    accountsLoaded: Bool, collections: PhotoCollectionsModel? = nil
  ) {
    self.records = records
    self.recordsRevision = recordsRevision
    self.cloud = cloud
    self.accountsLoaded = accountsLoaded
    _collections = State(initialValue: collections ?? .shared)
  }

  public var body: some View {
    Group {
      if showsSections {
        #if os(macOS)
          gallery
        #else
          list
        #endif
      } else {
        #if os(macOS)
          Color.clear
        #else
          List {}.listStyle(.insetGrouped)
        #endif
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsSections)
    .navigationTitle("Collections")
    .collectionDestinations(records: records, recordsRevision: recordsRevision, cloud: cloud, collections: collections)
    .task(id: cloud?.accountEmail) { cloud?.refresh() }
    .task {
      // Its change observer keeps a loaded model current.
      await collections.loadIfNeeded()
    }
    .task(id: sectionsAreReady) {
      guard let delay = Self.sectionRevealDelay(ready: sectionsAreReady, hasShown: canShowSections) else { return }
      // Give cached sections one short chance to arrive together, without waiting on a slow read.
      if delay > .zero {
        do { try await Task.sleep(for: delay) } catch { return }
      }
      guard !Task.isCancelled else { return }
      canShowSections = true
    }
  }

  nonisolated static func sectionRevealDelay(ready: Bool, hasShown: Bool) -> Duration? {
    if hasShown { return nil }
    return ready ? .zero : .milliseconds(250)
  }

  private var hasPhotoAccess: Bool { status == .authorized || status == .limited }
  private var showsSections: Bool { canShowSections || sectionsAreReady }

  private var sectionsAreReady: Bool {
    accountsLoaded && (!hasPhotoAccess || collections.isLoaded) && cloud?.isStateLoaded != false
  }

  private func requestPhotoAccess() {
    Task {
      status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      await collections.load()
    }
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
        Button("Allow Access", action: requestPhotoAccess)
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
          utilitySections
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
        if !collections.isLoaded {
          LazyVGrid(columns: galleryCoverColumns) {
            GalleryCover(title: "", count: 0, thumbnailID: nil).hidden()
          }
        } else if collections.albums.isEmpty {
          Text("No albums yet.")
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
      if hasPhotoAccess, !mediaKinds.isEmpty {
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 10)], spacing: 10) {
          ForEach(CollectionRoute.backupUtilities, id: \.self) { route in
            if let filter = route.mergedLibraryFilter {
              CollectionLink(route: route) {
                GalleryRow(title: filter.title, symbol: filter.symbol, tint: backupTint(for: filter))
              }
            }
          }
          if hasPhotoAccess {
            NavigationLink(value: CollectionRoute.scope(.recentlyAdded, .all)) {
              GalleryRow(title: String(localized: "Recently Added"), symbol: "clock")
            }
            NavigationLink(value: CollectionRoute.scope(.hidden, .all)) {
              GalleryRow(title: String(localized: "Hidden"), symbol: "eye.slash", tint: .secondary)
            }
          }
        }
        .buttonStyle(.plain)
      }

      if hasPhotoAccess, collections.isLoaded {
        Text("\(collections.photoCount.formatted()) Photos, \(collections.videoCount.formatted()) Videos")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
    }

    private func backupTint(for filter: LibraryFilter) -> Color {
      switch filter {
      case .notBackedUp: .orange
      case .backedUp: .green
      default: .secondary
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
        (String(localized: "Not Backed Up"), "icloud.slash.fill", nil, .libraryFilter(.notBackedUp)),
        (String(localized: "Hidden"), "eye.slash.fill", nil, .scope(.hidden, .all)),
      ]
    }
  #endif

  private var list: some View {
    List {
      if hasPhotoAccess {
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
                title: Text("Not Backed Up"), symbol: "icloud.slash.fill", keyAssetID: nil, route: .libraryFilter(.notBackedUp))
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
            Text(collections.isLoaded ? "No albums yet." : "Loading…")
              .foregroundStyle(.secondary)
              .padding(.horizontal, 20)
              .frame(height: PinnedTile.shelfHeight)
              .listRowInsets(EdgeInsets())
              .listRowBackground(Color.clear)
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
      } else {
        Section {
          ContentUnavailableView {
            Label("Allow Photo Access", systemImage: "photo.badge.exclamationmark")
          } description: {
            Text("Allow access to see your albums here.")
          } actions: {
            Button("Allow Access", action: requestPhotoAccess).buttonStyle(.glassProminent)
          }
        }
      }

      if let cloud { CloudCollectionsSection(library: cloud) }

      if hasPhotoAccess, !mediaKinds.isEmpty {
        Section("Media Types") {
          ForEach(mediaKinds) { summary in
            NavigationLink(value: CollectionRoute.scope(.mediaKind(summary.kind), .all)) {
              CountRow(title: summary.kind.title, symbol: summary.kind.symbol, count: summary.count)
            }
          }
        }
      }

      Section("Utilities") {
        ForEach(CollectionRoute.backupUtilities, id: \.self) { route in
          if let filter = route.mergedLibraryFilter {
            CollectionLink(route: route) {
              Label(filter.title, systemImage: filter.symbol)
            }
          }
        }
        if hasPhotoAccess {
          NavigationLink(value: CollectionRoute.scope(.recentlyAdded, .all)) {
            Label("Recently Added", systemImage: "clock")
          }
          NavigationLink(value: CollectionRoute.scope(.hidden, .all)) {
            Label("Hidden", systemImage: "eye.slash")
          }
        }
      }

      if hasPhotoAccess, collections.isLoaded {
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

private struct CollectionLink<Label: View>: View {
  @Environment(\.showLibraryFilter) private var showLibraryFilter
  let route: CollectionRoute
  @ViewBuilder let label: () -> Label

  var body: some View {
    if let filter = route.mergedLibraryFilter {
      Button {
        showLibraryFilter?(filter)
      } label: {
        label()
      }
    } else {
      NavigationLink(value: route, label: label)
    }
  }
}

/// A square tile, as in Photos' Pinned row: the collection's photo (or a neutral fill)
/// with its name in the corner. With no `side` it fills its grid cell (Mac).
private struct PinnedTile: View {
  let title: Text
  var symbol: String?
  let keyAssetID: String?
  let route: CollectionRoute
  static let shelfHeight: CGFloat = 127
  var side: CGFloat? = Self.shelfHeight

  var body: some View {
    CollectionLink(route: route) {
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
    case .libraryFilter:
      // CollectionLink and the sidebar handle this action without pushing a destination.
      EmptyView()
    case .albums:
      AlbumsGridView(collections: collections)
        .task { await collections.loadIfNeeded() }
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
    case .cloudLocked:
      if let cloud { LockedFolderView(library: cloud) }
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
