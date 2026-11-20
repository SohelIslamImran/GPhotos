import AppKit
import GPhotosKit
import SwiftUI

struct MacFoldersView: View {
  let store: MacSyncStore
  @Bindable var router: MacRouter
  @State private var folderPendingRemoval: MacWatchedFolder?
  /// The blocked folder being chosen again, so the panel opens beside it.
  @State private var folderToRegrant: MacWatchedFolder?
  @State private var isTargeted = false
  @State private var selection = Set<MacWatchedFolder.ID>()
  @State private var newExclusion = ""

  var body: some View {
    List(selection: $selection) {
      if !store.folders.isEmpty {
        Section {
          ForEach(store.folders) { folder in
            FolderRow(
              folder: folder,
              state: state(of: folder),
              onToggle: { store.setFolderEnabled(id: folder.id, isEnabled: $0) },
              onChooseAgain: {
                folderToRegrant = folder
                router.isAddingFolder = true
              },
              onShowInFinder: { store.openFolderInFinder(url: folder.url) },
              onRemove: { folderPendingRemoval = folder }
            )
            .contextMenu {
              Button("Sync Now") { store.requestSyncNow() }
                .disabled(!store.canSync)
              if [.needsAccess, .notWatched].contains(state(of: folder)) {
                Button("Choose Again…") {
                  folderToRegrant = folder
                  router.isAddingFolder = true
                }
              }
              Button("Skip a Folder Inside…") { chooseExcludedFolder(in: folder.url) }
              Divider()
              Button("Show in Finder") { store.openFolderInFinder(url: folder.url) }
              Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.url.path, forType: .string)
              }
              Divider()
              Button("Remove Folder…", role: .destructive) { folderPendingRemoval = folder }
            }
          }
        } header: {
          Text("Watched Folders")
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            Text(footer)
              .foregroundStyle(.secondary)
            if store.settings.autoDeleteDelay != .never {
              Button("Protected Folders…") { router.show(.settings) }
                .buttonStyle(.link)
                .help("Choose folders whose files are never removed")
            }
          }
          .font(.subheadline)
          .fontWeight(.regular)
          .padding(.top, 6)
        }
        exclusionsSection
      }
    }
    .listStyle(.inset)
    .contentMargins(.horizontal, 12, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .onDeleteCommand {
      if let id = selection.first, let folder = store.folders.first(where: { $0.id == id }) {
        folderPendingRemoval = folder
      }
    }
    .overlay {
      if store.folders.isEmpty {
        ContentUnavailableView {
          Label("No Folders", systemImage: "folder.badge.plus")
        } description: {
          Text("Add folders on this Mac, or drag them here. New photos and videos in them back up automatically.")
        } actions: {
          Button("Add Folder…") { router.isAddingFolder = true }
            .buttonStyle(.glassProminent)
        }
      }
    }
    .overlay {
      if isTargeted {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(8)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      let isDirectory = { (url: URL) in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      }
      let folders = files.filter(isDirectory)
      let loose = files.filter { !isDirectory($0) }
      for folder in folders { store.addFolder(url: folder) }
      if !loose.isEmpty { store.importFiles(loose) }
      return !files.isEmpty
    } isTargeted: {
      isTargeted = $0
    }
    .navigationTitle("Folders")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Folder", systemImage: "plus") { router.isAddingFolder = true }
          .help("Add a folder to back up")
      }
    }
    .fileImporter(isPresented: $router.isAddingFolder, allowedContentTypes: [.folder]) { result in
      guard case .success(let url) = result else { return }
      let started = url.startAccessingSecurityScopedResource()
      defer { if started { url.stopAccessingSecurityScopedResource() } }
      store.addFolder(url: url)
    }
    .fileDialogDefaultDirectory(folderToRegrant?.url.deletingLastPathComponent())
    .fileDialogMessage(
      folderToRegrant.map { "Select “\($0.title)” again to restore access." }
        ?? "New photos and videos in this folder back up to Google Photos."
    )
    .fileDialogConfirmationLabel(folderToRegrant == nil ? "Add Folder" : "Grant Access")
    .onChange(of: router.isAddingFolder) { _, isPresented in
      if !isPresented { folderToRegrant = nil }
    }
    .confirmationDialog(
      "Stop backing up “\(folderPendingRemoval?.title ?? "")”?",
      isPresented: Binding(get: { folderPendingRemoval != nil }, set: { if !$0 { folderPendingRemoval = nil } }),
      titleVisibility: .visible,
      presenting: folderPendingRemoval
    ) { folder in
      Button("Remove Folder", role: .destructive) { store.removeFolder(id: folder.id) }
    } message: { _ in
      Text("Photos already uploaded stay in Google Photos. Nothing on this Mac is deleted.")
    }
  }

  /// Names and folders the backup leaves out of every watched folder, such as an editor's
  /// project files inside Movies.
  private var exclusionsSection: some View {
    Section {
      ForEach(store.settings.backupExclusions, id: \.self) { rule in
        let isPath = rule.hasPrefix("/") || rule.hasPrefix("~")
        HStack(spacing: 10) {
          Image(systemName: isPath ? "folder.badge.minus" : "textformat.abc")
            .foregroundStyle(.secondary)
            .frame(width: 20)
          Text(isPath ? abbreviatedHomePath(NSString(string: rule).expandingTildeInPath) : rule)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button("Remove", systemImage: "minus.circle.fill") { store.removeBackupExclusion(rule) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Back this up again")
        }
        .contextMenu {
          Button("Remove", role: .destructive) { store.removeBackupExclusion(rule) }
        }
      }
      HStack(spacing: 8) {
        TextField("Folder or file name", text: $newExclusion, prompt: Text("Name, like CapCut or *.tmp"))
          .textFieldStyle(.roundedBorder)
          .onSubmit(addExclusion)
        Button("Skip", action: addExclusion)
          .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Choose Folder…") { chooseExcludedFolder(in: store.folders.first?.url) }
          .help("Skip one folder inside a watched folder")
      }
    } header: {
      Text("Skipped")
    } footer: {
      Text(
        "Folders and files with these names are skipped in every watched folder, with everything inside them. * matches any text. Files already backed up stay in Google Photos."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(.top, 6)
    }
  }

  private func addExclusion() {
    store.addBackupExclusion(newExclusion)
    newExclusion = ""
  }

  /// A path is kept as written, not a bookmark: the folder is only compared, never read.
  private func chooseExcludedFolder(in directory: URL?) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = String(localized: "Skip")
    panel.message = String(localized: "Photos and videos in these folders won’t back up.")
    panel.directoryURL = directory
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { store.addBackupExclusion(url.standardizedFileURL.path) }
  }

  private var footer: LocalizedStringKey {
    store.settings.autoDeleteDelay == .never
      ? "New photos and videos in these folders back up automatically. Drag folders here to add more."
      : "New photos and videos in these folders back up automatically. Drag folders here to add more. With Delete After Backup on, backed-up files are removed from these folders automatically, except in protected folders."
  }

  private func state(of folder: MacWatchedFolder) -> FolderRow.State {
    guard folder.isEnabled else { return .paused }
    guard store.isFolderReadable(folder) else { return .needsAccess }
    guard store.selectedAccount != nil else { return .waitingForSignIn }
    guard store.settings.autoSyncEnabled else { return .autoSyncOff }
    return store.unwatchableFolders.contains(folder.id) ? .notWatched : .watching
  }
}

