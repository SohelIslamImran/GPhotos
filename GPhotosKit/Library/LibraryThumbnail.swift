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
      .onChange(of: id) {
        image = nil
        load()
      }
  }

  private func load() {
    ticket?.cancel()
    guard let id, !id.isEmpty else { return }
    let key = ThumbnailKey(id: id, bucket: bucket)
    if let cached = ThumbnailPipeline.shared.placeholder(for: key) { image = cached }
    ticket = ThumbnailPipeline.shared.load(key, from: source) { image, _ in self.image = image }
  }
}
