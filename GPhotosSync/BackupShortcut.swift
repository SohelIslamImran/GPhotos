import AppIntents
import GPhotosKit

/// Runs a backup pass from Shortcuts. iOS decides on its own when background refresh runs,
/// and may rarely run it for an app that is seldom opened; an automation such as "When
/// iPhone is connected to power" gives a pass at a moment the user picks.
struct BackUpPhotosIntent: AppIntent {
  static let title: LocalizedStringResource = "Back Up Photos"
  static let description = IntentDescription(
    "Backs up new photos and videos to Google Photos. Large items wait until GPhotos can run longer.")
  static let supportedModes: IntentModes = .background

  @Dependency private var model: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let summary = await BackgroundTaskRegistrar.runShortcutPass(model: model)
    return .result(dialog: IntentDialog(stringLiteral: summary))
  }
}

struct GPhotosSyncShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: BackUpPhotosIntent(),
      phrases: ["Back up photos with \(.applicationName)", "Run \(.applicationName) backup"],
      shortTitle: "Back Up Photos",
      systemImageName: "arrow.triangle.2.circlepath")
    AppShortcut(
      intent: BackUpAssetsIntent(),
      phrases: ["Back up these photos with \(.applicationName)"],
      shortTitle: "Back Up Selected Photos", systemImageName: "photo.badge.arrow.up")
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
