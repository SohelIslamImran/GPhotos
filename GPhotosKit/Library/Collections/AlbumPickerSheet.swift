import Photos
import SwiftUI

/// Adds items to an existing album or a new one.
struct AlbumPickerSheet: View {
  let assets: [PHAsset]
  var count: Int? = nil
  var resolve: (() async -> [PHAsset])? = nil
  let onDone: () -> Void
  private let collections = PhotoCollectionsModel.shared
  @State private var isNaming = false
  @State private var newTitle = ""
  @State private var errorMessage: String?

  var body: some View {
    let count = count ?? assets.count
    NavigationStack {
      List {
        Button {
          isNaming = true
        } label: {
          Label("New Album", systemImage: "plus.rectangle.on.rectangle")
        }
        Section("Albums") {
          ForEach(collections.albums) { album in
            Button {
              finish { try await LibraryActions.add($0, toAlbum: album.id) }
            } label: {
              HStack(spacing: 12) {
                LibraryThumbnail(id: album.keyAssetID, bucket: .small)
                  .frame(width: 44, height: 44)
                  .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading) {
                  Text(album.title).foregroundStyle(.primary)
                  Text(album.count, format: .number).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .navigationTitle(count <= 1 ? "Add to Album" : "Add \(count) Items to Album")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
      }
      .alert("New Album", isPresented: $isNaming) {
        TextField("Title", text: $newTitle)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
          let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !title.isEmpty else { return }
          finish { try await LibraryActions.createAlbum(titled: title, with: $0) }
        }
      } message: {
        Text("Enter a name for this album.")
      }
      .alert(
        "Couldn't Add to Album", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(errorMessage ?? "")
      }
      .task { await collections.loadIfNeeded() }
    }
    #if os(macOS)
      .frame(minWidth: 360, minHeight: 420)
    #endif
  }

  private func finish(_ action: @escaping @MainActor ([PHAsset]) async throws -> Void) {
    Task {
      do {
        let current = await resolve?() ?? assets
        if resolve == nil || !current.isEmpty { try await action(current) }
        onDone()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
