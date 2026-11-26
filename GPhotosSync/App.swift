import AppIntents
import GPhotosKit
import SwiftUI
import UserNotifications

@main
struct GPhotosSyncApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @State private var notificationDelegate: CleanupNotificationDelegate
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Read while the rest starts up, so the Library's first frame can draw it.
    LibrarySnapshot.prefetch()
    // Collections opens complete, instead of filling in (and shifting) as it loads.
    Task { await PhotoCollectionsModel.shared.loadIfNeeded(priority: .utility) }
    let model = AppModel()
    model.prefetchAccounts()
    _model = State(initialValue: model)
    AppDelegate.backgroundUploads = model.backgroundUploads
    model.backgroundUploads.onTransfersFinished = { [weak model] in
      await model?.reconcileBackgroundTransfers()
    }
    // Must be in place before launch finishes, or a tap that launched the app is lost.
    let delegate = CleanupNotificationDelegate(model: model)
    UNUserNotificationCenter.current().delegate = delegate
    _notificationDelegate = State(initialValue: delegate)
    BackgroundTaskRegistrar.register(model: model)
    BackgroundTaskRegistrar.scheduleAppRefresh()
    AppDependencyManager.shared.add(dependency: model)
    // Siri can run the app without its window, before the root view reads anything.
    SiriLibrary.shared.loadAccounts = { [weak model] in
      if let model, !model.hasLoadedAccounts { await model.loadAccounts() }
    }
    SiriLibrary.shared.backedUpFolders = { [weak model] in
      model?.backedUpFolders.map { LibraryFolder(id: $0.id, path: $0.path, bookmarkData: $0.bookmarkData) } ?? []
    }
    BackupNotifier.shared.registerCategories()
    #if os(iOS) && canImport(ActivityKit)
      LiveActivityController.shared.endStaleActivitiesAtLaunch()
    #endif
  }

  @ViewBuilder
  private var root: some View {
    #if DEBUG
      if UserDefaults.standard.string(forKey: "UIScreen") == "gallery" {
        StateGallery()
      } else if UserDefaults.standard.string(forKey: "UIScreen") == "widgets" {
        WidgetGallery()
      } else {
        ContentView(model: model)
      }
    #else
      ContentView(model: model)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      root
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        BackgroundTaskRegistrar.scheduleProcessingOnBackground(for: model)
        BackgroundTaskRegistrar.scheduleMirror(for: model)
      } else if phase == .active {
        model.checkAndRunForegroundMirror()
      }
    }
  }
}

/// Turns a tapped "ready to remove" notification into the in-app cleanup prompt.
final class CleanupNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  private let model: AppModel

  init(model: AppModel) {
    self.model = model
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let actionIdentifier = response.actionIdentifier
    let isCleanup = AppModel.isCleanupNotification(userInfo: response.notification.request.content.userInfo)
    let destination = response.notification.request.content.userInfo[BackupNotifier.destinationKey] as? String
    let model = model

    if actionIdentifier == BackupNotifier.retryActionIdentifier {
      if await !model.hasLoadedAccounts { await model.loadAccounts() }
      await model.retryFailedForUser()
      return
    }

    guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

    if isCleanup {
      await MainActor.run { model.pendingCleanupPrompt = true }
      return
    }

    if let destination {
      await MainActor.run {
        switch destination {
        case BackupNotifier.destinationFailed:
          model.pendingActivityFilter = .failed
        case BackupNotifier.destinationAccount:
          model.pendingAccountSheet = true
        default:
          break
        }
      }
    }
  }
}
