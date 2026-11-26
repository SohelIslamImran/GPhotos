import Photos
import SwiftUI

/// How the main library is grouped, as in Photos.
public enum LibraryTimelineMode: String, CaseIterable, Hashable, Sendable {
  case years
  case months
  case all

  /// How close the view is: Years 0, Months 1, All 2.
  var depth: Int { Self.allCases.firstIndex(of: self) ?? 0 }

  var title: LocalizedStringKey {
    switch self {
    case .years: "Years"
    case .months: "Months"
    case .all: "All"
    }
  }
}

/// A library grid screen: the whole library or any collection, with backup badges from
/// the manifest, filters, selection and actions. Shared by both apps.
public struct LibraryView: View {
  let model: PhotoLibraryGridModel
  let records: [TransferRecord]
  /// Changes whenever `records` does, so 100k records are never compared.
  let recordsRevision: Int?
  let title: String?
  let cloud: CloudLibrary?
  @State private var zoomStep: Int
  @State private var selection: Set<Int> = []
  /// The selection's assets for the toolbar, resolved off the main actor once it pauses.
  @State private var picked: [PHAsset] = []
  @State private var pickTask: Task<Void, Never>?
  @State private var isSelecting = false
  @State private var opened: Int?
  @State private var zoom = ViewerZoom()
  @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  /// The month at the top of the grid; set only when it changes, so scrolling
  /// re-renders the screen once a month, not once a row.
  @State private var topMonth: String?
  @State private var scrollTarget: Int?
  @State private var mode: LibraryTimelineMode = .all
  @State private var pendingDelete: [PHAsset] = []
  @State private var albumTargets: AssetGroup?
  @State private var errorMessage: String?
  /// Photos are under the bar: it darkens and the title turns white, as in the Library.

