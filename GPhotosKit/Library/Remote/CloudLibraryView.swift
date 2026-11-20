import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// A Google Photos item for the share sheet: the file is downloaded only when a
/// destination asks for it.
public struct RemoteSharedItem: Transferable, Sendable {
  let library: CloudLibrary
  let item: RemoteItemSummary

  public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .movie) { shared in SentTransferredFile(try await shared.export()) }
      .exportingCondition { $0.item.kind == .video }
    FileRepresentation(exportedContentType: .image) { shared in SentTransferredFile(try await shared.export()) }
      .exportingCondition { $0.item.kind != .video }
  }

  func export() async throws -> URL { try await library.download(item) }
}

/// Saves downloaded Google Photos items into this device's photo library.
enum DeviceSaver {
  static func save(_ files: [(url: URL, isVideo: Bool)]) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      for file in files {
        PHAssetCreationRequest.forAsset().addResource(with: file.isVideo ? .video : .photo, fileURL: file.url, options: nil)
      }
    }
  }
}

/// A Google Photos library screen for one scope: the synced mirror in the shared grid,
/// with sync status, selection and remote actions.
public struct CloudLibraryView: View {
  let library: CloudLibrary
  let records: [TransferRecord]
  let recordsRevision: Int?
  @State private var model: RemoteLibraryGridModel
  @State private var zoomStep: Int
  @State private var selection: Set<Int> = []
  @State private var selectedKeys: Set<String> = []
  @State private var isSelecting = false
  @State private var opened: Int?
  @State private var zoom = ViewerZoom()
  /// The month at the top of the grid; set only when it changes, so scrolling
  /// re-renders the screen once a month, not once a row.
  @State private var topMonth: String?
  @State private var pendingTrash: [RemoteItemSummary] = []
  @State private var pendingDelete: [RemoteItemSummary] = []
  @State private var busyMessage: String?
  @State private var errorMessage: String?
  @State private var albumTargets: CloudAlbumTargets?
  /// Photos are under the bar: it darkens and the title turns white, as in the Library.

  public init(library: CloudLibrary, scope: RemoteScope = .library, records: [TransferRecord], recordsRevision: Int?) {
    self.library = library
    self.records = records
    self.recordsRevision = recordsRevision
    _model = State(initialValue: RemoteLibraryGridModel(library: library, scope: scope))
    #if os(iOS)
      _zoomStep = State(initialValue: PhotoGridZoom.columnSteps.firstIndex(of: PhotoGridZoom.defaultColumns) ?? 3)
    #else
      _zoomStep = State(initialValue: PhotoGridZoom.defaultStep)
    #endif
  }

  public var body: some View {
    decorated(content)
  }

