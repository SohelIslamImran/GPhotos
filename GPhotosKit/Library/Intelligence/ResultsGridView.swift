import SwiftUI

/// A subset of the merged library (search results, a person, a memory) as a grid source.
@MainActor
final class LibrarySubsetModel: MediaViewerSource {
  let base: UnifiedLibraryModel
  private(set) var positions: [Int]

  init(base: UnifiedLibraryModel, positions: [Int]) {
    self.base = base
    self.positions = positions
  }

  var itemCount: Int { positions.count }
  var badgeToken: Int { base.badgeToken }
  var thumbnailSource: any ThumbnailSource { base.thumbnailSource }

  private func position(_ index: Int) -> Int? { positions.indices.contains(index) ? positions[index] : nil }

  func itemID(at index: Int) -> String { position(index).map(base.itemID(at:)) ?? "" }
  func thumbnailIdentity(at index: Int) -> ThumbnailIdentity {
    position(index).map(base.thumbnailIdentity(at:)) ?? ThumbnailIdentity(id: "")
  }
  func aspectRatio(at index: Int) -> CGFloat? { position(index).flatMap(base.aspectRatio(at:)) }
  func badges(at index: Int) -> PhotoGridBadges { position(index).map(base.badges(at:)) ?? PhotoGridBadges() }
  func accessibilityLabel(at index: Int) -> String { position(index).map(base.accessibilityLabel(at:)) ?? "" }
  func viewerItem(at index: Int) -> ViewerItem? { position(index).flatMap(base.viewerItem(at:)) }
  func entityID(at index: Int) -> String? { position(index).flatMap(base.entityID(at:)) }
}

/// Items from the merged library by index id, in the grid with the full viewer.
struct ResultsGridView: View {
  let title: String
  let library: UnifiedLibraryModel
  /// Nil while they're being found.
  let ids: [String]?
  var searchQuery: String? = nil
  @State private var model: LibrarySubsetModel?
  @State private var reloadToken = 0
  @State private var opened: Int?
  @State private var zoom = ViewerZoom()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var zoomStep: Int = {
    #if os(iOS)
      PhotoGridZoom.columnSteps.firstIndex(of: PhotoGridZoom.defaultColumns) ?? 3
    #else
      PhotoGridZoom.defaultStep
    #endif
  }()

  private var countSubtitle: String {
    // Takes the subtitle's line from the first frame, so the title doesn't move.
    model.map { ProductCopy.inflected("^[\($0.itemCount) Item](inflect: true)") } ?? " "
  }

  var body: some View {
    Group {
      if let model, model.itemCount > 0 {
        // The grid runs under the bottom bars, and its last row stops above them. On
        // iPhone UIKit's own safe area leaves out the floating search field.
        GeometryReader { proxy in
          PhotoGrid(
            dataSource: model, reloadToken: reloadToken, badgeToken: library.badgeToken, zoomStep: $zoomStep,
            options: PhotoGridOptions(
              dragItem: { model.viewerItem(at: $0)?.dragItem }, proxy: zoom.proxy,
              bottomInset: proxy.safeAreaInsets.bottom + 8)
          ) { index in
            zoom.open(index, in: model) { opened = index }
          }
          #if os(iOS)
            // Under the top bar too, as the collections' grids are.
            .ignoresSafeArea(edges: [.top, .bottom])
          #else
            .ignoresSafeArea(edges: .bottom)
          #endif
        }
      } else if model != nil {
        ContentUnavailableView {
          Label(
            searchQuery.map { String(localized: "No Results for “\($0)”") } ?? String(localized: "No Items"),
            systemImage: "magnifyingglass")
        } description: {
          Text("Try a person, place, date, or a different word.")
        }
      } else {
        ProgressView()
      }
    }
    .gridTitle(title, subtitle: countSubtitle, zoom: zoom)
    #if os(iOS)
      // The Mac's title shows it already.
      .navigationSubtitle(countSubtitle)
    #endif
    .task(id: ids) {
      guard let ids else { return }
      model = LibrarySubsetModel(base: library, positions: library.positions(of: ids))
      reloadToken &+= 1
    }
    .onChange(of: library.reloadToken) {
      guard let ids else { return }
      model = LibrarySubsetModel(base: library, positions: library.positions(of: ids))
      reloadToken &+= 1
    }
    .photoViewer(index: $opened, source: model, zoom: zoom)
  }
}
