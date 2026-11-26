import GPhotosKit
import Photos
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var path: [Route] = []
  @State private var sheet: Sheet?
  /// Media picked in the source sheet, confirmed once that sheet has finished closing.
  @State private var pickedBatch: UploadBatch?
  /// Sign-in asked for while another sheet was up; shown once that one closes.
  @State private var pendingSignIn = false
  @State private var confirmCleanup = false
  @State private var cleanupPlan: CleanupPlan?
  @State private var isPreparingCleanup = false
  @State private var showsNothingToCleanUp = false
  @State private var tab: AppTab = .library
  @State private var isRestoringTabBar = false
  @State private var tabBarGrewAt = ContinuousClock.now - .seconds(1)
  @State private var library = UnifiedLibraryModel(waitsForInitialFolders: true)
  @State private var indexer = LibraryIndexer()
  @State private var searchQuery = ""
  @State private var searchPath = NavigationPath()
  @State private var collectionsPath = NavigationPath()
  @FocusState private var searchFocused: Bool

  enum AppTab: Hashable {
    case backup
    case library
    case collections
    case search
  }

  enum Route: Hashable {
    case activity(ActivityFilter)
    case folders
    case protectedItems
    case excludedAlbums
  }

  private enum Sheet: Identifiable {
    case account
    case signIn
    case uploadSource
    case confirmUpload(UploadBatch)
    #if DEBUG
      case sharePreview(ShareStagingModel)
    #endif

    var id: String {
      switch self {
      case .account: "account"
      case .signIn: "signIn"
      case .uploadSource: "uploadSource"
      case .confirmUpload(let batch): "confirm-" + batch.id.uuidString
      #if DEBUG
        case .sharePreview: "sharePreview"
      #endif
      }
    }
  }

  /// Choosing Library again goes to the newest photos, as in Photos. A tap on the shrunk
  /// bar only grows it back.
  private var tabSelection: Binding<AppTab> {
    Binding(
      get: { tab },
      set: { selected in
        // A shrunk bar offers only the current tab and Search, and the Years, Months and
        // All picker covers it. Another tab chosen then was under the picker: the bar had
        // grown back without saying so, and the tap was meant for the picker.
        if tab == .library, library.isTabBarMinimized, selected != .library, selected != .search {
          library.isTabBarMinimized = false
          return
        }
        // The bar may report growing just before the tap that grew it arrives.
        let grewWithTap = ContinuousClock.now - tabBarGrewAt < .milliseconds(500)
        if selected == tab, selected == .library, !library.isTabBarMinimized, !grewWithTap { library.showNewest() }
        tab = selected
      })
  }

  private var minimizeBehavior: TabBarMinimizeBehavior {
    guard tab == .library else { return .onScrollDown }
    return isRestoringTabBar ? .never : .onScrollUp
  }

  /// The tabs and what keeps them in step with the model; `body` adds the presentations.
  private var tabs: some View {
    TabView(selection: tabSelection) {
      Tab("Library", systemImage: "photo.on.rectangle", value: AppTab.library) {
        LibraryTab(model: model, library: library)
      }
      Tab("Collections", systemImage: "rectangle.stack", value: AppTab.collections) {
        CollectionsTab(model: model, path: $collectionsPath)
      }
      Tab("Backup", systemImage: "arrow.up.circle", value: AppTab.backup) {
        BackupTab(
          model: model, path: $path,
          cleanup: CleanupState(isPreparing: isPreparingCleanup, showsNothingToCleanUp: showsNothingToCleanUp),
          onCleanUp: startCleanup, onSignIn: { sheet = .signIn },
          onUpload: { sheet = .uploadSource }, onAccount: openAccount,
          openPendingActivity: openPendingActivity, openPendingAccountSheet: openPendingAccountSheet)
      }
      Tab(value: AppTab.search, role: .search) {
        SearchTab(
          model: model, library: library, indexer: indexer, query: $searchQuery, path: $searchPath, focused: $searchFocused)
      }
    }
    // Places, in Collections and Search, shows the merged library.
    .environment(library)
    .environment(
      \.showLibraryFilter,
      ShowLibraryFilterAction { filter in
        tab = .library
        Task { await library.setFilter(filter) }
      }
    )
    .background { LibraryObservers(model: model, library: library, indexer: indexer) }
    .onChange(of: SiriLibrary.shared.destination?.token, initial: true) { showSiriDestination() }
    // Grow the bar at the newest row, after the grid settles there.
    .task(id: tab == .library && library.isAtNewest) {
      isRestoringTabBar = false
      guard tab == .library, library.isAtNewest else { return }
      do {
        try await Task.sleep(for: .milliseconds(100))
        guard library.isTabBarMinimized else { return }
        isRestoringTabBar = true
        try await Task.sleep(for: .milliseconds(50))
        isRestoringTabBar = false
      } catch {
        // The next task resets the flag before checking the new scroll position.
      }
    }
    .onChange(of: library.isTabBarMinimized) { _, minimized in
      if !minimized { tabBarGrewAt = .now }
    }
    .tabViewSearchActivation(.searchTabSelection)
    // The Library's newest photos are at the bottom, so as in Photos its bar shrinks on the
    // way up, toward older ones, and only grows back at the newest row (or with a tap).
    .tabBarMinimizeBehavior(minimizeBehavior)
    // As in Photos, only in the shrunk tab bar, between Library and Search.
    .modifier(TabBarMinimizedTracker(model: library))
  }

  var body: some View {
    tabs
      .sheet(item: $sheet, onDismiss: presentNextSheet) { sheet in
        switch sheet {
        case .account:
          AccountSheet(model: model)
        case .signIn:
          signInSheet
        case .uploadSource:
          UploadSourceSheet { batch in
            pickedBatch = batch
            self.sheet = nil
          }
        case .confirmUpload(let batch):
          ConfirmUploadSheet(model: model, batch: batch)
        #if DEBUG
          case .sharePreview(let shareModel):
            ShareStagingView(model: shareModel, complete: { self.sheet = nil }, cancel: { self.sheet = nil })
        #endif
        }
      }
      .confirmationDialog(
        Text(ProductCopy.inflected("Remove ^[\(cleanupPlan?.itemCount ?? 0) item](inflect: true) from this iPhone?")),
        isPresented: $confirmCleanup,
        titleVisibility: .visible,
        presenting: cleanupPlan
      ) { plan in
        Button(ProductCopy.inflected("Remove ^[\(plan.itemCount) Item](inflect: true)"), role: .destructive) {
          Task { await model.performCleanup(plan: plan) }
        }
      } message: { plan in
        Text(cleanupMessage(for: plan))
      }
      .onChange(of: confirmCleanup) { _, isPresented in
        if !isPresented { cleanupPlan = nil }
      }
      // A sheet takes over presentation; a dialog left "presented" under it would block
      // every later cleanup.
      .onChange(of: sheet?.id) { _, id in
        if id != nil, confirmCleanup { confirmCleanup = false }
      }
      .onChange(of: model.pendingCleanupPrompt) { consumeCleanupPrompt() }
      .onChange(of: model.isStarting) { consumeCleanupPrompt() }
      .onChange(of: model.isRunning) { consumeCleanupPrompt() }
      .task(id: showsNothingToCleanUp) {
        guard showsNothingToCleanUp else { return }
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
        showsNothingToCleanUp = false
      }
      .task {
        if scenePhase == .active { model.sceneDidBecomeActive() }
        await model.onAppear()
        consumeCleanupPrompt()
        if model.manualUploadNeedsSignIn { requestSignIn() }
        if model.photoLibraryStatus == .notDetermined { await model.requestPhotoAccess() }
        #if DEBUG
          applyLaunchArguments()
        #endif
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          model.sceneDidBecomeActive()
          if model.manualUploadNeedsSignIn { requestSignIn() }
          Task {
            let folders = FolderMediaScanner.ForegroundRead()
            async let libraryRead: Void = library.refreshFolders(using: folders)
            await model.refreshPhotoLibraryStatus(using: folders)
            await libraryRead
          }
        case .background:
          model.sceneDidEnterBackground()
          Task { await model.prepareForBackground() }
        default:
          break
        }
      }
      .onChange(of: model.manualUploadNeedsSignIn) { _, needsSignIn in
        if needsSignIn { requestSignIn() }
      }
      .onOpenURL { url in
        if let link = WidgetLink(url: url) {
          switch link {
          case .photo(let id): SiriLibrary.shared.open(.item(id))
          case .person(let id): SiriLibrary.shared.open(.person(id))
          case .backup:
            sheet = nil
            path = []
            tab = .backup
          }
          return
        }
        // gphotosapp://activity?kind=failed
        guard url.scheme?.lowercased() == "gphotosapp", url.host == "activity" else { return }
        let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value
        path = [.activity(kind.flatMap(ActivityFilter.init(rawValue:)) ?? .all)]
      }
  }

  /// Tapping a notification sets one of these; the screen it names opens once.

  /// Shows what Siri, Spotlight or a shortcut asked for.
  private func showSiriDestination() {
    guard let (destination, token) = SiriLibrary.shared.destination else { return }
    SiriLibrary.shared.finish(token: token)
    sheet = nil
    switch destination {
    case .item(let id):
      tab = .library
      library.requestOpen(indexID: id)
    case .search(let text):
      tab = .search
      searchPath = NavigationPath()
      // Results, not the suggestions shown while typing.
      searchFocused = false
      searchQuery = text
    case .person(let id):
      tab = .search
      searchFocused = false
      searchQuery = ""
      Task {
        let name = try? await SiriLibrary.shared.store.personName(id: id)
        var path = NavigationPath()
        path.append(SearchRoute.person(id: id, name: name))
        searchPath = path
      }
    case .album(let album):
      tab = .collections
      var path = NavigationPath()
      path.append(album.collectionRoute)
      collectionsPath = path
    }
  }

  private func openPendingActivity() {
    guard let filter = model.pendingActivityFilter else { return }
    model.pendingActivityFilter = nil
    tab = .backup
    path = [.activity(filter)]
  }

  private func openPendingAccountSheet() {
    guard model.pendingAccountSheet else { return }
    model.pendingAccountSheet = false
    openAccount()
  }

  private func openAccount() {
    sheet = model.selectedAccount == nil ? .signIn : .account
  }

  private var signInSheet: some View {
    WebAuthSheet { credential in
      switch credential {
      case .oauthToken(let token): try await model.addAccountFromOAuthToken(token)
      case .credentialString(let raw): try await model.addAccountFromRawCredential(raw)
      }
      sheet = nil
      Task {
        await BackupNotifier.shared.requestAuthorization()
        await model.ingestSharedQueueItems()
        await model.resumePendingManualUploads()
        if model.settings.autoSyncEnabled {
          await model.syncLibrary()
          await model.syncFolders()
        }
      }
    } onCancel: {
      sheet = nil
    }
  }

  /// Works out what would be removed first, so the confirmation can name the count.
  private func startCleanup() {
    guard !isPreparingCleanup, !model.isCleaningUp else { return }
    confirmCleanup = false
    isPreparingCleanup = true
    showsNothingToCleanUp = false
    Task {
      let plan = await model.prepareLibraryCleanup()
      isPreparingCleanup = false
      if plan.isEmpty {
        showsNothingToCleanUp = true
      } else if sheet != nil {
        // The dialog can't present over a sheet that opened meanwhile; ask again once
        // it closes.
        model.pendingCleanupPrompt = true
      } else {
        cleanupPlan = plan
        confirmCleanup = true
      }
    }
  }

  /// A tapped notification or due items found in the foreground ask for the same flow
  /// as the button, once the account is loaded, no backup is running and no sheet is up.
  private func consumeCleanupPrompt() {
    guard model.pendingCleanupPrompt, !model.isStarting, !model.isRunning, model.selectedAccount != nil else { return }
    // A dialog already up, or being prepared, answers the request.
    if confirmCleanup || isPreparingCleanup {
      model.pendingCleanupPrompt = false
      return
    }
    guard sheet == nil else { return }
    model.pendingCleanupPrompt = false
    startCleanup()
  }

  private func cleanupMessage(for plan: CleanupPlan) -> String {
    let email = model.selectedAccount?.email ?? String(localized: "your Google account")
    let photos = plan.libraryAssetCount
    let files = plan.folderRecords.count
    switch (photos > 0, files > 0) {
    case (true, true):
      return ProductCopy.inflected(
        "^[\(photos) photo](inflect: true) from your library and ^[\(files) file](inflect: true) from your folders, all backed up to \(email). If iCloud Photos or a Shared Library is on, the photos are also removed there for everyone who can see them. Photos go to Recently Deleted for 30 days."
      )
    case (true, false):
      return String(
        localized:
          "They're backed up to \(email). If iCloud Photos or a Shared Library is on, they're also removed there for everyone who can see them. Photos go to Recently Deleted for 30 days."
      )
    case (false, true):
      return ProductCopy.inflected(
        "^[\(files) file](inflect: true) from your folders, already backed up to \(email). They're deleted from their folders."
      )
    case (false, false):
      return String(localized: "They're copies of files already backed up to \(email).")
    }
  }

  /// Replacing a sheet that is still up would drop it mid-task, so the request waits.
  private func requestSignIn() {
    if case .signIn? = sheet { return }
    if sheet == nil {
      sheet = .signIn
    } else {
      pendingSignIn = true
    }
  }

  /// Presenting from `onDismiss` guarantees the previous sheet is gone before the next one.
  private func presentNextSheet() {
    guard sheet == nil else { return }
    if let batch = pickedBatch {
      pickedBatch = nil
      sheet = .confirmUpload(batch)
    } else if pendingSignIn {
      pendingSignIn = false
      if model.manualUploadNeedsSignIn { sheet = .signIn }
    }
    if sheet == nil { consumeCleanupPrompt() }
  }

  #if DEBUG
    /// Opens a screen directly for UI review, e.g. `-UIScreen activity`.
    private func applyLaunchArguments() {
      DebugHooks.copyBackgroundLog()
      Task { await DebugHooks.addTestPhotoIfAsked() }
      switch UserDefaults.standard.string(forKey: "UIScreen") {
      case "backup": tab = .backup
      case "activity":
        tab = .backup
        path = [.activity(.all)]
      case "failed":
        tab = .backup
        path = [.activity(.failed)]
      case "folders":
        tab = .backup
        path = [.folders]
      case "protected":
        tab = .backup
        path = [.protectedItems]
      case "account": sheet = .account
      case "signIn": sheet = .signIn
      case "upload": sheet = .uploadSource
      case "uploading":
        tab = .backup
        model.workerPool.startPreviewSimulation()
        Task { model.startLiveActivity() }
      case "library", "viewer", "cloud", "cloudViewer", "cloudLarge": tab = .library
      case "collections": tab = .collections
      case "cloudCollections": tab = .collections
      case "search": tab = .search
      case let screen:
        if let state = ShareStagingModel.PreviewState(screen: screen) {
          sheet = .sharePreview(.preview(state))
        }
      }
    }
  #endif
}

