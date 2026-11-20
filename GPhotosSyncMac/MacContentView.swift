import GPhotosKit
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
  @Bindable var store: MacSyncStore
  @Bindable var router: MacRouter
  @State private var library = UnifiedLibraryModel()
  @State private var indexer = LibraryIndexer()
  /// Albums and media types, shared by the sidebar and Collections.
  @State private var collections = PhotoCollectionsModel()
  @State private var searchQuery = ""
  @FocusState private var isSearchFocused: Bool
  @State private var searchPath = NavigationPath()
  @State private var collectionsPath = NavigationPath()

  var body: some View {
    NavigationSplitView {
      MacSidebar(store: store, router: router, collections: collections)
    } detail: {
      detail
    }
    // In the sidebar, as in Music and Notes, so it's there on every screen; typing shows
    // the results in Search.
    .searchable(text: $searchQuery, placement: .sidebar, prompt: searchPrompt)
    .searchFocused($isSearchFocused)
    // Return shows the results. The field keeps focus on the Mac, which would keep the
    // suggestions up, and a sidebar search field never sends `onSubmit(of: .search)`.
    .background { SearchFieldReturnMonitor { isSearchFocused = false } }
    .onChange(of: searchQuery) { _, query in
      if !query.isEmpty, router.section != .search { router.show(.search) }
    }
    .onChange(of: router.focusLibrarySearch, initial: true) { _, wanted in
      guard wanted else { return }
      isSearchFocused = true
      router.focusLibrarySearch = false
    }
    .sheet(isPresented: $router.isSigningIn) {
      MacSignInSheet(store: store) { router.isSigningIn = false }
    }
    .fileImporter(
      isPresented: $router.isChoosingMedia,
      allowedContentTypes: [.image, .movie, .folder],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      store.importFiles(urls)
    }
    .fileDialogMessage("Choose photos, videos, or folders to upload now.")
    .fileDialogConfirmationLabel("Upload")
    .confirmationDialog("Sign out of Google Photos?", isPresented: $router.isConfirmingSignOut, titleVisibility: .visible) {
      Button("Sign Out", role: .destructive) { Task { await store.signOut() } }
    } message: {
      Text(ProductCopy.signOutMessage)
    }
    .onChange(of: store.presentSignIn, initial: true) { _, needsSignIn in
      guard needsSignIn else { return }
      store.presentSignIn = false
      router.isSigningIn = true
    }
    // A Google Photos view has nothing to show once its account is signed out.
    .onChange(of: store.cloudLibrary == nil) { _, signedOut in
      guard signedOut, case .collection(let route) = router.selection else { return }
      switch route {
      case .cloud, .cloudAlbums: router.show(.library)
      default: break
      }
    }
    .task { await store.start() }
    .task { await collections.load() }
    // Places, in Collections and Search, shows the merged library.
    .environment(library)
    // Search and sidebar Places stay current while the Library view isn't mounted.
    .onChange(of: store.cloudLibrary?.accountEmail, initial: true) { _, _ in
      guard router.section != .library else { return }
      library.setCloudLibrary(store.cloudLibrary)
      Task { await library.start(records: store.records) }
    }
    .onChange(of: store.cloudLibrary?.revision) {
      guard router.section != .library else { return }
      Task { await library.cloudChanged() }
    }
    .onChange(of: store.recordsRevision) {
      guard router.section != .library else { return }
      Task { await library.recordsChanged(store.records) }
    }
    .onChange(of: store.settings.uploadsOnMeteredNetworks, initial: true) { _, allowed in
      LibraryIndexer.usesMeteredNetworks.withLock { $0 = allowed }
      if library.isLoaded { indexer.update(from: library) }
    }
    .onChange(of: library.reloadToken) {
      indexer.update(from: library)
      WidgetPublisher.shared.libraryChanged(library)
    }
    .onChange(of: store.backupStatus, initial: true) { _, status in
      WidgetPublisher.shared.backupChanged(status, backedUpCount: store.accountRecordCounts.sent)
    }
    .onOpenURL { url in
      switch WidgetLink(url: url) {
      case .photo(let id): SiriLibrary.shared.open(.item(id))
      case .person(let id): SiriLibrary.shared.open(.person(id))
      case .backup: router.show(.overview)
      case nil: break
      }
    }
    .onChange(of: SiriLibrary.shared.destination?.token, initial: true) { showSiriDestination() }
    // The photos and videos in watched folders are part of the Library.
    .task(id: [AnyHashable(store.folders), AnyHashable(store.settings.backupExclusions)]) {
      await library.setFolders(
        store.folders.map {
          LibraryFolder(
            id: $0.id, path: $0.url.path, bookmarkData: $0.bookmarkData, exclusions: store.settings.folderExclusions)
        })
    }
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    switch router.selection ?? .section(.library) {
    case .section(let section): sectionView(section)
    case .collection(let route):
      NavigationStack {
        CollectionRouteView(
          route: route, records: store.records, recordsRevision: store.recordsRevision, cloud: store.cloudLibrary,
          collections: collections
        )
        .collectionDestinations(
          records: store.records, recordsRevision: store.recordsRevision, cloud: store.cloudLibrary,
          collections: collections)
      }
      // Another sidebar row starts from that collection, not from where this one was.
      .id(route)
    }
  }

  @ViewBuilder private func sectionView(_ section: MacSection) -> some View {
    switch section {
    case .overview: MacOverviewView(store: store, router: router)
    case .library:
      UnifiedLibraryView(
        model: library, cloudLibrary: store.cloudLibrary, records: store.records, recordsRevision: store.recordsRevision,
        accountsLoaded: store.hasLoadedAccounts)
    case .search:
      NavigationStack(path: $searchPath) {
        SearchView(
          library: library, indexer: indexer, cloud: store.cloudLibrary, records: store.records, query: $searchQuery, path: $searchPath,
          isEditing: isSearchFocused, finishSearch: { isSearchFocused = false })
      }
    case .collections:
      NavigationStack(path: $collectionsPath) {
        CollectionsView(
          records: store.records, recordsRevision: store.recordsRevision, cloud: store.cloudLibrary,
          collections: collections)
      }
    case .activity: MacActivityView(store: store, router: router, filter: $router.activityFilter)
    case .folders: MacFoldersView(store: store, router: router)
    case .settings: MacSettingsPage(store: store, router: router)
    }
  }

  /// Shows what Siri, Spotlight or a shortcut asked for.
  private func showSiriDestination() {
    guard let (destination, token) = SiriLibrary.shared.destination else { return }
    SiriLibrary.shared.finish(token: token)
    MacRouter.restoreMainWindow()
    switch destination {
    case .item(let id):
      router.show(.library)
      library.requestOpen(indexID: id)
    case .search(let text):
      router.show(.search)
      searchPath = NavigationPath()
      // Results, not the suggestions shown while typing.
      isSearchFocused = false
      searchQuery = text
    case .person(let id):
      router.show(.search)
      isSearchFocused = false
      searchQuery = ""
      Task {
        let name = try? await SiriLibrary.shared.store.people().first { $0.id == id }?.name
        var path = NavigationPath()
        path.append(SearchRoute.person(id: id, name: name))
        searchPath = path
      }
    case .album(let album):
      router.show(.collections)
      var path = NavigationPath()
      path.append(album.collectionRoute)
      collectionsPath = path
    }
  }
}

