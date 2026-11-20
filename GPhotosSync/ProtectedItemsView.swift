import GPhotosKit
import SwiftUI
import UniformTypeIdentifiers

/// What Clean Up never removes: Favorites and chosen albums in the photo library, and
/// anything inside a protected folder.
struct ProtectedItemsView: View {
  let model: AppModel
  @State private var albums: [AlbumSummary]?
  @State private var query = ""
  @State private var isChoosingFolder = false
  @State private var folderToUnprotect: IgnoredFolderLocation?
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

  var body: some View {
    content
      .navigationTitle("Protected Items")
      .navigationBarTitleDisplayMode(.inline)
      .task { albums = await model.userAlbums() }
      .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { model.addIgnoredFolder(url) }
      }
      .confirmationDialog(
        Text("Remove Protection?"),
        isPresented: isConfirmingUnprotect,
        titleVisibility: .visible,
        presenting: folderToUnprotect
      ) { folder in
        Button("Remove Protection", role: .destructive) { model.removeIgnoredFolder(folder.id) }
      } message: { folder in
        Text("Backed-up files in “\(folder.title)” may then be removed from this iPhone.")
      }
  }

  private var isConfirmingUnprotect: Binding<Bool> {
    Binding {
      folderToUnprotect != nil
    } set: {
      if !$0 { folderToUnprotect = nil }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let albums, albums.count > 8 {
      list(albums).searchable(text: $query, prompt: "Search Albums")
    } else {
      list(albums)
    }
  }

  private func list(_ albums: [AlbumSummary]?) -> some View {
    List {
      Section {
        Toggle(isOn: favoritesBinding) {
          SettingLabel(
            "Protect Favorites",
            detail: "Keep photos you've favorited on this iPhone.",
            symbol: "heart.fill", colors: [.pink, .red]
          )
        }
      } header: {
        Text("Favorites")
      }

      Section {
        ForEach(model.settings.ignoredFolders) { folder in
          folderLabel(folder)
            .swipeActions(edge: .trailing) {
              Button("Remove Protection…", systemImage: "lock.open") { folderToUnprotect = folder }
                .tint(.red)
            }
            .contextMenu {
              Button("Remove Protection…", systemImage: "lock.open", role: .destructive) { folderToUnprotect = folder }
            }
        }
        Button("Add Folder…", systemImage: "folder.badge.plus") { isChoosingFolder = true }
      } header: {
        Text("Folders")
      } footer: {
        Text("Files in these folders are never removed, even after they're backed up.")
      }

      Section {
        if let albums {
          let shown = filtered(albums)
          if albums.isEmpty {
            ContentUnavailableView(
              "No Albums", systemImage: "photo.on.rectangle",
              description: Text("Albums you create in Photos appear here.")
            )
          } else if shown.isEmpty {
            ContentUnavailableView.search(text: query)
          } else {
            ForEach(shown) { album in
              Toggle(isOn: binding(for: album)) {
                albumLabel(album)
              }
            }
          }
        } else {
          ProgressView()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
      } header: {
        Text("Albums")
      } footer: {
        Text(ProductCopy.cleanupExplanation)
      }
    }
  }

  private func albumLabel(_ album: AlbumSummary) -> some View {
    HStack(spacing: 14) {
      IconTile(symbol: "photo.on.rectangle", colors: [.blue, .cyan], size: iconSize)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: album.title)
          .font(.body.weight(.semibold))
          .lineLimit(2)
        Text("^[\(album.count) item](inflect: true)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func folderLabel(_ folder: IgnoredFolderLocation) -> some View {
    HStack(spacing: 14) {
      IconTile(symbol: "folder.fill", colors: [.orange, .yellow], size: iconSize)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: folder.title)
          .font(.body.weight(.semibold))
          .lineLimit(2)
        Text(verbatim: FolderBackup.displayPath(folder.path))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func filtered(_ albums: [AlbumSummary]) -> [AlbumSummary] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return albums }
    return albums.filter { $0.title.localizedStandardContains(trimmed) }
  }

  private var favoritesBinding: Binding<Bool> {
    Binding {
      model.settings.protectsFavorites
    } set: {
      model.setProtectsFavorites($0)
    }
  }

  private func binding(for album: AlbumSummary) -> Binding<Bool> {
    Binding {
      model.settings.protectedAlbumIDs.contains(album.id)
    } set: {
      model.setAlbumProtected(album.id, $0)
    }
  }
}
