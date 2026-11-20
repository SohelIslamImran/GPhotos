import SwiftUI

/// The grid's filter menu, laid out as Photos' is: the main filters, Media Types in a
/// submenu, then View Options (zoom, and which items show).
struct LibraryFilterMenu: View {
  let filter: LibraryFilter
  let filters: [LibraryFilter]
  let select: (LibraryFilter) -> Void
  /// Zoom In and Zoom Out, where the toolbar doesn't already have them (iPhone).
  var zoom: ((_ closer: Bool) -> Void)?
  var showsScreenshots: Binding<Bool>?

  var body: some View {
    Menu {
      // Checkmark toggles rather than an inline picker, which would hide the heading.
      Section("Filter:") {
        ForEach(filters, id: \.self) { item in
          Toggle(isOn: Binding(get: { filter == item }, set: { _ in select(item) })) {
            Label(item.title, systemImage: item.symbol)
          }
        }
      }
      Picker(selection: selection) {
        ForEach(LibraryFilter.mediaTypes, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
      } label: {
        Label("Media Types", systemImage: "photo.on.rectangle.angled")
      }
      .pickerStyle(.menu)
      if zoom != nil || showsScreenshots != nil {
        Menu("View Options") {
          if let zoom {
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom(true) }
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(false) }
          }
          if let showsScreenshots {
            Section("Show:") {
              Toggle(isOn: showsScreenshots) { Label("Screenshots", systemImage: "camera.viewfinder") }
            }
          }
        }
      }
    } label: {
      Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
    }
  }

  /// A media type chosen again goes back to All Items, as a checked item does in Photos.
  private var selection: Binding<LibraryFilter> {
    Binding(get: { filter }, set: { select($0 == filter && $0.isMediaType ? .all : $0) })
  }
}