/// The sidebar, in its own view so badge and album changes redraw only it.
/// Calls `onReturn` when Return is pressed in a search field of this view's window.
private struct SearchFieldReturnMonitor: NSViewRepresentable {
  let onReturn: () -> Void

  func makeNSView(context: Context) -> MonitorView { MonitorView() }
  func updateNSView(_ view: MonitorView, context: Context) { view.onReturn = onReturn }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    var onReturn: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated {
          guard let self, event.window === self.window, event.keyCode == 36 || event.keyCode == 76,
            let editor = self.window?.firstResponder as? NSTextView, editor.delegate is NSSearchField
          else { return }
          self.onReturn?()
        }
        return event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

/// AppKit-backed SF Symbol for sidebar rows. SwiftUI's default `Label` icons in a macOS
/// sidebar update their vibrant tint a frame or two after window activation, causing every
/// icon to flash when refocused. Observing row emphasis and window focus directly keeps
/// tint updates synchronous with the glass sidebar and selection pill.
private struct SidebarSymbol: NSViewRepresentable {
  let systemName: String

  func makeNSView(context: Context) -> SymbolView {
    let view = SymbolView()
    view.configure(systemName: systemName)
    return view
  }

  func updateNSView(_ view: SymbolView, context: Context) {
    view.configure(systemName: systemName)
    view.syncTint()
  }

