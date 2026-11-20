import AppIntents
import GPhotosKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import Photos
  private typealias BackupModel = AppModel
#else
  private typealias BackupModel = MacSyncStore
#endif

struct BackUpFilesIntent: AppIntent {
  static let title: LocalizedStringResource = "Back Up Files"
  static let description = IntentDescription("Back up image and video files to Google Photos in original quality.")
  static let supportedModes: IntentModes = .foreground

  @Parameter(title: "Files", supportedContentTypes: [.image, .movie])
  var files: [IntentFile]
  @Dependency private var model: BackupModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    if !model.hasLoadedAccounts { await model.loadAccounts() }
    guard model.selectedAccount != nil else {
      return .result(dialog: "Open GPhotos and sign in to back up.")
    }
    var accepted = 0
    for file in files {
      try Task.checkCancellation()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      // Intent files can be data-backed. Keep their extension for the media validator.
      let url = directory.appendingPathComponent(URL(fileURLWithPath: file.filename).lastPathComponent)
      try await Task.detached(priority: .utility) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
          if let source = file.fileURL {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: url)
          } else {
            try file.data.write(to: url)
          }
        } catch {
          try? FileManager.default.removeItem(at: directory)
          throw error
        }
      }.value
      defer { try? FileManager.default.removeItem(at: directory) }
      #if os(iOS)
        if try await model.uploadSingleFile(url: url) != nil { accepted += 1 }
      #else
        await model.uploadDroppedFiles(urls: [url])
        if let error = model.importError { return .result(dialog: IntentDialog(stringLiteral: error)) }
        accepted += 1
      #endif
    }
    return .result(dialog: "Sent ^[\(accepted) file](inflect: true) for backup. Check Activity for progress.")
  }
}

struct BackupStatusIntent: AppIntent {
  static let title: LocalizedStringResource = "Backup Status"
  static let description = IntentDescription("Check your Google Photos backup progress and last backup.")
  static let supportedModes: IntentModes = .background
  @Dependency private var model: BackupModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
    if !model.hasLoadedAccounts { await model.loadAccounts() }
    await model.refreshRecords()
    let status: BackupStatus = model.selectedAccount == nil ? .signedOut : model.backupStatus
    let summary =
      model.selectedAccount == nil
      ? String(localized: "Open GPhotos and sign in to back up.")
      : status.title + ". "
        + BackupIntentSummary.text(
          pending: model.accountQueuedCount, uploading: model.accountUploadingCount,
          failed: model.accountRecords.filter { $0.status == .failed }.count,
          lastBackup: model.accountRecords.compactMap(\.sentAt).max())
    return .result(dialog: IntentDialog(stringLiteral: summary)) {
      VStack(alignment: .leading, spacing: 8) {
        Label(status.title, systemImage: status.symbol)
          .font(.headline)
          .foregroundStyle(status.tint)
        Text(summary).font(.subheadline)
      }
      .padding()
    }
  }
}

#if os(iOS)
  struct BackUpAssetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up to Google Photos"
    static let description = IntentDescription("Back up the photos and videos you choose to Google Photos.")
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "Photos") var assets: [PHAsset]
    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
      if !model.hasLoadedAccounts { await model.loadAccounts() }
      guard model.selectedAccount != nil else {
        return .result(dialog: "Open GPhotos and sign in to back up.")
      }
      var accepted = 0
      for asset in assets {
        try Task.checkCancellation()
        if try await model.uploadIntentAsset(asset) { accepted += 1 }
      }
      return .result(dialog: "Sent ^[\(accepted) item](inflect: true) for backup. Check Activity for progress.")
    }
  }

  extension AppModel {
    /// Uses the same app-owned staging and upload path as the Photos picker.
    func uploadIntentAsset(_ asset: PHAsset) async throws -> Bool {
      let url = try await Task.detached(priority: .utility) {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("GPhotosIntentAssets").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
          let resources = PHAssetResource.assetResources(for: asset)
          guard let name = AssetExportService.primaryUploadFilename(for: asset, in: resources) else {
            throw GPhotosError.fileReadFailed("This item could not be read from Photos.")
          }
          let destination = directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
          return try await AssetExportService.exportResource(asset: asset, role: .primary, to: destination).0
        } catch {
          try? FileManager.default.removeItem(at: directory)
          throw error
        }
      }.value
      defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
      return try await uploadSingleFile(url: url) != nil
    }
  }
#endif