private struct BackupTab: View {
  let model: AppModel
  @Binding var path: [ContentView.Route]
  let cleanup: CleanupState
  let onCleanUp: () -> Void
  let onSignIn: () -> Void
  let onUpload: () -> Void
  let onAccount: () -> Void
  let openPendingActivity: () -> Void
  let openPendingAccountSheet: () -> Void

  var body: some View {
    NavigationStack(path: $path) {
      Dashboard(
        model: model,
        onSignIn: onSignIn,
        cleanup: cleanup,
        onCleanUp: onCleanUp,
        onNavigate: { path.append($0) }
      )
      .navigationTitle(ProductCopy.name)
      .navigationDestination(for: ContentView.Route.self) { route in
        switch route {
        case .activity(let filter): ActivityView(model: model, filter: filter)
        case .folders: BackedUpFoldersView(model: model)
        case .protectedItems: ProtectedItemsView(model: model)
        case .excludedAlbums: ExcludedAlbumsView(model: model)
        }
      }
      .toolbar { toolbar }
      // `initial` also covers a cold launch from a notification tap.
      .onChange(of: model.pendingActivityFilter, initial: true) { openPendingActivity() }
      .onChange(of: model.pendingAccountSheet, initial: true) { openPendingAccountSheet() }
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button("Upload Photos or Files", systemImage: "plus", action: onUpload)
    }
    ToolbarSpacer(.fixed, placement: .topBarTrailing)
    ToolbarItem(placement: .topBarTrailing) {
      Button(action: onAccount) {
        AccountAvatar(email: model.selectedAccount?.email, size: 36)
          .frame(width: 44, height: 44)
          // Toolbar items with custom content get a capsule; drawing the glass circle
          // here keeps the avatar concentric with it and sized like the "+" button.
          .glassEffect(.regular.interactive(), in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(model.selectedAccount == nil ? "Sign In" : "Account Settings")
      .accessibilityValue(model.selectedAccount?.email ?? "Not signed in")
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

private struct LibraryTab: View {
  let model: AppModel
  let library: UnifiedLibraryModel

  var body: some View {
    NavigationStack {
      UnifiedLibraryView(
        model: library, cloudLibrary: model.cloudLibrary, records: model.records, recordsRevision: nil,
        accountsLoaded: model.hasLoadedAccounts)
    }
  }
}

private struct CollectionsTab: View {
  let model: AppModel
  @Binding var path: NavigationPath

  var body: some View {
    NavigationStack(path: $path) {
      CollectionsView(
        records: model.records, recordsRevision: model.recordsRevision, cloud: model.cloudLibrary,
        accountsLoaded: model.hasLoadedAccounts
      )
      .toolbarTitleDisplayMode(.inlineLarge)
    }
  }
}

private struct SearchTab: View {
  let model: AppModel
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  @Binding var query: String
  @Binding var path: NavigationPath
  var focused: FocusState<Bool>.Binding

  var body: some View {
    NavigationStack(path: $path) {
      SearchView(
        library: library, indexer: indexer, cloud: model.cloudLibrary, records: model.records, query: $query, path: $path,
        isEditing: focused.wrappedValue, finishSearch: { focused.wrappedValue = false }
      )
      .toolbarTitleDisplayMode(.inlineLarge)
    }
    .searchable(text: $query, prompt: searchPrompt)
    .searchFocused(focused)
  }
}

private struct LibraryObservers: View {
  let model: AppModel
  let library: UnifiedLibraryModel
  let indexer: LibraryIndexer
  @State private var recordsUpdate: Task<Void, Never>?

  private var revision: Int? {
    // Track snapshot publication even when the Library tab is offscreen.
    _ = model.records
    return model.recordsRevision
  }

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: revision) { updateRecords() }
      .onDisappear { recordsUpdate?.cancel() }
      .onChange(of: model.settings.uploadsOnMeteredNetworks, initial: true) { _, allowed in
        LibraryIndexer.usesMeteredNetworks.withLock { $0 = allowed }
        if library.isLoaded { indexer.update(from: library) }
      }
      .onChange(of: model.isBackupActive, initial: true) { _, isActive in
        Task { await library.setBackupActive(isActive) }
      }
      .onChange(of: [library.reloadToken, library.indexMetadataToken]) {
        indexer.update(from: library)
        WidgetPublisher.shared.libraryChanged(library)
      }
      .onChange(
        of: WidgetBackupUpdate(status: model.backupStatus, count: model.accountTransferredCount),
        initial: true
      ) { _, update in
        WidgetPublisher.shared.backupChanged(update.status, backedUpCount: update.count)
      }
      .onChange(of: model.photoLibraryStatus) { _, status in
        guard status == .authorized || status == .limited else { return }
        Task { await library.start(records: model.records) }
      }
      // The photos and videos in backed-up folders are part of the Library.
      .task(id: [AnyHashable(model.backedUpFolders), AnyHashable(model.settings.backupExclusions)]) {
        let disabledIDs = Set(model.backedUpFolders.lazy.filter { !$0.isEnabled }.map(\.id))
        await library.setFolders(
          model.backedUpFolders.map {
            LibraryFolder(
              id: $0.id, path: $0.path, bookmarkData: $0.bookmarkData, exclusions: model.settings.folderExclusions)
          },
          disabledFolderIDs: disabledIDs)
      }
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
        Task { await model.manifestStore.purgeSortedCache() }
      }
  }

  private func updateRecords() {
    guard recordsUpdate == nil else { return }
    recordsUpdate = Task {
      defer { recordsUpdate = nil }
      while !Task.isCancelled {
        let revision = model.recordsRevision
        await library.recordsChanged(model.records)
        guard revision != model.recordsRevision else { return }
      }
    }
  }

  private struct WidgetBackupUpdate: Equatable {
    let status: BackupStatus
    let count: Int
  }
}

// MARK: - Dashboard

struct CleanupState: Equatable {
  var isPreparing = false
  var showsNothingToCleanUp = false
}

private struct Dashboard: View {
  @Bindable var model: AppModel
  let onSignIn: () -> Void
  let cleanup: CleanupState
  let onCleanUp: () -> Void
  let onNavigate: (ContentView.Route) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DisplayedBackupStatus(model.backupStatus) { shown in
      content(shown)
    }
  }

  private func content(_ shown: BackupStatus) -> some View {
    ScrollView {
      VStack(spacing: 32) {
        HeroCard(model: model, status: shown, onSignIn: onSignIn)

        if case .syncing = shown {
          NowUploadingList(pool: model.workerPool, record: model.uploadingRecord(for:))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        ForEach(model.accounts.filter { $0.email != model.selectedAccount?.email }, id: \.email) { account in
          AccountCopyCard(mirror: model.accountMirror, email: account.email)
        }

        VStack(spacing: 10) {
          HStack {
            Text("Activity")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(.uppercase)
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
              onNavigate(.activity(.all))
            } label: {
              HStack(spacing: 3) {
                Text("See All")
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.bold))
              }
              .font(.subheadline.weight(.semibold))
              .frame(minHeight: 44)
              .contentShape(.rect)
              .padding(.vertical, -8)
            }
            .accessibilityLabel("See all activity")
          }
          .padding(.horizontal, 6)
          SummaryTiles(model: model) { onNavigate(.activity($0)) }
        }

        BackupSettings(
          model: model,
          onShowFolders: { onNavigate(.folders) },
          onShowExcludedAlbums: { onNavigate(.excludedAlbums) }
        )
        StorageSettings(model: model, cleanup: cleanup, onCleanUp: onCleanUp) { onNavigate(.protectedItems) }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 48)
      .animation(reduceMotion ? nil : .smooth, value: model.isRunning)
    }
    .background { AmbientBackground(tint: shown.tint) }
  }
}