  static func dismantleNSView(_ view: SymbolView, coordinator: ()) {
    view.stopObserving()
  }

  final class SymbolView: NSImageView {
    private var currentSymbolName: String?
    private weak var observedRow: NSTableRowView?
    private weak var observedWindow: NSWindow?
    private var emphasisObservation: NSKeyValueObservation?
    private var selectionObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      imageScaling = .scaleProportionallyDown
      setContentHuggingPriority(.required, for: .horizontal)
      setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(systemName: String) {
      guard currentSymbolName != systemName else { return }
      currentSymbolName = systemName
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
      let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
      symbol?.isTemplate = true
      image = symbol
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      attachObservers()
      syncTint()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attachObservers()
      syncTint()
    }

    func stopObserving() {
      emphasisObservation = nil
      selectionObservation = nil
      observedRow = nil
      for token in notificationObservers { NotificationCenter.default.removeObserver(token) }
      notificationObservers.removeAll()
      observedWindow = nil
    }

    private func attachObservers() {
      let row = enclosingRowView
      if row !== observedRow {
        emphasisObservation = nil
        selectionObservation = nil
        observedRow = row
        if let row {
          emphasisObservation = row.observe(\.isEmphasized, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncTint() }
          }
          selectionObservation = row.observe(\.isSelected, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncTint() }
          }
        }
      }

      if window !== observedWindow {
        for token in notificationObservers { NotificationCenter.default.removeObserver(token) }
        notificationObservers.removeAll()
        observedWindow = window
        if let window {
          let center = NotificationCenter.default
          let windowNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
          ]
          for name in windowNames {
            notificationObservers.append(
              center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTint() }
              })
          }
          let appNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
          ]
          for name in appNames {
            notificationObservers.append(
              center.addObserver(forName: name, object: NSApp, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTint() }
              })
          }
        }
      }
    }

    private var enclosingRowView: NSTableRowView? {
      var current = superview
      while let view = current {
        if let row = view as? NSTableRowView { return row }
        current = view.superview
      }
      return nil
    }

    func syncTint() {
      let row = enclosingRowView
      let isEmphasizedSelection = row?.isSelected == true && row?.isEmphasized == true
      let isWindowActive = window?.isKeyWindow == true || window?.isMainWindow == true
      let nextTint: NSColor =
        if isEmphasizedSelection {
          .white
        } else if isWindowActive {
          .controlAccentColor
        } else {
          .secondaryLabelColor
        }
      if contentTintColor != nextTint {
        contentTintColor = nextTint
      }
    }

    isolated deinit { stopObserving() }
  }
}

private struct MacSidebar: View {
  let store: MacSyncStore
  @Bindable var router: MacRouter
  let collections: PhotoCollectionsModel
  @State private var isAccountHovered = false
  @State private var isShowingAccount = false
  @AppStorage("sidebarPinnedExpanded") private var isPinnedExpanded = true
  @AppStorage("sidebarAlbumsExpanded") private var isAlbumsExpanded = true
  @AppStorage("sidebarGoogleExpanded") private var isGoogleExpanded = true
  @AppStorage("sidebarBackupExpanded") private var isBackupExpanded = true
  @Environment(\.openURL) private var openURL

  var body: some View { sidebar }

