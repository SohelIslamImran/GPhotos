import MapKit
import SwiftUI

/// Every photo with a location on one map, on this device or only in Google Photos,
/// grouped into pins that split apart as you zoom in. Choosing a pin opens its photos.
struct PlacesView: View {
  let cloud: CloudLibrary?
  let records: [TransferRecord]
  /// The merged library, set by each app's root view.
  @Environment(UnifiedLibraryModel.self) private var library: UnifiedLibraryModel?
  @State private var hasFramed = false
  @State private var points: [PlacePoint] = []
  @State private var clusters: [PlaceCluster] = []
  @State private var position: MapCameraPosition = .automatic
  @State private var cellDegrees = 8.0
  @State private var area: PlaceClusters.Area?
  @State private var regroupGeneration = 0
  @State private var regroupTask: Task<Void, Never>?
  @State private var isLoaded = false

  var body: some View {
    Map(position: $position) {
      ForEach(clusters) { cluster in
        Annotation("", coordinate: cluster.coordinate, anchor: .bottom) {
          NavigationLink(
            value: CollectionRoute.place(ids: cluster.idList, latitude: cluster.latitude, longitude: cluster.longitude)
          ) {
            PlacePin(cluster: cluster, library: library)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("^[\(cluster.ids.count) item](inflect: true)"))
        }
      }
    }
    .mapStyle(.standard(pointsOfInterest: .excludingAll))
    .onMapCameraChange(frequency: .onEnd) { context in
      let region = context.region
      // Cell sizes go in steps of two, so the grid (and every pin on it) stays where it
      // is until the zoom has really changed.
      cellDegrees = PlaceClusters.cellDegrees(forSpan: region.span.longitudeDelta)
      // A screen's width of margin on each side, so a short pan already has its pins.
      area = PlaceClusters.Area(
        centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
        latitudeRadius: region.span.latitudeDelta * 1.5, longitudeRadius: region.span.longitudeDelta * 1.5)
      regroupTask?.cancel()
      regroupTask = Task { await regroup() }
    }
    .onDisappear { regroupTask?.cancel() }
    .overlay {
      if !isLoaded {
        ProgressView()
      } else if points.isEmpty {
        ContentUnavailableView(
          "No Places", systemImage: "map", description: Text("Photos taken with location turned on appear here."))
      }
    }
    .navigationTitle("Places")
    .task {
      // Places works before the Library tab has been opened.
      guard let library, !library.isLoaded else { return }
      library.setCloudLibrary(cloud)
      await library.start(records: records)
    }
    .task(id: library.map { [$0.reloadToken, $0.indexMetadataToken, $0.isLoaded ? 1 : 0] }) {
      guard let library else {
        isLoaded = true
        return
      }
      let snapshot = library.indexSnapshot()
      let needsRegion = !hasFramed
      let loaded = await Task.detached(priority: .userInitiated) {
        let unfiltered = snapshot.unfiltered()
        let found = Self.points(unfiltered)
        let region = needsRegion ? PlaceClusters.region(containing: found) : nil
        return (found, region)
      }.value
      guard !Task.isCancelled else { return }
      points = loaded.0
      isLoaded = library.isLoaded
      // A fixed starting region, set once: the automatic one frames the pins again every
      // time they regroup, which moves the map, which regroups them, without end.
      if !hasFramed, let region = loaded.1 {
        hasFramed = true
        position = .region(region)
        cellDegrees = PlaceClusters.cellDegrees(forSpan: region.span.longitudeDelta)
      }
      await regroup()
    }
  }

  private func regroup() async {
    // A slower, older grouping must not land after a newer one.
    regroupGeneration &+= 1
    let generation = regroupGeneration
    let points = points
    let cell = cellDegrees
    let area = area
    let work = Task.detached(priority: .userInitiated) {
      PlaceClusters.make(points, cellDegrees: cell, area: area)
    }
    let grouped = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    if !Task.isCancelled, generation == regroupGeneration { clusters = grouped }
  }

  /// Newest first, as the timeline lists them.
  nonisolated static func points(_ snapshot: UnifiedLibraryModel.IndexSnapshot) -> [PlacePoint] {
    let moments = snapshot.moments()
    var points: [PlacePoint] = []
    // The unified timeline runs oldest first, so iterate in reverse for newest-first pins.
    for position in moments.indices.reversed() {
      let moment = moments[position]
      guard let latitude = moment.latitude, let longitude = moment.longitude, latitude != 0 || longitude != 0,
        CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
        let id = snapshot.indexID(at: position)
      else { continue }
      points.append(PlacePoint(id: id, latitude: latitude, longitude: longitude))
    }
    return points
  }
}

private struct PlacePin: View {
  let cluster: PlaceCluster
  let library: UnifiedLibraryModel?

  var body: some View {
    LibraryThumbnail(
      id: library.flatMap { library in
        cluster.ids.first.flatMap(library.position(ofIndexID:)).map(library.itemID(at:))
      }, bucket: .small, source: library?.thumbnailSource ?? PhotoKitImageSource.shared
    )
    .frame(width: 56, height: 56)
    .clipShape(.rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
    .shadow(radius: 3, y: 1)
    .overlay(alignment: .topTrailing) {
      if cluster.ids.count > 1 {
        Text(cluster.ids.count, format: .number.notation(.compactName))
          .font(.caption2.bold())
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.blue, in: .capsule)
          .offset(x: 8, y: -8)
      }
    }
    .padding(8)
  }
}

/// The photos of one map pin, titled with the place's name once it's looked up.
struct PlaceLibraryScreen: View {
  let ids: [String]
  let latitude: Double
  let longitude: Double
  @Environment(UnifiedLibraryModel.self) private var library: UnifiedLibraryModel?
  @State private var title = String(localized: "Places")

  var body: some View {
    if let library {
      ResultsGridView(title: title, library: library, ids: ids)
        .task {
          if let name = await PlaceNameCache.shared.placeName(latitude: latitude, longitude: longitude) {
            title = name
          }
        }
    }
  }
}