private struct AccountCopyCard: View {
  let mirror: AccountMirror
  let email: String

  var body: some View {
    if let copy = mirror.state(for: email), copy.isMirrorEnabled, copy.isRunning || copy.pendingCount > 0 {
      VStack(alignment: .leading, spacing: 5) {
        Text(copy.isRunning ? "Copying to \(email)" : "Backup copy for \(email)")
          .font(.subheadline.weight(.semibold))
        Text(copy.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
        if copy.totalCount > 0 {
          Text("\(copy.copiedCount.formatted()) of \(copy.totalCount.formatted()) backed up")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .glassCard()
    }
  }
}

private struct HeroCard: View {
  let model: AppModel
  let status: BackupStatus
  let onSignIn: () -> Void
  @State private var syncTaps = 0

  var body: some View {
    StatusCard(status: status, liveProgress: { progress }, actions: { actions })
  }

  private var progress: TransferProgressSummary? {
    let pool = model.workerPool
    guard model.isRunning, pool.currentTotalBytes > 0 else { return nil }
    var summary = TransferProgressSummary(pool)
    let current = pool.workers.first {
      $0.filename == summary.filename && TransferState(workerStatus: $0.status) == .uploading
    }
    summary.record = current.flatMap(model.uploadingRecord(for:))
    return summary
  }

  @ViewBuilder
  private var actions: some View {
    // Startup reads as a scan, so it shows the scan's controls rather than swapping buttons.
    if model.isRunning || status.isScan || model.isStarting {
      TransferControls(model: model)
    } else if case .credentialsUnavailable = status {
      // Signing in again would hit the same keychain failure, so offer a re-read instead.
      Button("Try Again") { Task { await model.loadAccounts() } }
        .buttonStyle(.glass)
    } else if model.selectedAccount == nil {
      Button("Sign In", action: onSignIn)
        .buttonStyle(.glassProminent)
    } else {
      switch status {
      case .needsSource(.photosAccessNeeded(let canPrompt)):
        Button(canPrompt ? "Allow Photos" : "Open Settings") {
          if canPrompt {
            Task { await model.requestPhotoAccess() }
          } else {
            model.openPhotoSettings()
          }
        }
        .buttonStyle(.glassProminent)
        .tint(.orange)
      case .needsSource(.limitedPhotosAccess):
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            syncNowButton
              .buttonStyle(.glassProminent)
            Button("Manage Access") { model.openPhotoSettings() }
              .buttonStyle(.glass)
          }
        }
      case .failed:
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            Button("Retry") { Task { await model.retryFailedForUser() } }
              .buttonStyle(.glassProminent)
              .tint(.red)
            syncNowButton
              .buttonStyle(.glass)
          }
        }
      default:
        syncNowButton
          .buttonStyle(.glassProminent)
      }
    }
  }

  private var syncNowButton: some View {
    Button("Sync Now") {
      syncTaps += 1
      Task { await model.startTransfer() }
    }
    .disabled(!model.canRequestSync)
    .sensoryFeedback(.impact(weight: .light), trigger: syncTaps)
  }
}