  /// As in Photos on the Mac: the library and its views first, then pinned collections,
  /// albums and Google Photos (each collapsible), then backup.
  private var sidebar: some View {
    List(selection: selection) {
      Section {
        row(.library)
        row(.search)
        row(.collections)
      }

      Section("Pinned", isExpanded: $isPinnedExpanded) {
        collectionRow("Favorites", symbol: "heart", route: .scope(.mediaKind(.favorites), .all))
        collectionRow("Recently Added", symbol: "clock", route: .scope(.recentlyAdded, .all))
        collectionRow("Videos", symbol: "video", route: .scope(.mediaKind(.videos), .all))
        collectionRow("Places", symbol: "map", route: .places)
        collectionRow("Not Backed Up", symbol: "icloud.slash", route: .scope(.all, .notBackedUp))
        collectionRow("Hidden", symbol: "eye.slash", route: .scope(.hidden, .all))
      }

      if !collections.albums.isEmpty {
        Section("Albums", isExpanded: $isAlbumsExpanded) {
          ForEach(collections.albums) { album in
            sidebarLabel(Text(album.title), symbol: "rectangle.stack")
              .tag(MacSidebarItem.collection(.scope(.album(id: album.id, title: album.title), .all)))
          }
        }
      }

      if store.cloudLibrary != nil {
        Section("Google Photos", isExpanded: $isGoogleExpanded) {
          collectionRow("All Photos", symbol: "photo.on.rectangle.angled", route: .cloud(.library))
          collectionRow("Albums", symbol: "rectangle.stack", route: .cloudAlbums)
          collectionRow("Favorites", symbol: "heart", route: .cloud(.favorites))
          collectionRow("Archive", symbol: "archivebox", route: .cloud(.archive))
          collectionRow("Uses Storage", symbol: "externaldrive.badge.icloud", route: .cloud(.usesStorage))
          collectionRow("Trash", symbol: "trash", route: .cloud(.trash))
        }
      }

      Section("Backup", isExpanded: $isBackupExpanded) {
        row(.overview)
        row(.activity)
        row(.folders)
      }

      Section { row(.settings) }
    }
    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    // A bar with a hard edge, not a plain inset, so rows scrolling under it are covered
    // instead of showing through the status and account.
    .scrollEdgeEffectStyle(.hard, for: .bottom)
    .safeAreaBar(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        MacSidebarStatus(store: store, router: router)
        accountFooter
      }
    }
  }

  /// Choosing Search goes straight to its field, as in Music, so typing searches.
  private var selection: Binding<MacSidebarItem?> {
    Binding {
      router.selection
    } set: { item in
      router.selection = item
      if item == .section(.search) { router.focusLibrarySearch = true }
    }
  }

  private func row(_ section: MacSection) -> some View {
    sidebarLabel(section.title, symbol: section.symbol)
      .badge(badge(for: section))
      .tag(MacSidebarItem.section(section))
  }

  private func collectionRow(_ title: LocalizedStringKey, symbol: String, route: CollectionRoute) -> some View {
    sidebarLabel(title, symbol: symbol)
      .tag(MacSidebarItem.collection(route))
  }

  private func sidebarLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
    sidebarLabel(Text(title), symbol: symbol)
  }

  private func sidebarLabel(_ title: Text, symbol: String) -> some View {
    Label {
      title
    } icon: {
      SidebarSymbol(systemName: symbol)
    }
  }

  private func badge(for section: MacSection) -> Int {
    let counts = store.accountRecordCounts
    return switch section {
    case .activity: counts.failed
    case .folders: store.enabledFoldersNeedingAccess
    case .overview, .library, .collections, .search, .settings: 0
    }
  }

  private var accountFooter: some View {
    Group {
      if let account = store.selectedAccount {
        Button {
          isShowingAccount.toggle()
        } label: {
          HStack(spacing: 10) {
            AccountAvatar(email: account.email, size: 28)
            VStack(alignment: .leading, spacing: 0) {
              Text(account.email)
                .lineLimit(1)
                .truncationMode(.middle)
              Text("Google Photos")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .padding(6)
          .background(
            isAccountHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8, style: .continuous)
          )
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isAccountHovered = $0 }
        .accessibilityLabel("Account, \(account.email)")
        .popover(isPresented: $isShowingAccount, arrowEdge: .top) {
          let counts = store.accountRecordCounts
          AccountSummaryView(
            email: account.email, uploadedCount: counts.sent, backedUpBytes: counts.completedBytes,
            onOpenGooglePhotos: {
              isShowingAccount = false
              openURL(ProductCopy.googlePhotosURL)
            },
            onSettings: {
              isShowingAccount = false
              router.show(.settings)
            },
            onSignOut: {
              isShowingAccount = false
              router.isConfirmingSignOut = true
            }
          )
          .padding(20)
          .frame(width: 320)
        }
      } else {
        Button {
          router.isSigningIn = true
        } label: {
          HStack(spacing: 10) {
            AccountAvatar(email: nil, size: 28)
            VStack(alignment: .leading, spacing: 0) {
              Text("Sign In…")
              Text("Google Photos")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
          }
          .padding(6)
          .background(
            isAccountHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8, style: .continuous)
          )
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isAccountHovered = $0 }
        .accessibilityLabel("Sign in to Google Photos")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.12), value: isAccountHovered)
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
    .padding(.top, 4)
  }
}

