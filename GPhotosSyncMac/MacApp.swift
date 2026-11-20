import AppIntents
import AppKit
import GPhotosKit
import SwiftUI
import UserNotifications

@main
struct GPhotosSyncMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
  @State private var store: MacSyncStore
  @State private var router = MacRouter()

  init() {
    LibrarySnapshot.prefetch()
    let store = MacSyncStore()
    AppDependencyManager.shared.add(dependency: store)
    // Siri can run the app without its window, before the window reads anything.
    SiriLibrary.shared.loadAccounts = { [weak store] in
      if let store, !store.hasLoadedAccounts { await store.loadAccounts() }
    }
    SiriLibrary.shared.backedUpFolders = { [weak store] in
      store?.folders.map { LibraryFolder(id: $0.id, path: $0.url.path, bookmarkData: $0.bookmarkData) } ?? []
    }
    // The keychain read overlaps the window's setup instead of following it.
    store.prefetchAccounts()
    _store = State(initialValue: store)
  }

  @ViewBuilder
  private var root: some View {
    #if DEBUG
      // Opens a screen directly for UI review, e.g. `-UIScreen activity`.
      let screen = UserDefaults.standard.string(forKey: "UIScreen")
      if let shareState = ShareStagingModel.PreviewState(screen: screen) {
        SharePreview(state: shareState)
      } else {
        switch screen {
        case "gallery": StateGallery()
        case "widgets": WidgetGallery().onAppear { MacWindowSnapshot.scheduleIfRequested() }
        case "menubar": MacMenuBarView(store: store, router: router).fixedSize()
        case "menubarUploading":
          MacMenuBarView(store: store, router: router).fixedSize()
            .onAppear { store.workerPool.startPreviewSimulation() }
        default:
          MacContentView(store: store, router: router)
            .onAppear {
              router.applyLaunchArguments()
              MacWindowSnapshot.scheduleIfRequested()
              if UserDefaults.standard.string(forKey: "UIScreen") == "uploading" {
                store.workerPool.startPreviewSimulation()
              }
            }
        }
      }
    #else
      MacContentView(store: store, router: router)
    #endif
  }

  var body: some Scene {
    Window(ProductCopy.name, id: MacRouter.mainWindowID) {
      root
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { appDelegate.attach(to: store, router: router) }
    }
    .defaultSize(width: 1000, height: 680)
    .commands {
      SidebarCommands()
      MacCommands(store: store, router: router)
    }

    MenuBarExtra {
      MacMenuBarView(store: store, router: router)
    } label: {
      MacMenuBarIcon(store: store)
    }
    .menuBarExtraStyle(.window)
  }
}

#if DEBUG
  /// The share extension's UI in a fixed state, held in state so window updates keep it.
  private struct SharePreview: View {
    @State private var model: ShareStagingModel

    init(state: ShareStagingModel.PreviewState) {
      _model = State(initialValue: .preview(state))
    }

    var body: some View {
      ShareStagingView(model: model, complete: {}, cancel: {})
    }
  }
#endif

#if DEBUG
  /// Writes the main window to a PNG for UI review without screen recording access, e.g.
  /// `-UISnapshot /tmp/library.png` (after `-UISnapshotDelay` seconds, 6 by default).
  @MainActor
  enum MacWindowSnapshot {
    static func scheduleIfRequested() {
      let defaults = UserDefaults.standard
      guard let path = defaults.string(forKey: "UISnapshot") else { return }
      let delay = defaults.double(forKey: "UISnapshotDelay")
      Task {
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 6))
        guard let view = MacRouter.mainWindow?.contentView?.superview ?? MacRouter.mainWindow?.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      }
    }
  }
#endif

/// Where the main window should be and what it should present. Commands and the menu
/// bar write here; the window reads it.
@MainActor
@Observable
final class MacRouter {
  static let mainWindowID = "main"

