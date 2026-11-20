import GPhotosKit
import SwiftUI

/// Albums in the photo library whose items are excluded from backup.
struct ExcludedAlbumsView: View {
  let model: AppModel
  @State private var albums: [AlbumSummary]?
  @State private var query = ""
  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

  var body: some View {
    content
      .navigationTitle("Don’t Back Up")
      .navigationBarTitleDisplayMode(.inline)
      .task { albums = await model.userAlbums() }
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
        Text("Photos in these albums aren’t backed up. Ones already backed up stay in Google Photos.")
      }
    }
  }

  private func albumLabel(_ album: AlbumSummary) -> some View {
    HStack(spacing: 14) {
      IconTile(symbol: "photo.on.rectangle", colors: [.orange, .red], size: iconSize)
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

  private func filtered(_ albums: [AlbumSummary]) -> [AlbumSummary] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return albums }
    return albums.filter { $0.title.localizedStandardContains(trimmed) }
  }

  private func binding(for album: AlbumSummary) -> Binding<Bool> {
    Binding {
      model.settings.excludedAlbumIDs.contains(album.id)
    } set: {
      model.setAlbumExcluded(album.id, $0)
    }
  }
}
