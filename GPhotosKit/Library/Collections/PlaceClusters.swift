import CoreLocation
import Foundation
import MapKit

public struct PlacePoint: Sendable, Equatable {
  public let id: String
  public let latitude: Double
  public let longitude: Double

  public init(id: String, latitude: Double, longitude: Double) {
    self.id = id
    self.latitude = latitude
    self.longitude = longitude
  }
}

public struct PlaceCluster: Identifiable, Sendable, Equatable {
  public let id: String
  public let latitude: Double
  public let longitude: Double
  /// Newest first, as the points were given; compared by identity for navigation.
  public let idList: ItemIDs
  public var ids: [String] { idList.values }

  public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Groups photo locations into map pins by snapping them to a grid whose cell size
/// follows the map's zoom. Linear in the number of points, so the whole library
/// regroups in milliseconds when the map stops moving.
public enum PlaceClusters {
  /// The area pins are made for: the visible region with a margin around it.
  public struct Area: Sendable {
    public let latitudes: ClosedRange<Double>
    public let longitudes: ClosedRange<Double>

    /// Degrees each way from the center. An area crossing the antimeridian, or covering
    /// most of the globe, is not narrowed (nil).
    public init?(centerLatitude: Double, centerLongitude: Double, latitudeRadius: Double, longitudeRadius: Double) {
      guard longitudeRadius < 90, centerLongitude - longitudeRadius >= -180, centerLongitude + longitudeRadius <= 180
      else { return nil }
      latitudes = max(-90, centerLatitude - latitudeRadius)...min(90, centerLatitude + latitudeRadius)
      longitudes = (centerLongitude - longitudeRadius)...(centerLongitude + longitudeRadius)
    }

    func contains(_ point: PlacePoint) -> Bool {
      latitudes.contains(point.latitude) && longitudes.contains(point.longitude)
    }
  }

  /// Pins for the points inside `area` (all points without one). Above `limit` cells, the
  /// cells grow rather than dropping photos; only past a world-sized cell are the
  /// smallest left out.
  public static func make(_ points: [PlacePoint], cellDegrees: Double, area: Area? = nil, limit: Int = 150)
    -> [PlaceCluster]
  {
    guard cellDegrees > 0 else { return [] }
    let inside = area.map { area in points.filter(area.contains) } ?? points
    var cellDegrees = cellDegrees
    var buckets = group(inside, cellDegrees: cellDegrees)
    while buckets.count > limit, cellDegrees < 180 {
      cellDegrees *= 2
      buckets = group(inside, cellDegrees: cellDegrees)
    }
    return
      buckets
      .sorted { $0.value.ids.count > $1.value.ids.count }
      .prefix(limit)
      .map { cell, bucket in
        let count = Double(bucket.ids.count)
        // The cell size is part of the id: a pin at another zoom is another pin, not this
        // one sliding across the map.
        return PlaceCluster(
          id: "\(cellDegrees):\(cell.row):\(cell.column)", latitude: bucket.latitude / count, longitude: bucket.longitude / count,
          idList: ItemIDs(bucket.ids))
      }
  }

  /// The grid cell for a map showing `span` degrees of longitude: about a sixth of it,
  /// rounded up to a power of two.
  public static func cellDegrees(forSpan span: Double) -> Double {
    let wanted = max(span / 6, 0.0005)
    return min(pow(2, (log2(wanted)).rounded(.up)), 180)
  }

  /// The region showing where most photos were taken, with some room around them; nil
  /// without points. A few far-off photos (one trip abroad) are left out of the framing,
  /// or the box would span the world and open on the empty ocean between.
  public static func region(containing points: [PlacePoint]) -> MKCoordinateRegion? {
    guard !points.isEmpty else { return nil }
    let latitudes = points.map(\.latitude).sorted()
    let longitudes = points.map(\.longitude).sorted()
    let trim = points.count >= 20 ? points.count / 20 : 0
    let latitudeRange = latitudes[trim]...latitudes[latitudes.count - 1 - trim]
    let longitudeRange = longitudes[trim]...longitudes[longitudes.count - 1 - trim]
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (latitudeRange.lowerBound + latitudeRange.upperBound) / 2,
        longitude: (longitudeRange.lowerBound + longitudeRange.upperBound) / 2),
      span: MKCoordinateSpan(
        latitudeDelta: min(max((latitudeRange.upperBound - latitudeRange.lowerBound) * 1.3, 0.02), 170),
        longitudeDelta: min(max((longitudeRange.upperBound - longitudeRange.lowerBound) * 1.3, 0.02), 350)))
  }

  private struct Bucket {
    var latitude = 0.0
    var longitude = 0.0
    var ids: [String] = []
  }

  private struct Cell: Hashable {
    let row: Int
    let column: Int
  }

  private static func group(_ points: [PlacePoint], cellDegrees: Double) -> [Cell: Bucket] {
    var buckets: [Cell: Bucket] = [:]
    for point in points {
      let cell = Cell(
        row: Int((point.latitude / cellDegrees).rounded(.down)), column: Int((point.longitude / cellDegrees).rounded(.down)))
      buckets[cell, default: Bucket()].latitude += point.latitude
      buckets[cell, default: Bucket()].longitude += point.longitude
      buckets[cell, default: Bucket()].ids.append(point.id)
    }
    return buckets
  }
}