  /// What the sidebar has selected: one of the app's sections, or a collection opened
  /// straight from the sidebar (an album, Favorites, a Google Photos view).
  var selection: MacSidebarItem? = .section(.library)
  var activityFilter: ActivityFilter = .all
  var isSigningIn = false
  var isConfirmingSignOut = false
  var isAddingFolder = false
  var isChoosingMedia = false
  /// Focus Activity's search field.
  var focusSearch = false
  /// Focus the sidebar's library search field.
  var focusLibrarySearch = false
  var isConfirmingCleanup = false

  /// The main window, once SwiftUI has created it.
  static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true }
  }

  /// Un-minimizes and fronts the main window if it exists.
  static func restoreMainWindow() {
    guard let window = mainWindow else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  var section: MacSection? {
    if case .section(let section) = selection { return section }
    return nil
  }

  func show(_ section: MacSection, filter: ActivityFilter? = nil) {
    selection = .section(section)
    if let filter { activityFilter = filter }
  }

  #if DEBUG
    func applyLaunchArguments() {
      switch UserDefaults.standard.string(forKey: "UIScreen") {
      case "activity": show(.activity)
      case "library", "viewer", "cloud", "cloudViewer": show(.library)
      case "collections": show(.collections)
      case "cloudCollections": show(.collections)
      case "search": show(.search)
      case "overview", "uploading": show(.overview)
      case "failed": show(.activity, filter: .failed)
      case "folders": show(.folders)
      case "settings", "storage": show(.settings)
      case "signIn", "signInGoogle", "signInSwitch": isSigningIn = true
      default: break
      }
    }
  #endif
}

/// A row in the main window's sidebar.
enum MacSidebarItem: Hashable {
  case section(MacSection)
  case collection(CollectionRoute)
}

enum MacSection: String, CaseIterable, Identifiable {
  case library
  case search
  case collections
  case overview
  case activity
  case folders
  case settings

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .overview: "Backup"
    case .library: "Library"
    case .collections: "Collections"
    case .search: "Search"
    case .activity: "Activity"
    case .folders: "Folders"
    case .settings: "Settings"
    }
  }

  /// Outline symbols share one sidebar column; filled variants sit on different baselines.
  var symbol: String {
    switch self {
    case .overview: "arrow.triangle.2.circlepath.icloud"
    case .library: "photo.on.rectangle"
    case .collections: "rectangle.stack"
    case .search: "magnifyingglass"
    case .activity: "clock"
    case .folders: "folder"
    case .settings: "gearshape"
    }
  }
}

/// Isolated from the scene body so upload progress cannot invalidate the window.
private struct MacMenuBarIcon: View {
  let store: MacSyncStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    DisplayedBackupStatus(store.backupStatus) { status in
      Image(systemName: status.menuBarSymbol)
        .accessibilityLabel(Text("\(ProductCopy.name), \(status.title)"))
    }
    // Siri can ask for something in the Library while the window is closed; the icon is
    // always there to open it, and the window shows what was asked for.
    .onChange(of: SiriLibrary.shared.destination?.token) { _, token in
      guard token != nil, MacRouter.mainWindow == nil else { return }
      openWindow(id: MacRouter.mainWindowID)
      NSApp.activate()
    }
  }
}

