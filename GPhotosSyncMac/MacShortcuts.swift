import AppIntents
import GPhotosKit

struct MacBackUpNowIntent: AppIntent {
  static let title: LocalizedStringResource = "Back Up Now"
  static let description = IntentDescription("Back up new photos and videos in your watched folders to Google Photos.")
  static let supportedModes: IntentModes = .foreground
  @Dependency private var store: MacSyncStore

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await store.start()
    guard store.selectedAccount != nil else {
      return .result(dialog: "Open GPhotos and sign in to back up.")
    }
    store.requestSyncNow(donate: false)
    return .result(dialog: "Backup requested. Check Activity for progress.")
  }
}

struct GPhotosSyncMacShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: MacBackUpNowIntent(),
      phrases: ["Back up now with \(.applicationName)", "Run \(.applicationName) backup"],
      shortTitle: "Back Up Now", systemImageName: "arrow.triangle.2.circlepath")
    AppShortcut(
      intent: BackUpFilesIntent(),
      phrases: ["Back up files with \(.applicationName)"],
      shortTitle: "Back Up Files", systemImageName: "doc.badge.arrow.up")
    AppShortcut(
      intent: BackupStatusIntent(),
      phrases: ["Check my \(.applicationName) backup", "How is my \(.applicationName) backup"],
      shortTitle: "Backup Status", systemImageName: "icloud.and.arrow.up")
    AppShortcut(
      intent: SearchLibraryIntent(),
      phrases: ["Search \(.applicationName)", "Search my photos in \(.applicationName)"],
      shortTitle: "Search Library", systemImageName: "magnifyingglass")
    AppShortcut(
      intent: FindPhotosIntent(),
      phrases: ["Find photos in \(.applicationName)", "Find pictures with \(.applicationName)"],
      shortTitle: "Find Photos", systemImageName: "photo.on.rectangle.angled")
    AppShortcut(
      intent: OpenAlbumIntent(),
      phrases: ["Open an album in \(.applicationName)", "Show my albums in \(.applicationName)"],
      shortTitle: "Open Album", systemImageName: "rectangle.stack")
  }
}