private struct TransferControls: View {
  let model: AppModel

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        if model.isRunning {
          Button(
            model.isPaused ? "Resume" : "Pause",
            systemImage: model.isPaused ? "play.fill" : "pause.fill"
          ) {
            model.isPaused ? model.resumeTransfer() : model.pauseTransfer()
          }
        }
        Button(model.isRunning ? "Stop" : "Stop Scanning", systemImage: "stop.fill") { model.stopTransfer() }
          .tint(.red)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .disabled(model.workerPool.isStopping)
    }
  }
}

private struct SummaryTiles: View {
  let model: AppModel
  let onSelect: (ActivityFilter) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let queued = model.accountQueuedCount + model.accountUploadingCount
    let failed = model.accountFailedCount
    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    GlassEffectContainer(spacing: 10) {
      layout {
        StatTile(
          "To Back Up", value: queued,
          detail: queued == 0 ? String(localized: "Up to date") : String(localized: "\(queued) remaining"),
          symbol: "clock.arrow.circlepath", tint: .blue, isActive: queued > 0 && model.backupStatus.rotates
        ) { onSelect(.pending) }
        StatTile(
          "Uploaded", value: model.accountTransferredCount, detail: ByteFormat.string(model.accountCompletedByteCount),
          symbol: "checkmark.circle.fill", tint: .green
        ) { onSelect(.uploaded) }
        StatTile(
          "Failed", value: failed, detail: failed == 0 ? String(localized: "None") : String(localized: "Needs retry"),
          symbol: failed == 0 ? "exclamationmark.triangle" : "exclamationmark.triangle.fill",
          tint: failed == 0 ? .secondary : .red, isActive: failed > 0 && model.isRunning
        ) { onSelect(.failed) }
      }
    }
  }
}