private struct FolderRow: View {
  enum State {
    case watching
    case paused
    case needsAccess
    case notWatched
    case waitingForSignIn
    case autoSyncOff

    var title: LocalizedStringKey {
      switch self {
      case .watching: "Watching for new photos"
      case .paused: "Paused"
      case .needsAccess: "macOS is blocking this folder"
      case .notWatched: "Can’t watch for changes — use Sync Now"
      case .waitingForSignIn: "Waiting for sign-in"
      case .autoSyncOff: "Auto-Sync is off"
      }
    }

    var tint: Color {
      switch self {
      case .watching: .green
      case .paused, .waitingForSignIn, .autoSyncOff: .secondary
      case .needsAccess, .notWatched: .orange
      }
    }
  }

  let folder: MacWatchedFolder
  let state: State
  let onToggle: (Bool) -> Void
  let onChooseAgain: () -> Void
  let onShowInFinder: () -> Void
  let onRemove: () -> Void

  private var needsRecovery: Bool { state == .needsAccess || state == .notWatched }

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: state == .needsAccess ? "exclamationmark.triangle.fill" : "folder.fill")
        .font(.title2)
        .foregroundStyle(state == .needsAccess ? Color.orange : Color.blue)
        .frame(width: 36)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(folder.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(abbreviatedHomePath(folder.url.path))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Label(state.title, systemImage: "circle.fill")
          .labelStyle(StatusDotLabelStyle(tint: state.tint))
          .font(.caption)
          .lineLimit(1)
          .help(Text(state.title))
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 12)
      Button("Choose Again…", action: onChooseAgain)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(
          state == .needsAccess
            ? "macOS is blocking this folder — select it again to restore access"
            : "macOS will not watch this folder for changes — select it again to retry"
        )
        .opacity(needsRecovery ? 1 : 0)
        .disabled(!needsRecovery)
        .accessibilityHidden(!needsRecovery)
      Toggle("Watch \(folder.title)", isOn: Binding(get: { folder.isEnabled }, set: { onToggle($0) }))
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityHint(state.title)
      HStack(spacing: 4) {
        Button("Show \(folder.title) in Finder", systemImage: "magnifyingglass.circle", action: onShowInFinder)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .contentShape(.rect)
          .help("Show in Finder")
        Button("Remove \(folder.title)", systemImage: "trash", role: .destructive, action: onRemove)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.red.opacity(0.85))
          .frame(width: 26, height: 26)
          .contentShape(.rect)
          .help("Remove Folder…")
      }
    }
    .frame(height: 64)
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }
}

private struct StatusDotLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon
        .font(.system(size: 8))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      configuration.title
        .foregroundStyle(.secondary)
    }
  }
}

/// `path` with the user's home shown as `~`. The sandbox redirects `NSHomeDirectory()`
/// into the container, so this reads the real home.
func abbreviatedHomePath(_ path: String) -> String {
  guard let home = getpwuid(getuid())?.pointee.pw_dir else { return (path as NSString).abbreviatingWithTildeInPath }
  let prefix = String(cString: home)
  if path == prefix { return "~" }
  return path.hasPrefix(prefix + "/") ? "~" + path.dropFirst(prefix.count) : path
}