  private func decorated(_ view: some View) -> some View {
    view
      #if os(iOS)
        .navigationTitle(model.scope.title)
        .navigationSubtitle(
          isSelecting || library.status != .idle ? subtitle : countText(model.isLoaded ? model.itemCount : nil)
        )
        .toolbarTitleDisplayMode(.inlineLarge)
      #else
        .gridTitle(model.scope.title, subtitle: subtitle, zoom: zoom)
      #endif
      .toolbar { toolbar }
      .task {
        library.refresh()
        await model.reloadIfNeeded()
        await model.updateDeviceMatches(from: records)
      }
      .onChange(of: library.revision) { Task { await model.reloadIfNeeded() } }
      .onChange(of: recordsRevision) { Task { await model.updateDeviceMatches(from: records) } }
      // Positions shift as the library syncs, so the selection follows its items.
      .onChange(of: model.reloadToken) {
        guard !selectedKeys.isEmpty else { return }
        selection = Set(model.items.indices.filter { selectedKeys.contains(model.items[$0].mediaKey) })
      }
      .onChange(of: selection) { _, selection in selectedKeys = Set(model.items(at: selection).map(\.mediaKey)) }
      .onChange(of: isSelecting) { _, selecting in if !selecting { selection = [] } }
      .refreshable { library.refresh(force: true) }
      .sheet(item: $albumTargets) { targets in
        CloudAlbumPickerSheet(library: library, items: targets.items) {
          albumTargets = nil
          isSelecting = false
        }
      }
      .confirmationDialog(
        pendingTrash.count == 1 ? "Move to Trash?" : "Move \(pendingTrash.count) Items to Trash?",
        isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } }),
        titleVisibility: .visible
      ) {
        Button("Move to Trash", role: .destructive) {
          let items = pendingTrash
          run(String(localized: "Moving to Trash…")) {
            try await library.trash(items)
            isSelecting = false
          }
        }
      } message: {
        Text("It's removed from Google Photos on all your devices. You can restore it from Trash for 60 days.")
      }
      .confirmationDialog(
        pendingDelete.count == 1 ? "Delete Forever?" : "Delete \(pendingDelete.count) Items Forever?",
        isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
        titleVisibility: .visible
      ) {
        Button("Delete Forever", role: .destructive) {
          let items = pendingDelete
          run(String(localized: "Deleting…")) {
            try await library.deleteForever(items)
            isSelecting = false
          }
        }
      } message: {
        Text(
          pendingDelete.count == 1
            ? "It's deleted from Google Photos on all your devices. This can't be undone."
            : "They're deleted from Google Photos on all your devices. This can't be undone.")
      }
      .alert(
        "Couldn't Finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(errorMessage ?? "")
      }
      .overlay(alignment: .bottom) {
        if let busyMessage {
          Label(busyMessage, systemImage: "arrow.down.circle")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect()
            .padding(.bottom, 80)
            .transition(.opacity)
        }
      }
      #if os(iOS)
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
          if isSelecting { selectionBar }
        }
        .photoViewer(index: $opened, source: model, zoom: zoom)
      #else
        .photoViewer(index: $opened, source: model, zoom: zoom)
      #endif
  }

  private var subtitle: String {
    if isSelecting || selection.count > 1 {
      return selection.isEmpty ? String(localized: "Select Items") : String(localized: "\(selection.count) Selected")
    }
    switch library.status {
    case .syncing(let progress):
      return library.syncState.initialSyncDone
        ? String(localized: "Updating…") : String(localized: "Syncing \(progress.updated.formatted()) items…")
    case .failed: return String(localized: "Couldn't sync")
    case .idle:
      if let month = topMonth ?? model.monthTitle(at: 0) { return month }
      return model.isLoaded ? ProductCopy.inflected("^[\(model.itemCount) Item](inflect: true)") : " "
    }
  }

  @ViewBuilder private var content: some View {
    // The grid is there from the start (empty for the moment its items take to load): made
    // during the push, it would restart the bar's animation as it joins it.
    if model.itemCount == 0, model.isLoaded || library.status != .idle {
      emptyState
    } else {
      PhotoGrid(
        dataSource: model, reloadToken: model.reloadToken, badgeToken: model.badgeToken, zoomStep: $zoomStep,
        selection: $selection,
        options: PhotoGridOptions(
          isSelecting: isSelecting,
          onTopIndexChange: { index in
            let month = model.monthTitle(at: index)
            if month != topMonth { topMonth = month }
          }, menu: { menuItems(for: $0) },
          dragItem: { model.viewerItem(at: $0)?.dragItem }, proxy: zoom.proxy)
      ) { index in
        zoom.open(index, in: model) { opened = index }
      }
      #if os(iOS)
        // Under the bars: a grid sized by the bar would change height as the title
        // collapses, which scrolls it, which moves the title again.
        .ignoresSafeArea(edges: [.top, .bottom])
      #else
        .ignoresSafeArea(edges: .bottom)
      #endif
    }
  }

  @ViewBuilder private var emptyState: some View {
    switch library.status {
    case .syncing(let progress) where !library.syncState.initialSyncDone:
      ContentUnavailableView {
        Label("Syncing Google Photos", systemImage: "arrow.triangle.2.circlepath.icloud")
      } description: {
        Text(
          progress.updated == 0
            ? "Getting your library from Google Photos." : "\(progress.updated.formatted()) items so far.")
      } actions: {
        ProgressView()
      }
    case .failed(let message):
      ContentUnavailableView {
        Label("Couldn't Sync", systemImage: "exclamationmark.icloud")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { library.refresh(force: true) }.buttonStyle(.glassProminent)
      }
    default:
      if model.isLoaded {
        ContentUnavailableView(emptyTitle, systemImage: model.scope.symbol, description: Text(emptyDescription))
      } else {
        ProgressView()
      }
    }
  }

  private var emptyTitle: LocalizedStringKey {
    switch model.scope {
    case .library: "No Photos"
    case .favorites: "No Favorites"
    case .videos: "No Videos"
    case .archive: "Nothing Archived"
    case .trash: "Trash Is Empty"
    case .usesStorage: "Nothing Uses Storage"
    case .album: "No Items to Show"
    }
  }

  private var emptyDescription: LocalizedStringKey {
    switch model.scope {
    case .trash: "Items you move to Trash stay here for 60 days, unless you delete them sooner."
    case .archive: "Archived items are hidden from your library but stay in albums and search."
    case .usesStorage: "No items in this view are counted against your Google Account storage."
    case .album: "This album's items appear here once Google Photos lists them in the sync."
    default: "Photos and videos in Google Photos appear here."
    }
  }

  // MARK: Toolbar and actions

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(iOS)
      ToolbarItem(placement: .topBarTrailing) {
        if isSelecting {
          Button(selection.count == model.itemCount ? "Deselect All" : "Select All") {
            selection = selection.count == model.itemCount ? [] : Set(0..<model.itemCount)
          }
        } else {
          syncButton
        }
      }
      // Separate pieces of glass, as in Photos.
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
      ToolbarItem(placement: .topBarTrailing) {
        Button(isSelecting ? "Cancel" : "Select") { withAnimation(.smooth) { isSelecting.toggle() } }
          .disabled(model.itemCount == 0)
      }
    #else
      if opened == nil {
        ToolbarItemGroup {
          if !selection.isEmpty { selectionButtons }
          Button {
            zoomStep = min(zoomStep + 1, PhotoGridZoom.cellWidthSteps.count - 1)
          } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
          }
          .keyboardShortcut("-", modifiers: .command)
          Button {
            zoomStep = max(zoomStep - 1, 0)
          } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
          }
          .keyboardShortcut("=", modifiers: .command)
          syncButton
        }
      }
    #endif
  }

  private var syncButton: some View {
    Button {
      library.refresh(force: true)
    } label: {
      if library.isSyncing {
        ProgressView().controlSize(.small)
      } else {
        Label("Sync Now", systemImage: "arrow.clockwise")
      }
    }
    .disabled(library.isSyncing)
    // ⌘R is Sync Now, the backup's own, in the Backup menu.
    .keyboardShortcut("r", modifiers: [.command, .option])
  }

  private var selected: [RemoteItemSummary] { model.items(at: selection) }

  @ViewBuilder private var selectionButtons: some View {
    let items = selected
    let allFavorites = !items.isEmpty && items.allSatisfy(\.isFavorite)
    PhotoShareButton(
      items: items.map { RemoteSharedItem(library: library, item: $0) }, ids: items.map(\.thumbnailID),
      videoCount: items.filter { $0.kind == .video }.count
    ) {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .disabled(items.isEmpty)
    if model.scope == .trash {
      Button {
        run(String(localized: "Restoring…")) {
          try await library.restore(items)
          isSelecting = false
        }
      } label: {
        Label("Restore", systemImage: "arrow.uturn.backward")
      }
      .disabled(items.isEmpty)
      Button(role: .destructive) {
        pendingDelete = items
      } label: {
        Label("Delete Forever", systemImage: "trash")
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(items.isEmpty)
    } else {
      Button {
        run(nil) { try await library.toggleFavorite(items) }
      } label: {
        Label(allFavorites ? "Unfavorite" : "Favorite", systemImage: allFavorites ? "heart.slash" : "heart")
      }
      .keyboardShortcut(".", modifiers: [])
      .disabled(items.isEmpty)
      Button {
        save(items)
      } label: {
        Label("Save to Device", systemImage: "arrow.down.circle")
      }
      .disabled(items.isEmpty)
      Button {
        run(nil) {
          try await library.setArchived(items, archived: model.scope != .archive)
          isSelecting = false
        }
      } label: {
        Label(model.scope == .archive ? "Unarchive" : "Archive", systemImage: "archivebox")
      }
      .disabled(items.isEmpty)
      Button(role: .destructive) {
        pendingTrash = items
      } label: {
        Label("Move to Trash", systemImage: "trash")
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(items.isEmpty)
    }
  }

  #if os(iOS)
    private var selectionBar: some View {
      GlassEffectContainer {
        HStack(spacing: 16) { selectionButtons }
          .labelStyle(.iconOnly)
          .font(.title3)
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
      }
      .padding(.bottom, 8)
    }
  #endif

  /// Laid out as in Photos; tapping the preview opens the item.
  private func menuItems(for indices: Set<Int>) -> [PhotoGridMenuItem] {
    let items = model.items(at: indices)
    guard !items.isEmpty else { return [] }
    var menu: [PhotoGridMenuItem] = []
    if model.scope == .trash {
      menu.append(
        PhotoGridMenuItem(String(localized: "Restore"), systemImage: "arrow.uturn.backward") {
          run(String(localized: "Restoring…")) { try await library.restore(items) }
        })
      menu.append(
        PhotoGridMenuItem(String(localized: "Delete Forever"), systemImage: "trash", isDestructive: true) {
          pendingDelete = items
        })
      return menu
    }
    menu.append(
      PhotoGridMenuItem(String(localized: "Save to Device"), systemImage: "arrow.down.circle", group: .quick) {
        save(items)
      })
    let archived = model.scope == .archive
    menu.append(
      PhotoGridMenuItem(
        archived ? String(localized: "Unarchive") : String(localized: "Archive"), systemImage: "archivebox", group: .quick
      ) { run(nil) { try await library.setArchived(items, archived: !archived) } })
    #if os(iOS)
      menu.append(
        PhotoGridMenuItem(String(localized: "Share"), systemImage: "square.and.arrow.up") {
          SharePresenter.share(
            items.map { RemoteSharedItem(library: library, item: $0) }, ids: items.map(\.thumbnailID),
            videoCount: items.filter { $0.kind == .video }.count)
        })
    #endif
    let allFavorites = items.allSatisfy(\.isFavorite)
    menu.append(
      PhotoGridMenuItem(
        allFavorites ? String(localized: "Unfavorite") : String(localized: "Favorite"),
        systemImage: allFavorites ? "heart.slash" : "heart"
      ) { run(nil) { try await library.toggleFavorite(items) } })
    menu.append(
      PhotoGridMenuItem(String(localized: "Add to Album"), systemImage: "rectangle.stack.badge.plus", group: .organize) {
        albumTargets = CloudAlbumTargets(items: items)
      })
    menu.append(
      PhotoGridMenuItem(String(localized: "Move to Trash"), systemImage: "trash", isDestructive: true) {
        pendingTrash = items
      })
    return menu
  }

  private func save(_ items: [RemoteItemSummary]) {
    run(String(localized: "Saving \(items.count) to this device…")) {
      var files: [(url: URL, isVideo: Bool)] = []
      for item in items { files.append((try await library.download(item), item.kind == .video)) }
      try await DeviceSaver.save(files)
      isSelecting = false
    }
  }

  private func run(_ message: String?, _ action: @escaping @MainActor () async throws -> Void) {
    Task {
      withAnimation(.smooth) { busyMessage = message }
      defer { withAnimation(.smooth) { busyMessage = nil } }
      do {
        try await action()
      } catch let error as PHPhotosError where error.code == .userCancelled {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

/// Google Photos collections and storage for the Collections screen.
struct CloudCollectionsSection: View {
  let library: CloudLibrary

  var body: some View {
    Section {
      NavigationLink(value: CollectionRoute.cloudAlbums) {
        Label("Albums", systemImage: "rectangle.stack")
      }
      ForEach(RemoteScope.collectionScopes, id: \.self) { scope in
        NavigationLink(value: CollectionRoute.cloud(scope)) {
          LabeledContent {
            if let count = library.collectionCount(for: scope) { Text(count, format: .number) }
          } label: {
            // Under a "Google Photos" heading the whole library is "All Photos", as on the Mac.
            Label(scope == .library ? String(localized: "All Photos") : scope.title, systemImage: scope.symbol)
          }
        }
      }
    } header: {
      Text("Google Photos")
    } footer: {
      Text(library.collectionsFooter)
    }
  }
}

#if os(macOS)
  /// Google Photos on the Mac's Collections page: its albums' covers, then its scopes.
  struct CloudCollectionsGallery: View {
    let library: CloudLibrary
    @State private var albums: [RemoteAlbum] = []

    var body: some View {
      GallerySection("Google Photos") {
        if albums.count > Self.albumPreviewCount {
          NavigationLink("Show All Albums", value: CollectionRoute.cloudAlbums)
        }
      } content: {
        VStack(alignment: .leading, spacing: 18) {
          if !albums.isEmpty {
            LazyVGrid(columns: galleryCoverColumns, spacing: 20) {
              ForEach(albums.prefix(Self.albumPreviewCount)) { album in
                NavigationLink(value: CollectionRoute.cloud(.album(key: album.mediaKey, title: album.title))) {
                  GalleryCover(
                    title: album.title.isEmpty ? String(localized: "Untitled Album") : album.title,
                    count: album.itemCount,
                    thumbnailID: album.coverMediaKey.map { RemoteThumbnailID(mediaKey: $0, contentVersion: 0).string },
                    source: library.localFirstThumbnails)
                }
                .buttonStyle(.plain)
              }
            }
          }
          LazyVGrid(columns: galleryRowColumns, spacing: 10) {
            if albums.count <= Self.albumPreviewCount {
              NavigationLink(value: CollectionRoute.cloudAlbums) {
                GalleryRow(
                  title: String(localized: "Albums"), symbol: "rectangle.stack", count: albums.isEmpty ? nil : albums.count)
              }
            }
            ForEach(RemoteScope.collectionScopes, id: \.self) { scope in
              NavigationLink(value: CollectionRoute.cloud(scope)) {
                GalleryRow(
                  title: scope == .library ? String(localized: "All Photos") : scope.title, symbol: scope.symbol,
                  tint: scope == .trash ? .secondary : .accentColor,
                  count: library.collectionCount(for: scope))
              }
            }
          }
          .buttonStyle(.plain)
          Text(library.collectionsFooter)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .task(id: library.revision) { albums = await library.albums() }
    }

    private static let albumPreviewCount = 6
  }
#endif

extension RemoteScope {
  /// The scopes Collections lists, in order.
  static let collectionScopes: [RemoteScope] = [.library, .favorites, .videos, .archive, .usesStorage, .trash]
}

extension CloudLibrary {
  /// The count shown beside a scope, where the mirror keeps one.
  func collectionCount(for scope: RemoteScope) -> Int? {
    switch scope {
    case .archive: stats.archived
    case .trash: stats.trashed
    case .usesStorage: stats.chargedItems
    case .videos: stats.videos
    case .library: stats.items
    default: nil
    }
  }

  var collectionsFooter: String {
    guard syncState.initialSyncDone else {
      return String(localized: "Your Google Photos library appears here after its first sync.")
    }
    let photos = ProductCopy.inflected("^[\(stats.photos) photo](inflect: true)")
    let videos = ProductCopy.inflected("^[\(stats.videos) video](inflect: true)")
    var text = String(localized: "\(photos) and \(videos), \(stats.bytes.formatted(.byteCount(style: .file))) in all.")
    if stats.chargedBytes > 0 {
      text += " " + String(localized: "\(stats.chargedBytes.formatted(.byteCount(style: .file))) counts toward your storage.")
    }
    if let last = syncState.lastSyncedAt {
      text += " " + String(localized: "Synced \(last.formatted(.relative(presentation: .named))).")
    }
    return text
  }
}

struct CloudAlbumTargets: Identifiable {
  let id = UUID()
  let items: [RemoteItemSummary]
}

/// Every Google Photos album, newest activity first.
struct GoogleAlbumsView: View {
  let library: CloudLibrary
  @State private var albums: [RemoteAlbum] = []
  @State private var isLoaded = false

  var body: some View {
    ScrollView {
      #if os(macOS)
        LazyVGrid(columns: galleryCoverColumns, spacing: 20) {
          ForEach(albums) { album in
            NavigationLink(value: CollectionRoute.cloud(.album(key: album.mediaKey, title: album.title))) {
              GalleryCover(
                title: album.title.isEmpty ? String(localized: "Untitled Album") : album.title, count: album.itemCount,
                thumbnailID: album.coverMediaKey.map { RemoteThumbnailID(mediaKey: $0, contentVersion: 0).string },
                source: library.localFirstThumbnails)
            }
            .buttonStyle(.plain)
          }
        }
        .galleryPage()
      #else
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
          ForEach(albums) { album in
            NavigationLink(value: CollectionRoute.cloud(.album(key: album.mediaKey, title: album.title))) {
              GoogleAlbumCard(library: library, album: album, side: 150)
            }
            .buttonStyle(.plain)
          }
        }
        .padding()
      #endif
    }
    .overlay {
      if isLoaded, albums.isEmpty {
        ContentUnavailableView(
          "No Albums", systemImage: "rectangle.stack",
          description: Text("Albums in Google Photos appear here after a sync."))
      }
    }
    .navigationTitle("Google Photos Albums")
    .task(id: library.revision) {
      albums = await library.albums()
      isLoaded = true
    }
  }
}

struct GoogleAlbumCard: View {
  let library: CloudLibrary
  let album: RemoteAlbum
  let side: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LibraryThumbnail(
        id: album.coverMediaKey.map { RemoteThumbnailID(mediaKey: $0, contentVersion: 0).string }, bucket: .medium,
        source: library.localFirstThumbnails
      )
      .frame(width: side, height: side)
      .clipShape(.rect(cornerRadius: 12))
      Text(album.title.isEmpty ? String(localized: "Untitled Album") : album.title).font(.subheadline).lineLimit(1)
      Text(album.itemCount, format: .number).font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: side)
    .accessibilityElement(children: .combine)
  }
}

/// Adds Google Photos items to one of the account's albums, or a new one.
struct CloudAlbumPickerSheet: View {
  let library: CloudLibrary
  let items: [RemoteItemSummary]
  let onDone: () -> Void
  @State private var albums: [RemoteAlbum] = []
  @State private var isNaming = false
  @State private var newTitle = ""
  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        Button {
          isNaming = true
        } label: {
          Label("New Album", systemImage: "plus.rectangle.on.rectangle")
        }
        Section("Google Photos Albums") {
          ForEach(albums) { album in
            Button {
              finish { try await library.add(items, toAlbum: album) }
            } label: {
              HStack(spacing: 12) {
                LibraryThumbnail(
                  id: album.coverMediaKey.map { RemoteThumbnailID(mediaKey: $0, contentVersion: 0).string },
                  bucket: .small, source: library.localFirstThumbnails
                )
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading) {
                  Text(album.title).foregroundStyle(.primary)
                  Text(album.itemCount, format: .number).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .disabled(isWorking)
      .navigationTitle(items.count == 1 ? "Add to Album" : "Add \(items.count) Items to Album")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
      }
      .alert("New Album", isPresented: $isNaming) {
        TextField("Title", text: $newTitle)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
          let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !title.isEmpty else { return }
          finish { try await library.createAlbum(titled: title, with: items) }
        }
      } message: {
        Text("Enter a name for this album in Google Photos.")
      }
      .alert(
        "Couldn't Add to Album", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(errorMessage ?? "")
      }
      .task { albums = await library.albums() }
    }
    #if os(macOS)
      .frame(minWidth: 360, minHeight: 420)
    #endif
  }

  private func finish(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
      isWorking = true
      defer { isWorking = false }
      do {
        try await action()
        onDone()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
