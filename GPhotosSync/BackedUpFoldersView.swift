import GPhotosKit
import SwiftUI
import UniformTypeIdentifiers

/// Folders from the Files app whose photos and videos are backed up.
struct BackedUpFoldersView: View {
  let model: AppModel
  @State private var isImporting = false
  @State private var importPurpose = ImportPurpose.add
  @State private var folderToRemove: BackedUpFolder?
  @State private var errorMessage: String?
  @State private var newExclusion = ""
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 34

  private enum ImportPurpose {
    case add
    case reauthorize(String)
  }

  var body: some View {
    List {
      if !model.backedUpFolders.isEmpty {
        Section {
          ForEach(model.backedUpFolders) { folder in
            row(folder)
              .listRowBackground(Rectangle().fill(.regularMaterial))
              .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "trash") { folderToRemove = folder }
                  .tint(.red)
              }
              .contextMenu {
                if model.status(of: folder) == .needsAccess {
                  Button("Choose Again…", systemImage: "folder.badge.questionmark") { choose(.reauthorize(folder.id)) }
                }
                Button("Copy Path", systemImage: "link") { UIPasteboard.general.string = folder.path }
                Button("Remove", systemImage: "trash", role: .destructive) { folderToRemove = folder }
              }
          }
        } footer: {
          Text(footer)
        }
        Section {
          SettingRow(
            "Albums from Folders", detail: "Add photos to an album named after their folder.",
            symbol: "rectangle.stack.fill", colors: [.blue, .indigo]
          ) {
            Toggle("Albums from Folders", isOn: model.setting(\.createAlbumsFromFolders))
          }
          .listRowInsets(EdgeInsets())
          .listRowBackground(Rectangle().fill(.regularMaterial))
        }
        exclusionsSection
      }
    }
    .scrollContentBackground(.hidden)
    .background { AmbientBackground(tint: .orange) }
    .overlay {
      if model.backedUpFolders.isEmpty {
        ContentUnavailableView {
          Label("No Folders", systemImage: "folder")
        } description: {
          Text("Add folders from the Files app. New photos and videos in them back up automatically.")
        } actions: {
          Button("Add Folder…") { choose(.add) }
            .buttonStyle(.glassProminent)
        }
      }
    }
    .navigationTitle("Folders")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Folder", systemImage: "plus") { choose(.add) }
      }
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
      handleImport(result)
    }
    .confirmationDialog(
      Text("Stop Backing Up “\(folderToRemove?.title ?? "")”?"),
      isPresented: isConfirmingRemoval,
      titleVisibility: .visible,
      presenting: folderToRemove
    ) { folder in
      Button("Remove", role: .destructive) { model.removeBackedUpFolder(id: folder.id) }
    } message: { _ in
      Text("Already uploaded photos stay in Google Photos.")
    }
    .alert("Couldn't Add Folder", isPresented: isShowingError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .task { await model.refreshFolderStatus() }
  }

  /// Names the backup leaves out of every folder, such as an editor's project files.
  private var exclusionsSection: some View {
    Section {
      ForEach(model.settings.backupExclusions, id: \.self) { rule in
        Label(rule, systemImage: "nosign")
          .lineLimit(1)
          .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash") { model.removeBackupExclusion(rule) }
              .tint(.red)
          }
          .contextMenu {
            Button("Remove", systemImage: "trash", role: .destructive) { model.removeBackupExclusion(rule) }
          }
          .listRowBackground(Rectangle().fill(.regularMaterial))
      }
      HStack {
        TextField("Folder or File Name", text: $newExclusion, prompt: Text("Name, like CapCut or *.tmp"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit(addExclusion)
        Button("Skip", action: addExclusion)
          .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .listRowBackground(Rectangle().fill(.regularMaterial))
    } header: {
      Text("Skipped")
    } footer: {
      Text(
        "Folders and files with these names are skipped in every folder, with everything inside them. * matches any text."
      )
    }
  }

  private func addExclusion() {
    model.addBackupExclusion(newExclusion)
    newExclusion = ""
  }

  private var footer: LocalizedStringKey {
    model.settings.autoDeleteDelay == .never
      ? "New photos and videos in these folders are backed up to Google Photos."
      : "New photos and videos in these folders are backed up to Google Photos. With Delete After Backup on, backed-up files are removed from these folders automatically, except in protected folders."
  }

  private func row(_ folder: BackedUpFolder) -> some View {
    let status = model.status(of: folder)
    let needsAccess = status == .needsAccess
    return HStack(spacing: 14) {
      IconTile(
        symbol: needsAccess ? "exclamationmark.triangle.fill" : "folder.fill",
        colors: needsAccess ? [.red, .orange] : [.orange, .yellow],
        size: iconSize
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: folder.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Text(verbatim: FolderBackup.displayPath(folder.path))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(status.title)
          .font(.footnote.weight(needsAccess ? .semibold : .regular))
          .foregroundStyle(needsAccess ? Color.red : Color.secondary)
        if needsAccess {
          Button("Choose Again…") { choose(.reauthorize(folder.id)) }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(isOn: enabledBinding(for: folder)) {
        Text("Back Up \(folder.title)")
      }
      .labelsHidden()
      .disabled(needsAccess)
    }
    .padding(.vertical, 4)
  }

  private func enabledBinding(for folder: BackedUpFolder) -> Binding<Bool> {
    Binding {
      model.backedUpFolders.first { $0.id == folder.id }?.isEnabled ?? false
    } set: {
      model.setFolderEnabled(id: folder.id, isEnabled: $0)
    }
  }

  private var isConfirmingRemoval: Binding<Bool> {
    Binding {
      folderToRemove != nil
    } set: {
      if !$0 { folderToRemove = nil }
    }
  }

  private var isShowingError: Binding<Bool> {
    Binding {
      errorMessage != nil
    } set: {
      if !$0 { errorMessage = nil }
    }
  }

  private func choose(_ purpose: ImportPurpose) {
    importPurpose = purpose
    isImporting = true
  }

  private func handleImport(_ result: Result<URL, any Error>) {
    switch result {
    case .success(let url):
      let purpose = importPurpose
      Task {
        let failure =
          switch purpose {
          case .add: await model.addBackedUpFolder(url)
          case .reauthorize(let id): await model.reauthorizeBackedUpFolder(id: id, url: url)
          }
        errorMessage = failure
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }
}