/// The backup's state at the foot of the sidebar, as Photos shows its sync there. It's
/// always two lines of the same height (the second a progress bar while uploading), so
/// the sidebar never moves as backups start and stop. Isolated so progress ticks redraw
/// only this.
private struct MacSidebarStatus: View {
  let store: MacSyncStore
  let router: MacRouter
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DisplayedBackupStatus(store.backupStatus) { status in
      Button {
        if store.accountRecordCounts.failed > 0, !status.isActive {
          router.show(.activity, filter: .failed)
        } else {
          router.show(.overview)
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: status.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(status.tint)
            .symbolEffect(.rotate, isActive: status.rotates && !reduceMotion)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 3) {
            Text(status.title)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Group {
              if store.isRunning, store.workerPool.currentTotalBytes > 0 {
                ProgressView(value: store.workerPool.currentProgress)
                  .controlSize(.mini)
              } else {
                Text(detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .frame(height: 14)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
          isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous)
        )
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .onHover { isHovered = $0 }
      .help(status.subtitle)
      .accessibilityLabel(Text(status.title))
      .accessibilityHint(Text(status.subtitle))
    }
    .padding(.horizontal, 12)
  }

  private var detail: String {
    let counts = store.accountRecordCounts
    let inProgress = counts.queued + counts.uploading
    if counts.failed > 0 { return String(localized: "\(counts.failed.formatted()) failed") }
    if inProgress > 0 { return String(localized: "\(inProgress.formatted()) waiting") }
    return String(localized: "\(counts.sent.formatted()) backed up")
  }
}

/// The sign-in sheet plus what happens after it.
struct MacSignInSheet: View {
  let store: MacSyncStore
  let onDone: () -> Void

  var body: some View {
    WebAuthSheet { credential in
      switch credential {
      case .oauthToken(let token): try await store.addAccountFromOAuthToken(token)
      case .credentialString(let raw): try await store.addAccountFromRawCredential(raw)
      }
      onDone()
      Task {
        await BackupNotifier.shared.requestAuthorization()
        await store.resumePendingImports()
        await store.ingestSharedQueueItems()
        if store.settings.autoSyncEnabled { await store.syncNow() }
      }
    } onCancel: {
      store.discardPendingDropURLs()
      onDone()
    }
  }
}

extension MacSyncStore {
  /// Uploads files the user handed over. Without an account they wait, and the store
  /// raises `presentSignIn`.
  func importFiles(_ urls: [URL]) {
    Task { await uploadDroppedFiles(urls: urls) }
  }

  var backupStatus: BackupStatus {
    var inputs = BackupStatus.Inputs()
    inputs.credentialError = credentialError
    inputs.isStarting = isStarting
    inputs.isSignedIn = selectedAccount != nil
    inputs.importError = importError
    inputs.isRunning = isRunning
    inputs.isStopping = workerPool.isStopping
    inputs.isPaused = isPaused
    inputs.isWaitingForNetwork = isWaitingForUnmeteredNetwork
    inputs.isOffline = isOffline
    inputs.isRateLimited = workerPool.isRateLimited
    inputs.isScanning = isScanning
    inputs.source = .folders
    if !hasUsableEnabledFolder {
      inputs.sourceIssue =
        enabledFoldersNeedingAccess > 0 ? .foldersBlocked(count: enabledFoldersNeedingAccess) : .noFolders
    }
    let counts = accountRecordCounts
    inputs.uploadingCount = counts.uploading
    inputs.queuedCount = counts.queued
    inputs.failedCount = counts.failed
    inputs.albumWarning = workerPool.statusMessage.hasPrefix("Uploaded, but") ? workerPool.statusMessage : nil
    inputs.autoSyncEnabled = settings.autoSyncEnabled
    inputs.isStoppedForSession = isStoppedForThisSession
    inputs.cleanupMessage = cleanupMessage
    return BackupStatus(inputs)
  }
}
