import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// A device or Google Photos item for the share sheet, so a mixed selection shares at once.
public enum UnifiedShareItem: Transferable, Sendable {
  case device(SharedAsset)
  case cloud(RemoteSharedItem)
  case file(FileSharedItem)

  var isVideo: Bool {
    switch self {
    case .device(let shared): shared.asset.mediaType == .video
    case .cloud(let shared): shared.item.kind == .video
    case .file(let shared): shared.item.isVideo
    }
  }

  func export() async throws -> URL {
    switch self {
    case .device(let shared): return try await shared.export()
    case .cloud(let shared): return try await shared.export()
    case .file(let shared):
      guard LocalFirstThumbnailSource.fileAliasIsCurrent(shared.item) else { throw CocoaError(.fileNoSuchFile) }
      return shared.item.url
    }
  }

  public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .movie) { item in SentTransferredFile(try await item.export()) }
      .exportingCondition { $0.isVideo }
    FileRepresentation(exportedContentType: .image) { item in SentTransferredFile(try await item.export()) }
      .exportingCondition { !$0.isVideo }
  }
}

/// The Library tab: one timeline of this device's photos and the Google Photos library.
/// Items on both show once with a backed-up badge; items only in Google Photos show a
/// cloud. Without an account it's the device library.
public struct UnifiedLibraryView: View {
  let model: UnifiedLibraryModel
  let cloudLibrary: CloudLibrary?
  let records: [TransferRecord]
  let recordsRevision: Int?
  let accountsLoaded: Bool
  let isActive: Bool
  @State private var zoomStep: Int
  @State private var selectedIDs: Set<UnifiedLibraryModel.SelectionID> = []
  @State private var selectedPositions: Set<Int> = []
  @State private var selectionToken = -1
  private var selection: Set<Int> {
    selectionToken == model.reloadToken ? selectedPositions : model.selectionPositions(selectedIDs)
  }
  @State private var filterAnchors: [LibraryFilter: String] = [:]
  @State private var isSelecting = false
  @State private var opened: Int?
  @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  /// The month at the top of the grid; set only when it changes, so scrolling
  /// re-renders the screen once a month, not once a row.
  /// What's at the top of the grid. Changes many times a second in a fast scroll, so it
  /// lives in its own object and only the title reads it; the screen doesn't re-render.
  @State private var top = TopOfGrid()
  /// Photos are under the bar: it darkens and the title turns white, as in Photos.
  @State private var isScrolledUnderBar = false
  /// The grid shows its newest photos: the title says how many items there are, as in
  /// Photos; anywhere else it shows the day at the top.
  @State private var isAtNewest = true
  @State private var hasDrawnGrid = false
  /// The viewer zooms out of, and back into, the cell of the photo it shows.
  @State private var zoom = ViewerZoom()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var scrollTarget: Int?
  private var mode: LibraryTimelineMode {
    get { model.timelineMode }
    nonmutating set { model.timelineMode = newValue }
  }
  @State private var lockedFolderMove = LockedFolderMove()
  @State private var pendingDelete: PendingDelete?
  @State private var albumTargets: AlbumTargets?
  @State private var busyMessage: String?
  /// The selection resolved off the main actor, once per change; the toolbar reads this
  /// instead of resolving the whole selection on every redraw.
  @State private var picked = UnifiedLibraryModel.Picked()
  @State private var pickTask: Task<Void, Never>?