  private struct AssetGroup: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
  }

  public init(
    model: PhotoLibraryGridModel, records: [TransferRecord], recordsRevision: Int?, title: String? = nil, cloud: CloudLibrary? = nil
  ) {
    self.model = model
    self.records = records
    self.recordsRevision = recordsRevision
    self.title = title
    self.cloud = cloud
    #if os(iOS)
      _zoomStep = State(initialValue: PhotoGridZoom.columnSteps.firstIndex(of: PhotoGridZoom.defaultColumns) ?? 3)
    #else
      _zoomStep = State(initialValue: PhotoGridZoom.defaultStep)
    #endif
  }

  private var showsModes: Bool { model.scope == .all && model.filter == .all }

  public var body: some View {
    #if os(iOS)
      presentations(
        dialogs(
          lifecycle(
            content
              // The bar's own large title and subtitle: it moves them with the screen.
              .navigationTitle(screenTitle)
              .navigationSubtitle(isSelecting ? subtitle : countText(model.isLoaded ? model.itemCount : nil))
              .toolbarTitleDisplayMode(.inlineLarge))))
    #else
      presentations(dialogs(lifecycle(content.gridTitle(screenTitle, subtitle: subtitle, zoom: zoom))))
    #endif
  }

  private var screenTitle: String { title ?? model.scope.title }

  private func refreshBackupStates() async {
    await model.updateBackupStates(
      from: records, confirmedCloudIDs: cloud?.localFirstThumbnails.localCopies.confirmedAssetIDs ?? [],
      accountEmail: cloud?.accountEmail)
  }

  private func lifecycle(_ view: some View) -> some View {
    view
      .toolbar { toolbar }
      .task {
        await refreshBackupStates()
        await model.load()
      }
      .onChange(of: recordsRevision) {
        Task { await refreshBackupStates() }
      }
      .onChange(of: cloud?.accountEmail) { Task { await refreshBackupStates() } }
      .onChange(of: cloud?.localCopyRevision) { Task { await refreshBackupStates() } }
      .onReceive(NotificationCenter.default.publisher(for: AppSettingsStore.didChange).receive(on: DispatchQueue.main)) { _ in
        Task { await refreshBackupStates() }
      }
      // Positions shift when photos arrive or leave, so the selection follows its photos.
      .onChange(of: model.reloadToken) {
        guard !selection.isEmpty else { return }
        if picked.count == selection.count {
          selection = Set(picked.compactMap(model.index(of:)))
        } else {
          selection = selection.filter { $0 < model.itemCount }
        }
      }
      .onChange(of: isSelecting) { _, selecting in
        if !selecting { selection = [] }
      }
      .onChange(of: selection) { _, selection in
        pickTask?.cancel()
        pickTask = Task {
          try? await Task.sleep(for: .milliseconds(80))
          guard !Task.isCancelled else { return }
          let resolved = await model.resolveAssets(at: selection)
          if !Task.isCancelled { picked = resolved }
        }
      }
  }

  private func dialogs(_ view: some View) -> some View {
    view
      .confirmationDialog(
        deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          let assets = pendingDelete
          run {
            try await LibraryActions.delete(assets)
            isSelecting = false
          }
        }
      } message: {
        Text("They're also removed from iCloud Photos on your other devices, if you use it.")
      }
      .sheet(item: $albumTargets) { group in
        AlbumPickerSheet(assets: group.assets) {
          albumTargets = nil
          isSelecting = false
        }
      }
      .alert(
        "Couldn't Finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(errorMessage ?? "")
      }
  }

  private func presentations(_ view: some View) -> some View {
    #if os(iOS)
      view
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
          if isSelecting {
            selectionBar.transition(.move(edge: .bottom).combined(with: .opacity))
          } else if showsModes, model.itemCount > 0 {
            modePicker.padding(.bottom, 8)
          }
        }
        .photoViewer(index: $opened, source: model, zoom: zoom)
    #else
      view.photoViewer(index: $opened, source: model, zoom: zoom)
    #endif
  }

  private var subtitle: String {
    if isSelecting || selection.count > 1 {
      return selection.isEmpty
        ? String(localized: "Select Items") : String(localized: "\(selection.count) Selected")
    }
    if mode == .all, model.scope.isDateOrdered, let month = topMonth ?? model.monthTitle(at: 0) { return month }
    return model.isLoaded ? ProductCopy.inflected("^[\(model.itemCount) Item](inflect: true)") : " "
  }

  private var deleteTitle: String {
    pendingDelete.count == 1
      ? (pendingDelete[0].mediaType == .video
        ? String(localized: "Delete This Video?") : String(localized: "Delete This Photo?"))
      : String(localized: "Delete \(pendingDelete.count) Items?")
  }

  @ViewBuilder private var content: some View {
    if status == .authorized || status == .limited {
      if model.isLoaded, model.itemCount == 0 {
        emptyState
      } else if mode == .all || !showsModes {
        PhotoGrid(
          dataSource: model, reloadToken: model.reloadToken, badgeToken: model.badgeToken, zoomStep: $zoomStep,
          selection: $selection, scrollTarget: $scrollTarget,
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
      } else {
        TimelineCardsView(
          timeline: model.timeline, itemCount: model.itemCount, source: model.thumbnailSource, mode: mode,
          itemID: model.itemID(at:), keyIndex: model.keyIndex(in:)
        ) { index in
          mode = .all
          scrollTarget = index
          topMonth = model.monthTitle(at: index)
        }
      }
    } else {
      ContentUnavailableView {
        Label("Allow Photo Access", systemImage: "photo.badge.exclamationmark")
      } description: {
        Text("Allow access to see your library here.")
      } actions: {
        Button("Allow Access") {
          Task {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await model.load()
          }
        }
        .buttonStyle(.glassProminent)
      }
    }
  }

  @ViewBuilder private var emptyState: some View {
    if model.filter != .all {
      ContentUnavailableView {
        Label(model.filter.emptyTitle, systemImage: model.filter.symbol)
      } actions: {
        Button("Show All Items") { Task { await model.setFilter(.all) } }
      }
    } else {
      ContentUnavailableView(
        "No Photos", systemImage: "photo.on.rectangle",
        description: Text("Photos and videos appear here."))
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(iOS)
      ToolbarItem(placement: .topBarTrailing) {
        if isSelecting {
          Button(selection.count == model.itemCount ? "Deselect All" : "Select All") {
            selection = selection.count == model.itemCount ? [] : Set(0..<model.itemCount)
          }
        } else {
          filterMenu
        }
      }
      // Separate pieces of glass, as in Photos.
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
      ToolbarItem(placement: .topBarTrailing) {
        Button(isSelecting ? "Cancel" : "Select") {
          withAnimation(.smooth) { isSelecting.toggle() }
        }
        .disabled(model.itemCount == 0)
      }
    #else
      if showsModes, opened == nil {
        ToolbarItem(placement: .principal) { modePicker }
      }
      if opened == nil {
        ToolbarItemGroup {
          if !selection.isEmpty {
            selectionButtons
          }
          Button {
            zoomStep = min(zoomStep + 1, PhotoGridZoom.cellWidthSteps.count - 1)
          } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
          }
          .keyboardShortcut("-", modifiers: .command)
          .disabled(mode != .all && showsModes)
          Button {
            zoomStep = max(zoomStep - 1, 0)
          } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
          }
          .keyboardShortcut("=", modifiers: .command)
          .disabled(mode != .all && showsModes)
          filterMenu
        }
      }
    #endif
  }

  private var filterMenu: some View {
    LibraryFilterMenu(
      filter: model.filter, filters: LibraryFilter.deviceFilters,
      select: { filter in Task { await model.setFilter(filter) } })
  }

  private var modePicker: some View {
    Picker("View", selection: $mode) {
      ForEach(LibraryTimelineMode.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }

  /// Resolved when an action runs, since `picked` can trail the selection by a moment.
  private var selectedAssets: [PHAsset] { model.assets(at: selection) }

  @ViewBuilder private var selectionButtons: some View {
    let assets = picked
    PhotoShareButton(
      items: assets.map(SharedAsset.init), identities: assets.map(PhotoKitImageSource.identity(for:)),
      videoCount: assets.filter { $0.mediaType == .video }.count
    ) {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .disabled(assets.isEmpty)
    Button {
      let assets = selectedAssets
      run { try await LibraryActions.toggleFavorite(assets) }
    } label: {
      Label(
        assets.allSatisfy(\.isFavorite) && !assets.isEmpty ? "Unfavorite" : "Favorite",
        systemImage: assets.allSatisfy(\.isFavorite) && !assets.isEmpty ? "heart.slash" : "heart")
    }
    .keyboardShortcut(".", modifiers: [])
    .disabled(assets.isEmpty)
    Button {
      albumTargets = AssetGroup(assets: selectedAssets)
    } label: {
      Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
    }
    .disabled(assets.isEmpty)
    Button(role: .destructive) {
      pendingDelete = selectedAssets
    } label: {
      Label("Delete", systemImage: "trash")
    }
    .keyboardShortcut(.delete, modifiers: .command)
    .disabled(assets.isEmpty)
  }

  #if os(iOS)
    private var selectionBar: some View {
      GlassEffectContainer {
        HStack(spacing: 20) {
          selectionButtons
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
      }
      .padding(.bottom, 8)
    }
  #endif

  // MARK: Actions

  /// Laid out as in Photos; tapping the preview opens the photo.
  private func menuItems(for indices: Set<Int>) -> [PhotoGridMenuItem] {
    let assets = model.assets(at: indices)
    guard !assets.isEmpty else { return [] }
    var items: [PhotoGridMenuItem] = []
    if assets.count == 1, let asset = assets.first, asset.mediaType == .image {
      items.append(
        PhotoGridMenuItem(String(localized: "Copy"), systemImage: "doc.on.doc", group: .quick) {
          run { try await LibraryActions.copy(asset) }
        })
    }
    let hidden = model.scope == .hidden
    items.append(
      PhotoGridMenuItem(
        hidden ? String(localized: "Unhide") : String(localized: "Hide"), systemImage: hidden ? "eye" : "eye.slash",
        group: .quick
      ) { run { try await LibraryActions.setHidden(assets, hidden: !hidden) } })
    #if os(iOS)
      items.append(
        PhotoGridMenuItem(String(localized: "Share"), systemImage: "square.and.arrow.up") {
          SharePresenter.share(
            assets.map(SharedAsset.init), identities: assets.map(PhotoKitImageSource.identity(for:)),
            videoCount: assets.filter { $0.mediaType == .video }.count)
        })
    #endif
    let allFavorites = assets.allSatisfy(\.isFavorite)
    items.append(
      PhotoGridMenuItem(
        allFavorites ? String(localized: "Unfavorite") : String(localized: "Favorite"),
        systemImage: allFavorites ? "heart.slash" : "heart"
      ) { run { try await LibraryActions.toggleFavorite(assets) } })
    items.append(
      PhotoGridMenuItem(String(localized: "Add to Album"), systemImage: "rectangle.stack.badge.plus", group: .organize) {
        albumTargets = AssetGroup(assets: assets)
      })
    if case .album(let id, _) = model.scope {
      items.append(
        PhotoGridMenuItem(
          String(localized: "Remove from Album"), systemImage: "rectangle.stack.badge.minus", group: .organize
        ) { run { try await LibraryActions.remove(assets, fromAlbum: id) } })
    }
    items.append(
      PhotoGridMenuItem(String(localized: "Delete"), systemImage: "trash", isDestructive: true) {
        pendingDelete = assets
      })
    return items
  }

  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
      do {
        try await action()
      } catch let error as PHPhotosError where error.code == .userCancelled {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

/// Years and Months: one card per period with a key photo. Choosing a card
/// shows that period in the All grid.
struct TimelineCardsView: View {
  let timeline: TimelineIndex
  let itemCount: Int
  let source: any ThumbnailSource
  let mode: LibraryTimelineMode
  let itemID: (Int) -> String
  let keyIndex: (Range<Int>) -> Int
  /// The item the All grid was showing: the cards open at its period, as in Photos.
  var focusIndex: Int?
  /// The newest period is last, and the cards open there.
  var startsAtEnd = false
  /// Whether the cards show their newest end, and whether any are scrolled under the bar.
  var onAtEndChange: ((Bool) -> Void)?
  var onScrolledUnderBarChange: ((Bool) -> Void)?
  /// The items of the topmost card in view, once they've been scrolled.
  var onTopChange: ((Range<Int>) -> Void)?
  let onSelect: (Int) -> Void
  @State private var hasScrolled = false

  var body: some View {
    let sections = mode == .years ? timeline.years() : timeline.months
    ScrollViewReader { reader in
      cards(sections)
        .onAppear {
          guard let focusIndex, let section = sections.first(where: { $0.range.contains(focusIndex) }) else { return }
          reader.scrollTo(section.id, anchor: .top)
        }
    }
  }

  private func cards(_ sections: [TimelineIndex.Section]) -> some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: mode == .years ? 260 : 320), spacing: 14)], spacing: 14) {
        ForEach(sections) { section in
          Button {
            onSelect(section.range.lowerBound)
          } label: {
            card(section)
          }
          .buttonStyle(.plain)
          .id(section.id)
          .accessibilityLabel(Text("\(title(for: section)), \(countText(section.range.count))"))
        }
      }
      .scrollTargetLayout()
      .padding()
      #if os(iOS)
        .background(BarsFollowScrollView())
      #endif
    }
    .onScrollPhaseChange { _, phase in
      if phase == .interacting { hasScrolled = true }
    }
    .onScrollTargetVisibilityChange(idType: Int.self) { ids in
      guard hasScrolled, let onTopChange, let top = ids.min(), let section = sections.first(where: { $0.id == top })
      else { return }
      onTopChange(section.range)
    }
    .defaultScrollAnchor(startsAtEnd ? .bottom : .top)
    // Opaque, so fading in over the grid shows no grid between the cards at the end.
    .background(.background)
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 1
    } action: { _, atEnd in
      onAtEndChange?(atEnd)
    }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.y + geometry.contentInsets.top > 0
    } action: { _, scrolled in
      onScrolledUnderBarChange?(scrolled)
    }
    .overlay {
      if sections.isEmpty, itemCount > 0 { ProgressView() }
    }
  }

  private func title(for section: TimelineIndex.Section) -> String {
    mode == .years
      ? section.start.formatted(.dateTime.year()) : section.start.formatted(.dateTime.month(.wide).year())
  }

  /// A month as in Photos on iPhone and the Mac: its name above a mosaic of photos from across it.
  @ViewBuilder private func card(_ section: TimelineIndex.Section) -> some View {
    if mode == .months, showsMonthMosaic {
      MonthMosaic(
        title: section.start.formatted(.dateTime.month(.abbreviated).year()), range: section.range, source: source,
        itemID: itemID)
    } else {
      periodCard(section)
    }
  }

  private var showsMonthMosaic: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .phone
    #else
      true
    #endif
  }

  private func periodCard(_ section: TimelineIndex.Section) -> some View {
    LibraryThumbnail(id: itemID(keyIndex(section.range)), bucket: .huge, source: source)
      .aspectRatio(mode == .years ? 1.33 : 1.4, contentMode: .fit)
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title(for: section)).font(.title2.bold())
          // As in Photos, a year is only its name.
          if mode != .years {
            Text(ProductCopy.inflected("^[\(section.range.count) Item](inflect: true)")).font(.subheadline)
          }
        }
        .foregroundStyle(.white)
        .shadow(radius: 6)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
      }
      .clipShape(.rect(cornerRadius: 18))
      .contentShape(.rect(cornerRadius: 18))
  }
}