// MARK: - Settings

private struct BackupSettings: View {
  @Bindable var model: AppModel
  let onShowFolders: () -> Void
  let onShowExcludedAlbums: () -> Void

  private var foldersDetail: LocalizedStringKey {
    let count = model.backedUpFolders.count
    return count == 0 ? "Back up photos and videos from Files." : "^[\(count) folder](inflect: true)"
  }

  private var excludedAlbumsDetail: LocalizedStringKey {
    let count = model.settings.excludedAlbumIDs.count
    return count == 0 ? "Skip photos in chosen albums." : "^[\(count) album](inflect: true)"
  }

  var body: some View {
    SettingsGroup("Backup & Sync") {
      SettingRow(
        "Auto-Sync",
        detail: "Back up your photo library and folders automatically. Photos keep backing up after you close the app.",
        symbol: "arrow.triangle.2.circlepath", colors: [.green, .mint]
      ) {
        Toggle("Auto-Sync", isOn: autoSync)
      }
      Button(action: onShowFolders) {
        SettingRow(
          "Folders",
          detail: foldersDetail,
          symbol: "folder.fill", colors: [.orange, .yellow]
        ) {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      Button(action: onShowExcludedAlbums) {
        SettingRow(
          "Don’t Back Up",
          detail: excludedAlbumsDetail,
          symbol: "xmark.rectangle.fill", colors: [.orange, .red]
        ) {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      SettingRow(
        "Pair Live Photos",
        detail: "Upload the photo and its motion together.",
        symbol: "livephoto", colors: [.orange, .yellow]
      ) {
        Toggle("Pair Live Photos", isOn: model.setting(\.pairLivePhotos))
      }
      SettingRow(
        "Back Up Originals of Edits",
        detail: model.settings.backsUpUneditedOriginals
          ? "Edited photos and videos also upload as they were taken." : "Only the edited version uploads.",
        symbol: "slider.horizontal.3", colors: [.pink, .orange]
      ) {
        Toggle("Back Up Originals of Edits", isOn: model.setting(\.backsUpUneditedOriginals))
      }
      SettingRow(
        "Date from Filename",
        detail: "Use dates in names like IMG_20240101_120000.",
        symbol: "calendar.badge.clock", colors: [.purple, .indigo]
      ) {
        Toggle("Date from Filename", isOn: model.setting(\.setDateFromFilename))
      }
      SettingRow(
        "Concurrent Uploads",
        detail: model.isRunning ? "Can be changed when no backup is running." : "Upload more files at once for faster backups.",
        symbol: "square.stack.3d.up.fill", colors: [.blue, .cyan]
      ) {
        HStack(spacing: 10) {
          Text(model.settings.uploadThreads, format: .number)
            .accessibilityIdentifier("ConcurrentUploadsValue")
            .font(.headline)
            .foregroundStyle(.tint)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(model.settings.uploadThreads)))
            .animation(.snappy, value: model.settings.uploadThreads)
          Stepper("Concurrent Uploads", value: model.setting(\.uploadThreads), in: 1...8)
        }
        .fixedSize()
        .disabled(model.isRunning)
      }
      SettingRow(
        "Use Cellular Data",
        detail: "Upload and prepare Search on cellular when Wi‑Fi isn’t available.",
        symbol: "antenna.radiowaves.left.and.right", colors: [.green, .teal]
      ) {
        Toggle("Use Cellular Data", isOn: model.setting(\.uploadsOnMeteredNetworks))
      }
      SettingRow(
        "Mirror Photos Albums",
        detail: model.isAuthorized
          ? "Recreate your Photos albums in Google Photos." : "Needs access to your photo library.",
        symbol: "rectangle.stack.fill", colors: [.pink, .orange]
      ) {
        Toggle("Mirror Photos Albums", isOn: model.setting(\.mirrorPhotoAlbums))
          .disabled(!model.isAuthorized)
      }
    }
  }

  private var autoSync: Binding<Bool> {
    Binding {
      model.settings.autoSyncEnabled
    } set: { enabled in
      model.setting(\.autoSyncEnabled).wrappedValue = enabled
      if enabled, model.selectedAccount != nil {
        Task {
          await model.syncLibrary()
          await model.syncFolders()
        }
      }
    }
  }
}

private struct StorageSettings: View {
  @Bindable var model: AppModel
  let cleanup: CleanupState
  let onCleanUp: () -> Void
  let onShowProtectedItems: () -> Void

  private var cleanUpDetail: LocalizedStringKey {
    ProductCopy.cleanupDetail(
      isSignedIn: model.selectedAccount != nil, deleteDelay: model.settings.autoDeleteDelay,
      isBackingUp: model.workerPool.isRunning)
  }

  private var foundItemsDetail: LocalizedStringKey {
    ProductCopy.foundItemsDetail(
      count: model.foundInAccountCount, isOn: model.settings.removesItemsAlreadyInGooglePhotos,
      deleteDelay: model.settings.autoDeleteDelay)
  }

  private var protectedDetail: LocalizedStringKey {
    let albums = model.settings.protectedAlbumIDs.count
    let folders = model.settings.ignoredFolders.count
    if albums > 0, folders > 0 { return "^[\(albums) album](inflect: true) and ^[\(folders) folder](inflect: true) protected" }
    if albums > 0 { return "^[\(albums) album](inflect: true) protected" }
    if folders > 0 { return "^[\(folders) folder](inflect: true) protected" }
    return model.settings.protectsFavorites
      ? "Favorites are never removed by Clean Up." : "Choose albums and folders Clean Up never touches."
  }

  private var cleanUpDisabled: Bool {
    model.selectedAccount == nil || model.settings.autoDeleteDelay == .never || model.workerPool.isRunning
      || cleanup.isPreparing || model.isCleaningUp
  }

  var body: some View {
    VStack(spacing: 10) {
      group
      if cleanup.showsNothingToCleanUp {
        InlineMessage(String(localized: "Nothing to clean up right now."), style: .info)
          .transition(.opacity)
      }
    }
    .animation(.snappy, value: cleanup.showsNothingToCleanUp)
  }

  private var group: some View {
    SettingsGroup("Device Storage") {
      SettingRow(
        "Delete After Backup",
        detail: "Free up space once items are safely in Google Photos.",
        symbol: "clock.badge.checkmark", colors: [.red, .orange]
      ) {
        Menu {
          Picker("Delete After Backup", selection: model.setting(\.autoDeleteDelay)) {
            ForEach(AutoDeleteDelay.allCases) { Text($0.title).tag($0) }
          }
        } label: {
          HStack(spacing: 4) {
            Text(model.settings.autoDeleteDelay.title)
            Image(systemName: "chevron.up.chevron.down")
              .font(.footnote.weight(.semibold))
          }
          .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Delete After Backup")
      }
      SettingRow(
        "Only When Low on Space",
        detail: model.settings.autoDeleteDelay == .never
          ? "Choose a Delete After Backup time to use this." : "Only remove items when less than 5 GB is free.",
        symbol: "internaldrive", colors: [.teal, .cyan]
      ) {
        Toggle("Only When Low on Space", isOn: model.setting(\.smartDeleteEnabled))
          .disabled(model.settings.autoDeleteDelay == .never)
      }
      SettingRow(
        "Keep Recently Viewed",
        detail: model.settings.autoDeleteDelay == .never
          ? "Choose a Delete After Backup time to use this."
          : "Photos you opened lately stay on this iPhone. Removed photos still show in your library from Google Photos.",
        symbol: "eye", colors: [.purple, .indigo]
      ) {
        Picker("Keep Recently Viewed", selection: model.setting(\.keepsRecentlyViewed)) {
          ForEach(RecentlyViewedRetention.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .disabled(model.settings.autoDeleteDelay == .never)
      }
      SettingRow(
        "Remove Items Found in Google Photos",
        detail: foundItemsDetail,
        symbol: "checkmark.icloud", colors: [.green, .mint]
      ) {
        Toggle("Remove Items Found in Google Photos", isOn: model.setting(\.removesItemsAlreadyInGooglePhotos))
          .disabled(model.settings.autoDeleteDelay == .never)
      }
      SettingRow(
        "Clean Up Now",
        detail: cleanUpDetail,
        symbol: "sparkles", colors: [.orange, .yellow]
      ) {
        if cleanup.isPreparing || model.isCleaningUp {
          ProgressView()
            .accessibilityLabel("Preparing Clean Up")
        } else {
          Button("Clean Up", action: onCleanUp)
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .tint(.orange)
            .disabled(cleanUpDisabled)
        }
      }
      Button(action: onShowProtectedItems) {
        SettingRow(
          "Protected Items",
          detail: protectedDetail,
          symbol: "lock.shield.fill", colors: [.blue, .indigo]
        ) {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }
}

// MARK: - Model helpers

extension AppModel {
  /// A binding that writes one setting through `updateSettings`, which persists it.
  func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding {
      self.settings[keyPath: keyPath]
    } set: { value in
      var settings = self.settings
      settings[keyPath: keyPath] = value
      self.updateSettings(settings)
    }
  }

  /// The record a worker is sending, for its thumbnail.
  func uploadingRecord(for worker: WorkerState) -> TransferRecord? {
    accountBuckets.record(id: worker.itemID)
  }

  var backupStatus: BackupStatus {
    var inputs = BackupStatus.Inputs()
    inputs.credentialError = credentialError
    inputs.isStarting = isStarting
    inputs.isSignedIn = selectedAccount != nil
    inputs.isRunning = isRunning
    inputs.isStopping = workerPool.isStopping
    inputs.isPaused = isPaused
    inputs.isWaitingForNetwork = isWaitingForUnmeteredNetwork
    inputs.isOffline = isOffline || workerPool.lastBatchLostNetwork
    inputs.isRateLimited = workerPool.isRateLimited
    inputs.isScanning = isScanning || isScanningFolders
    inputs.source = .photoLibrary
    inputs.sourceIssue =
      switch photoLibraryStatus {
      case .notDetermined: .photosAccessNeeded(canPrompt: true)
      case .denied, .restricted: .photosAccessNeeded(canPrompt: false)
      case .limited: .limitedPhotosAccess
      default: nil
      }
    inputs.uploadingCount = max(0, workerPool.lastBatchTotalCount - workerPool.lastBatchCompletedCount - workerPool.lastBatchFailedCount)
    inputs.queuedCount = isRunning ? 0 : accountQueuedCount
    inputs.failedCount = accountFailedCount
    inputs.isWaitingForBackgroundBackup =
      accountUploadingCount == 0
      && accountPendingRecords.allSatisfy { backgroundUploadWaitIDs.contains($0.id) }
      && (selectedAccount.map { account in backgroundUploadWaitIDs.contains { $0.hasPrefix("\(account.email)|") } } ?? false)
    inputs.albumWarning = workerPool.statusMessage.hasPrefix("Uploaded, but") ? workerPool.statusMessage : nil
    inputs.autoSyncEnabled = settings.autoSyncEnabled
    inputs.isStoppedForSession = isStoppedForSession
    inputs.cleanupMessage = cleanupMessage
    return BackupStatus(inputs)
  }
}

/// Tells the Library when the tab bar shrinks, which is when it shows Years / Months / All
/// beside the bar.
private struct TabBarMinimizedTracker: ViewModifier {
  let model: UnifiedLibraryModel

  func body(content: Content) -> some View {
    content.background {
      TabBarMinimizedReader { minimized in
        if model.isTabBarMinimized != minimized { model.isTabBarMinimized = minimized }
      }
    }
  }
}

/// Whether the system has shrunk the tab bar. SwiftUI doesn't say, so it's read from the
/// bar: it shrinks by showing a small platter in place
/// of the full-width one, and grows by showing the full one again, each at the start of
/// its animation, so the picker comes and goes with the bar.
private struct TabBarMinimizedReader: UIViewRepresentable {
  let onChange: (Bool) -> Void

  func makeUIView(context: Context) -> ReaderView { ReaderView() }

  func updateUIView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
    view.attach()
  }

  final class ReaderView: UIView {
    var onChange: (Bool) -> Void = { _ in }
    private weak var full: UIView?
    private weak var small: UIView?
    private var observations: [NSKeyValueObservation] = []

    override func didMoveToWindow() {
      super.didMoveToWindow()
      // The tab bar is laid out after its content.
      DispatchQueue.main.async { self.attach() }
    }

    private weak var bar: UITabBar?

    func attach() {
      // The bar is found once; its platters only change as it shrinks and grows.
      if bar?.window == nil { bar = window.flatMap(Self.tabBar(in:)) }
      guard let bar else { return }
      let width = bar.bounds.width
      guard let full = bar.subviews.first(where: { $0.bounds.width > width / 2 }) else { return }
      // The small platter can be made again each time the bar shrinks.
      let small = bar.subviews.first { $0.bounds.width < width / 4 && $0.frame.midX < width / 2 }
      guard full !== self.full || small !== self.small else { return }
      self.full = full
      self.small = small
      // Called from a view update, which mustn't change state itself.
      let minimized = full.isHidden
      DispatchQueue.main.async { self.onChange(minimized) }
      var observations = [
        full.observe(\.isHidden, options: [.new]) { [weak self] _, change in
          guard let hidden = change.newValue else { return }
          MainActor.assumeIsolated { self?.changed(minimized: hidden) }
        }
      ]
      if let small {
        observations.append(
          small.observe(\.isHidden, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated { self?.changed(minimized: true) }
          })
      }
      self.observations = observations
    }

    private func changed(minimized: Bool) {
      onChange(minimized)
      DispatchQueue.main.async { self.attach() }
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
      if let bar = view as? UITabBar { return bar }
      for subview in view.subviews {
        if let bar = tabBar(in: subview) { return bar }
      }
      return nil
    }
  }
}