  @State private var errorMessage: String?
  /// How the grid looked at the last launch's end, drawn until the grid itself has.
  @State private var snapshot = LibrarySnapshot.ready
  @State private var showsSnapshot = true
  @State private var lastCapture: (time: ContinuousClock.Instant, snapshot: LibrarySnapshot)?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.scenePhase) private var scenePhase

  private struct PendingDelete {
    let ids: Set<UnifiedLibraryModel.SelectionID>
    let reviewed: UnifiedLibraryModel.Picked
    let deviceOnly: Bool

    var count: Int { reviewed.device.count + (deviceOnly ? 0 : reviewed.cloud.count) }

    func matches(_ fresh: UnifiedLibraryModel.Picked, includingCopies: Bool) -> Bool {
      Set(reviewed.device.map(\.localIdentifier)) == Set(fresh.device.map(\.localIdentifier))
        && (deviceOnly || reviewed.cloud.map(\.dedupKey).sorted() == fresh.cloud.map(\.dedupKey).sorted())
        && (!includingCopies || reviewed.cloudCopies.map(\.dedupKey).sorted() == fresh.cloudCopies.map(\.dedupKey).sorted())
    }
  }

  private struct AlbumTargets: Identifiable {
    let id = UUID()
    let rows: Set<UnifiedLibraryModel.SelectionID>
  }

  public init(
    model: UnifiedLibraryModel, cloudLibrary: CloudLibrary?, records: [TransferRecord], recordsRevision: Int?,
    accountsLoaded: Bool, isActive: Bool = true
  ) {
    self.model = model
    self.accountsLoaded = accountsLoaded
    self.isActive = isActive
    self.cloudLibrary = cloudLibrary
    self.records = records
    self.recordsRevision = recordsRevision
    _zoomStep = State(initialValue: Self.defaultZoomStep)
  }

  #if os(iOS)
    private static let defaultZoomStep = PhotoGridZoom.columnSteps.firstIndex(of: PhotoGridZoom.defaultColumns) ?? 3
  #else
    private static let defaultZoomStep = PhotoGridZoom.defaultStep
  #endif

  /// Read live: access granted from the system prompt or Settings shows up here too.
  private var hasAccess: Bool {
    _ = status
    return PhotoLibraryGridModel.hasAccess
  }
  private func refreshPhotoAccess() {
    let updated = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status != updated else { return }
    status = updated
    Task { await model.startLocal() }
  }

  private var showsModes: Bool { model.showsModes }

  public var body: some View {
    #if os(iOS)
      presentations(
        dialogs(
          lifecycle(
            content.navigationTitle("Library").toolbarTitleDisplayMode(.inline)
              .toolbarColorScheme(isOverPhotos ? .dark : colorScheme, for: .navigationBar)
          )))
    #else
      presentations(dialogs(lifecycle(content)))
        .background {
          if isActive {
            Color.clear.gridTitle(String(localized: "Library"), subtitle: subtitle, zoom: zoom)
          }
        }
        .onChange(of: isActive) { _, active in
          if !active { opened = nil }
        }
    #endif
  }

  private var cloudSyncFailed: Bool {
    if case .failed = cloudLibrary?.status { return true }
    return false
  }

  private func loadLibrary(_ view: some View) -> some View {
    view
      .task { await model.startLocal(firstScreen: firstScreen) }
      .task {
        // Thumbnails may never come (offline): the saved screen can't stay over the grid.
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { hideSnapshot() }
      }
      .onReceive(NotificationCenter.default.publisher(for: LockedItems.didLock).receive(on: DispatchQueue.main)) { _ in
        // It may show what was just locked.
        snapshot = nil
      }
      .task(id: accountsLoaded) {
        guard accountsLoaded else { return }
        model.setCloudLibrary(cloudLibrary)
        cloudLibrary?.refresh()
        await model.start(records: records)
        #if DEBUG
          await runReviewHook()
        #endif
      }
      .onChange(of: cloudLibrary.map(ObjectIdentifier.init)) { previous, _ in
        if previous != nil {
          snapshot = nil
          hideSnapshot()
        }
        // The first account is merged once its records are in, by the task above.
        guard accountsLoaded else { return }
        model.setCloudLibrary(cloudLibrary)
        cloudLibrary?.refresh()
        Task { await model.start(records: records) }
      }
      .onChange(of: cloudLibrary?.revision) { Task { await model.cloudChanged() } }
      .onChange(of: cloudLibrary?.isSyncing) { Task { await model.contentProbeConditionsChanged() } }
      .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main)) { _ in
        Task { await model.contentProbeConditionsChanged() }
      }
      .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: DispatchQueue.main)) {
        _ in
        Task { await model.contentProbeConditionsChanged() }
      }
      .onChange(of: cloudSyncFailed) { Task { await model.rebuild() } }
      .onChange(of: cloudLibrary?.syncState.initialSyncDone) { Task { await model.rebuild() } }
      .onChange(of: recordsRevision) { Task { await model.recordsChanged(records) } }
      .onReceive(NotificationCenter.default.publisher(for: AppSettingsStore.didChange).receive(on: DispatchQueue.main)) { _ in
        Task { await model.recordsChanged(records) }
      }
      .onChange(of: model.hasResolvedFilter) { _, complete in
        if complete, model.itemCount == 0 { hideSnapshot() }
      }
      .onChange(of: scenePhase) { _, phase in
        // Changes made in Google Photos elsewhere come in on return, within the sync interval.
        if phase == .active { cloudLibrary?.refresh() }
        Task { await model.contentProbeConditionsChanged() }
      }
      .onChange(of: model.device.reloadToken) { Task { await model.startLocal() } }
  }

  #if DEBUG
    private func runReviewHook() async {
      switch UserDefaults.standard.string(forKey: "UIScreen") {
      case "viewer":
        for _ in 0..<40 where model.itemCount == 0 { try? await Task.sleep(for: .milliseconds(250)) }
        if model.itemCount > 0 { zoom.open(0, in: model) { opened = 0 } }
      case "cloudGridStress", "cloudPinchStress":
        // Waits for the 100,000-item library, then flings through it and logs frame times.
        for _ in 0..<600 where cloudLibrary?.isSyncing != false || model.itemCount < 90_000 {
          try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        if UserDefaults.standard.string(forKey: "UIScreen") == "cloudPinchStress" {
          zoom.proxy.runPinchStress(seconds: 12)
        } else {
          zoom.proxy.runStress(seconds: 6)
        }
      case "cloudFilmstripStress":
        for _ in 0..<600 where cloudLibrary?.isSyncing != false || model.itemCount < 90_000 {
          try? await Task.sleep(for: .milliseconds(500))
        }
        zoom.open(50_000, in: model) { opened = 50_000 }
      case "cloudViewer":
        // Local folder items can arrive first; this hook must open a cloud photo.
        for _ in 0..<40 {
          if let index = model.entries.firstIndex(where: {
            if case .cloud(let index) = $0 { return model.cloud?.item(at: index)?.kind == .photo }
            return false
          }) {
            zoom.open(index, in: model) { opened = index }
            break
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
      default: break
      }
    }
  #endif

  private func lifecycle(_ view: some View) -> some View {
    loadLibrary(view.toolbar { toolbar })
      // Tried again as the Library loads, until the item is there.
      .task(id: [model.openRequest?.token ?? -1, model.reloadToken]) { await openRequested() }
      // Positions shift when items arrive or leave, so the selection follows its items.
      #if os(iOS)
        .task(
          id: SnapshotTrigger(
            rows: model.reloadToken, badges: model.badgeToken, zoom: zoomStep,
            canTake: !showsSnapshot && opened == nil && model.isAtNewest && !isSelecting && mode == .all
              && model.filter == .all)
        ) {
          guard !showsSnapshot, opened == nil, model.isAtNewest else { return }
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          if scenePhase == .active { saveSnapshot() }
        }
      #endif
      .onChange(of: model.reloadToken) {
        if let id = top.periodID { top.period = model.position(ofIndexID: id) }
        select(model.selectionPositions(selectedIDs))
      }
      .onChange(of: model.displayedFilter) { old, filter in
        filterAnchors[old] = model.isAtNewest ? nil : top.anchorID
        if let id = filterAnchors[filter], let index = model.position(ofIndexID: id) {
          scrollTarget = index
        } else if model.itemCount > 0 {
          scrollTarget = model.itemCount - 1
        }
      }
      // Back to All from Years or Months, at the period that was showing.
      .onChange(of: model.timelineMode) { old, mode in
        if old == .all {
          top.period = top.index
          top.periodID = top.anchorID
        }
        if mode == .all {
          if scrollTarget == nil, let index = top.period { scrollTarget = index }
          top.period = nil
          top.periodID = nil
        }
        // The next view opens at its newest end, then moves to the period that was showing
        // and says so.
        model.isAtNewest = true
      }
      .onChange(of: model.showNewestRequest) { showNewest() }
      .onChange(of: isSelecting) { _, selecting in
        model.isSelecting = selecting
        if !selecting { select([]) }
      }
      .onChange(of: SelectionRevision(ids: selectedIDs, reload: model.reloadToken, badges: model.badgeToken)) { _, revision in
        pickTask?.cancel()
        picked = .init()
        pickTask = Task {
          // Drag-selecting changes the selection per row; resolve once it pauses.
          try? await Task.sleep(for: .milliseconds(80))
          guard !Task.isCancelled else { return }
          let resolved = await model.picked(model.selectionPositions(revision.ids))
          if !Task.isCancelled, model.reloadToken == revision.reload, model.badgeToken == revision.badges,
            selectedIDs == revision.ids
          {
            picked = resolved
          }
        }
      }
      .refreshable { cloudLibrary?.refresh(force: true) }
  }

  private struct SelectionRevision: Equatable {
    let ids: Set<UnifiedLibraryModel.SelectionID>
    let reload: Int
    let badges: Int
  }

  private func select(_ indices: Set<Int>) {
    selectedPositions = indices
    selectionToken = model.reloadToken
    selectedIDs = Set(indices.compactMap(model.selectionID(at:)))
  }

  /// The cells the grid shows when it opens, at the zoom it opens at.
  private var firstScreen: (count: Int, pixelSide: CGFloat)? {
    #if os(iOS)
      guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return nil }
      let columns = CGFloat(PhotoGridZoom.columnSteps[min(max(zoomStep, 0), PhotoGridZoom.columnSteps.count - 1)])
      let side = (screen.bounds.width - (columns - 1) * 2) / columns
      guard side > 0 else { return nil }
      let rows = Int((screen.bounds.height / side).rounded(.up)) + 1
      return (rows * Int(columns), side * screen.scale)
    #else
      return nil
    #endif
  }

  /// From Years or Months, back to All at its newest.
  private func showNewest() {
    guard model.itemCount > 0 else { return }
    guard mode == .all else {
      top.period = nil
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { mode = .all }
      return
    }
    zoom.proxy.scrollToEnd()
  }

  private func dialogs(_ view: some View) -> some View {
    view
      .modifier(LockedFolderMovePresentation(move: lockedFolderMove))
      .confirmationDialog(
        deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        titleVisibility: .visible
      ) {
        if let pending = pendingDelete {
          // As in Google Photos: a backed-up item goes from both places unless asked otherwise.
          Button(
            pending.deviceOnly || pending.reviewed.cloudCopies.isEmpty ? "Delete" : "Delete Everywhere",
            role: .destructive
          ) {
            delete(pending, deviceOnly: pending.deviceOnly)
          }
          if !pending.deviceOnly, !pending.reviewed.cloudCopies.isEmpty {
            Button("Delete from This Device", role: .destructive) { delete(pending, deviceOnly: true) }
          }
        }
      } message: {
        Text(deleteMessage)
      }
      .sheet(item: $albumTargets) { targets in
        AlbumPickerSheet(
          assets: [], count: model.selectionPositions(targets.rows).count,
          resolve: { await model.resolveSelection(targets.rows).device }
        ) {
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
      .overlay(alignment: .bottom) {
        if let busyMessage {
          Label(busyMessage, systemImage: "arrow.down.circle")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect()
            .padding(.bottom, 90)
            .transition(.opacity)
        }
      }
  }

  private func presentations(_ view: some View) -> some View {
    #if os(iOS)
      view
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
          if isSelecting {
            selectionBar.transition(.move(edge: .bottom).combined(with: .opacity))
          } else if showsModes, !LibraryModePicker.isInTabBar {
            LibraryModePicker(model: model).padding(.bottom, 8)
          }
        }
        // Drawn here rather than as the tab bar's accessory, which wraps it in a second capsule.
        .overlay {
          ZStack {
            if LibraryModePicker.isInTabBar, showsModes, !isSelecting, model.isTabBarMinimized {
              LibraryModePicker(model: model)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .transition(.opacity)
            }
          }
          .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.isTabBarMinimized)
        }
        .photoViewer(index: $opened, source: model, zoom: zoom)
        .task {
          guard snapshot == nil, showsSnapshot, let loaded = await LibrarySnapshot.load(), showsSnapshot else { return }
          snapshot = loaded
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background { saveSnapshot() }
          if phase == .active { refreshPhotoAccess() }
        }
    #else
      view.photoViewer(index: $opened, source: model, zoom: zoom)
        .task {
          guard snapshot == nil, showsSnapshot, let loaded = await LibrarySnapshot.load(), showsSnapshot else { return }
          snapshot = loaded
        }
        // A Mac app quits from anywhere, often without going to the background first.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
          saveSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          refreshPhotoAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
          if let window = zoom.proxy.window, note.object as? NSWindow === window { saveSnapshot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          saveSnapshot(now: true)
        }
    #endif
  }

  /// Siri or Spotlight asked for an item: the viewer opens on it once the Library has it.
  /// While the Library loads (a large one, at launch) each reload tries again; a request
  /// for an item that never appears is dropped after two minutes.
  private func openRequested() async {
    guard let (id, token, madeAt) = model.openRequest else { return }
    if model.filter != .all, model.position(ofIndexID: id) == nil {
      // The rebuild without the filter tries again.
      await model.setFilter(.all)
      return
    }
    guard model.position(ofIndexID: id) != nil else {
      if ContinuousClock.now - madeAt > .seconds(120) { model.finishOpenRequest(token: token) }
      return
    }
    if opened != nil {
      opened = nil
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
    }
    // Read after the wait: the Library may have changed meanwhile.
    guard let position = model.position(ofIndexID: id) else { return }
    isSelecting = false
    zoom.open(position, in: model) { opened = position }
    model.finishOpenRequest(token: token)
  }

  #if os(iOS)
    /// Photos scrolled under the bar turn it dark with white text, as in Photos; at the top
    /// edge the grid starts below the title on the plain background.
    private var isOverPhotos: Bool {
      shownSnapshot?.info.isScrolledUnderBar ?? (model.itemCount > 0 && isScrolledUnderBar)
    }

    private var showsSnapshotImage: Bool { shownSnapshot != nil }
  #endif

  /// As in Photos, Years and Months have no title or buttons over their cards. The bar
  /// itself stays, so nothing under it moves or changes color on the way.
  private var showsBarItems: Bool { mode == .all || !showsModes }

  private var subtitle: String {
    // On iPhone the count of selected items is in the selection bar.
    #if os(macOS)
      if isSelecting || selection.count > 1 {
        return selection.isEmpty ? String(localized: "Select Items") : String(localized: "\(selection.count) Selected")
      }
    #endif
    if model.displayedFilter != model.filter { return " " }
    if case .syncing(let progress) = cloudLibrary?.status, cloudLibrary?.syncState.initialSyncDone == false {
      return String(localized: "Syncing \(progress.updated.formatted()) items…")
    }
    // On iPhone the day at the top of the grid is drawn by the title itself (see `top`).
    #if os(macOS)
      // The timeline runs oldest first; the grid opens at its newest end.
      if mode == .all, model.filter == .all, let month = top.title ?? model.monthTitle(at: model.itemCount - 1) { return month }
    #endif
    #if os(iOS)
      // The snapshot's count, until the library has loaded.
      if !model.isLoaded, let count = shownSnapshot?.info.itemCount {
        return ProductCopy.inflected("^[\(count) Item](inflect: true)")
      }
    #endif
    return model.isLoaded ? ProductCopy.inflected("^[\(model.itemCount) Item](inflect: true)") : " "
  }

  /// The device's items first: if the system's own prompt is declined, nothing is
  /// trashed in Google Photos either.
  private func delete(_ pending: PendingDelete, deviceOnly: Bool) {
    let library = model.cloud?.library
    run(nil) {
      let fresh = await model.resolveSelection(pending.ids)
      let reviewed = PendingDelete(ids: pending.ids, reviewed: fresh, deviceOnly: deviceOnly)
      guard reviewed.count > 0 else { return }
      let changedCount = pending.count != reviewed.count
      if changedCount || !pending.matches(fresh, includingCopies: !deviceOnly) {
        pendingDelete = reviewed
        return
      }

      if !fresh.device.isEmpty { try await LibraryActions.delete(fresh.device) }
      if !deviceOnly, library === model.cloud?.library, let library {
        var seen = Set<String>()
        let cloud = (fresh.cloud + fresh.cloudCopies).filter {
          !LockedItems.contains($0.mediaKey, accountEmail: library.accountEmail) && seen.insert($0.mediaKey).inserted
        }
        if !cloud.isEmpty { try await library.trash(cloud) }
      }
      isSelecting = false
    }
  }

  private var deleteTitle: String {
    guard let pending = pendingDelete else { return "" }
    return pending.count == 1 ? String(localized: "Delete This Item?") : String(localized: "Delete \(pending.count) Items?")
  }

  private var deleteMessage: String {
    guard let pending = pendingDelete else { return "" }
    var parts: [String] = []
    if !pending.reviewed.device.isEmpty {
      parts.append(String(localized: "Items on this device are also removed from iCloud Photos, if you use it."))
    }
    if !pending.deviceOnly, !pending.reviewed.cloudCopies.isEmpty {
      parts.append(
        String(
          localized:
            "Delete Everywhere also moves their Google Photos copies to its Trash for 60 days."))
    } else if !pending.deviceOnly, !pending.reviewed.cloud.isEmpty {
      parts.append(String(localized: "Items only in Google Photos move to its Trash for 60 days."))
    }
    if !pending.reviewed.files.isEmpty {
      parts.append(String(localized: "Files in backed-up folders stay in their folders."))
    }
    return parts.joined(separator: " ")
  }

  // MARK: Content

  @ViewBuilder private var content: some View {
    // Backed-up folders have photos to show without photo access, so it's asked for only
    // once the first merge has found nothing.
    if !hasAccess, accountsLoaded, cloudLibrary == nil, model.hasResolvedFilter, model.itemCount == 0, model.filter == .all {
      ContentUnavailableView {
        Label("Allow Photo Access", systemImage: "photo.badge.exclamationmark")
      } description: {
        Text("Allow access to see your library here.")
      } actions: {
        Button("Allow Access") {
          Task {
            // Once refused, only Settings can change it: the prompt doesn't show again.
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied {
              #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
              #else
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                  NSWorkspace.shared.open(url)
                }
              #endif
              return
            }
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await model.start(records: records)
          }
        }
        .buttonStyle(.glassProminent)
      }
    } else if model.hasResolvedFilter, model.itemCount == 0, model.mirrorRetry == nil {
      emptyState
    } else {
      // One stack, so the farther view (Years over Months over All) is always the one on
      // top, and the one that fades.
      ZStack {
        timelineContent
          .opacity(model.displayedFilter == model.filter ? 1 : 0)
          .allowsHitTesting(model.displayedFilter == model.filter)
          .accessibilityHidden(model.displayedFilter != model.filter)
        launchFeedback
        if showsLoadingIndicator, model.launchIsStillEmpty, shownSnapshot == nil {
          ContentUnavailableView("Library Is Still Loading", systemImage: "photo.on.rectangle")
        }
        if model.mirrorRetry == .empty {
          ContentUnavailableView {
            Label("Couldn’t Load Library", systemImage: "photo.badge.exclamationmark")
          } actions: {
            Button("Try Again") { Task { await model.cloudChanged() } }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if model.mirrorRetry == .banner {
          HStack(spacing: 12) {
            Text("Couldn't Load New Items")
            Button("Try Again") { Task { await model.cloudChanged() } }
              .buttonStyle(.glass)
          }
          .padding(12)
          .glassEffect()
          .padding(.bottom, 8)
        }
      }
    }
  }

  private var showsLoadingIndicator: Bool {
    (model.displayedFilter != model.filter || model.itemCount == 0) && !model.mirrorReadFailed
  }

  #if os(iOS)
    /// The last launch's grid, for the moments before this one's has drawn; it fades out
    /// over the live grid. Only where it would look the same: same size, scale and
    /// appearance.
    @ViewBuilder private var launchFeedback: some View {
      // The grid itself draws the snapshot, under the bar's own effect.
      if shownSnapshot != nil {
        Color.clear
          .allowsHitTesting(false)
          .onAppear { model.showsSavedScreen = true }
          .onDisappear { model.showsSavedScreen = false }
      } else if showsLoadingIndicator, !model.launchIsStillEmpty {
        LateProgressView(title: "Loading Library…")
      }
    }

    private var shownSnapshot: LibrarySnapshot? {
      // Prefetch can finish after State was initialized but before this first body pass.
      guard let snapshot = snapshot ?? LibrarySnapshot.ready, canShowSnapshot(snapshot), mode == .all, !isSelecting,
        snapshot.info.scale == displayScale,
        snapshot.info.isDark == (colorScheme == .dark),
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size,
        abs(screen.width - snapshot.info.width) < 1, abs(screen.height - snapshot.info.height) < 1
      else { return nil }
      return snapshot
    }

  #else
    /// The saved grid uses the current layout and appearance while live pixels load.
    @ViewBuilder private var launchFeedback: some View {
      let candidate = shownSnapshot
      if candidate != nil || (showsLoadingIndicator && !model.launchIsStillEmpty) {
        GeometryReader { proxy in
          if let snapshot = candidate,
            abs(proxy.size.width - snapshot.info.width) < 1, abs(proxy.size.height - snapshot.info.height) < 1
          {
            Image(decorative: snapshot.image, scale: snapshot.info.scale)
              .onAppear { model.showsSavedScreen = true }
              .onDisappear { model.showsSavedScreen = false }
              .onTapGesture { hideSnapshot() }
              .accessibilityHidden(true)
              .transition(.opacity)
          } else if showsLoadingIndicator, !model.launchIsStillEmpty {
            ProgressView("Loading Library…")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .allowsHitTesting(candidate != nil)
      }
    }

    private var shownSnapshot: LibrarySnapshot? {
      guard let snapshot, canShowSnapshot(snapshot), mode == .all, !isSelecting, selection.isEmpty,
        zoomStep == PhotoGridZoom.defaultStep, snapshot.info.scale == displayScale,
        snapshot.info.isDark == (colorScheme == .dark)
      else { return nil }
      return snapshot
    }

  #endif

  private func canShowSnapshot(_ snapshot: LibrarySnapshot) -> Bool {
    showsSnapshot && snapshot.generation == LibrarySnapshot.currentGeneration
      && model.filter == .all && status == .authorized
      // On the first frames, before the accounts are read: signing out, switching account and
      // locking an item all delete it.
      && (!accountsLoaded || snapshot.info.accountEmail == cloudLibrary?.accountEmail)
  }

  private func hideSnapshot() {
    guard showsSnapshot else { return }
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showsSnapshot = false }
  }

  /// What the next launch's first frame would show. It's saved again a moment after any
  /// of it changes (items added or removed, the viewer closed, back at the newest photos),
  /// not only on the way out: the app may leave from somewhere it can't be taken, or be
  /// stopped in the foreground, and an older picture would move once the grid is live.
  private struct SnapshotTrigger: Hashable {
    let rows: Int
    let badges: Int
    let zoom: Int
    let canTake: Bool
  }

  private func saveSnapshot(now: Bool = false) {
    guard status == .authorized, accountsLoaded, mode == .all, model.filter == .all, !isSelecting,
      selection.isEmpty, opened == nil, model.isAtNewest, model.isLoaded, model.itemCount > 0,
      zoomStep == Self.defaultZoomStep
    else { return }
    let generation = LibrarySnapshot.currentGeneration
    let time = ContinuousClock.now
    if let recent = lastCapture, recent.snapshot.generation == generation,
      recent.snapshot.info.accountEmail == cloudLibrary?.accountEmail,
      recent.time.duration(to: time) < .milliseconds(500)
    {
      if now { LibrarySnapshot.saveNow(recent.snapshot.image, info: recent.snapshot.info, generation: generation) }
      return
    }
    guard let image = zoom.proxy.snapshot() else { return }
    let info = LibrarySnapshot.Info(
      width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale, scale: displayScale,
      isDark: colorScheme == .dark, itemCount: model.itemCount, isScrolledUnderBar: isScrolledUnderBar,
      accountEmail: cloudLibrary?.accountEmail)
    lastCapture = (time, LibrarySnapshot(image: image, info: info, generation: generation))
    if now {
      LibrarySnapshot.saveNow(image, info: info, generation: generation)
    } else {
      LibrarySnapshot.save(image, info: info, generation: generation)
    }
  }

  private var gridOptions: PhotoGridOptions {
    var options = PhotoGridOptions(
      isSelecting: isSelecting,
      onTopIndexChange: { index in
        #if os(iOS)
          let title = model.dayTitle(at: index)
        #else
          let title = model.monthTitle(at: index)
        #endif
        top.index = index
        top.anchorID = model.indexID(at: index)
        if title != top.title { top.title = title }
      }, menu: { menuItems(for: $0) },
      dragItem: { model.dragItem(at: $0) }, proxy: zoom.proxy,
      onPinchPastDensest: showsModes
        ? { withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { mode = .months } } : nil,
      onScrolledUnderBarChange: { scrolled in
        let animates = hasDrawnGrid && !reduceMotion
        hasDrawnGrid = true
        withAnimation(animates ? .smooth(duration: 0.25) : nil) { isScrolledUnderBar = scrolled }
      },
      topPadding: 14, startsAtEnd: true,
      onAtEndChange: { atEnd in
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isAtNewest = atEnd }
        model.isAtNewest = atEnd
      },
      onShowItems: { hideSnapshot() })
    options.positionOfItem = { model.index(ofItemID: $0, near: 0) }
    options.currentReloadToken = { model.reloadToken }
    options.itemsToCome = model.itemsToCome
    #if os(iOS)
      options.placeholderCount = model.itemCount == 0 ? shownSnapshot?.info.itemCount ?? 0 : 0
      options.placeholderImage = shownSnapshot?.image
    #endif
    return options
  }

  @ViewBuilder private var timelineContent: some View {
    if mode == .all || !showsModes {
      PhotoGrid(
        dataSource: model, reloadToken: model.reloadToken, badgeToken: model.badgeToken, zoomStep: $zoomStep,
        selection: Binding(get: { selection }, set: select), scrollTarget: $scrollTarget, options: gridOptions
      ) { index in
        zoom.open(index, in: model) { opened = index }
      }
      .ignoresSafeArea(edges: [.top, .bottom])
      .zIndex(0)
      .transition(TimelineZoom(model: model, mode: .all))
    } else {
      TimelineCardsView(
        timeline: model.timeline, itemCount: model.itemCount, source: model.thumbnailSource, mode: mode,
        itemID: model.itemID(at:), keyIndex: model.keyIndex(in:), focusIndex: top.period ?? top.index, startsAtEnd: true,
        onAtEndChange: { model.isAtNewest = $0 },
        onScrolledUnderBarChange: { scrolled in
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isScrolledUnderBar = scrolled }
        },
        // Back in All, the grid opens at the period scrolled to here; at the same place
        // as before if that's still the one.
        onTopChange: { range in
          if !(top.period.map(range.contains) ?? false) {
            top.period = range.lowerBound
            top.periodID = model.indexID(at: range.lowerBound)
          }
        }
      ) { index in
        scrollTarget = index
        top.index = index
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { mode = .all }
      }
      .id(mode)
      .zIndex(Double(LibraryTimelineMode.all.depth - mode.depth))
      .transition(TimelineZoom(model: model, mode: mode))
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
        "No Photos", systemImage: "photo.on.rectangle", description: Text("Photos and videos appear here."))
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(iOS)
      // Photos keeps a large title on the left while the grid scrolls under the bar (and
      // while selecting), rather than collapsing it to a small centered one.
      ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
      if showsBarItems {
        ToolbarItem(placement: .topBarLeading) {
          LargeBarTitle(
            title: String(localized: "Library"), subtitle: subtitle,
            top: mode == .all && model.filter == .all && !isAtNewest ? top : nil,
            isOverContent: isOverPhotos)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { filterMenu }
      }
      // As in Photos: Filter and Select are separate pieces of glass; while selecting,
      // Filter and "…" share one and Done stands alone.
      if isSelecting {
        ToolbarItem(placement: .topBarTrailing) { selectionMenu }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done", systemImage: "xmark") { withAnimation(reduceMotion ? nil : .smooth) { isSelecting = false } }
        }
      } else if showsBarItems {
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
          Button("Select") { withAnimation(reduceMotion ? nil : .smooth) { isSelecting = true } }
            .disabled(model.itemCount == 0 && !showsSnapshotImage)
        }
      }
    #else
      // The viewer puts its own controls in the toolbar while it's open.
      if isActive, showsModes, opened == nil {
        ToolbarItem(placement: .principal) { LibraryModePicker(model: model) }
      }
      if isActive, opened == nil {
        ToolbarItemGroup {
          if !selection.isEmpty { selectionButtons }
          Button {
            zoomStep = min(zoomStep + 1, PhotoGridZoom.cellWidthSteps.count - 1)
          } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
          }
          .keyboardShortcut("-", modifiers: .command)
          // Years and Months have no zoom of their own.
          .disabled(mode != .all)
          Button {
            zoomStep = max(zoomStep - 1, 0)
          } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
          }
          .keyboardShortcut("=", modifiers: .command)
          .disabled(mode != .all)
          if let cloudLibrary {
            Button {
              cloudLibrary.refresh(force: true)
            } label: {
              Label("Sync Google Photos", systemImage: "arrow.clockwise")
            }
            .disabled(cloudLibrary.isSyncing)
            // ⌘R is Sync Now, the backup's own, in the Backup menu.
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Sync Google Photos (⌥⌘R)")
          }
          filterMenu
        }
      }
    #endif
  }

  private var filterMenu: some View {
    LibraryFilterMenu(
      filter: model.filter, filters: model.availableFilters, select: { filter in Task { await model.setFilter(filter) } },
      zoom: zoomFromMenu,
      showsScreenshots: Binding(
        get: { model.showsScreenshots }, set: { shows in Task { await model.setShowsScreenshots(shows) } }))
  }

  /// On iPhone the grid's zoom is in the menu; the Mac has toolbar buttons and shortcuts.
  private var zoomFromMenu: ((Bool) -> Void)? {
    #if os(iOS)
      { closer in
        guard mode == .all else { return }
        zoomStep = closer ? max(zoomStep - 1, 0) : min(zoomStep + 1, PhotoGridZoom.columnSteps.count - 1)
      }
    #else
      nil
    #endif
  }

  // MARK: Selection

  private func share(_ rows: Set<UnifiedLibraryModel.SelectionID>) {
    withFreshSelection(rows) { fresh in
      var items = fresh.device.map { UnifiedShareItem.device(SharedAsset($0)) }
      var identities = fresh.device.map(PhotoKitImageSource.identity(for:))
      if let library = model.cloud?.library {
        items += fresh.cloud.map { .cloud(RemoteSharedItem(library: library, item: $0)) }
        identities += fresh.cloud.map { library.localFirstThumbnails.thumbnailIdentity(for: $0.thumbnailID) }
      }
      items += fresh.files.map { .file(FileSharedItem(item: $0)) }
      identities += fresh.files.map(\.thumbnailIdentity)
      SharePresenter.share(items, identities: identities, videoCount: items.filter(\.isVideo).count)
    }
  }

  /// Folder files can only be shared, so a selection of just those still can be.
  private var cannotShare: Bool { selection.isEmpty || (picked.isEmpty && picked.files.isEmpty) }

  @ViewBuilder private var selectionButtons: some View {
    let cloud = picked.cloud
    Button {
      select([])
    } label: {
      Label("Deselect All", systemImage: "xmark.circle")
    }
    .help("Deselect All (Esc)")
    let empty = picked.isEmpty || selection.isEmpty
    let allFavorites = picked.allFavorites
    Button {
      share(selectedIDs)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .disabled(cannotShare)
    Button {
      withFreshSelection(selectedIDs) { toggleFavorite(device: $0.device, cloud: $0.cloud) }
    } label: {
      Label(allFavorites ? "Unfavorite" : "Favorite", systemImage: allFavorites ? "heart.slash" : "heart")
    }
    .keyboardShortcut(".", modifiers: [])
    .disabled(empty)
    if cloud.isEmpty {
      Button {
        openAlbumPicker(selectedIDs)
      } label: {
        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
      }
      .disabled(empty)
    } else {
      Button {
        withFreshSelection(selectedIDs) { save($0.cloud) }
      } label: {
        Label("Save to Device", systemImage: "arrow.down.circle")
      }
    }
    if let cloudLibrary, picked.lockableCloudItems.contains(where: cloudLibrary.canMoveToLockedFolder) {
      Button(LockedFolderMove.title, systemImage: LockedFolderMove.symbol) {
        requestLockedFolderMove(selectedIDs)
      }
    }
    Button(role: .destructive) {
      requestDelete(selectedIDs)
    } label: {
      Label("Delete", systemImage: "trash")
    }
    .keyboardShortcut(.delete, modifiers: .command)
    .disabled(empty)
  }

  private func withFreshSelection(
    _ rows: Set<UnifiedLibraryModel.SelectionID>, _ action: @escaping @MainActor (UnifiedLibraryModel.Picked) -> Void
  ) {
    Task {
      let fresh = await model.resolveSelection(rows)
      guard !fresh.isEmpty || !fresh.files.isEmpty else { return }
      action(fresh)
    }
  }

  private func requestLockedFolderMove(_ rows: Set<UnifiedLibraryModel.SelectionID>) {
    guard let library = model.cloud?.library else { return }
    withFreshSelection(rows) { fresh in
      guard library === model.cloud?.library else { return }
      lockedFolderMove.request(
        fresh.lockableCloudItems, in: library, keepsLocalCopies: !fresh.cloudCopies.isEmpty || !fresh.folderCloudCopies.isEmpty
      ) { isSelecting = false }
    }
  }

  private func requestDelete(_ rows: Set<UnifiedLibraryModel.SelectionID>) {
    withFreshSelection(rows) { fresh in
      guard !fresh.isEmpty else { return }
      pendingDelete = PendingDelete(ids: rows, reviewed: fresh, deviceOnly: false)
    }
  }

  private func openAlbumPicker(_ rows: Set<UnifiedLibraryModel.SelectionID>) {
    let devices = rows.filter {
      if case .device = $0 { return true }
      return false
    }
    withFreshSelection(devices) { fresh in
      guard !fresh.device.isEmpty else { return }
      albumTargets = AlbumTargets(rows: Set(fresh.device.map { .device($0.localIdentifier) }))
    }
  }

  #if os(iOS)
    /// As in Photos: share, the count in the middle, delete; the rest is under "…".
    private var selectionBar: some View {
      let empty = picked.isEmpty || selection.isEmpty
      return GlassEffectContainer {
        HStack {
          Button {
            share(selectedIDs)
          } label: {
            Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 36, height: 36)
          }
          .accessibilityLabel("Share")
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .disabled(cannotShare)
          Spacer()
          Text(selection.isEmpty ? String(localized: "Select Items") : String(localized: "\(selection.count) Selected"))
            .font(.headline)
            .contentTransition(.numericText())
            .padding(.horizontal, 22)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
          Spacer()
          Button(role: .destructive) {
            requestDelete(selectedIDs)
          } label: {
            Image(systemName: "trash").font(.title3).frame(width: 36, height: 36)
          }
          .accessibilityLabel("Delete")
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .disabled(empty)
        }
        .padding(.horizontal, 20)
      }
      .padding(.bottom, 8)
    }

    private var selectionMenu: some View {
      let empty = picked.isEmpty || selection.isEmpty
      return Menu {
        Button(
          selection.count == model.itemCount ? "Deselect All" : "Select All",
          systemImage: selection.count == model.itemCount ? "circle" : "checkmark.circle"
        ) {
          select(selection.count == model.itemCount ? [] : Set(0..<model.itemCount))
        }
        Section {
          Button(
            picked.allFavorites ? "Unfavorite" : "Favorite", systemImage: picked.allFavorites ? "heart.slash" : "heart"
          ) {
            withFreshSelection(selectedIDs) { toggleFavorite(device: $0.device, cloud: $0.cloud) }
          }
          .disabled(empty)
          if picked.cloud.isEmpty {
            Button("Add to Album", systemImage: "rectangle.stack.badge.plus") {
              openAlbumPicker(selectedIDs)
            }
            .disabled(empty)
            Button("Hide", systemImage: "eye.slash") {
              withFreshSelection(selectedIDs) { picked in run(nil) { try await LibraryActions.setHidden(picked.device, hidden: true) } }
            }
            .disabled(empty)
          } else {
            Button("Save to Device", systemImage: "arrow.down.circle") { withFreshSelection(selectedIDs) { save($0.cloud) } }
          }
          if let cloudLibrary, picked.lockableCloudItems.contains(where: cloudLibrary.canMoveToLockedFolder) {
            Button(LockedFolderMove.title, systemImage: LockedFolderMove.symbol) {
              requestLockedFolderMove(selectedIDs)
            }
          }
        }
      } label: {
        Label("More", systemImage: "ellipsis")
      }
    }
  #endif

  /// Laid out as in Photos: quick actions as icons, then share and favorite, then
  /// organizing, then delete. Tapping the preview opens the item.
  private func menuItems(for indices: Set<Int>) -> [PhotoGridMenuItem] {
    let rows = Set(indices.compactMap(model.selectionID(at:)))
    let usesPicked = indices.count > 1 && indices == selection && picked.device.count + picked.cloud.count == indices.count
    let (device, cloud) = usesPicked ? (picked.device, picked.cloud) : model.split(indices)
    var items: [PhotoGridMenuItem] = []
    if device.count == 1, cloud.isEmpty, device.first?.mediaType == .image {
      items.append(
        PhotoGridMenuItem(String(localized: "Copy"), systemImage: "doc.on.doc", group: .quick) {
          withFreshSelection(rows) { fresh in
            if let asset = fresh.device.first { run(nil) { try await LibraryActions.copy(asset) } }
          }
        })
    }
    if !device.isEmpty && cloud.isEmpty {
      items.append(
        PhotoGridMenuItem(String(localized: "Hide"), systemImage: "eye.slash", group: .quick) {
          withFreshSelection(rows) { fresh in run(nil) { try await LibraryActions.setHidden(fresh.device, hidden: true) } }
        })
    } else if !cloud.isEmpty {
      items.append(
        PhotoGridMenuItem(String(localized: "Save to Device"), systemImage: "arrow.down.circle", group: .quick) {
          withFreshSelection(rows) { save($0.cloud) }
        })
      if device.isEmpty, let cloudLibrary {
        items.append(
          PhotoGridMenuItem(String(localized: "Archive"), systemImage: "archivebox", group: .quick) {
            withFreshSelection(rows) { fresh in run(nil) { try await cloudLibrary.setArchived(fresh.cloud, archived: true) } }
          })
      }
    }
    #if os(iOS)
      if !rows.isEmpty {
        items.append(PhotoGridMenuItem(String(localized: "Share"), systemImage: "square.and.arrow.up") { share(rows) })
      }
    #endif
    if let cloudLibrary,
      indices.contains(where: { index in
        model.googleCopy(at: index).map(cloudLibrary.canMoveToLockedFolder) == true
      })
    {
      items.append(
        PhotoGridMenuItem(LockedFolderMove.title, systemImage: LockedFolderMove.symbol, group: .organize) {
          requestLockedFolderMove(rows)
        })
    }
    guard !device.isEmpty || !cloud.isEmpty else { return items }
    let allFavorites = device.allSatisfy(\.isFavorite) && cloud.allSatisfy(\.isFavorite)
    items.append(
      PhotoGridMenuItem(
        allFavorites ? String(localized: "Unfavorite") : String(localized: "Favorite"),
        systemImage: allFavorites ? "heart.slash" : "heart"
      ) { withFreshSelection(rows) { toggleFavorite(device: $0.device, cloud: $0.cloud) } })
    if cloud.isEmpty {
      items.append(
        PhotoGridMenuItem(String(localized: "Add to Album"), systemImage: "rectangle.stack.badge.plus", group: .organize) {
          openAlbumPicker(rows)
        })
    }
    items.append(
      PhotoGridMenuItem(String(localized: "Delete"), systemImage: "trash", isDestructive: true) {
        requestDelete(rows)
      })
    return items
  }

  private func toggleFavorite(device: [PHAsset], cloud: [RemoteItemSummary]) {
    let favorite = !(device.allSatisfy(\.isFavorite) && cloud.allSatisfy(\.isFavorite))
    run(nil) {
      let deviceTargets = device.filter { $0.isFavorite != favorite }
      if !deviceTargets.isEmpty { try await LibraryActions.toggleFavorite(deviceTargets) }
      let cloudTargets = cloud.filter { $0.isFavorite != favorite }
      if !cloudTargets.isEmpty, let cloudLibrary { try await cloudLibrary.toggleFavorite(cloudTargets) }
    }
  }

  private func save(_ items: [RemoteItemSummary]) {
    guard let cloudLibrary else { return }
    run(String(localized: "Saving \(items.count) to this device…")) {
      var files: [(url: URL, isVideo: Bool)] = []
      for item in items { files.append((try await cloudLibrary.download(item), item.kind == .video)) }
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

/// Years / Months / All for the merged Library. On iPhone (iOS 26.1 and later) it is the
/// tab bar's accessory: above the bar, and between Library and Search once the bar
/// shrinks on scroll, as in Photos.
public struct LibraryModePicker: View {
  let model: UnifiedLibraryModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  public init(model: UnifiedLibraryModel) {
    self.model = model
  }

  /// Whether the app shows the picker in the tab bar rather than over the grid.
  public static var isInTabBar: Bool {
    #if os(iOS)
      // An iPad's tab bar never shrinks, so the picker stays over the grid there.
      return UIDevice.current.userInterfaceIdiom == .phone
    #else
      return false
    #endif
  }

  public var body: some View {
    // The system's segmented control, which is Liquid Glass on its own.
    Picker(
      "View",
      selection: Binding(
        get: { model.timelineMode },
        set: { mode in withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { model.timelineMode = mode } })
    ) {
      ForEach(LibraryTimelineMode.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    #if os(iOS)
      .controlSize(.extraLarge)
      // Photos' size on iPhone, on the shrunk tab bar's line.
      .frame(width: 260, height: 48)
      // Glass exactly the control's size, so its labels stay readable over photos.
      .glassEffect(.regular, in: .capsule)
      // Dark over the photos of All, as in Photos, where the page behind it may be light.
      .environment(\.colorScheme, model.timelineMode == .all ? .dark : colorScheme)
    #else
      // A toolbar control at the toolbar's size; the toolbar draws its own glass.
      .fixedSize()
    #endif
    .sensoryFeedback(.selection, trigger: model.timelineMode)
  }
}

#if os(iOS)
  /// A title and a line under it, sized like a large navigation title, for a bar whose
  /// title stays put while content scrolls under it.
  struct LargeBarTitle: View {
    let title: String
    let subtitle: String
    /// When set, its title (the day at the top of the grid) replaces `subtitle`.
    var top: TopOfGrid?
    /// Over photos (with a dark scrim behind): white, like Photos.
    var isOverContent = false
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(title).font(.largeTitle.bold())
          .foregroundStyle(isOverContent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        Text(top?.title ?? subtitle).font(.subheadline.weight(.semibold))
          // A long one ("Syncing Google Photos: 12,345 items…") truncates before it reaches
          // Filter and Select.
          .frame(maxWidth: 210, alignment: .leading)
          .foregroundStyle(isOverContent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
          .contentTransition(.numericText())
      }
      .shadow(color: .black.opacity(isOverContent ? 0.25 : 0), radius: 6, y: 1)
      .lineLimit(1)
      .fixedSize()
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
    }
  }
#endif

/// Moving between Years, Months and All, as in Photos: going closer, the cards grow and
/// fade away from the view beneath; going back, they settle down onto it from a little
/// larger. Only the farther of the two moves and fades, on top of the closer one, which
/// stays still and opaque beneath it, so the background never shows through midway. The
/// direction is read from the model as the view leaves, since the leaving view was last
/// drawn before the change.
private struct TimelineZoom: Transition {
  let model: UnifiedLibraryModel
  let mode: LibraryTimelineMode

  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .scaleEffect(scale(phase))
      // The view beneath changes a hair, or SwiftUI would take it away at once.
      .opacity(phase.isIdentity ? 1 : fades(phase) ? 0 : 0.98)
  }

  private func fades(_ phase: TransitionPhase) -> Bool {
    let other = phase == .willAppear ? model.previousTimelineMode : model.timelineMode
    return mode.depth < other.depth
  }

  private func scale(_ phase: TransitionPhase) -> CGFloat {
    guard fades(phase) else { return 1 }
    let zoomsIn = model.timelineZoomsIn
    switch phase {
    case .willAppear: return zoomsIn ? 0.94 : 1.06
    case .didDisappear: return zoomsIn ? 1.1 : 0.94
    case .identity: return 1
    }
  }
}

/// The item at the top of a grid and its date, updated as it scrolls.
@MainActor
@Observable
final class TopOfGrid {
  var title: String?
  /// Read only from actions and closures, never from a view body.
  @ObservationIgnored var index: Int?
  @ObservationIgnored var anchorID: String?
  @ObservationIgnored var periodID: String?
  /// In Years and Months, the item All goes back to: where the grid was, or the period
  /// scrolled to since. The grid reports its own top as soon as it's made again, so this
  /// is kept apart.
  @ObservationIgnored var period: Int?
}

/// A wait worth mentioning: a quick one shows nothing.
private struct LateProgressView: View {
  let title: LocalizedStringKey
  @State private var isLate = false

  var body: some View {
    ZStack {
      if isLate { ProgressView(title) }
    }
    .task {
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      isLate = true
    }
  }
}