private struct MacCommands: Commands {
  let store: MacSyncStore
  let router: MacRouter
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { present { router.show(.settings) } }
        .keyboardShortcut(",")
    }

    CommandGroup(before: .appTermination) {
      if store.selectedAccount == nil {
        Button("Sign In…") { present { router.isSigningIn = true } }
      } else {
        Button("Sign Out…") { present { router.isConfirmingSignOut = true } }
      }
      Divider()
    }

    CommandGroup(after: .textEditing) {
      Button("Find…") {
        present {
          if router.section == .activity {
            router.focusSearch = true
          } else {
            router.focusLibrarySearch = true
          }
        }
      }
      .keyboardShortcut("f")
      Button("Find in Activity…") {
        present {
          router.show(.activity)
          router.focusSearch = true
        }
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
    }

    CommandGroup(replacing: .newItem) {
      Button("Upload Photos, Videos, or Folders…") {
        present { router.isChoosingMedia = true }
      }
      .keyboardShortcut("o")
      Button("Add Folder to Back Up…") {
        present {
          router.show(.folders)
          router.isAddingFolder = true
        }
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
    }

    CommandGroup(before: .sidebar) {
      ForEach(Array(MacSection.allCases.enumerated()), id: \.element) { index, section in
        Button(section.title) { present { router.show(section) } }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
      Divider()
    }

    CommandMenu("Backup") {
      Button("Sync Now") { store.requestSyncNow() }
        .keyboardShortcut("r")
        .disabled(!store.canSync)
      Button(store.isPaused ? "Resume" : "Pause") {
        store.isPaused ? store.resumeTransfer() : store.pauseTransfer()
      }
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(!store.isRunning || store.workerPool.isStopping)
      Button("Stop") { store.stopTransfer() }
        .keyboardShortcut(".", modifiers: [.command, .option])
        .disabled(!store.isRunning || store.workerPool.isStopping)
      Divider()
      Button("Retry Failed Uploads") { Task { await store.retryFailedForUser() } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(store.accountRecordCounts.failed == 0)
    }
  }

  private func present(_ change: () -> Void) {
    change()
    openWindow(id: MacRouter.mainWindowID)
    NSApp.activate()
    MacRouter.restoreMainWindow()
  }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private weak var store: MacSyncStore?
  private weak var router: MacRouter?
  /// Files handed over by Finder before the window, and so the store, exist. Kept in
  /// defaults too, so a quit before the store attaches doesn't lose them.
  private var pendingURLs: [URL] = []
  private static let pendingPathsKey = "pendingExternalImportPaths"

  #if DEBUG
    func applicationWillFinishLaunching(_ notification: Notification) {
      // Forces an appearance for UI review, e.g. `-UIAppearance dark`.
      switch UserDefaults.standard.string(forKey: "UIAppearance") {
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
      case "light": NSApp.appearance = NSAppearance(named: .aqua)
      default: break
      }
    }
  #endif

  func attach(to store: MacSyncStore, router: MacRouter) {
    self.store = store
    self.router = router
    UNUserNotificationCenter.current().delegate = self
    BackupNotifier.shared.registerCategories()
    MacMirrorScheduler.shared.start(store: store)
    var urls = pendingURLs
    pendingURLs.removeAll()
    let defaults = UserDefaults.standard
    let saved = defaults.stringArray(forKey: Self.pendingPathsKey) ?? []
    defaults.removeObject(forKey: Self.pendingPathsKey)
    for path in saved where !urls.contains(where: { $0.path == path }) {
      urls.append(URL(fileURLWithPath: path))
    }
    guard !urls.isEmpty else { return }
    Task { await store.uploadDroppedFiles(urls: urls) }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    Task {
      await store.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    guard let store else {
      pendingURLs.append(contentsOf: files)
      let defaults = UserDefaults.standard
      let saved = defaults.stringArray(forKey: Self.pendingPathsKey) ?? []
      defaults.set(saved + files.map(\.path), forKey: Self.pendingPathsKey)
      return
    }
    Task { await store.uploadDroppedFiles(urls: files) }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { MacRouter.restoreMainWindow() }
    return true
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let actionIdentifier = response.actionIdentifier
    let destination = response.notification.request.content.userInfo[BackupNotifier.destinationKey] as? String

    await MainActor.run {
      if actionIdentifier == BackupNotifier.retryActionIdentifier {
        Task { [weak self] in
          await self?.store?.retryFailedForUser()
        }
        return
      }

      guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

      if let destination {
        switch destination {
        case BackupNotifier.destinationFailed:
          self.router?.show(.activity, filter: .failed)
        case BackupNotifier.destinationAccount:
          self.router?.isSigningIn = true
        default:
          break
        }
      }
      NSApp.activate()
      MacRouter.restoreMainWindow()
    }
  }
}
