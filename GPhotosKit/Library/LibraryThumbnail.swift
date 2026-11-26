import Photos
import SwiftUI

/// One thumbnail outside the grid (album covers, month cards, map pins), through the same
/// pipeline and cache as the grid.
struct LibraryThumbnail: View {
  let id: String?
  var bucket: ThumbnailBucket = .medium
  var source: any ThumbnailSource = PhotoKitImageSource.shared
  @State private var image: CGImage?
  @State private var ticket: ThumbnailTicket?

  var body: some View {
    Rectangle().fill(.quaternary)
      .overlay {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .transition(.opacity)
        }
      }
      .clipped()
      .onAppear(perform: load)
      .onDisappear {
        ticket?.cancel()
        ticket = nil
      }
      .onReceive(NotificationCenter.default.publisher(for: LockedItems.didLock).receive(on: DispatchQueue.main)) { _ in
        guard let id, source.thumbnailIdentity(for: id).isLocked else { return }
        ticket?.cancel()
        ticket = nil
        image = nil
      }
      .onChange(of: id) {
        image = nil
        load()
      }
  }

  private func load() {
    ticket?.cancel()
    guard let id, !id.isEmpty else { return }
    let key = ThumbnailKey(identity: source.thumbnailIdentity(for: id), bucket: bucket)
    if let cached = ThumbnailPipeline.shared.placeholder(for: key) { image = cached }
    ticket = ThumbnailPipeline.shared.load(
      key, from: source,
      onUnavailable: {
        if key.identity.isLocked { image = nil }
      }, handler: { image, _ in self.image = image })
  }
}
