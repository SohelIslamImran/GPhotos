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

/// A selection of Google Photos items, resolved once per change.
struct CloudSelection: Sendable {
  var items: [RemoteItemSummary] = []
  var allFavorites = false

  init() {}

  init(_ indices: Set<Int>, in all: [RemoteItemSummary]) {
    items = indices.sorted().compactMap { all.indices.contains($0) ? all[$0] : nil }
    allFavorites = !items.isEmpty && items.allSatisfy(\.isFavorite)
  }
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
  @State private var selectedPositions: Set<Int> = []
  @State private var selectionToken = -1
  @State private var selectedKeys = Set<String>()
  private var selection: Set<Int> {
    selectionToken == model.reloadToken ? selectedPositions : model.positions(for: selectedKeys)
  }
  /// The selection resolved to items off the main actor, a moment after it changes: with a
  /// whole library selected, the toolbar doesn't sort and map 100,000 items each redraw.
  @State private var picked = CloudSelection()
  private struct SelectionRevision: Equatable {
    let keys: Set<String>
    let rows: Int
    let badges: Int
  }
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
    _model = State(initialValue: RemoteLibraryGridModel(library: library, scope: scope, buildsTimeline: true))
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
        await model.updateDeviceMatches(from: records)
        library.refresh()
        await model.reloadIfNeeded()
      }
      .onChange(of: library.revision) { Task { await model.reloadIfNeeded() } }
      .onChange(of: recordsRevision) { Task { await model.updateDeviceMatches(from: records) } }
      // Positions shift as the library syncs, so the selection follows its items.
      .onChange(of: model.reloadToken) { select(model.positions(for: selectedKeys)) }
      .task(id: SelectionRevision(keys: selectedKeys, rows: model.reloadToken, badges: model.badgeToken)) {
        let keys = selectedKeys
        picked = .init()
        guard !keys.isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        let indices = model.positions(for: keys)
        let items = model.items
        let resolved = await Task.detached(priority: .userInitiated) { CloudSelection(indices, in: items) }.value
        if !Task.isCancelled, keys == selectedKeys { picked = resolved }
      }
      .onChange(of: isSelecting) { _, selecting in if !selecting { select([]) } }
      .refreshable {
        library.refresh(force: true)
        await model.reloadIfNeeded()
      }
      .sheet(item: $albumTargets) { targets in
        CloudAlbumPickerSheet(
          library: library, items: resolve(targets.keys),
          resolve: {
            await model.reloadIfNeeded()
            return resolve(targets.keys)
          }
        ) {
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
            await model.reloadIfNeeded()
            let fresh = resolve(Set(items.map(\.mediaKey)))
            guard !fresh.isEmpty else { return }
            guard matchesReview(items, fresh) else {
              pendingTrash = fresh
              return
            }
            try await library.trash(fresh)
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
            await model.reloadIfNeeded()
            let fresh = resolve(Set(items.map(\.mediaKey))).filter { $0.trashedAt != nil }
            guard !fresh.isEmpty else { return }
            guard matchesReview(items, fresh) else {
              pendingDelete = fresh
              return
            }
            try await library.deleteForever(fresh)
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
      .safeAreaInset(edge: .bottom) {
        // Earlier items stay on screen; what's new can be asked for again.
        if model.loadFailed, model.itemCount > 0, !isSelecting {
          HStack(spacing: 12) {
            Text("Couldn't Load New Items")
            Button("Try Again") { Task { await model.reloadIfNeeded() } }
              .buttonStyle(.glass)
          }
          .padding(12)
          .glassEffect()
          .padding(.bottom, 8)
        }
      }
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
      if model.scope == .library, let month = topMonth ?? model.monthTitle(at: 0) { return month }
      return model.isLoaded ? ProductCopy.inflected("^[\(model.itemCount) Item](inflect: true)") : " "
    }
  }

  @ViewBuilder private var content: some View {
    // The grid is there from the start (empty for the moment its items take to load): made
    // during the push, it would restart the bar's animation as it joins it.
    if model.itemCount == 0, model.isLoaded || model.loadFailed || library.status != .idle {
      emptyState
    } else {
      PhotoGrid(
        dataSource: model, reloadToken: model.reloadToken, badgeToken: model.badgeToken, zoomStep: $zoomStep,
        selection: Binding(get: { selection }, set: select),
        options: gridOptions
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
      if model.loadFailed {
        ContentUnavailableView {
          Label("Couldn't Load Library", systemImage: "photo.badge.exclamationmark")
        } actions: {
          Button("Try Again") { Task { await model.reloadIfNeeded() } }.buttonStyle(.glassProminent)
        }
      } else if model.isLoaded {
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
            select(selection.count == model.itemCount ? [] : Set(0..<model.itemCount))
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

  private var gridOptions: PhotoGridOptions {
    var options = PhotoGridOptions(
      isSelecting: isSelecting,
      onTopIndexChange: { index in
        let month = model.monthTitle(at: index)
        if month != topMonth { topMonth = month }
      }, menu: { menuItems(for: $0) },
      dragItem: { index in
        guard let item = model.item(at: index), let fresh = resolve([item.mediaKey]).first else { return nil }
        let drag = ViewerItem.cloud(fresh, library: library, isOnDevice: false).dragItem
        return PhotoGridDragItem(fileName: drag.fileName, isVideo: drag.isVideo) {
          guard let current = await resolve([item.mediaKey]).first else { throw CocoaError(.fileNoSuchFile) }
          return try await library.download(current)
        }
      }, proxy: zoom.proxy)
    options.currentReloadToken = { model.reloadToken }
    return options
  }

  private func select(_ indices: Set<Int>) {
    selectedPositions = indices
    selectionToken = model.reloadToken
    selectedKeys = Set(indices.compactMap { model.item(at: $0)?.mediaKey })
  }

  private func resolve(_ keys: Set<String>) -> [RemoteItemSummary] {
    guard model.library === library else { return [] }
    return model.resolveSelection(keys)
  }

  private var selected: [RemoteItemSummary] { resolve(selectedKeys) }

  private func matchesReview(_ reviewed: [RemoteItemSummary], _ fresh: [RemoteItemSummary]) -> Bool {
    reviewed.count == fresh.count
      && reviewed.map(\.dedupKey).sorted() == fresh.map(\.dedupKey).sorted()
  }

  private func share(_ keys: Set<String>) {
    let items = resolve(keys)
    SharePresenter.share(
      items.map { RemoteSharedItem(library: library, item: $0) },
      identities: items.map { library.localFirstThumbnails.thumbnailIdentity(for: $0.thumbnailID) },
      videoCount: items.filter { $0.kind == .video }.count)
  }

  @ViewBuilder private var selectionButtons: some View {
    let empty = selection.isEmpty
    Button {
      share(selectedKeys)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .disabled(empty || picked.items.isEmpty)
    if model.scope == .trash {
      Button {
        let items = selected
        run(String(localized: "Restoring…")) {
          try await library.restore(items)
          isSelecting = false
        }
      } label: {
        Label("Restore", systemImage: "arrow.uturn.backward")
      }
      .disabled(empty)
      Button(role: .destructive) {
        pendingDelete = selected
      } label: {
        Label("Delete Forever", systemImage: "trash")
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(empty)
    } else {
      Button {
        let items = selected
        run(nil) { try await library.toggleFavorite(items) }
      } label: {
        Label(picked.allFavorites ? "Unfavorite" : "Favorite", systemImage: picked.allFavorites ? "heart.slash" : "heart")
      }
      .keyboardShortcut(".", modifiers: [])
      .disabled(empty)
      Button {
        save(selected)
      } label: {
        Label("Save to Device", systemImage: "arrow.down.circle")
      }
      .disabled(empty)
      Button {
        let items = selected
        run(nil) {
          try await library.setArchived(items, archived: model.scope != .archive)
          isSelecting = false
        }
      } label: {
        Label(model.scope == .archive ? "Unarchive" : "Archive", systemImage: "archivebox")
      }
      .disabled(empty)
      Button(role: .destructive) {
        pendingTrash = selected
      } label: {
        Label("Move to Trash", systemImage: "trash")
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(empty)
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
    let keys = Set(model.items(at: indices).map(\.mediaKey))
    let items = resolve(keys)
    guard !items.isEmpty else { return [] }
    var menu: [PhotoGridMenuItem] = []
    if model.scope == .trash {
      menu.append(
        PhotoGridMenuItem(String(localized: "Restore"), systemImage: "arrow.uturn.backward") {
          run(String(localized: "Restoring…")) { try await library.restore(resolve(keys)) }
        })
      menu.append(
        PhotoGridMenuItem(String(localized: "Delete Forever"), systemImage: "trash", isDestructive: true) {
          pendingDelete = resolve(keys)
        })
      return menu
    }
    menu.append(
      PhotoGridMenuItem(String(localized: "Save to Device"), systemImage: "arrow.down.circle", group: .quick) {
        save(resolve(keys))
      })
    let archived = model.scope == .archive
    menu.append(
      PhotoGridMenuItem(
        archived ? String(localized: "Unarchive") : String(localized: "Archive"), systemImage: "archivebox", group: .quick
      ) { run(nil) { try await library.setArchived(resolve(keys), archived: !archived) } })
    #if os(iOS)
      menu.append(
        PhotoGridMenuItem(String(localized: "Share"), systemImage: "square.and.arrow.up") {
          share(keys)
        })
    #endif
    let allFavorites = items.allSatisfy(\.isFavorite)
    menu.append(
      PhotoGridMenuItem(
        allFavorites ? String(localized: "Unfavorite") : String(localized: "Favorite"),
        systemImage: allFavorites ? "heart.slash" : "heart"
      ) { run(nil) { try await library.toggleFavorite(resolve(keys)) } })
    menu.append(
      PhotoGridMenuItem(String(localized: "Add to Album"), systemImage: "rectangle.stack.badge.plus", group: .organize) {
        albumTargets = CloudAlbumTargets(keys: keys)
      })
    menu.append(
      PhotoGridMenuItem(String(localized: "Move to Trash"), systemImage: "trash", isDestructive: true) {
        pendingTrash = resolve(keys)
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
      if library.isStateLoaded, library.hasLockedItems {
        NavigationLink(value: CollectionRoute.cloudLocked) {
          Label("Locked Folder", systemImage: LockedFolderView.symbol)
        }
      }
    } header: {
      Text("Google Photos")
    } footer: {
      // Read with the library's saved state, so it never shows a guess first.
      Text(library.isStateLoaded ? library.collectionsFooter : " ")
    }
  }
}

#if os(macOS)
  /// Google Photos on the Mac's Collections page: its albums' covers, then its scopes.
  struct CloudCollectionsGallery: View {
    let library: CloudLibrary
    private var albums: [RemoteAlbum] { library.albumList }

    var body: some View {
      GallerySection("Google Photos") {
        if albums.count > Self.albumPreviewCount {
          NavigationLink("Show All Albums", value: CollectionRoute.cloudAlbums)
        }
      } content: {
        VStack(alignment: .leading, spacing: 18) {
          if !library.isStateLoaded {
            LazyVGrid(columns: galleryCoverColumns) {
              GalleryCover(title: "", count: 0, thumbnailID: nil).hidden()
            }
          } else if !albums.isEmpty {
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
            if library.isStateLoaded, library.hasLockedItems {
              NavigationLink(value: CollectionRoute.cloudLocked) {
                GalleryRow(title: String(localized: "Locked Folder"), symbol: LockedFolderView.symbol, tint: .secondary)
              }
            }
          }
          .buttonStyle(.plain)
          // Read with the library's saved state, so it never shows a guess first.
          Text(library.isStateLoaded ? library.collectionsFooter : " ")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
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
    guard isStateLoaded else { return nil }
    return switch scope {
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
  let keys: Set<String>
}

/// Every Google Photos album, newest activity first.
struct GoogleAlbumsView: View {
  let library: CloudLibrary
  private var albums: [RemoteAlbum] { library.albumList }

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
      if library.isStateLoaded, albums.isEmpty {
        ContentUnavailableView(
          "No Albums", systemImage: "rectangle.stack",
          description: Text("Albums in Google Photos appear here after a sync."))
      }
    }
    .navigationTitle("Google Photos Albums")
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
  var resolve: (() async -> [RemoteItemSummary])? = nil
  let onDone: () -> Void
  private var albums: [RemoteAlbum] { library.albumList }
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
              finish { try await library.add($0, toAlbum: album) }
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
          finish { try await library.createAlbum(titled: title, with: $0) }
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
    }
    #if os(macOS)
      .frame(minWidth: 360, minHeight: 420)
    #endif
  }

  private func finish(_ action: @escaping @MainActor ([RemoteItemSummary]) async throws -> Void) {
    Task {
      isWorking = true
      defer { isWorking = false }
      do {
        let current = await resolve?() ?? items
        if !current.isEmpty { try await action(current) }
        onDone()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