/// Up to six photos spread evenly across a month: one large with two beside it, three below.
private struct MonthMosaic: View {
  let title: String
  let range: Range<Int>
  let source: any ThumbnailSource
  let itemID: (Int) -> String

  private static let spacing: CGFloat = 4
  private static let maxTiles = 6

  /// Evenly spaced, so a month costs the same however many items it holds.
  private var picks: [Int] {
    let count = min(Self.maxTiles, range.count)
    guard count > 1 else { return range.isEmpty ? [] : [range.lowerBound] }
    let step = Double(range.count - 1) / Double(count - 1)
    return (0..<count).map { range.lowerBound + Int((Double($0) * step).rounded()) }
  }

  var body: some View {
    let picks = picks
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.title2.bold()).foregroundStyle(.primary)
      switch picks.count {
      case 0: EmptyView()
      case 1: tile(picks[0], bucket: .huge).aspectRatio(1.2, contentMode: .fit)
      case 2:
        HStack(spacing: Self.spacing) {
          ForEach(picks, id: \.self) { tile($0, bucket: .huge).aspectRatio(0.75, contentMode: .fit) }
        }
      default:
        VStack(spacing: Self.spacing) {
          // Sized from the width it's given: an adaptive column on a landscape phone or the Mac.
          GeometryReader { proxy in
            let side = (proxy.size.width - Self.spacing) * 2 / 3
            HStack(spacing: Self.spacing) {
              tile(picks[0], bucket: .huge).frame(width: side)
              VStack(spacing: Self.spacing) {
                tile(picks[1])
                tile(picks[2])
              }
            }
          }
          .aspectRatio(1.5, contentMode: .fit)
          if picks.count > 3 {
            HStack(spacing: Self.spacing) {
              ForEach(picks[3...], id: \.self) { tile($0).aspectRatio(1, contentMode: .fit) }
            }
          }
        }
      }
    }
  }

  private func tile(_ index: Int, bucket: ThumbnailBucket = .medium) -> some View {
    LibraryThumbnail(id: itemID(index), bucket: bucket, source: source)
      .clipShape(.rect(cornerRadius: 12))
      .contentShape(.rect(cornerRadius: 12))
  }
}

#if os(iOS)
  /// Makes the scroll view it's placed in the one the bars follow (the tab bar shrinks
  /// with it), as `PhotoGrid` does for its own: once the grid has claimed that, SwiftUI
  /// doesn't hand it back to one of its scroll views.
  private struct BarsFollowScrollView: UIViewRepresentable {
    func makeUIView(context: Context) -> FinderView { FinderView() }
    func updateUIView(_ view: FinderView, context: Context) {}

    final class FinderView: UIView {
      override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var view = superview
        while let current = view, !(current is UIScrollView) { view = current.superview }
        guard let scrollView = view as? UIScrollView else { return }
        var responder = scrollView.next
        while let current = responder, !(current is UITabBarController) {
          (current as? UIViewController)?.setContentScrollView(scrollView, for: [.top, .bottom])
          responder = current.next
        }
      }
    }
  }
#endif

#if os(iOS)
  let gridTopPadding: CGFloat = 14
#else
  let gridTopPadding: CGFloat = 0
#endif

/// "149 Items", or a blank line while the count is loading.
func countText(_ count: Int?) -> String {
  guard let count else { return " " }
  return ProductCopy.inflected("^[\(count) Item](inflect: true)")
}
